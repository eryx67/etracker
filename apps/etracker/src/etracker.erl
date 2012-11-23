-module(etracker).

-export([start/0, stop/0]).

start() ->
    ensure_started(crypto),
    ensure_started(cowboy),
    ensure_started(lager),
    application:start(etracker).

stop() ->
    application:stop(etracker).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.
