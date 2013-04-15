%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_db).

%% API
-export([start_link/0, stop/0]).
-export([system_info/0, system_info/1, system_info_update_counter/2]).
-export([announce/1, torrent_info/1, torrent_infos/1, torrent_peers/2]).
-export([expire_torrent_peers/1]).

-define(SERVER, ?MODULE).
-define(INFO_TBL, etracker_info).

-define(INFO_DB_KEYS, [torrents,
                       seeders,
                       leechers,
                       peers
                      ]).

-define(INFO_COUNTERS, [announces,
                        scrapes,
                        invalid_queries,
                        failed_queries,
                        unknown_queries,
                        deleted_peers
                       ]).

-define(INFO_KEYS, (?INFO_COUNTERS ++ ?INFO_DB_KEYS)).

-define(TIMEOUT, 30 * 1000).

start_link() ->
    ets:new(?INFO_TBL, [named_table, set, public, {write_concurrency, true}]),
    ets:insert(?INFO_TBL, [{K, 0} || K <- ?INFO_COUNTERS]),
    DefaultOpts = {
      [{worker_module, etracker_mnesia},
       {size, 5}, {max_overflow, 10}
      ],
      []
     },
    {PoolOpts, WorkerArgs} = confval(db_pool, DefaultOpts),
    PoolArgs = [{name, {local, ?SERVER}}|PoolOpts],
    poolboy:start_link(PoolArgs, WorkerArgs).

stop() ->
    poolboy:stop(?SERVER).

announce(Ann) ->
	db_cast({announce, Ann}).

torrent_peers(InfoHash, Num) ->
    CacheTTL = confval(db_cache_peers_ttl, 0),
    CacheKey = {torrent_peers, InfoHash},
    Req = {torrent_peers, InfoHash, Num},
    case CacheTTL of
        0 ->
            db_call(Req);
        _ ->
            case etracker_db_cache:get(CacheKey) of
                undefined ->
                    Res = db_call(Req),
                    etracker_db_cache:put_ttl(CacheKey, Res, CacheTTL),
                    Res;
                {ok, Res} ->
                    Res
            end
    end.

expire_torrent_peers(ExpireTime) ->
    db_call({expire_torrent_peers, ExpireTime}, infinity).

torrent_info(InfoHash) when is_binary(InfoHash) ->
	db_call({torrent_info, InfoHash}).

torrent_infos(InfoHashes) when is_list(InfoHashes) ->
	db_call({torrent_infos, InfoHashes, self()}).

system_info() ->
    [{K, system_info(K)} || K <- ?INFO_DB_KEYS] ++ ets:tab2list(?INFO_TBL).

system_info(info_keys) -> ?INFO_KEYS;
system_info(Key) when Key == seeders
                      orelse Key == leechers ->
    CacheTTL = confval(db_cache_peers_ttl, 0),
    Req = CacheKey = {system_info, Key},
    case CacheTTL of
        0 ->
            db_call(Req, infinity);
        _ ->
            case etracker_db_cache:get(CacheKey) of
                undefined ->
                    Res = db_call(Req, infinity),
                    etracker_db_cache:put_ttl(CacheKey, Res, CacheTTL),
                    Res;
                {ok, Res} ->
                    Res
            end
    end;
system_info(Key) when Key == torrents
                      orelse Key == peers ->
    db_call({system_info, Key});
system_info(Key) when Key == announces
                      orelse Key == scrapes
                      orelse Key == unknown_queries
                      orelse Key == failed_queries
                      orelse Key == invalid_queries
                      orelse Key == deleted_peers ->
    case ets:lookup(?INFO_TBL, Key) of
        [{_, Val}] ->
            Val;
        _ ->
            0
    end;
system_info(Key) ->
    error({invalid_key, Key}).

system_info_update_counter(Key, Inc) when Key == announces
                                          orelse Key == scrapes
                                          orelse Key == unknown_queries
                                          orelse Key == failed_queries
                                          orelse Key == invalid_queries
                                          orelse Key == deleted_peers ->
    ets:update_counter(?INFO_TBL, Key, Inc).

confval(Key, Default) ->
    etracker_env:get(Key, Default).

db_call(Args) ->
    db_call(Args, ?TIMEOUT).

db_call(Args, Timeout) ->
    poolboy:transaction(?SERVER,
                        fun (W) ->
                                gen_server:call(W, Args, Timeout)
                        end,
                        Timeout).

db_cast(Args) ->
    poolboy:transaction(?SERVER,
                        fun (W) ->
                                gen_server:cast(W, Args)
                        end,
                        ?TIMEOUT).
