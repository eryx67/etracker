%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Dec 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_cleaner).

-export([start_link/0, init/2, stop/0]).
-export([force_clean/1]).
-export([system_code_change/4, system_continue/3, system_terminate/4, write_debug/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).

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
    AnswerInterval = confval(answer_interval, ?ANNOUNCE_ANSWER_INTERVAL),
    Default = round(AnswerInterval * 1.5),
    CleanInterval = confval(clean_interval, Default),
    proc_lib:start_link(?MODULE, init, [self(), #state{clean_interval=CleanInterval * 1000}]).

stop() ->
    ?SERVER ! stop,
    ok.

init(Parent, State=#state{clean_interval=CleanInterval}) ->
    register(?SERVER, self()),
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    ExpireTime = now(),
    ExpDT = calendar:now_to_local_time(ExpireTime),
    Self = self(),
    lager:info("~s will start in ~w ms, next expire time ~p", [?MODULE, CleanInterval, ExpDT]),
    TRef = erlang:send_after(CleanInterval, Self, {clean, ExpireTime}),
    loop(Parent, Debug, State#state{tref=TRef, expire_time=ExpireTime}).

loop(Parent, Debug, State=#state{tref=TRef}) ->
    receive
        {system, From, Request} ->
            sys:handle_system_msg(
                Request, From, Parent, ?MODULE, Debug, State
            );
        {force_clean, ExpireTime} ->
            erlang:cancel_timer(TRef),
            NxtState= do_clean(ExpireTime, State),
            loop(Parent, Debug, NxtState);
        {clean, ExpireTime} ->
            NxtState= do_clean(ExpireTime, State),
            loop(Parent, Debug, NxtState);
        stop ->
            erlang:cancel_timer(TRef),
            ok;
        Msg ->
            % Let's print unknown messages.
            sys:handle_debug(
                Debug, fun ?MODULE:write_debug/3, ?MODULE, {in, Msg}
            ),
            loop(Parent, Debug, State)
    end.

do_clean(ExpireTime, State=#state{clean_interval=CleanInterval}) ->
    NxtExpireTime = now(),
    NxtExpDT = calendar:now_to_local_time(NxtExpireTime),
    lager:info("~s started, next cleanup in ~w ms, next expire time ~p",
               [?MODULE, CleanInterval, NxtExpDT]),
    Cnt = etracker_db:expire_torrent_peers(ExpireTime),
    etracker_event:cleanup_completed(Cnt),
    lager:info("~s cleanup completed, deleted ~w", [?MODULE, Cnt]),
    Self = self(),
    TRef = erlang:send_after(CleanInterval, Self, {clean, NxtExpireTime}),
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
