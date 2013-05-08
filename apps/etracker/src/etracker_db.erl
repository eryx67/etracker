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
-export([announce/1, full_scrape/2, torrent_info/1, torrent_infos/2, torrent_peers/2]).
-export([expire/2, write/1, member/2]).
-export([import/4, db_call/1, db_call/2, db_cast/1]).

-define(SERVER, ?MODULE).
-define(INFO_TBL, etracker_info).

-define(INFO_DB_KEYS, [torrents,
                       alive_torrents,
                       seederless_torrents,
                       peerless_torrents,
                       seeders,
                       leechers,
                       peers
                      ]).

-define(INFO_COUNTERS, [announces,
                        scrapes,
                        full_scrapes,
                        invalid_queries,
                        failed_queries,
                        unknown_queries,
                        deleted_peers,
                        udp_connections,
                        udp_deleted_connections
                       ]).

-define(INFO_KEYS, (?INFO_COUNTERS ++ ?INFO_DB_KEYS)).

-define(TIMEOUT, 60 * 1000).

start_link() ->
    {ok, Cwd} = file:get_cwd(),
    CacheDir = filename:absname(confval(db_cache_dir, "etracker_data"),
                                Cwd),
    ok = filelib:ensure_dir(filename:join(CacheDir, "tmp")),
    etracker_env:set(db_cache_dir, CacheDir),
    ets:new(?INFO_TBL, [named_table, set, public,
                        {read_concurrency, true}, {write_concurrency, true}]),
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
	db_call({announce, Ann}).

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

expire(Type, ExpireTime) ->
    db_call({expire, Type, ExpireTime}, infinity).

full_scrape(FileName, EncodeFun) ->
    CacheTTL = confval(db_cache_full_scrape_ttl, 0),
    CacheKey = {file, FileName},
    case CacheTTL of
        0 ->
            false;
        _ ->
            case etracker_db_cache:get(CacheKey) of
                undefined ->
                    Self = self(),
                    {ok, CacheDir} = confval(db_cache_dir),
                    FN = filename:absname(FileName, CacheDir),
                    WriterF = fun () ->
                                    write_full_scrape(FN, EncodeFun)
                              end,
                    {Pid, OwnerPid} = gproc:reg_or_locate({n, l, CacheKey}, Self, WriterF),
                    MonRef = erlang:monitor(process, Pid),
                    receive
                        {'DOWN', MonRef, _, Pid, Reason} ->
                            if (Reason == normal) orelse (Reason == noproc) ->
                                    case OwnerPid of
                                        Self ->
                                            etracker_db_cache:put_ttl(CacheKey, FN, CacheTTL);
                                        _ ->
                                            ok
                                    end,
                                    {ok, FN};
                                true ->
                                    {error, Reason}
                            end
                    end;
                Res ->
                    Res
            end
    end.

write_full_scrape(FileName, EncodeFun) ->
    {ok, Fd} = file:open(FileName, [write]),
    WriteF = fun (Data) ->
                     EncData = EncodeFun(Data),
                     ok = file:write(Fd, EncData)
             end,
    torrent_infos([], WriteF),
    ok = file:close(Fd).

torrent_info(InfoHash) when is_binary(InfoHash) ->
	db_call({torrent_info, InfoHash}).

torrent_infos(InfoHashes, Callback) when is_list(InfoHashes) ->
    Period = torrents_info_query_period(),
	db_call({torrent_infos, InfoHashes, Period, Callback}, infinity).

write(Data) ->
    db_call({write, Data}).

member(Tbl, Key) ->
    db_call({member, Tbl, Key}).

system_info() ->
    [{K, system_info(K)} || K <- ?INFO_DB_KEYS] ++ ets:tab2list(?INFO_TBL).

system_info(info_keys) -> ?INFO_KEYS;
system_info(Key) when Key == seeders
                      orelse Key == leechers
                      orelse Key == alive_torrents
                      orelse Key == seederless_torrents
                      orelse Key == peerless_torrents ->
    CacheTTL = confval(db_cache_peers_ttl, 0),
    CacheKey = {system_info, Key},
    Req = if (Key == leechers) orelse (Key == seeders) ->
                  CacheKey;
             true ->
                  Period = torrents_info_query_period(),
                  {system_info, Key, Period}
          end,
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
                      orelse Key == full_scrapes
                      orelse Key == unknown_queries
                      orelse Key == failed_queries
                      orelse Key == invalid_queries
                      orelse Key == deleted_peers
                      orelse Key == udp_deleted_connections
                      orelse Key == udp_connections ->
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
                                          orelse Key == full_scrapes
                                          orelse Key == unknown_queries
                                          orelse Key == failed_queries
                                          orelse Key == invalid_queries
                                          orelse Key == deleted_peers
                                          orelse Key == udp_deleted_connections
                                          orelse Key == udp_connections ->
    ets:update_counter(?INFO_TBL, Key, Inc).

% seconds
torrents_info_query_period() ->
    etracker_env:get(answer_interval, 1800) * 3.

import(MgrModule, DbModule, MgrParams, DbParams) ->
    {ok, MgrPid} = MgrModule:start_link(MgrParams),
    {ok, DbPid} = DbModule:start_link(DbParams),
    ImportF = fun (Rec, Cnt) ->
                      ok = db_call({write, Rec}),
                      Cnt + 1
              end,
    InfoCnt = gen_server:call(DbPid, {fold, torrent_info, 0, ImportF}, infinity),
    UserCnt = gen_server:call(DbPid, {fold, torrent_user, 0, ImportF}, infinity),
    DbModule:stop(DbPid),
    MgrModule:stop(MgrPid),
    {ok, {InfoCnt, UserCnt}}.

confval(Key) ->
    etracker_env:get(Key).

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
