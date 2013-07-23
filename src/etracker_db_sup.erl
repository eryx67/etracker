%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created :  2 Jul 2013 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_db_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include("../include/etracker.hrl").

-define(SERVER, ?MODULE).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD_TIMEOUT(I, Type, Timeout), {I, {I, start_link, []}, permanent, Timeout, Type, [I]}).
-define(SUPERVISOR(I), {I, {I, start_link, []}, permanent, infinity, supervisor, [I]}).
-define(WORKER(I, A), {I, {I, start_link, A}, permanent, 5000, worker, [I]}).
-define(WORKER1(N, I, A), {N, {I, start_link, A}, permanent, 5000, worker, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([]) ->
    RestartStrategy = rest_for_one,
    MaxRestarts = 5,
    MaxSecondsBetweenRestarts = 10,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    Db = ?CHILD(etracker_db, worker),
    DbCache = ?CHILD(etracker_db_cache, worker),
    DbMgr = ?CHILD_TIMEOUT(etracker_db_mgr, worker, 1800000),

    Workers =
        begin
            UpdTTL = max(etracker_env:get(db_cache_peers_ttl, 120) * 5, 600) * 1000,
            StatsF = fun (_) -> etracker_db:stats_update() end,
            Stats = ?WORKER1(stats, gencron_periodic, [stats, UpdTTL, StatsF]),

            AnswerIntervalSec = etracker_env:get(answer_interval, ?ANNOUNCE_ANSWER_INTERVAL),
            CleanIntervalSec = etracker_env:get(clean_interval, round(AnswerIntervalSec * 1.5)),
            CleanIntervalMs = CleanIntervalSec * 1000,
            etracker_env:set(clean_interval, CleanIntervalSec),
            Cleaners = lists:map(
                         fun (TblName) ->
                                 F = fun (_) -> etracker_db:cleanup_table(TblName) end,
                                 ?WORKER1(TblName, gencron_periodic, [TblName, CleanIntervalMs, F])
                         end,
                         [torrent_user, udp_connection_info]),
            [Stats|Cleaners]
        end,
    {ok, {SupFlags, [DbMgr, Db, DbCache|Workers]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
