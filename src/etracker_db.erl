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
-export([start_link/0, stop/0, stats_update/0]).
-export([announce/1, full_scrape/2, torrent_info/1, torrent_infos/2, torrent_peers/2]).
-export([cleanup_table/1, write/1, member/2]).
-export([import/4, db_call/1, db_call/2, db_cast/1]).

-include("../include/etracker.hrl").

-define(SERVER, ?MODULE).
-define(STATS_TAG, ?MODULE).

-define(STATS_DB_KEYS, [torrents,
                        alive_torrents,
                        seederless_torrents,
                        peerless_torrents,
                        seeders,
                        leechers,
                        peers
                      ]).

-define(TIMEOUT, 60 * 1000).

start_link() ->
    {ok, Cwd} = file:get_cwd(),
    CacheDir = filename:absname(confval(db_cache_dir, "etracker_data"),
                                Cwd),
    ok = filelib:ensure_dir(filename:join(CacheDir, "tmp")),
    etracker_env:set(db_cache_dir, CacheDir),
    init_stats(),
    DefaultOpts = {
      [{worker_module, etracker_ets},
       {size, 5}, {max_overflow, 10}
      ],
      []
     },
    {PoolOpts, WorkerArgs} = confval(db_pool, DefaultOpts),
    PoolArgs = [{name, {local, ?SERVER}}|PoolOpts],
    poolboy:start_link(PoolArgs, WorkerArgs).

stop() ->
    poolboy:stop(?SERVER).

init_stats() ->
    lists:foreach(fun (CN) ->
                          Cnt = {?STATS_TAG, CN},
                          case folsom_metrics:metric_exists(Cnt) of
                              false ->
                                  folsom_metrics:new_gauge(Cnt),
                                  folsom_metrics:tag_metric(Cnt, ?STATS_TAG);
                              true ->
                                  ok
                          end
                  end, ?STATS_DB_KEYS).

stats_update() ->
    FullPeriodNames = [seeders, leechers, torrents, peers],
    lists:foreach(fun (N) ->
                          stats_set(N, db_call({stats_info, N}, infinity))
                  end, FullPeriodNames),
    Period = torrents_info_query_period(),
        lists:foreach(fun (N) ->
                          stats_set(N, db_call({stats_info, N, Period}, infinity))
                  end, ?STATS_DB_KEYS -- FullPeriodNames).

stats_set(Name, Val) ->
    Cnt = {?STATS_TAG, Name},
    ok = folsom_metrics:notify({Cnt, Val}).

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

cleanup_table(Table=torrent_user) ->
    AnswerInterval = etracker_env:get(answer_interval, ?ANNOUNCE_ANSWER_INTERVAL),
    CleanInterval = etracker_env:get(clean_interval, round(AnswerInterval * 1.5)),
    ExpireTime = etracker_time:now_sub_sec(now(), CleanInterval),
    PeersCnt = expire(Table, ExpireTime),
    etracker_event:cleanup_completed(peers, PeersCnt),
    lager:info("~w cleanup completed, deleted ~w", [Table, PeersCnt]);
cleanup_table(Table=udp_connection_info) ->
    AnswerInterval = etracker_env:get(answer_interval, ?ANNOUNCE_ANSWER_INTERVAL),
    CleanInterval = etracker_env:get(clean_interval, round(AnswerInterval * 1.5)),
    ExpireTime = etracker_time:now_sub_sec(now(), CleanInterval),
    ConnCnt = expire(Table, ExpireTime),
    etracker_event:cleanup_completed(udp_connections, ConnCnt),
    lager:info("~w cleanup completed, deleted ~w", [Table, ConnCnt]).

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
