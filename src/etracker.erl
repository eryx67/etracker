-module(etracker).

-export([start/0, stop/0, info/0, info/1]).

start() ->
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
