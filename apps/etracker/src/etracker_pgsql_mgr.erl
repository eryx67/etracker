%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Dec 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_pgsql_mgr).

-export([start_link/1, stop/1]).
-export([init/2]).
-export([system_code_change/4, system_continue/3, system_terminate/4, write_debug/3]).

-include("etracker.hrl").

-record(state, {
         }).

start_link(_Opts) ->
    proc_lib:start_link(?MODULE, init, [self(), #state{}]).

init(Parent, State) ->
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Parent, Debug, State).

stop(Pid) ->
    Pid ! stop.

loop(Parent, Debug, State) ->
    receive
        stop ->
            ok;
        Msg ->
            % Let's print unknown messages.
            sys:handle_debug(
                Debug, fun ?MODULE:write_debug/3, ?MODULE, {in, Msg}
            ),
            loop(Parent, Debug, State)
    end.

write_debug(Dev, Event, Name) ->
    io:format(Dev, "~p event = ~p~n", [Name, Event]).

system_continue(Parent, Debug, State) ->
    loop(Parent, Debug, State).

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.
