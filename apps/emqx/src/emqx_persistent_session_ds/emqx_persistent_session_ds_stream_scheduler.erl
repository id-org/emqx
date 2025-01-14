%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Stream scheduler is a helper module used by durable sessions
%% to track states of the DS streams (Stream Replay States, or SRS for
%% short). It has two main duties:
%%
%% - It manages DS subscriptions.
%%
%% - It keeps track of stream block states.
%%
%% - It accumulates new stream notifications, tracks stream ranks, and
%% advances generations.
%%
%% - During session reconnect, it returns the list of SRS that must be
%% replayed in order.
%%
%% ** Blocked streams
%%
%% For performance reasons we keep only one record of in-flight
%% messages per stream, and we don't want to overwrite these records
%% prematurely.
%%
%% ** Stream state machine
%%
%% During normal operation, state of each stream can be described as a
%% FSM.
%%
%% There are the following stream replay states:
%%
%% - *(P)ending*: stream belongs to a newer generation that can not be
%% replayed yet.
%%
%% - *(R)eady*: stream is not blocked. Messages from such streams can
%% be enqueued directly to inflight.
%%
%% - *BQ1*, *BQ2* and *BQ12*: stream is blocked by un-acked QoS1, QoS2
%% or QoS1&2 messages respectively. Such streams are stored in
%% `#s.bq1' or `#s.bq2' buckets (or both).
%%
%% - *(U)ndead*: zombie streams that are kept for historical reasons
%% only. For example, streams for unsubcribed topics can linger in the
%% session state for a while until all queued messages are acked, as
%% well as streams that reached `end_of_stream'. This state is
%% implicit: undead streams are simply removed from all buckets.
%% Undead streams are ignored by the scheduler until the moment they
%% can be garbage-collected. So this is a terminal state. Even if the
%% client resubscribes, it will produce a new, totally separate set of
%% SRS.
%%
%% *** State transitions
%%
%% New streams start in *Ready* or *Pending* state, depending on their
%% rank Y, from which they follow one of these paths:
%%
%% *P* --(`renew_streams') --> *R* -> ...
%%    \
%%     `--(`on_unsubscribe') --> *U*
%%
%% Upon receiving a `poll_reply' for a *ready* stream, session assigns
%% QoS and sequence numbers to the  messages according to its own
%% logic, and enqueues batch to the buffer. Then it returns the
%% updated SRS back to the scheduler, where it can undergo the
%% following transitions:
%%
%%        ,--(`on_unsubscribe')--> *U*
%%       /
%%      /--(only QoS0 messages in the batch)--> *R* --> ...
%%     /
%% *R* --([QoS0] & QoS1 messages)--> *BQ1* --> ...
%%    \
%%     \--([QoS0] & QoS2 messages)--> *BQ2* --> ...
%%      \
%%       \--([QoS0] & QoS1 & QoS2)--> *BQ12* --> ...
%%        \
%%         `--(`end_of_stream')--> *U*
%%
%%
%% *BQ1* and *BQ2* are handled similarly. They transition to *Ready*
%% once session calls `?MODULE:on_seqno_release' for the corresponding
%% QoS track and sequence number equal to the SRS's last sequence
%% number for the track:
%%
%% *BQX* --(`?MODULE:on_seqno_release(?QOS_X, LastSeqNoX)')--> *R* --> ...
%%      \
%%       `--(`on_unsubscribe')--> *U*
%%
%% *BQ12* is handled like this:
%%
%%        .--(`on_seqno_release(?QOS_1, LastSeqNo1)')--> *BQ2* --> ...
%%       /
%% *BQ12*--(`on_unsubscribe')--> *U*
%%       \
%%        `--(`on_seqno_release(?QOS_2, LastSeqNo2)')--> *BQ1* --> ...
%%
%%
-module(emqx_persistent_session_ds_stream_scheduler).

%% API:
-export([
    init/1,
    on_subscribe/4,
    on_unsubscribe/4,
    on_new_stream_event/3,
    verify_reply/2,
    suback/3,
    on_enqueue/5,
    on_seqno_release/4,
    find_replay_streams/1,
    is_fully_acked/2,
    is_active_unblocked/2,
    gc/1
]).

%% internal exports:
-export([]).

-ifdef(TEST).
-export([
    runtime_state_invariants/2,
    offline_state_invariants/2
]).
-endif.

-export_type([t/0, stream_key/0, srs/0, ret/0]).

-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx_durable_storage/include/emqx_ds.hrl").
-include("emqx_mqtt.hrl").
-include("session_internals.hrl").

-ifdef(TEST).
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/assert.hrl").
-endif.

%%================================================================================
%% Type declarations
%%================================================================================

-type stream_key() :: {emqx_persistent_session_ds:subscription_id(), emqx_ds:stream()}.

-type ret() :: {[stream_key()], emqx_persistent_session_ds_state:t(), t()}.

-type srs() :: #srs{}.

-record(block, {
    id :: stream_key(),
    last_seqno_qos1 :: emqx_persistent_session_ds:seqno(),
    last_seqno_qos2 :: emqx_persistent_session_ds:seqno()
}).

-type block() :: #block{}.

-type blocklist() :: gb_trees:tree(emqx_persistent_session_ds:seqno(), block()).

-type new_stream_subs() :: #{
    emqx_ds_new_streams:watch() => emqx_persistent_session_ds:topic_filter()
}.

-type stream_map() :: #{emqx_ds:rank_x() => [{emqx_ds:rank_y(), emqx_ds:stream()}]}.

%% Subscription-specific state:
-record(sub_metadata, {
    subid :: emqx_persistent_session_ds:subscription_id(),
    %% Cache of streams pending for future replay (essentially,
    %% these are streams that have y-rank greater than the
    %% currently active y-rank for x-rank):
    pending_streams = #{} :: stream_map(),
    %% Back-reference to the new stream watch:
    new_streams_watch = emqx_ds_new_streams:watch()
}).

-type sub_metadata() :: #sub_metadata{}.

-record(ds_sub, {
    handle :: emqx_ds:subscription_handle(),
    sub_ref :: reference(),
    seqno = 0 :: emqx_ds:sub_seqno()
}).

-type ds_sub() :: #ds_sub{}.

-record(s, {
    %% Lookup table that maps new stream watch ID to topic filter:
    new_stream_subs = #{} :: new_stream_subs(),
    %% Per-topic metadata records:
    sub_metadata = #{} :: #{emqx_types:topic() => sub_metadata()},
    %% DS subscriptions:
    ds_subs = #{} :: #{stream_key() => ds_sub()},
    %% Block queues:
    bq1 :: blocklist(),
    bq2 :: blocklist()
}).

-opaque t() :: #s{}.

-type state() :: p | r | bq1 | bq2 | bq12 | u.

%%================================================================================
%% API functions
%%================================================================================

-spec init(emqx_persistent_session_ds_state:t()) -> {emqx_persistent_session_ds_state:t(), t()}.
init(S0) ->
    SchedS0 = #s{
        bq1 = gb_trees:empty(),
        bq2 = gb_trees:empty()
    },
    %% Initialize per-subscription records:
    {S, SchedS1} = emqx_persistent_session_ds_subs:fold_private_subscriptions(
        fun(TopicFilterBin, Subscription, {AccS0, AccSchedS0}) ->
            {_NewSRSIds, AccS, AccSchedS} = init_for_subscription(
                TopicFilterBin, Subscription, AccS0, AccSchedS0
            ),
            {AccS, AccSchedS}
        end,
        {S0, SchedS0},
        S0
    ),
    %% Subscribe to new messages:
    ActiveStreams = find_active_streams(S),
    SchedS2 = SchedS1#s{ds_subs = ds_subscribe(ActiveStreams, S, #{})},
    %% Restore stream states.
    %%
    %% Note: these states are NOT used during replay.
    Comm1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S0),
    Comm2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S0),
    SchedS = emqx_persistent_session_ds_state:fold_streams(
        fun(Key, Srs, Acc) ->
            ?tp(?sessds_stream_state_trans, #{key => Key, to => '$restore'}),
            case derive_state(Comm1, Comm2, Srs) of
                r ->
                    ?tp(?sessds_stream_state_trans, #{key => Key, to => r, from => '$restore'}),
                    Acc;
                u ->
                    ?tp(?sessds_stream_state_trans, #{key => Key, to => u, from => '$restore'}),
                    Acc;
                bq1 ->
                    to_BQ1(Key, Srs, Acc);
                bq2 ->
                    to_BQ2(Key, Srs, Acc);
                bq12 ->
                    to_BQ12(Key, Srs, Acc)
            end
        end,
        SchedS2,
        S
    ),
    {S, SchedS}.

-spec find_active_streams(emqx_persistent_session_ds_state:t()) -> [stream_key()].
find_active_streams(S) ->
    emqx_persistent_session_ds_state:fold_streams(
        fun(Key, SRS, Acc) ->
            case SRS of
                #srs{unsubscribed = true} -> Acc;
                #srs{it_end = end_of_stream} -> Acc;
                #srs{} -> [Key | Acc]
            end
        end,
        [],
        S
    ).

%% @doc Find the streams that have unacked (in-flight) messages.
%% Return them in the order they were previously replayed.
-spec find_replay_streams(emqx_persistent_session_ds_state:t()) ->
    [{stream_key(), emqx_persistent_session_ds:stream_state()}].
find_replay_streams(S) ->
    Comm1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S),
    Comm2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S),
    %% 1. Find the streams that aren't fully acked
    Streams = emqx_persistent_session_ds_state:fold_streams(
        fun(Key, Stream, Acc) ->
            case is_fully_acked(Comm1, Comm2, Stream) of
                false ->
                    [{Key, Stream} | Acc];
                true ->
                    Acc
            end
        end,
        [],
        S
    ),
    lists:sort(fun compare_streams/2, Streams).

%% @doc DS notified us about new streams.
-spec on_new_stream_event(emqx_ds_new_streams:watch(), emqx_persistent_session_ds_state:t(), t()) ->
    ret().
on_new_stream_event(Ref, S0, SchedS0 = #s{sub_metadata = SubsMetadata}) ->
    case SchedS0#s.new_stream_subs of
        #{Ref := TopicFilterBin} ->
            #{TopicFilterBin := SubS0} = SubsMetadata,
            ?tp(?sessds_sched_new_stream_event, #{ref => Ref, topic => TopicFilterBin}),
            TopicFilter = emqx_topic:words(TopicFilterBin),
            Subscription =
                #{start_time := StartTime} = emqx_persistent_session_ds_state:get_subscription(
                    TopicFilterBin, S0
                ),
            %% Renew streams:
            StreamMap = get_streams(TopicFilter, StartTime),
            {NewSRSIds, S, SubS} = renew_streams(S0, TopicFilter, Subscription, StreamMap, SubS0),
            %% Update state:
            SchedS = SchedS0#s{
                sub_metadata = SubsMetadata#{TopicFilterBin := SubS},
                ds_subs = ds_subscribe(NewSRSIds, S, SchedS0#s.ds_subs)
            },
            {NewSRSIds, S, SchedS};
        _ ->
            ?tp(warning, ?sessds_unexpected_stream_notification, #{ref => Ref}),
            {[], S0, SchedS0}
    end.

%% @doc Verify sequence number of DS subscription reply
verify_reply(Reply, SchedS) ->
    #poll_reply{ref = Ref, userdata = StreamKey, size = Size, seqno = SeqNo} = Reply,
    #s{ds_subs = DSSubs0} = SchedS,
    DSSubState = maps:get(StreamKey, DSSubs0, undefined),
    case DSSubState of
        #ds_sub{seqno = PrevSeenSeqNo, sub_ref = Ref} when
            PrevSeenSeqNo + Size =:= SeqNo
        ->
            DSSubs = DSSubs0#{StreamKey := DSSubState#ds_sub{seqno = SeqNo}},
            {true, SchedS#s{ds_subs = DSSubs}};
        _ ->
            ?tp(warning, ?sessds_unexpected_reply, #{
                stream => StreamKey,
                batch_seqno => SeqNo,
                batch_size => Size,
                sub_state => DSSubState,
                sub_ref => Ref,
                stuck => Reply#poll_reply.stuck,
                lagging => Reply#poll_reply.lagging
            }),
            %% FIXME: re-subscribe if anything is mismatched
            {false, SchedS}
    end.

suback(StreamKey, SeqNo, #s{ds_subs = Subs}) ->
    case Subs of
        #{StreamKey := #ds_sub{handle = Ref}} ->
            emqx_ds:suback(?PERSISTENT_MESSAGE_DB, Ref, SeqNo);
        #{} ->
            ok
    end.

-spec on_enqueue(
    _IsReplay :: boolean(), stream_key(), srs(), emqx_persistent_session_ds_state:t(), t()
) ->
    ret().
on_enqueue(true, _Key, _SRS, S, SchedS) ->
    {[], S, SchedS};
on_enqueue(false, Key, SRS, S0, SchedS0) ->
    %% Drop DS subscription when encounter end_of_stream:
    SchedS =
        case SRS of
            #srs{it_end = end_of_stream} ->
                ds_unsubscribe(Key, SchedS0);
            _ ->
                SchedS0
        end,
    %% Is the stream blocked?
    Comm1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S0),
    Comm2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S0),
    case derive_state(Comm1, Comm2, SRS) of
        r ->
            ?tp(?sessds_stream_state_trans, #{key => Key, to => r, from => r}),
            {[Key], S0, SchedS};
        bq1 ->
            {[], S0, to_BQ1(Key, SRS, SchedS)};
        bq2 ->
            {[], S0, to_BQ2(Key, SRS, SchedS)};
        bq12 ->
            {[], S0, to_BQ12(Key, SRS, SchedS)};
        u ->
            %% Handle a special case: session just enqueued the last
            %% batch at the end of a stream, that contained only QoS0
            %% messages. Since no acks are expected for this batch, we
            %% should attempt to advance generation now:
            ?tp(?sessds_stream_state_trans, #{key => Key, to => u, from => r}),
            on_stream_unblock(Key, SRS, S0, SchedS)
    end.

-spec on_seqno_release(
    ?QOS_1 | ?QOS_2, emqx_persistent_session_ds:seqno(), emqx_persistent_session_ds_state:t(), t()
) -> ret().
on_seqno_release(?QOS_1, SnQ1, S, SchedS0 = #s{bq1 = PrimaryTab0, bq2 = SecondaryTab}) ->
    case check_block_status(PrimaryTab0, SecondaryTab, SnQ1, #block.last_seqno_qos2) of
        false ->
            %% This seqno doesn't unlock anything:
            {[], S, SchedS0};
        {false, Key, PrimaryTab} ->
            %% It was BQ1:
            Srs = emqx_persistent_session_ds_state:get_stream(Key, S),
            on_stream_unblock(Key, Srs, S, SchedS0#s{bq1 = PrimaryTab});
        {true, Key, PrimaryTab} ->
            %% It was BQ12:
            ?tp(?sessds_stream_state_trans, #{
                key => Key,
                to => bq2,
                from => bq12
            }),
            {[], S, SchedS0#s{bq1 = PrimaryTab}}
    end;
on_seqno_release(?QOS_2, SnQ2, S, SchedS0 = #s{bq2 = PrimaryTab0, bq1 = SecondaryTab}) ->
    case check_block_status(PrimaryTab0, SecondaryTab, SnQ2, #block.last_seqno_qos1) of
        false ->
            %% This seqno doesn't unlock anything:
            {[], S, SchedS0};
        {false, Key, PrimaryTab} ->
            %% It was BQ2:
            Srs = emqx_persistent_session_ds_state:get_stream(Key, S),
            on_stream_unblock(Key, Srs, S, SchedS0#s{bq2 = PrimaryTab});
        {true, Key, PrimaryTab} ->
            %% It was BQ12:
            ?tp(?sessds_stream_state_trans, #{
                key => Key,
                to => bq1,
                from => bq12
            }),
            {[], S, SchedS0#s{bq2 = PrimaryTab}}
    end.

check_block_status(PrimaryTab0, SecondaryTab, PrimaryKey, SecondaryIdx) ->
    case gb_trees:take_any(PrimaryKey, PrimaryTab0) of
        error ->
            false;
        {Block = #block{id = StreamKey}, PrimaryTab} ->
            StillBlocked =
                case gb_trees:lookup(element(SecondaryIdx, Block), SecondaryTab) of
                    {value, #block{id = StreamKey}} ->
                        %% The same stream is also present
                        %% in the secondary table:
                        true;
                    _ ->
                        %% `none' or `{value, _Other}':
                        false
                end,
            {StillBlocked, StreamKey, PrimaryTab}
    end.

-spec on_stream_unblock(stream_key(), srs(), emqx_persistent_session_ds_state:t(), t()) ->
    {[stream_key(), ...], emqx_persistent_session_ds_state:t(), t()}.
on_stream_unblock(Key = {SubId, _}, #srs{it_end = end_of_stream, rank_x = RankX}, S0, SchedS0) ->
    %% We've reached end of the stream. We might advance generation
    %% now:
    ?tp(?sessds_stream_state_trans, #{key => Key, to => u, from => bx, eos => true}),
    {Keys, S, SchedS} = renew_streams_for_x(S0, SubId, RankX, SchedS0),
    %% TODO: Reporting this key as unblocked for compatibility with
    %% shared_sub. This should not be needed.
    {[Key | Keys], S, SchedS};
on_stream_unblock(Key, _SRS, S, SchedS) ->
    ?tp(?sessds_stream_state_trans, #{key => Key, to => r, from => bx}),
    {[Key], S, SchedS}.

%% @doc Batch operation to clean up historical streams.
%%
%% 1. Remove fully replayed streams for past generations.
%%
%% 2. Remove unblocked streams for deleted subscriptions.
-spec gc(emqx_persistent_session_ds_state:t()) ->
    emqx_persistent_session_ds_state:t().
gc(S) ->
    CommQos1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S),
    CommQos2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S),
    emqx_persistent_session_ds_state:fold_streams(
        fun(Key, SRS, Acc) ->
            maybe_drop_stream(CommQos1, CommQos2, Key, SRS, Acc)
        end,
        S,
        S
    ).

-spec on_subscribe(
    emqx_types:topic(),
    emqx_persistent_session_ds:subscription(),
    emqx_persistent_session_ds_state:t(),
    t()
) ->
    ret().
on_subscribe(TopicFilterBin, Subscription, S0, SchedS0 = #s{sub_metadata = Subs}) ->
    case Subs of
        #{TopicFilterBin := _} ->
            %% Already subscribed:
            {[], S0, SchedS0};
        _ ->
            init_for_subscription(
                TopicFilterBin, Subscription, S0, SchedS0
            )
    end.

%% @doc Makes stream scheduler forget about a subscription.
%%
%% Side effects:
%%
%% 1. Unsubscribe from the new stream events for the topic-filter.
%%
%% 2. Set `unsubscribed' flag on SRS records that belong to the subscription
%%
%% 3. Remove streams from the buckets
-spec on_unsubscribe(
    emqx_types:topic(),
    emqx_persistent_session_ds:subscription_id(),
    emqx_persistent_session_ds_state:t(),
    t()
) ->
    {emqx_persistent_session_ds_state:t(), t()}.
on_unsubscribe(
    TopicFilterBin, SubId, S0, SchedS0 = #s{new_stream_subs = Watches0, sub_metadata = Subs}
) ->
    #{TopicFilterBin := SubS} = Subs,
    #sub_metadata{new_streams_watch = Ref} = SubS,
    %% Unsubscribe from new stream notifications:
    Watches = unwatch_streams(TopicFilterBin, Ref, Watches0),
    SchedS1 = SchedS0#s{
        new_stream_subs = Watches,
        sub_metadata = maps:remove(TopicFilterBin, Subs)
    },
    %% NOTE: this function only marks streams for deletion, but
    %% it doesn't outright delete them.
    %%
    %% It's done for two reasons:
    %%
    %% - MQTT standard states that the broker MUST process acks for
    %% all sent messages, and it MAY keep on sending buffered
    %% messages:
    %% https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901186
    %%
    %% - Deleting the streams may lead to gaps in the sequence number
    %% series, and lead to problems with acknowledgement tracking, we
    %% avoid that by delaying the deletion.
    %%
    %% When the stream is marked for deletion, the session won't fetch
    %% _new_ batches from it. Actual deletion is done by `gc', when it
    %% detects that all in-flight messages from the stream have been
    %% acked by the client.
    emqx_persistent_session_ds_state:fold_streams(
        SubId,
        fun(Stream, SRS, {SAcc, SchedSAcc}) ->
            unsubscribe_stream({SubId, Stream}, SRS, SAcc, SchedSAcc)
        end,
        {S0, SchedS1},
        S0
    ).

-spec is_fully_acked(
    emqx_persistent_session_ds:stream_state(), emqx_persistent_session_ds_state:t()
) -> boolean().
is_fully_acked(Srs, S) ->
    CommQos1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S),
    CommQos2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S),
    is_fully_acked(CommQos1, CommQos2, Srs).

-spec is_active_unblocked(srs() | undefined, emqx_persistent_session_ds_state:t()) -> boolean().
is_active_unblocked(undefined, _S) ->
    false;
is_active_unblocked(#srs{unsubscribed = true}, _S) ->
    false;
is_active_unblocked(SRS, S) ->
    is_fully_acked(SRS, S).

%%================================================================================
%% Internal functions
%%================================================================================

%% @doc Side effects:
%%
%% 1. Subscribe to new stream events
%%
%% 2. Get streams from DS
%%
%% 3. Create iterators and SRS records for the streams from the first
%% applicable generation
%%
%% 4. Mark new streams as ready
-spec init_for_subscription(
    emqx_types:topic(),
    emqx_persistent_session_ds_subs:subscription(),
    emqx_persistent_session_ds_state:t(),
    t()
) ->
    ret().
init_for_subscription(
    TopicFilterBin,
    Subscription,
    S0,
    SchedS0 = #s{new_stream_subs = NewStreamSubs, sub_metadata = SubMetadata, ds_subs = Subs}
) ->
    #{id := SubId, start_time := StartTime} = Subscription,
    TopicFilter = emqx_topic:words(TopicFilterBin),
    %% Start watching the streams immediately:
    NewStreamsWatch = watch_streams(TopicFilter),
    %% Create the initial record for subscription:
    SubState0 = #sub_metadata{
        subid = SubId,
        new_streams_watch = NewStreamsWatch
    },
    %% Renew streams:
    StreamMap = get_streams(TopicFilter, StartTime),
    {NewSRSIds, S, SubState} = renew_streams(
        S0, TopicFilter, Subscription, StreamMap, SubState0
    ),
    %% Update the accumulator:
    SchedS = SchedS0#s{
        new_stream_subs = NewStreamSubs#{NewStreamsWatch => TopicFilterBin},
        sub_metadata = SubMetadata#{TopicFilterBin => SubState},
        ds_subs = ds_subscribe(NewSRSIds, S, Subs)
    },
    {NewSRSIds, S, SchedS}.

%% @doc This function makes the session aware of the new streams.
%%
%% It has the following properties:
%%
%% 1. For each RankX, it schedules only the streams with the same
%% RankY.
%%
%% 2. For each RankX, it never advances RankY until _all_ streams with
%% the same RankX are replayed.
%%
%% 3. Once all streams with the given rank are replayed, it advances
%% the RankY to the smallest known RankY that is greater than replayed
%% RankY.
%%
%% 4. If the RankX is seen for the first time, it selects the streams
%% with the smallest RankY.
%%
%% This way, messages from the same topic/shard are never reordered.
-spec renew_streams(
    emqx_persistent_session_ds_state:t(),
    emqx_ds:topic_filter(),
    emqx_persistent_session_ds_subs:subscription(),
    stream_map(),
    sub_metadata()
) ->
    {[stream_key()], emqx_persistent_session_ds_state:t(), sub_metadata()}.
renew_streams(S0, TopicFilter, Subscription, StreamMap, SubState0) ->
    ?tp(?sessds_sched_renew_streams, #{topic_filter => TopicFilter}),
    {NewSRSIds, S, Pending} =
        maps:fold(
            fun(RankX, YStreamL, {AccNewSRSIds, AccS0, AccPendingStreams}) ->
                {NewSRSIds, AccS, Pending} = do_renew_streams_for_x(
                    AccS0, TopicFilter, Subscription, RankX, YStreamL
                ),
                {
                    NewSRSIds ++ AccNewSRSIds,
                    AccS,
                    AccPendingStreams#{RankX => Pending}
                }
            end,
            {[], S0, #{}},
            StreamMap
        ),
    SubState = SubState0#sub_metadata{pending_streams = Pending},
    ?tp(
        debug,
        ?sessds_sched_renew_streams_result,
        #{
            topic => TopicFilter,
            all_streams => StreamMap,
            new => NewSRSIds,
            sub_state => SubState
        }
    ),
    {NewSRSIds, S, SubState}.

-spec renew_streams_for_x(
    emqx_persistent_session_ds_state:t(),
    emqx_persistent_session_ds:subscription_id(),
    emqx_ds:rank_x(),
    t()
) ->
    ret().
renew_streams_for_x(S0, SubId, RankX, SchedS0 = #s{sub_metadata = SubMeta0, ds_subs = Subs}) ->
    case find_subscription_by_subid(SubId, maps:iterator(SubMeta0)) of
        {TopicFilterBin, SubS0} ->
            case emqx_persistent_session_ds_state:get_subscription(TopicFilterBin, S0) of
                undefined ->
                    {[], S0, SchedS0};
                Subscription ->
                    TopicFilter = emqx_topic:words(TopicFilterBin),
                    #sub_metadata{pending_streams = Cache} = SubS0,
                    #{RankX := Pending0} = Cache,
                    {NewSRSIds, S, Pending} = do_renew_streams_for_x(
                        S0, TopicFilter, Subscription, RankX, Pending0
                    ),
                    SubS = SubS0#sub_metadata{pending_streams = Cache#{RankX => Pending}},
                    SchedS = SchedS0#s{
                        sub_metadata = SubMeta0#{TopicFilterBin := SubS},
                        ds_subs = ds_subscribe(NewSRSIds, S, Subs)
                    },
                    {NewSRSIds, S, SchedS}
            end;
        undefined ->
            {[], S0, SchedS0}
    end.

-spec do_renew_streams_for_x(
    emqx_persistent_session_ds_state:t(),
    emqx_ds:topic_filter(),
    emqx_persistent_session_ds_subs:subscription(),
    emqx_ds:rank_x(),
    [{emqx_ds:rank_y(), emqx_ds:stream()}]
) ->
    {[stream_key()], emqx_persistent_session_ds_state:t(), [{emqx_ds:rank_y(), emqx_ds:stream()}]}.
do_renew_streams_for_x(S0, TopicFilter, Subscription = #{id := SubId}, RankX, YStreamL) ->
    CommQos1 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_1), S0),
    CommQos2 = emqx_persistent_session_ds_state:get_seqno(?committed(?QOS_2), S0),
    ReplayedRankY = emqx_persistent_session_ds_state:get_rank({SubId, RankX}, S0),
    %% 1. Scan the list of streams returned from DS (or from the local
    %% stream cache) to find new streams, as well as y-rank of the
    %% generation that can be scheduled for replay:
    {DiscoveredStreams, CurrentY} =
        lists:foldl(
            fun
                ({Y, _}, Acc) when is_integer(ReplayedRankY) andalso Y =< ReplayedRankY ->
                    %% This stream belongs to a generation that we
                    %% marked as fully replayed. Ignore it:
                    Acc;
                ({Y, Stream}, {AccPendingStreams, AccMinUnreplayed}) ->
                    case emqx_persistent_session_ds_state:get_stream({SubId, Stream}, S0) of
                        undefined ->
                            %% We've never seen this stream:
                            {[{Y, Stream} | AccPendingStreams], min(Y, AccMinUnreplayed)};
                        SRS ->
                            case is_fully_replayed(CommQos1, CommQos2, SRS) of
                                true ->
                                    %% This is a known stream that has
                                    %% been fully replayed:
                                    {AccPendingStreams, AccMinUnreplayed};
                                false ->
                                    %% This is a known in-progress
                                    %% stream:
                                    {AccPendingStreams, min(Y, AccMinUnreplayed)}
                            end
                    end
            end,
            %% According to the Erlang term order, atom `undefined' is
            %% less than any integer y-rank:
            {[], undefined},
            YStreamL
        ),
    %% 2. Select newly discovered streams that belong to the current
    %% generation and ensure all of them have an iterator:
    lists:foldl(
        fun
            ({RankY, Stream}, {AccNewSRSIds, AccS0, AccPendingStreams}) when
                RankY =:= CurrentY
            ->
                {NewSRSIds, AccS} = make_iterator(
                    TopicFilter, Subscription, {{RankX, RankY}, Stream}, AccS0
                ),
                {NewSRSIds ++ AccNewSRSIds, AccS, AccPendingStreams};
            (I = {_, Stream}, {AccNewSRSIds, AccS, AccPendingStreams}) ->
                ?tp(?sessds_stream_state_trans, #{key => {SubId, Stream}, to => p}),
                {AccNewSRSIds, AccS, [I | AccPendingStreams]}
        end,
        {[], S0, []},
        DiscoveredStreams
    ).

-spec get_streams(emqx_ds:topic_filter(), emqx_ds:time()) -> stream_map().
get_streams(TopicFilter, StartTime) ->
    L = emqx_ds:get_streams(?PERSISTENT_MESSAGE_DB, TopicFilter, StartTime),
    maps:groups_from_list(
        fun({{RankX, _}, _}) -> RankX end,
        fun({{_, RankY}, Stream}) -> {RankY, Stream} end,
        L
    ).

%% @doc Set `unsubscribed' flag and remove stream from the buckets
unsubscribe_stream(Key, SRS0 = #srs{}, S, SchedS) ->
    SRS = SRS0#srs{unsubscribed = true},
    ?tp(?sessds_stream_state_trans, #{key => Key, to => u, from => x}),
    {
        emqx_persistent_session_ds_state:put_stream(Key, SRS, S),
        bq_drop(Key, SRS, ds_unsubscribe(Key, SchedS))
    }.

maybe_drop_stream(CommQos1, CommQos2, Key, SRS = #srs{unsubscribed = true}, S) ->
    %% This stream belongs to an unsubscribed topic:
    case is_fully_acked(CommQos1, CommQos2, SRS) of
        true ->
            ?SLOG(debug, #{
                msg => sessds_del_stream,
                reason => unsubscribed,
                key => Key
            }),
            emqx_persistent_session_ds_state:del_stream(Key, S);
        false ->
            S
    end;
maybe_drop_stream(
    _CommQos1,
    _CommQos2,
    Key = {SubId, _Stream},
    #srs{rank_x = RankX, rank_y = RankY, it_end = end_of_stream},
    S
) ->
    %% This is a fully replayed stream:
    case emqx_persistent_session_ds_state:get_rank({SubId, RankX}, S) of
        undefined ->
            S;
        MinRankY when RankY =< MinRankY ->
            %% 1. Remove fully replayed streams:
            ?SLOG(debug, #{
                msg => sessds_del_stream,
                reason => fully_replayed,
                key => Key,
                rank => {RankX, RankY},
                min => MinRankY
            }),
            emqx_persistent_session_ds_state:del_stream(Key, S);
        _ ->
            S
    end;
maybe_drop_stream(_CommQos1, _CommQos2, _Key, _SRS, S) ->
    S.

find_subscription_by_subid(SubId, It0) ->
    case maps:next(It0) of
        {TopicFilterBin, SubS = #sub_metadata{subid = SubId}, _It} ->
            {TopicFilterBin, SubS};
        {_, _, It} ->
            find_subscription_by_subid(SubId, It);
        none ->
            undefined
    end.

%%--------------------------------------------------------------------------------
%% DS subscription management
%%--------------------------------------------------------------------------------

ds_subscribe([], _S, Subs) ->
    Subs;
ds_subscribe([SrsID | Rest], S, Subs) ->
    case Subs of
        #{SrsID := _} ->
            ds_subscribe(Rest, S, Subs);
        _ ->
            #srs{it_end = It} = emqx_persistent_session_ds_state:get_stream(SrsID, S),
            %% FIXME: don't hardcode max_unacked
            {ok, Handle, SubRef} = emqx_ds:subscribe(?PERSISTENT_MESSAGE_DB, SrsID, It, #{
                max_unacked => 100
            }),
            ?tp(debug, ?sessds_sched_subscribe, #{stream => SrsID, ref => Handle}),
            ds_subscribe(Rest, S, Subs#{SrsID => #ds_sub{handle = Handle, sub_ref = SubRef}})
    end.

ds_unsubscribe(SrsID, SchedS = #s{ds_subs = Subs}) ->
    case Subs of
        #{SrsID := #ds_sub{handle = SubRef}} ->
            emqx_ds:unsubscribe(?PERSISTENT_MESSAGE_DB, SubRef),
            ?tp(debug, ?sessds_sched_unsubscribe, #{stream => SrsID, ref => SubRef}),
            SchedS#s{ds_subs = maps:remove(SrsID, Subs)};
        #{} ->
            SchedS
    end.

%%--------------------------------------------------------------------------------
%% SRS FSM
%%--------------------------------------------------------------------------------

-spec derive_state(
    emqx_persistent_session_ds:seqno(), emqx_persistent_session_ds:seqno(), srs()
) -> state().
derive_state(_, _, #srs{unsubscribed = true}) ->
    u;
derive_state(Comm1, Comm2, SRS) ->
    case is_fully_replayed(Comm1, Comm2, SRS) of
        true ->
            u;
        false ->
            case {is_track_acked(?QOS_1, Comm1, SRS), is_track_acked(?QOS_2, Comm2, SRS)} of
                {true, true} -> r;
                {false, true} -> bq1;
                {true, false} -> bq2;
                {false, false} -> bq12
            end
    end.

-spec to_BQ1(stream_key(), srs(), t()) -> t().
to_BQ1(Key, SRS, S = #s{bq1 = BQ1}) ->
    ?tp(?sessds_stream_state_trans, #{
        key => Key,
        to => bq1
    }),
    Block = #block{last_seqno_qos1 = SN1} = block_of_srs(Key, SRS),
    S#s{bq1 = gb_trees:insert(SN1, Block, BQ1)}.

-spec to_BQ2(stream_key(), srs(), t()) -> t().
to_BQ2(Key, SRS, S = #s{bq2 = BQ2}) ->
    ?tp(?sessds_stream_state_trans, #{
        key => Key,
        to => bq2
    }),
    Block = #block{last_seqno_qos2 = SN2} = block_of_srs(Key, SRS),
    S#s{bq2 = gb_trees:insert(SN2, Block, BQ2)}.

-spec to_BQ12(stream_key(), srs(), t()) -> t().
to_BQ12(Key, SRS, S = #s{bq1 = BQ1, bq2 = BQ2}) ->
    ?tp(?sessds_stream_state_trans, #{
        key => Key,
        to => bq12
    }),
    Block = #block{last_seqno_qos1 = SN1, last_seqno_qos2 = SN2} = block_of_srs(Key, SRS),
    S#s{bq1 = gb_trees:insert(SN1, Block, BQ1), bq2 = gb_trees:insert(SN2, Block, BQ2)}.

-spec block_of_srs(stream_key(), srs()) -> block().
block_of_srs(Key, #srs{last_seqno_qos1 = SN1, last_seqno_qos2 = SN2}) ->
    #block{id = Key, last_seqno_qos1 = SN1, last_seqno_qos2 = SN2}.

%% @doc Remove stream from the block queues:
-spec bq_drop(stream_key(), srs(), t()) -> t().
bq_drop(Key, #srs{last_seqno_qos1 = SN1, last_seqno_qos2 = SN2}, S = #s{bq1 = BQ1, bq2 = BQ2}) ->
    S#s{
        bq1 = gb_tree_remove(Key, SN1, BQ1),
        bq2 = gb_tree_remove(Key, SN2, BQ2)
    }.

gb_tree_remove(Key, SN, BQ0) ->
    case gb_trees:take_any(SN, BQ0) of
        {#block{id = Key}, BQ} ->
            BQ;
        {#block{}, _} ->
            BQ0;
        error ->
            BQ0
    end.

%%--------------------------------------------------------------------------------
%% Misc.
%%--------------------------------------------------------------------------------

%% Create an iterator for the stream if it doesn't exist yet.
-spec make_iterator(
    emqx_ds:topic_filter(),
    emqx_persistent_session_ds_subs:subscription(),
    {emqx_ds:stream_rank(), emqx_ds:stream()},
    emqx_persistent_session_ds_state:t()
) ->
    {
        [stream_key()],
        emqx_persistent_session_ds_state:t()
    }.
make_iterator(TopicFilter, Subscription, {{RankX, RankY}, Stream}, S) ->
    #{id := SubId, start_time := StartTime, current_state := CurrentSubState} = Subscription,
    Key = {SubId, Stream},
    case emqx_ds:make_iterator(?PERSISTENT_MESSAGE_DB, Stream, TopicFilter, StartTime) of
        {ok, Iterator} ->
            ?tp(?sessds_stream_state_trans, #{key => Key, to => r, from => void}),
            NewStreamState = #srs{
                rank_x = RankX,
                rank_y = RankY,
                it_begin = Iterator,
                it_end = Iterator,
                sub_state_id = CurrentSubState
            },
            {
                [Key],
                emqx_persistent_session_ds_state:put_stream(Key, NewStreamState, S)
            };
        {error, Class = unrecoverable, Reason} ->
            %% TODO: Handling of recoverable errors is non-trivial,
            %% since stream renewal is an event-driven process. As
            %% such, re-creation of iterators should be triggered by
            %% some event. Currently we just restart the session
            %% should we encounter one in hope that it will recover.
            ?SLOG(info, #{
                msg => "failed_to_initialize_stream_iterator",
                stream => Stream,
                class => Class,
                reason => Reason
            }),
            {[], S}
    end.

%% @doc Compare the streams by the order in which they were replayed.
compare_streams(
    {_KeyA, #srs{first_seqno_qos1 = A1, first_seqno_qos2 = A2}},
    {_KeyB, #srs{first_seqno_qos1 = B1, first_seqno_qos2 = B2}}
) ->
    case A1 =:= B1 of
        true ->
            A2 =< B2;
        false ->
            A1 < B1
    end.

is_fully_replayed(Comm1, Comm2, S = #srs{it_end = It}) ->
    It =:= end_of_stream andalso is_fully_acked(Comm1, Comm2, S).

is_fully_acked(Comm1, Comm2, SRS) ->
    is_track_acked(?QOS_1, Comm1, SRS) andalso
        is_track_acked(?QOS_2, Comm2, SRS).

is_track_acked(?QOS_1, Committed, #srs{first_seqno_qos1 = First, last_seqno_qos1 = Last}) ->
    First =:= Last orelse Committed >= Last;
is_track_acked(?QOS_2, Committed, #srs{first_seqno_qos2 = First, last_seqno_qos2 = Last}) ->
    First =:= Last orelse Committed >= Last.

watch_streams(TopicFilter) ->
    ?tp(?sessds_sched_watch_streams, #{topic_filter => TopicFilter}),
    {ok, Ref} = emqx_ds_new_streams:watch(?PERSISTENT_MESSAGE_DB, TopicFilter),
    Ref.

unwatch_streams(TopicFilterBin, Ref, NewStreamSubs) ->
    ?tp(debug, ?sessds_sched_unwatch_streams, #{
        topic_filter => emqx_topic:words(TopicFilterBin), ref => Ref
    }),
    emqx_ds_new_streams:unwatch(?PERSISTENT_MESSAGE_DB, Ref),
    maps:remove(Ref, NewStreamSubs).

%%--------------------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------------------

-ifdef(TEST).

-spec runtime_state_invariants(
    emqx_persistent_session_ds_fuzzer:model_state(), #{s := map(), scheduler_state_s := t()}
) ->
    boolean().
runtime_state_invariants(ModelState, #{s := S, stream_scheduler_s := SchedS}) ->
    invariant_subscription_states(ModelState, SchedS) and
        invariant_active_streams_y_ranks(S).

-spec offline_state_invariants(
    emqx_persistent_session_ds_fuzzer:model_state(), #{s := map()}
) ->
    boolean().
offline_state_invariants(_ModelState, #{s := S}) ->
    invariant_active_streams_y_ranks(S).

%% Verify that each active subscription has a state and a
%% watch:
invariant_subscription_states(#{subs := Subs}, #s{
    new_stream_subs = Watches, sub_metadata = SubStates
}) ->
    ExpectedTopics = lists:sort(maps:keys(Subs)),
    ?defer_assert(
        ?assertEqual(
            ExpectedTopics,
            lists:sort(maps:keys(SubStates)),
            "There's a 1:1 relationship between subscribed streams and scheduler's internal subscription states"
        )
    ),
    ?defer_assert(
        ?assertEqual(
            ExpectedTopics,
            lists:sort(maps:values(Watches)),
            "There's a 1:1 relationship between subscribed streams and watches"
        )
    ),
    true.

%% Verify that all active streams belong to the same generation:
invariant_active_streams_y_ranks(#{streams := StreamMap}) ->
    %% Derive active ranks:
    ActiveRanks = maps:fold(
        fun({SubId, _Stream}, #srs{rank_x = X, rank_y = Y, unsubscribed = U, it_end = ItEnd}, Acc) ->
            case (not U) and (ItEnd =/= end_of_stream) of
                true ->
                    %% This is an active stream, add its rank to the list:
                    map_cons({SubId, X}, Y, Acc);
                false ->
                    Acc
            end
        end,
        #{},
        StreamMap
    ),
    %% Verify that only one generation is active at a time:
    maps:foreach(
        fun({SubId, X}, Ys) ->
            Comment = #{
                msg => "For each subscription and x-rank there should be only one active y-rank",
                subid => SubId,
                x => X
            },
            ?defer_assert(?assertMatch([_], Ys, Comment))
        end,
        ActiveRanks
    ),
    true.

map_cons(Key, NewElem, Map) ->
    maps:update_with(Key, fun(L) -> [NewElem | L] end, [NewElem], Map).

-endif.
