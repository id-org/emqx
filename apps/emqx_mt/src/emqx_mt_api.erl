%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_mt_api).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx_utils/include/emqx_utils_api.hrl").
%% -include_lib("emqx/include/logger.hrl").

%% `minirest' and `minirest_trails' API
-export([
    namespace/0,
    api_spec/0,
    fields/1,
    paths/0,
    schema/1
]).

%% `minirest' handlers
-export([
    ns_list/2,
    client_list/2,
    client_count/2
]).

%%-------------------------------------------------------------------------------------------------
%% Type definitions
%%-------------------------------------------------------------------------------------------------

-define(TAGS, [<<"Multi-tenancy">>]).

%%-------------------------------------------------------------------------------------------------
%% `minirest' and `minirest_trails' API
%%-------------------------------------------------------------------------------------------------

namespace() -> "mt".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/mt/ns_list",
        "/mt/client_list/:ns",
        "/mt/client_count/:ns"
    ].

schema("/mt/ns_list") ->
    #{
        'operationId' => ns_list,
        get => #{
            tags => ?TAGS,
            summary => <<"List Namespaces">>,
            description => ?DESC("ns_list"),
            responses =>
                #{
                    200 =>
                        emqx_dashboard_swagger:schema_with_examples(
                            array(binary()),
                            example_ns_list()
                        )
                }
        }
    };
schema("/mt/client_list/:ns") ->
    #{
        'operationId' => client_list,
        get => #{
            tags => ?TAGS,
            summary => <<"List Clients in a Namespace">>,
            description => ?DESC("client_list"),
            parameters => [param_path_ns()],
            responses =>
                #{
                    200 =>
                        emqx_dashboard_swagger:schema_with_examples(
                            array(binary()),
                            example_client_list()
                        ),
                    404 => error_schema('NOT_FOUND', "Namespace not found")
                }
        }
    };
schema("/mt/client_count/:ns") ->
    #{
        'operationId' => client_count,
        get => #{
            tags => ?TAGS,
            summary => <<"Count Clients in a Namespace">>,
            description => ?DESC("client_count"),
            parameters => [param_path_ns()],
            responses =>
                #{
                    200 => [{count, mk(non_neg_integer(), #{desc => <<"Client count">>})}],
                    404 => error_schema('NOT_FOUND', "Namespace not found")
                }
        }
    }.

param_path_ns() ->
    {ns,
        mk(
            binary(),
            #{
                in => path,
                required => true,
                example => <<"tns1">>,
                desc => ?DESC("param_path_ns")
            }
        )}.

%% no structs in this schema
fields(_) -> [].

mk(Type, Props) -> hoconsc:mk(Type, Props).

array(Type) -> hoconsc:array(Type).

error_schema(Code, Message) ->
    BinMsg = unicode:characters_to_binary(Message),
    emqx_dashboard_swagger:error_codes([Code], BinMsg).

%%-------------------------------------------------------------------------------------------------
%% `minirest' handlers
%%-------------------------------------------------------------------------------------------------

ns_list(get, _Params) ->
    ?OK(emqx_mt:list_ns()).

client_list(get, #{bindings := #{ns := Ns}}) ->
    case emqx_mt:list_clients(Ns) of
        {ok, Clients} -> ?OK(Clients);
        {error, not_found} -> ?NOT_FOUND("Namespace not found")
    end.

client_count(get, #{bindings := #{ns := Ns}}) ->
    case emqx_mt:count_clients(Ns) of
        {ok, Count} -> ?OK(#{count => Count});
        {error, not_found} -> ?NOT_FOUND("Namespace not found")
    end.

%%-------------------------------------------------------------------------------------------------
%% helper functions
%%-------------------------------------------------------------------------------------------------
example_ns_list() ->
    #{
        <<"list">> =>
            #{
                summary => <<"List">>,
                value => [<<"tns1">>, <<"tns2">>]
            }
    }.

example_client_list() ->
    #{
        <<"list">> =>
            #{
                summary => <<"List">>,
                value => [<<"client1">>, <<"client2">>]
            }
    }.
