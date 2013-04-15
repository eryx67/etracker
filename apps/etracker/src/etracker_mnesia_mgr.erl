%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Dec 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_mnesia_mgr).

-export([start_link/1, init/2]).
-export([system_code_change/4, system_continue/3, system_terminate/4, write_debug/3]).

-include("etracker.hrl").

-define(DUMP_INTERVAL, 3600). % sec

-record(state, {
          dump_interval=?DUMP_INTERVAL,
          tref
         }).

start_link(Opts) ->
    etracker_mnesia:setup(Opts),
    DumpIval = proplists:get_value(dump_interval, Opts, ?DUMP_INTERVAL),
    proc_lib:start_link(?MODULE, init, [self(), #state{dump_interval=DumpIval * 1000}]).

init(Parent, State=#state{dump_interval=DumpIval}) ->
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    {ok, TRef} = timer:apply_interval(DumpIval, etracker_mnesia, dump_tables, []),
    loop(Parent, Debug, State#state{tref=TRef}).

loop(Parent, Debug, State=#state{tref=TRef}) ->
    receive
        stop ->
            timer:cancel(TRef),
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
