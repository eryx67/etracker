%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Dec 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_cleaner).

-export([start_link/0, init/2]).
-export([force_clean/1]).
-export([system_code_change/4, system_continue/3, system_terminate/4, write_debug/3]).

-include("etracker.hrl").

-record(state, {
          clean_interval=0,
          expire_time=erlang:now(),
          tref
         }).

%% @doc Cleanup all peers before Time.
%% @end
-spec force_clean(tuple()) -> ok.
force_clean(Time) ->
    ?MODULE ! {force_clean, Time},
    ok.

start_link() ->
    AnswerInterval = confval(answer_interval, ?ANNOUNCE_ANSWER_MAX_PEERS),
    CleanInterval = confval(clean_interval, round(AnswerInterval * 1.5)) * 1000,
    proc_lib:start_link(?MODULE, init, [self(), #state{clean_interval=CleanInterval}]).

init(Parent, State=#state{clean_interval=CleanInterval}) ->
    register(?MODULE, self()),
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    ExpireTime = now(),
    {ok, TRef} = timer:send_after(CleanInterval, {clean, ExpireTime}),
    loop(Parent, Debug, State#state{tref=TRef, expire_time=ExpireTime}).

loop(Parent, Debug, State=#state{tref=TRef}) ->
    receive
        {system, From, Request} ->
            sys:handle_system_msg(
                Request, From, Parent, ?MODULE, Debug, State
            );
        {force_clean, ExpireTime} ->
            timer:cancel(TRef),
            NxtState= do_clean(ExpireTime, State),
            loop(Parent, Debug, NxtState);
        {clean, ExpireTime} ->
            NxtState= do_clean(ExpireTime, State),
            loop(Parent, Debug, NxtState);
        Msg ->
            % Let's print unknown messages.
            sys:handle_debug(
                Debug, fun ?MODULE:write_debug/3, ?MODULE, {in, Msg}
            ),
            loop(Parent, Debug, State)
    end.

do_clean(ExpireTime, State=#state{clean_interval=CleanInterval}) ->
    NxtExpireTime = now(),
    ok = etracker_db:expire_torrent_peers(ExpireTime),
    etracker_event:cleanup_completed(),
    lager:info("~s cleanup completed", [?MODULE]),
    {ok, TRef} = timer:send_after(CleanInterval, {clean, NxtExpireTime}),
    State#state{tref=TRef, expire_time=NxtExpireTime}.

write_debug(Dev, Event, Name) ->
    io:format(Dev, "~p event = ~p~n", [Name, Event]).

system_continue(Parent, Debug, State) ->
    loop(Parent, Debug, State).

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

confval(Key, Default) ->
    case application:get_env(Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.
