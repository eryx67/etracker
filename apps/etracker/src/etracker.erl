-module(etracker).

-export([start/0, stop/0, info/0, info/1]).

start() ->
    %% ensure_started(ranch),
    ensure_started(crypto),
    ensure_started(cowboy),
    ensure_started(syntax_tools),
    ensure_started(compiler),
    ensure_started(lager),
    application:start(etracker).

stop() ->
    application:stop(etracker).

info() ->
    etracker_db:system_info().

info([]) ->
    info();
info(Keys) when is_list(Keys) ->
    [{Key, etracker_db:system_info(Key)} || Key <- Keys];
info(Key) ->
    etracker_db:system_info(Key).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.
