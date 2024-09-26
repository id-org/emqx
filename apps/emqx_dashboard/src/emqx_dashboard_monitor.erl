%%--------------------------------------------------------------------
%% Copyright (c) 2020-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_dashboard_monitor).

-include("emqx_dashboard.hrl").

-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

-export([create_tables/0]).
-export([start_link/0]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    samplers/0,
    samplers/2,
    current_rate/1
]).

%% for rpc
-export([do_sample/2]).

%% For tests
-export([
    current_rate_cluster/0,
    sample_interval/1,
    store/1,
    format/1,
    clean/1,
    lookup/1,
    sample_nodes/3,
    randomize/2,
    randomize/3,
    sample_fill_gap/2,
    fill_gaps/2
]).

-define(TAB, ?MODULE).

-define(ONE_SECOND, 1_000).
-define(SECONDS, ?ONE_SECOND).
-define(ONE_MINUTE, 60 * ?SECONDS).
-define(MINUTES, ?ONE_MINUTE).
-define(ONE_HOUR, 60 * ?MINUTES).
-define(HOURS, ?ONE_HOUR).
-define(ONE_DAY, 24 * ?HOURS).
-define(DAYS, ?ONE_DAY).

-define(CLEAN_EXPIRED_INTERVAL, 10 * ?MINUTES).
-define(RETENTION_TIME, 7 * ?DAYS).

-record(state, {
    last,
    clean_timer,
    extra = []
}).

-record(emqx_monit, {
    time :: integer(),
    data :: map()
}).

create_tables() ->
    ok = mria:create_table(?TAB, [
        {type, set},
        {local_content, true},
        {storage, disc_copies},
        {record_name, emqx_monit},
        {attributes, record_info(fields, emqx_monit)}
    ]),
    [?TAB].

%% -------------------------------------------------------------------------------------------------
%% API

samplers() ->
    format(sample_fill_gap(all, 0)).

samplers(NodeOrCluster, Latest) ->
    SinceTime = latest2time(Latest),
    case format(sample_fill_gap(NodeOrCluster, SinceTime)) of
        {badrpc, Reason} ->
            {badrpc, Reason};
        List when is_list(List) ->
            List
    end.

latest2time(infinity) -> 0;
latest2time(Latest) -> erlang:system_time(millisecond) - (Latest * 1000).

current_rate(all) ->
    current_rate_cluster();
current_rate(Node) when Node == node() ->
    try
        do_call(current_rate)
    catch
        _E:R ->
            ?SLOG(warning, #{msg => "dashboard_monitor_error", reason => R}),
            %% Rate map 0, ensure api will not crash.
            %% When joining cluster, dashboard monitor restart.
            Rate0 = [
                {Key, 0}
             || Key <- ?GAUGE_SAMPLER_LIST ++ maps:values(?DELTA_SAMPLER_RATE_MAP)
            ],
            {ok, maps:merge(maps:from_list(Rate0), non_rate_value())}
    end;
current_rate(Node) ->
    case emqx_dashboard_proto_v1:current_rate(Node) of
        {badrpc, Reason} ->
            {badrpc, {Node, Reason}};
        {ok, Rate} ->
            {ok, Rate}
    end.

%% Get the current rate. Not the current sampler data.
current_rate_cluster() ->
    Fun =
        fun
            (Node, Cluster) when is_map(Cluster) ->
                case current_rate(Node) of
                    {ok, CurrentRate} ->
                        merge_cluster_rate(CurrentRate, Cluster);
                    {badrpc, Reason} ->
                        {badrpc, {Node, Reason}}
                end;
            (_Node, Error) ->
                Error
        end,
    case lists:foldl(Fun, #{}, mria:cluster_nodes(running)) of
        {badrpc, Reason} ->
            {badrpc, Reason};
        Metrics ->
            {ok, adjust_synthetic_cluster_metrics(Metrics)}
    end.

%% -------------------------------------------------------------------------------------------------
%% gen_server functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    sample_timer(),
    %% clean immediately
    self() ! clean_expired,
    {ok, #state{last = undefined, clean_timer = undefined, extra = []}}.

handle_call(current_rate, _From, State = #state{last = Last}) ->
    NowTime = erlang:system_time(millisecond),
    NowSamplers = sample(NowTime),
    Rate = cal_rate(NowSamplers, Last),
    NonRateValue = non_rate_value(),
    Samples = maps:merge(Rate, NonRateValue),
    {reply, {ok, Samples}, State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info({sample, Time}, State = #state{last = Last}) ->
    Now = sample(Time),
    {atomic, ok} = flush(Last, Now),
    ?tp(dashboard_monitor_flushed, #{}),
    sample_timer(),
    {noreply, State#state{last = Now}};
handle_info(clean_expired, #state{clean_timer = TrefOld} = State) ->
    ok = maybe_cancel_timer(TrefOld),
    clean(),
    TrefNew = clean_timer(),
    {noreply, State#state{clean_timer = TrefNew}};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------------------------------------
%% Internal functions

%% for testing
randomize(Count, Data) when is_map(Data) ->
    MaxAge = 7 * ?DAYS,
    randomize(Count, Data, MaxAge).

randomize(Count, Data, Age) when is_map(Data) andalso is_integer(Age) ->
    Now = erlang:system_time(millisecond) - 1,
    Interval = sample_interval(Age),
    NowBase = Now - (Now rem Interval),
    StartTs = NowBase - Age,
    lists:foreach(
        fun(_) ->
            Ts = StartTs + rand:uniform(Now - StartTs),
            Record = #emqx_monit{time = Ts, data = Data},
            case ets:lookup(?TAB, Ts) of
                [] ->
                    store(Record);
                [#emqx_monit{data = D} = R] ->
                    store(R#emqx_monit{data = merge_sampler_maps(D, Data)})
            end
        end,
        lists:seq(1, Count)
    ).

maybe_cancel_timer(Tref) when is_reference(Tref) ->
    _ = erlang:cancel_timer(Tref),
    ok;
maybe_cancel_timer(_) ->
    ok.

do_call(Request) ->
    gen_server:call(?MODULE, Request, 5000).

do_sample(Node, infinity) ->
    %% handle RPC from old version nodes
    do_sample(Node, 0);
do_sample(all, Time) when is_integer(Time) ->
    AllNodes = emqx:running_nodes() -- [node()],
    Local = do_sample(node(), Time),
    All = sample_nodes(AllNodes, Time, Local),
    maps:map(fun(_, S) -> adjust_synthetic_cluster_metrics(S) end, All);
do_sample(Node, Time) when Node == node() andalso is_integer(Time) ->
    MS = ets:fun2ms(fun(#emqx_monit{time = T} = A) when T >= Time -> A end),
    FromDB = ets:select(?TAB, MS),
    Map = to_ts_data_map(FromDB),
    %% downsample before return RPC calls for less data to merge by the caller nodes
    downsample(Time, Map);
do_sample(Node, Time) when is_integer(Time) ->
    case emqx_dashboard_proto_v1:do_sample(Node, Time) of
        {badrpc, Reason} ->
            {badrpc, #{node => Node, reason => Reason}};
        Res ->
            Res
    end.

sample_nodes(Nodes, Time, Local) ->
    ResList = concurrently_sample_nodes(Nodes, Time),
    {Failed, Success} = lists:partition(
        fun
            ({badrpc, _}) -> true;
            (_) -> false
        end,
        ResList
    ),
    Failed =/= [] andalso
        ?SLOG(warning, #{msg => "failed_to_sample_monitor_data", errors => Failed}),
    lists:foldl(fun merge_samplers/2, Local, Success).

concurrently_sample_nodes(Nodes, Time) ->
    %% emqx_dashboard_proto_v1:do_sample has a timeout (5s),
    Timeout = ?RPC_TIMEOUT + ?ONE_SECOND,
    %% call emqx_utils:pmap here instead of a rpc multicall
    %% to avoid having to introduce a new bpapi proto version
    emqx_utils:pmap(fun(Node) -> do_sample(Node, Time) end, Nodes, Timeout).

merge_samplers(Increment, Base) ->
    maps:fold(fun merge_samplers_loop/3, Base, Increment).

merge_samplers_loop(TS, Increment, Base) when is_map(Increment) ->
    case maps:get(TS, Base, undefined) of
        undefined ->
            Base#{TS => Increment};
        BaseSample when is_map(BaseSample) ->
            Base#{TS => merge_sampler_maps(Increment, BaseSample)}
    end.

merge_sampler_maps(M1, M2) when is_map(M1) andalso is_map(M2) ->
    Fun =
        fun
            (Key, Map) when
                %% cluster-synced values
                Key =:= topics;
                Key =:= subscriptions_durable;
                Key =:= disconnected_durable_sessions
            ->
                Map#{Key => max(maps:get(Key, M1, 0), maps:get(Key, M2, 0))};
            (Key, Map) ->
                Map#{Key => maps:get(Key, M1, 0) + maps:get(Key, M2, 0)}
        end,
    lists:foldl(Fun, #{}, ?SAMPLER_LIST).

merge_cluster_rate(Node, Cluster) ->
    Fun =
        fun
            %% cluster-synced values
            (disconnected_durable_sessions, V, NCluster) ->
                NCluster#{disconnected_durable_sessions => V};
            (subscriptions_durable, V, NCluster) ->
                NCluster#{subscriptions_durable => V};
            (topics, V, NCluster) ->
                NCluster#{topics => V};
            (retained_msg_count, V, NCluster) ->
                NCluster#{retained_msg_count => V};
            (shared_subscriptions, V, NCluster) ->
                NCluster#{shared_subscriptions => V};
            (license_quota, V, NCluster) ->
                NCluster#{license_quota => V};
            %% for cluster sample, ignore node_uptime
            (node_uptime, _V, NCluster) ->
                NCluster;
            (Key, Value, NCluster) ->
                ClusterValue = maps:get(Key, NCluster, 0),
                NCluster#{Key => Value + ClusterValue}
        end,
    maps:fold(Fun, Cluster, Node).

adjust_synthetic_cluster_metrics(Metrics0) ->
    DSSubs = maps:get(subscriptions_durable, Metrics0, 0),
    RamSubs = maps:get(subscriptions, Metrics0, 0),
    DisconnectedDSs = maps:get(disconnected_durable_sessions, Metrics0, 0),
    Metrics1 = maps:update_with(
        subscriptions,
        fun(Subs) -> Subs + DSSubs end,
        0,
        Metrics0
    ),
    Metrics = maps:put(subscriptions_ram, RamSubs, Metrics1),
    maps:update_with(
        connections,
        fun(RamConns) -> RamConns + DisconnectedDSs end,
        DisconnectedDSs,
        Metrics
    ).

format({badrpc, Reason}) ->
    {badrpc, Reason};
format(Data0) ->
    Data1 = maps:to_list(Data0),
    Data = lists:keysort(1, Data1),
    lists:map(fun({TimeStamp, V}) -> V#{time_stamp => TimeStamp} end, Data).

cal_rate(_Now, undefined) ->
    AllSamples = ?GAUGE_SAMPLER_LIST ++ maps:values(?DELTA_SAMPLER_RATE_MAP),
    lists:foldl(fun(Key, Acc) -> Acc#{Key => 0} end, #{}, AllSamples);
cal_rate(
    #emqx_monit{data = NowData, time = NowTime},
    #emqx_monit{data = LastData, time = LastTime} = Last
) ->
    case NowTime - LastTime of
        0 ->
            %% make sure: not divide by zero
            timer:sleep(5),
            NewSamplers = sample(erlang:system_time(millisecond)),
            cal_rate(NewSamplers, Last);
        TimeDelta ->
            Filter = fun(Key, _) -> lists:member(Key, ?GAUGE_SAMPLER_LIST) end,
            Gauge = maps:filter(Filter, NowData),
            {_, _, _, Rate} =
                lists:foldl(
                    fun cal_rate_/2,
                    {NowData, LastData, TimeDelta, Gauge},
                    ?DELTA_SAMPLER_LIST
                ),
            Rate
    end.

cal_rate_(Key, {Now, Last, TDelta, Res}) ->
    NewValue = maps:get(Key, Now),
    LastValue = maps:get(Key, Last),
    Rate = ((NewValue - LastValue) * 1000) div TDelta,
    RateKey = maps:get(Key, ?DELTA_SAMPLER_RATE_MAP),
    {Now, Last, TDelta, Res#{RateKey => Rate}}.

%% Try to keep the total number of recrods around 1000.
%% When the oldest data point is
%% < 1h: sample every 10s: 360 data points
%% < 1d: sample every 1m: 1440 data points
%% < 3d: sample every 5m: 864 data points
%% < 7d: sample every 10m: 1008 data points
sample_interval(Age) when Age =< 60 * ?SECONDS ->
    %% so far this can happen only during tests
    ?ONE_SECOND;
sample_interval(Age) when Age =< ?ONE_HOUR ->
    10 * ?SECONDS;
sample_interval(Age) when Age =< ?ONE_DAY ->
    ?ONE_MINUTE;
sample_interval(Age) when Age =< 3 * ?DAYS ->
    5 * ?MINUTES;
sample_interval(_Age) ->
    10 * ?MINUTES.

sample_fill_gap(Node, SinceTs) ->
    Samples = do_sample(Node, SinceTs),
    fill_gaps(Samples, SinceTs).

fill_gaps(Samples, SinceTs) ->
    TsList = lists:sort(maps:keys(Samples)),
    case length(TsList) >= 2 of
        true ->
            do_fill_gaps(hd(TsList), tl(TsList), Samples, SinceTs);
        false ->
            Samples
    end.

do_fill_gaps(FirstTs, TsList, Samples, SinceTs) ->
    Latest = lists:last(TsList),
    Interval = sample_interval(Latest - SinceTs),
    StartTs =
        case round_down(SinceTs, Interval) of
            T when T =:= 0 orelse T =:= FirstTs ->
                FirstTs;
            T ->
                T
        end,
    fill_gaps_loop(StartTs, Interval, Latest, Samples).

fill_gaps_loop(T, _Interval, Latest, Samples) when T >= Latest ->
    Samples;
fill_gaps_loop(T, Interval, Latest, Samples) ->
    Samples1 =
        case is_map_key(T, Samples) of
            true ->
                Samples;
            false ->
                Samples#{T => #{}}
        end,
    fill_gaps_loop(T + Interval, Interval, Latest, Samples1).

downsample(SinceTs, TsDataMap) when map_size(TsDataMap) >= 2 ->
    TsList = lists:sort(maps:keys(TsDataMap)),
    Latest = lists:last(TsList),
    Interval = sample_interval(Latest - SinceTs),
    downsample_loop(TsList, TsDataMap, Interval, #{});
downsample(_Since, TsDataMap) ->
    TsDataMap.

round_down(Ts, Interval) ->
    Ts - (Ts rem Interval).

downsample_loop([], _TsDataMap, _Interval, Res) ->
    Res;
downsample_loop([Ts | Rest], TsDataMap, Interval, Res) ->
    Bucket = round_down(Ts, Interval),
    Agg0 = maps:get(Bucket, Res, #{}),
    Inc = maps:get(Ts, TsDataMap),
    Agg = merge_sampler_maps(Inc, Agg0),
    downsample_loop(Rest, TsDataMap, Interval, Res#{Bucket => Agg}).

%% -------------------------------------------------------------------------------------------------
%% timer

sample_timer() ->
    {NextTime, Remaining} = next_interval(),
    erlang:send_after(Remaining, self(), {sample, NextTime}).

clean_timer() ->
    erlang:send_after(?CLEAN_EXPIRED_INTERVAL, self(), clean_expired).

%% Per interval seconds.
%% As an example:
%%  Interval = 10
%%  The monitor will start working at full seconds, as like 00:00:00, 00:00:10, 00:00:20 ...
%% Ensure that the monitor data of all nodes in the cluster are aligned in time
next_interval() ->
    Interval = emqx_conf:get([dashboard, sample_interval], ?DEFAULT_SAMPLE_INTERVAL) * 1000,
    Now = erlang:system_time(millisecond),
    NextTime = round_down(Now, Interval) + Interval,
    Remaining = NextTime - Now,
    {NextTime, Remaining}.

%% -------------------------------------------------------------------------------------------------
%% data

sample(Time) ->
    Fun =
        fun(Key, Acc) ->
            Acc#{Key => getstats(Key)}
        end,
    Data = lists:foldl(Fun, #{}, ?SAMPLER_LIST),
    #emqx_monit{time = Time, data = Data}.

flush(_Last = undefined, Now) ->
    store(Now);
flush(_Last = #emqx_monit{data = LastData}, Now = #emqx_monit{data = NowData}) ->
    Store = Now#emqx_monit{data = delta(LastData, NowData)},
    store(Store).

delta(LastData, NowData) ->
    Fun =
        fun(Key, Data) ->
            Value = maps:get(Key, NowData) - maps:get(Key, LastData),
            Data#{Key => Value}
        end,
    lists:foldl(Fun, NowData, ?DELTA_SAMPLER_LIST).

lookup(Ts) ->
    ets:lookup(?TAB, Ts).

store(MonitData) ->
    {atomic, ok} =
        mria:transaction(mria:local_content_shard(), fun mnesia:write/3, [?TAB, MonitData, write]).

clean() ->
    clean(?RETENTION_TIME).

clean(Retention) ->
    Now = erlang:system_time(millisecond),
    MS = ets:fun2ms(fun(#emqx_monit{time = T}) -> Now - T > Retention end),
    _ = ets:select_delete(?TAB, MS),
    ok.

%% This data structure should not be changed because it's a RPC contract.
%% Otherwise dashboard may not work during rolling upgrade.
to_ts_data_map(List) when is_list(List) ->
    Fun =
        fun(#emqx_monit{time = Time, data = Data}, All) ->
            All#{Time => Data}
        end,
    lists:foldl(Fun, #{}, List).

getstats(Key) ->
    %% Stats ets maybe not exist when ekka join.
    try
        stats(Key)
    catch
        _:_ -> 0
    end.

stats(connections) ->
    emqx_stats:getstat('connections.count');
stats(disconnected_durable_sessions) ->
    emqx_persistent_session_bookkeeper:get_disconnected_session_count();
stats(subscriptions_durable) ->
    emqx_stats:getstat('durable_subscriptions.count');
stats(live_connections) ->
    emqx_stats:getstat('live_connections.count');
stats(cluster_sessions) ->
    emqx_stats:getstat('cluster_sessions.count');
stats(topics) ->
    emqx_stats:getstat('topics.count');
stats(subscriptions) ->
    emqx_stats:getstat('subscriptions.count');
stats(shared_subscriptions) ->
    emqx_stats:getstat('subscriptions.shared.count');
stats(retained_msg_count) ->
    emqx_stats:getstat('retained.count');
stats(received) ->
    emqx_metrics:val('messages.received');
stats(received_bytes) ->
    emqx_metrics:val('bytes.received');
stats(sent) ->
    emqx_metrics:val('messages.sent');
stats(sent_bytes) ->
    emqx_metrics:val('bytes.sent');
stats(validation_succeeded) ->
    emqx_metrics:val('messages.validation_succeeded');
stats(validation_failed) ->
    emqx_metrics:val('messages.validation_failed');
stats(transformation_succeeded) ->
    emqx_metrics:val('messages.transformation_succeeded');
stats(transformation_failed) ->
    emqx_metrics:val('messages.transformation_failed');
stats(dropped) ->
    emqx_metrics:val('messages.dropped');
stats(persisted) ->
    emqx_metrics:val('messages.persisted').

%% -------------------------------------------------------------------------------------------------
%% Retained && License Quota

%% the non rate values should be same on all nodes
non_rate_value() ->
    (license_quota())#{
        retained_msg_count => stats(retained_msg_count),
        shared_subscriptions => stats(shared_subscriptions),
        node_uptime => emqx_sys:uptime()
    }.

-if(?EMQX_RELEASE_EDITION == ee).
license_quota() ->
    case emqx_license_checker:limits() of
        {ok, #{max_connections := Quota}} ->
            #{license_quota => Quota};
        {error, no_license} ->
            #{license_quota => 0}
    end.
-else.
license_quota() ->
    #{}.
-endif.
