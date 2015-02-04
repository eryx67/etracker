-module(etracker_app).

-behaviour(application).

-export([start/0, start/2, stop/1]).

-define(APP, etracker).

start() ->
    application:load(?APP),
    application:ensure_all_started(?APP).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(_StartType, _StartArgs) ->
    etracker_sup:start_link().

stop(_State) ->
    ok.
