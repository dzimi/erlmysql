% ---------------------------------------------------------------------
%%
%% Copyright (c) 2010-2016 jtendo Sp. z.o.o. .
%% All Rights Reserved.
%%
%% The exclusive owner of this work is jtendo Sp. z o.o.
%% This work, including all associated documents and
%% components is Copyright (c) jtendo Sp. z o.o. 2016.
%%
%% ---------------------------------------------------------------------
-module(mysql_ds).

-include_lib("my.hrl").

%% API
-export([
    connect/0,
    connect/2,
    disconnect/0,
    get_connection/0,
    execute_query/1,
    execute_query/2,
    execute_query_with_conn/2,
    execute_query_with_conn/3,
    execute_query_with_conn/4,
    execute_transaction/1,
    mysql_decimal_to_number/1
]).

-define(PRIMARY_DATA_SOURCE, primary_datasource).
-define(SECONDARY_DATA_SOURCE, secondary_datasource).

-record(db_update_meta, {
    rows_affected :: integer()
}).

%%%===================================================================
%%% API functions
%%%===================================================================
connect() ->
    connect(get_env(?PRIMARY_DATA_SOURCE, []), get_env(?SECONDARY_DATA_SOURCE, [])).

connect(PrimaryDs, []) ->
    {ok, _Pid} = connect_ds(?PRIMARY_DATA_SOURCE, PrimaryDs),
    ok;
connect(PrimaryDs, SecondaryDs) ->
    connect(PrimaryDs, []),
    {ok, _Pid2} = connect_ds(?SECONDARY_DATA_SOURCE, SecondaryDs),
    ok.
    
disconnect() ->
    ok = datasource:close(?PRIMARY_DATA_SOURCE),
    case get_env(?SECONDARY_DATA_SOURCE, []) of
        [] -> ok;
        _ ->
            ok = datasource:close(?SECONDARY_DATA_SOURCE)
    end,
    ok.


get_connection() ->
    case get_connection(?PRIMARY_DATA_SOURCE) of
        {error, Reason} ->
            error_logger:info_msg("getting connection from primary datasource failed: ~p", [Reason]),
            case get_env(?SECONDARY_DATA_SOURCE, []) of
                [] -> {error, Reason};
                _ ->
                    get_connection(?SECONDARY_DATA_SOURCE)
            end;
        Conn ->
            Conn
    end.

execute_query(Query) ->
    execute_query(Query, undefined).

execute_query(Query, Params) ->
    Connection = get_connection(),
    execute_query_with_conn(Connection, Query, Params).

execute_query_with_conn(Connection, Query) ->
    execute_query_with_conn(Connection, Query, undefined).

execute_query_with_conn(Connection, Query, Params) ->
    execute_query_with_conn(Connection, Query, Params, return_conn).

execute_query_with_conn({error, Reason}, _Query, _Params, _Opt) ->
    {error, Reason};
execute_query_with_conn(Cn = {_Ds, Conn}, Query, undefined, Opt) ->
    handle_query_result(Cn, connection:execute_query(Conn, Query), Opt);
execute_query_with_conn(Cn = {_Ds, Conn}, Query, Params, Opt) ->
    Params2 = lists:map(fun cast_params/1, Params),
    Types = get_types(Params2),
    H = connection:get_prepared_statement_handle(Conn, Query),
    Result = connection:execute_statement(Conn, H, Types, Params2),
    connection:close_statement(Conn, H),
    handle_query_result(Cn, Result, Opt).

execute_transaction(Transaction) ->
    Connection = get_connection(),
    handle_query_result(Connection, transaction(Connection, Transaction), return_conn).

%%%===================================================================
%%% Internal functions
%%%===================================================================
transaction({error, Reason}, _Transaction) ->
    {error, Reason};
transaction({Ds, Conn}, Transaction) ->
    TransactionF2 = fun(Connection) -> Transaction({Ds, Connection}) end,
    connection:transaction(Conn, TransactionF2).

connect_ds(DsName, Conf) ->
    DSDef = #datasource{
        name = DsName,
        host = proplists:get_value(host, Conf),
        port = proplists:get_value(port, Conf),
        database = proplists:get_value(database, Conf),
        user = proplists:get_value(user, Conf),
        password = proplists:get_value(password, Conf)
    },
    PoolDef = [
        {min_idle, proplists:get_value(pool_min_idle, Conf)},
        {max_active, proplists:get_value(pool_max_active, Conf)},
        {max_wait, proplists:get_value(pool_max_wait, Conf)},
        % on hour max idle time
        {max_idle_time, 3600000}
    ],
    my:new_datasource(DsName, DSDef, PoolDef).


get_connection(Ds) ->
    case datasource:get_connection(Ds) of
        {error, Reason} ->
            {error, Reason};
        Conn ->
            {Ds, Conn}
    end.

handle_query_result({Ds, Conn}, Result = #mysql_error{}, _) ->
    error_logger:info_msg("invalidate connection ~p, reason ~p", [Conn, Result]),
    datasource:invalidate_connection(Ds, Conn),
    transform_response(Result);
handle_query_result({Ds, Conn}, Result, return_conn) ->
    datasource:return_connection(Ds, Conn),
    transform_response(Result);
handle_query_result(_, Result, not_return_conn) ->
    transform_response(Result).


get_types(Query) ->
    lists:map(fun erl_type_to_mysql_type/1, Query).

erl_type_to_mysql_type(It) when is_list(It) ->
    ?MYSQL_TYPE_VARCHAR;
erl_type_to_mysql_type(It) when is_binary(It) ->
    ?MYSQL_TYPE_VARCHAR;
erl_type_to_mysql_type(It) when It =:= true; It =:= false ->
    ?MYSQL_TYPE_TINY;
erl_type_to_mysql_type(It) when is_atom(It) ->
    ?MYSQL_TYPE_VARCHAR;
erl_type_to_mysql_type(It) when is_integer(It) ->
    ?MYSQL_TYPE_LONGLONG;
erl_type_to_mysql_type(It) when is_pid(It) ->
    ?MYSQL_TYPE_VARCHAR;
erl_type_to_mysql_type(_It) ->
    ?MYSQL_TYPE_VARCHAR.

transform_response(Res) ->
    case Res of
        {_Meta, [{ok_packet, AffectedRows, _, _, _, _}]} ->
            {ok, #db_update_meta{rows_affected = AffectedRows}};
        {_Meta, Result} ->
            {ok, Result};
        #mysql_error{} ->
            {error, Res};
        R = pool_timeout ->
            {error, R};
        _ ->
            {error, unexpected_response, Res}
    end.

cast_params(Arg) when is_list(Arg) -> Arg;
cast_params(Arg) when is_binary(Arg) -> binary_to_list(Arg);
cast_params(false) -> 0;
cast_params(true) -> 1;
cast_params(Arg) when is_atom(Arg) -> atom_to_list(Arg);
cast_params(Arg) when is_reference(Arg) -> erlang:ref_to_list(Arg);
cast_params(Arg) when is_pid(Arg) -> erlang:pid_to_list(Arg);
cast_params(Arg) -> Arg.

get_env(Key, Default) ->
    case application:get_env(mysql_client, Key) of
        undefined -> Default;
        {ok, Value} -> Value
    end.

mysql_decimal_to_number({mysql_decimal, Int, []}) ->
    list_to_integer(Int);
mysql_decimal_to_number({mysql_decimal, Int, Fraction}) ->
    list_to_float(Int ++ "." ++ Fraction);
mysql_decimal_to_number(_) ->
    0.
