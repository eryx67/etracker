-module(etracker_app).

-behaviour(application).

-export([start/0, start/2, stop/1]).

-define(APP, etracker).

start() ->
    application:load(?APP),
    start_app_deps(?APP),
    application:start(?APP).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(_StartType, _StartArgs) ->
    etracker_sup:start_link().

stop(_State) ->
    ok.

start_app_deps(App) ->
    {ok, DepApps} = application:get_key(App, applications),
    lists:foreach(fun ensure_started/1, DepApps),
    ok.

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.
