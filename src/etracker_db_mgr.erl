%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_db_mgr).

%% API
-export([start_link/0, stop/0]).

-define(SERVER, ?MODULE).

start_link() ->
    DefaultOpts = {etracker_ets_mgr, [{dir, "etracker_data"},
                                      {dump_interval, 3600},
                                      %% {db_type, ets}
                                      {db_type, dict}
                                     ]},
    {Module, Args} = confval(db_mgr, DefaultOpts),
    Ret = Module:start_link(Args),
    case Ret of
        {ok, Pid} ->
            register(?SERVER, Pid);
        _ ->
            ok
    end,
    Ret.

stop() ->
    ?SERVER ! stop,
    ok.

confval(Key, Default) ->
    etracker_env:get(Key, Default).
