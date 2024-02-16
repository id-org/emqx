%%--------------------------------------------------------------------
%% Copyright (c) 2018-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_cluster_rpc_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(NODE1, emqx_cluster_rpc).
-define(NODE2, emqx_cluster_rpc2).
-define(NODE3, emqx_cluster_rpc3).

all() ->
    [
        t_base_test,
        t_commit_fail_test,
        t_commit_crash_test,
        t_commit_ok_but_apply_fail_on_other_node,
        t_commit_ok_apply_fail_on_other_node_then_recover,
        t_del_stale_mfa,
        t_skip_failed_commit,
        t_fast_forward_commit,
        t_commit_concurrency
    ].
suite() -> [{timetrap, {minutes, 5}}].
groups() -> [].

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [
            emqx,
            {emqx_conf,
                "node.cluster_call {"
                "\n  retry_interval = 1s"
                "\n  max_history = 100"
                "\n  cleanup_interval = 500ms"
                "\n}"}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    meck:new(mria, [non_strict, passthrough, no_link]),
    meck:expect(mria, running_nodes, 0, [?NODE1, {node(), ?NODE2}, {node(), ?NODE3}]),
    [{suite_apps, Apps} | Config].

end_per_suite(Config) ->
    ok = meck:unload(mria),
    ok = emqx_cth_suite:stop(?config(suite_apps, Config)).

init_per_testcase(_TestCase, Config) ->
    stop(),
    start(),
    Config.

end_per_testcase(_Config) ->
    stop(),
    ok.

t_base_test(_Config) ->
    ?assertEqual(emqx_cluster_rpc:status(), {atomic, []}),
    Pid = self(),
    MFA = {M, F, A} = {?MODULE, echo, [Pid, test]},
    {ok, TnxId, ok} = multicall(M, F, A),
    {atomic, Query} = emqx_cluster_rpc:query(TnxId),
    ?assertEqual(MFA, maps:get(mfa, Query)),
    ?assertEqual(node(), maps:get(initiator, Query)),
    ?assert(maps:is_key(created_at, Query)),
    ?assertEqual(ok, receive_msg(3, test)),
    ?assertEqual({ok, 2, ok}, multicall(M, F, A)),
    {atomic, Status} = emqx_cluster_rpc:status(),
    case length(Status) =:= 3 of
        true ->
            ?assert(lists:all(fun(I) -> maps:get(tnx_id, I) =:= 2 end, Status));
        false ->
            %% wait for mnesia to write in.
            ct:sleep(42),
            {atomic, Status1} = emqx_cluster_rpc:status(),
            ct:pal("status: ~p", Status),
            ct:pal("status1: ~p", Status1),
            ?assertEqual(3, length(Status1)),
            ?assert(lists:all(fun(I) -> maps:get(tnx_id, I) =:= 2 end, Status))
    end,
    ok.

t_commit_fail_test(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    {M, F, A} = {?MODULE, failed_on_node, [erlang:whereis(?NODE2)]},
    {init_failure, "MFA return not ok"} = multicall(M, F, A),
    ?assertEqual({atomic, []}, emqx_cluster_rpc:status()),
    ok.

t_commit_crash_test(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    {M, F, A} = {?MODULE, no_exist_function, []},
    {init_failure, {error, Meta}} = multicall(M, F, A),
    ?assertEqual(undef, maps:get(reason, Meta)),
    ?assertEqual(error, maps:get(exception, Meta)),
    ?assertEqual(true, maps:is_key(stacktrace, Meta)),
    ?assertEqual({atomic, []}, emqx_cluster_rpc:status()),
    ok.

t_commit_ok_but_apply_fail_on_other_node(_Config) ->
    emqx_cluster_rpc:reset(),
    {atomic, []} = emqx_cluster_rpc:status(),
    Pid = self(),
    {BaseM, BaseF, BaseA} = {?MODULE, echo, [Pid, test]},
    {ok, _TnxId, ok} = multicall(BaseM, BaseF, BaseA),
    ?assertEqual(ok, receive_msg(3, test)),

    {M, F, A} = {?MODULE, failed_on_node, [erlang:whereis(?NODE1)]},
    {ok, _, ok} = multicall(M, F, A, 1, 1000),
    {atomic, AllStatus} = emqx_cluster_rpc:status(),
    Node = node(),
    ?assertEqual(
        [
            {1, {Node, emqx_cluster_rpc2}},
            {1, {Node, emqx_cluster_rpc3}},
            {2, Node}
        ],
        lists:sort([{T, N} || #{tnx_id := T, node := N} <- AllStatus])
    ),
    erlang:send(?NODE2, test),
    Call = emqx_cluster_rpc:make_initiate_call_req(M, F, A),
    Res1 = gen_server:call(?NODE2, Call),
    Res2 = gen_server:call(?NODE3, Call),
    %% Node2 is retry on tnx_id 1, and should not run Next MFA.
    ?assertEqual(
        {init_failure, #{
            msg => stale_view_of_cluster_state,
            retry_times => 2,
            cluster_tnx_id => 2,
            node_tnx_id => 1
        }},
        Res1
    ),
    ?assertEqual(Res1, Res2),
    ok.

t_commit_concurrency(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    Pid = self(),
    {BaseM, BaseF, BaseA} = {?MODULE, echo, [Pid, test]},
    {ok, _TnxId, ok} = multicall(BaseM, BaseF, BaseA),
    ?assertEqual(ok, receive_msg(3, test)),

    %% call concurrently without stale tnx_id error
    Workers = lists:seq(1, 256),
    lists:foreach(
        fun(Seq) ->
            {EchoM, EchoF, EchoA} = {?MODULE, echo_delay, [Pid, Seq]},
            Call = emqx_cluster_rpc:make_initiate_call_req(EchoM, EchoF, EchoA),
            spawn_link(fun() ->
                ?assertMatch({ok, _, ok}, gen_server:call(?NODE1, Call, infinity))
            end),
            spawn_link(fun() ->
                ?assertMatch({ok, _, ok}, gen_server:call(?NODE2, Call, infinity))
            end),
            spawn_link(fun() ->
                ?assertMatch({ok, _, ok}, gen_server:call(?NODE3, Call, infinity))
            end)
        end,
        Workers
    ),
    %% receive seq msg in order
    List = lists:sort(receive_seq_msg([])),
    ?assertEqual(256 * 3 * 3, length(List), List),
    {atomic, Status} = emqx_cluster_rpc:status(),
    lists:map(
        fun(#{tnx_id := TnxId} = S) ->
            ?assertEqual(256 * 3 + 1, TnxId, S)
        end,
        Status
    ),
    AllMsgIndex = lists:flatten(lists:duplicate(9, Workers)),
    Result =
        lists:foldl(
            fun(Index, Acc) ->
                ?assertEqual(true, lists:keymember(Index, 1, Acc), {Index, Acc}),
                lists:keydelete(Index, 1, Acc)
            end,
            List,
            AllMsgIndex
        ),
    ?assertEqual([], Result),
    receive
        Unknown -> throw({receive_unknown_msg, Unknown})
    after 1000 -> ok
    end,
    ok.

receive_seq_msg(Acc) ->
    receive
        {msg, Seq, Time, Pid} ->
            receive_seq_msg([{Seq, Time, Pid} | Acc])
    after 3000 ->
        Acc
    end.

t_catch_up_status_handle_next_commit(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    {M, F, A} = {?MODULE, failed_on_node_by_odd, [erlang:whereis(?NODE1)]},
    {ok, 1, ok} = multicall(M, F, A, 1, 1000),
    Call = emqx_cluster_rpc:make_initiate_call_req(M, F, A),
    {ok, 2} = gen_server:call(?NODE2, Call),
    ok.

t_commit_ok_apply_fail_on_other_node_then_recover(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    ets:new(test, [named_table, public]),
    ets:insert(test, {other_mfa_result, failed}),
    ct:pal("111:~p~n", [ets:tab2list(cluster_rpc_commit)]),
    {M, F, A} = {?MODULE, failed_on_other_recover_after_retry, [erlang:whereis(?NODE1)]},
    {ok, 1, ok} = multicall(M, F, A, 1, 1000),
    ct:pal("222:~p~n", [ets:tab2list(cluster_rpc_commit)]),
    ct:pal("333:~p~n", [emqx_cluster_rpc:status()]),
    {atomic, [_Status | L]} = emqx_cluster_rpc:status(),
    ?assertEqual([], L),
    ets:insert(test, {other_mfa_result, ok}),
    {ok, 2, ok} = multicall(io, format, ["test"], 1, 1000),
    ct:sleep(1000),
    {atomic, NewStatus} = emqx_cluster_rpc:status(),
    ?assertEqual(3, length(NewStatus)),
    Pid = self(),
    MFAEcho = {M1, F1, A1} = {?MODULE, echo, [Pid, test]},
    {ok, TnxId, ok} = multicall(M1, F1, A1),
    {atomic, Query} = emqx_cluster_rpc:query(TnxId),
    ?assertEqual(MFAEcho, maps:get(mfa, Query)),
    ?assertEqual(node(), maps:get(initiator, Query)),
    ?assert(maps:is_key(created_at, Query)),
    ?assertEqual(ok, receive_msg(3, test)),
    ok.

t_del_stale_mfa(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    MFA = {M, F, A} = {io, format, ["test"]},
    Keys = lists:seq(1, 50),
    Keys2 = lists:seq(51, 150),
    Ids =
        [
            begin
                {ok, TnxId, ok} = multicall(M, F, A),
                TnxId
            end
         || _ <- Keys
        ],
    ?assertEqual(Keys, Ids),
    Ids2 =
        [
            begin
                {ok, TnxId, ok} = multicall(M, F, A),
                TnxId
            end
         || _ <- Keys2
        ],
    ?assertEqual(Keys2, Ids2),
    ct:sleep(1200),
    [
        begin
            ?assertEqual({aborted, not_found}, emqx_cluster_rpc:query(I))
        end
     || I <- lists:seq(1, 50)
    ],
    [
        begin
            {atomic, Map} = emqx_cluster_rpc:query(I),
            ?assertEqual(MFA, maps:get(mfa, Map)),
            ?assertEqual(node(), maps:get(initiator, Map)),
            ?assert(maps:is_key(created_at, Map))
        end
     || I <- lists:seq(51, 150)
    ],
    ok.

t_skip_failed_commit(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    {ok, 1, ok} = multicall(io, format, ["test~n"], all, 1000),
    ct:sleep(180),
    {atomic, List1} = emqx_cluster_rpc:status(),
    Node = node(),
    ?assertEqual(
        [{Node, 1}, {{Node, ?NODE2}, 1}, {{Node, ?NODE3}, 1}],
        tnx_ids(List1)
    ),
    {M, F, A} = {?MODULE, failed_on_node, [erlang:whereis(?NODE1)]},
    {ok, 2, ok} = multicall(M, F, A, 1, 1000),
    2 = gen_server:call(?NODE2, skip_failed_commit, 5000),
    {atomic, List2} = emqx_cluster_rpc:status(),
    ?assertEqual(
        [{Node, 2}, {{Node, ?NODE2}, 2}, {{Node, ?NODE3}, 1}],
        tnx_ids(List2)
    ),
    ok.

t_fast_forward_commit(_Config) ->
    {atomic, []} = emqx_cluster_rpc:status(),
    {ok, 1, ok} = multicall(io, format, ["test~n"], all, 1000),
    ct:sleep(180),
    {atomic, List1} = emqx_cluster_rpc:status(),
    Node = node(),
    ?assertEqual(
        [{Node, 1}, {{Node, ?NODE2}, 1}, {{Node, ?NODE3}, 1}],
        tnx_ids(List1)
    ),
    {M, F, A} = {?MODULE, failed_on_node, [erlang:whereis(?NODE1)]},
    {ok, 2, ok} = multicall(M, F, A, 1, 1000),
    {ok, 3, ok} = multicall(M, F, A, 1, 1000),
    {ok, 4, ok} = multicall(M, F, A, 1, 1000),
    {ok, 5, ok} = multicall(M, F, A, 1, 1000),
    {peers_lagging, 6, ok, _} = multicall(M, F, A, 2, 1000),
    3 = gen_server:call(?NODE2, {fast_forward_to_commit, 3}, 5000),
    4 = gen_server:call(?NODE2, {fast_forward_to_commit, 4}, 5000),
    6 = gen_server:call(?NODE2, {fast_forward_to_commit, 7}, 5000),
    2 = gen_server:call(?NODE3, {fast_forward_to_commit, 2}, 5000),
    {atomic, List2} = emqx_cluster_rpc:status(),
    ?assertEqual(
        [{Node, 6}, {{Node, ?NODE2}, 6}, {{Node, ?NODE3}, 2}],
        tnx_ids(List2)
    ),
    ok.

t_cleaner_unexpected_msg(_Config) ->
    Cleaner = emqx_cluster_cleaner,
    OldPid = erlang:whereis(Cleaner),
    ok = gen_server:cast(Cleaner, unexpected_cast_msg),
    ignore = gen_server:call(Cleaner, unexpected_cast_msg),
    erlang:send(Cleaner, unexpected_info_msg),
    NewPid = erlang:whereis(Cleaner),
    ?assertEqual(OldPid, NewPid),
    ok.

tnx_ids(Status) ->
    lists:sort(
        lists:map(
            fun(#{tnx_id := TnxId, node := Node}) ->
                {Node, TnxId}
            end,
            Status
        )
    ).

start() ->
    {ok, _Pid2} = emqx_cluster_rpc:start_link({node(), ?NODE2}, ?NODE2, 500),
    {ok, _Pid3} = emqx_cluster_rpc:start_link({node(), ?NODE3}, ?NODE3, 500),
    ok = emqx_cluster_rpc:reset(),
    ok.

stop() ->
    [
        begin
            case erlang:whereis(N) of
                undefined ->
                    ok;
                P ->
                    erlang:unlink(P),
                    erlang:exit(P, kill)
            end
        end
     || N <- [?NODE2, ?NODE3]
    ].

receive_msg(0, _Msg) ->
    ok;
receive_msg(Count, Msg) when Count > 0 ->
    receive
        Msg ->
            receive_msg(Count - 1, Msg)
    after 1000 ->
        timeout
    end.

echo(Pid, Msg) ->
    erlang:send(Pid, Msg),
    ok.

echo_delay(Pid, Msg) ->
    timer:sleep(rand:uniform(150)),
    erlang:send(Pid, {msg, Msg, erlang:system_time(), self()}),
    ok.

failed_on_node(Pid) ->
    case Pid =:= self() of
        true -> ok;
        false -> "MFA return not ok"
    end.

failed_on_node_by_odd(Pid) ->
    case Pid =:= self() of
        true ->
            ok;
        false ->
            catch ets:new(test, [named_table, set, public]),
            Num = ets:update_counter(test, self(), {2, 1}, {self(), 1}),
            case Num rem 2 =:= 0 of
                false -> "MFA return not ok";
                true -> ok
            end
    end.

failed_on_other_recover_after_retry(Pid) ->
    case Pid =:= self() of
        true ->
            ok;
        false ->
            [{_, Res}] = ets:lookup(test, other_mfa_result),
            Res
    end.

multicall(M, F, A, N, T) ->
    emqx_cluster_rpc:do_multicall(M, F, A, N, T).

multicall(M, F, A) ->
    multicall(M, F, A, all, timer:minutes(2)).
