-module(ejabberd_trace).

-behaviour(application).

%% API
-export([new_user/1, new_user/2, new_user/3,
         user/1,
         state/1]).

%% `application' callbacks
-export([start/2,
         stop/1]).

%% Types
-type dbg_flag() :: s | r | m | c | p | sos | sol | sofs | sofl | all | clear.
-export_type([dbg_flag/0]).

-type sys_status() :: {status, pid(), {module, module()}, [any()]}.
-export_type([sys_status/0]).

-type jid() :: string().
-export_type([jid/0]).

-type string_type() :: list | binary.
-export_type([string_type/0]).

-type xmlelement() :: any().
-export_type([xmlelement/0]).

-include("ejabberd_trace_internal.hrl").

%%
%% API
%%

%% @doc Trace a user who is to connect in near future once he/she connects.
%% This intends to trace *all* of the communication of a specific connection.
%%
%% The usage scenario is as follows:
%% 1) `new_user/1,2' is called (e.g. from the shell) - the call blocks,
%% 2) the user connects,
%% 3) the call returns while the connection process responsible for `Jid'
%%    is being traced.
%%
%% The magic happens in step (2) as the connection process is involved
%% and also more users than the one expected might connect.
%% This function takes care of determining who of those who connected
%% to trace based on his/her `Jid'.
%% In order to do that some stanza with the Jid must already be sent
%% on the connection - only then the matching may success.
%% This function buffers all debug messages up to the point of receiving
%% that stanza; then it forwards all the buffered messages for the traced user
%% and discards all the rest.
%% @end

-spec new_user(jid()) -> any() | no_return().
new_user(Jid) ->
    new_user(Jid, m).

-spec new_user(jid(), [dbg_flag()]) -> any() | no_return().
new_user(Jid, Flags) ->
    new_user(Jid, Flags, []).

-spec new_user(jid(), [dbg_flag()], [node()]) -> any() | no_return().
new_user(Jid, Flags, Nodes) ->
    start_new_user_tracer(Nodes),
    ejabberd_trace_server:trace_new_user(Jid, Flags).

%% @doc Trace an already logged in user given his/her Jid.
%% @end

-spec user(jid()) -> {ok, any()} |
                     {error, not_found} |
                     {error, {multiple_sessions, list()}} |
                     {error, any()}.
user(Jid) ->
    user(Jid, m).

-spec user(jid(), [dbg_flag()]) -> {ok, any()} |
                                   {error, not_found} |
                                   {error, {multiple_sessions, list()}} |
                                   {error, any()}.
user(Jid, Flags) ->
    is_dbg_running() orelse dbg:tracer(),
    %% TODO: use ejabberd_sm to get the session list!
    UserSpec = parse_jid(Jid),
    MatchSpec = match_session_pid(UserSpec),
    error_logger:info_msg("Session match spec: ~p~n", [MatchSpec]),
    case ets:select(session, MatchSpec) of
        [] ->
            {error, not_found};
        [{_, C2SPid}] ->
            dbg:p(C2SPid, Flags);
        [C2SPid] ->
            dbg:p(C2SPid, Flags);
        [_|_] = Sessions ->
            {error, {multiple_sessions, Sessions}}
    end.

%% @doc Return sys:get_status/1 result of the process corresponding to Jid.
%% @end

-spec state(jid()) -> sys_status().
state(Jid) ->
    UserSpec = parse_jid(Jid),
    MatchSpec = match_session_pid(UserSpec),
    error_logger:info_msg("Session match spec: ~p~n", [MatchSpec]),
    case ets:select(session, MatchSpec) of
        [] ->
            {error, not_found};
        [{_, C2SPid}] ->
            sys:get_status(C2SPid);
        [C2SPid] ->
            sys:get_status(C2SPid);
        [_|_] = Sessions ->
            {error, {multiple_sessions, Sessions}}
    end.

%%
%% `application' callbacks
%%

start(_StartType, _Args) ->
    ejabberd_trace_sup:start_link().

stop(_) ->
    ok.

%%
%% Internal functions
%%

-spec get_c2s_sup() -> pid() | undefined.
get_c2s_sup() ->
    erlang:whereis(ejabberd_c2s_sup).

is_dbg_running() ->
    case erlang:whereis(dbg) of
        Pid when is_pid(Pid) -> true;
        _ -> false
    end.

start_new_user_tracer(Nodes) ->
    is_dbg_running() andalso error(dbg_running),
    maybe_start(),
    TracerState = {fun dbg:dhandler/2, erlang:whereis(ejabberd_trace_server)},
    dbg:tracer(process, {fun ?LIB:trace_handler/2, TracerState}),
    [dbg:n(Node) || Node <- Nodes],
    dbg:p(get_c2s_sup(), [c, m, sos]),
    dbg:tpl(ejabberd_c2s, send_text, x),
    dbg:tpl(ejabberd_c2s, send_element, x),
    ok.

maybe_start() ->
    Apps = application:which_applications(),
    case lists:keymember(ejabberd_trace, 1, Apps) of
        true ->
            ok;
        false ->
            application:start(sasl),
            application:start(ejabberd_trace)
    end.

parse_jid(Jid) ->
    parse_jid(?LIB:get_env(ejabberd_trace, string_type, list), Jid).

-spec parse_jid(StringType, Jid) -> {User, Domain, Resource} |
                                    {User, Domain} when
      StringType :: string_type(),
      Jid :: jid(),
      User :: list() | binary(),
      Domain :: list() | binary(),
      Resource :: list() | binary().
parse_jid(list, Jid) ->
    case string:tokens(Jid, "@/") of
        [User, Domain, Resource] ->
            {User, Domain, Resource};
        [User, Domain] ->
            {User, Domain}
    end;
parse_jid(binary, Jid) ->
    list_to_tuple([list_to_binary(E)
                   || E <- tuple_to_list(parse_jid(list, Jid))]).

-spec match_session_pid(UserSpec) -> ets:match_spec() when
      UserSpec :: {string(), string(), string()} | {string(), string()}.
match_session_pid({_User, _Domain, _Resource} = UDR) ->
    [{%% match pattern
      set(session(), [{2, {'_', '$1'}},
                      {3, UDR}]),
      %% guards
      [],
      %% return
      ['$1']}];

match_session_pid({User, Domain}) ->
    [{%% match pattern
      set(session(), [{2, {'_', '$1'}},
                      {3, '$2'},
                      {4, {User, Domain}}]),
      %% guards
      [],
      %% return
      [{{'$2', '$1'}}]}].

session() ->
    set(erlang:make_tuple(6, '_'), [{1, session}]).

%% @doc Set multiple fields of a record in one call.
%% Usage:
%% set(Record, [{#record.field1, Val1},
%%              {#record.field1, Val2},
%%              {#record.field3, Val3}])
%% @end
set(Record, FieldValues) ->
    F = fun({Field, Value}, Rec) ->
                setelement(Field, Rec, Value)
        end,
    lists:foldl(F, Record, FieldValues).
