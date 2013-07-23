%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 10 Apr 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_db_cache).


%% API
-export([start_link/0, stop/0, reset/0, put/2, put_ttl/3, get/1, remove/1]).

-define(SERVER, ?MODULE).

start_link() ->
    CacheSize = confval(db_cache_size, undefined),
    etsachet:start_link(?SERVER, CacheSize).

stop() ->
    etsachet:stop(?SERVER).

reset() ->
    etsachet:reset(?SERVER).

put(Key, Val) ->
    etsachet:put(?SERVER, Key, Val).

put_ttl(Key, Val, TTL) ->
    etsachet:put_ttl(?SERVER, Key, Val, TTL).

get(Key) ->
    etsachet:get(?SERVER, Key).

remove(Key) ->
    etsachet:remove(?SERVER, Key).

confval(Key, Default) ->
    etracker_env:get(Key, Default).
