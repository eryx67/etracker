
-module(etracker_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD_TIMEOUT(I, Type, Timeout), {I, {I, start_link, []}, permanent, Timeout, Type, [I]}).
-define(SUPERVISOR(I), {I, {I, start_link, []}, permanent, infinity, supervisor, [I]}).
-define(WORKER(I, A), {I, {I, start_link, A}, permanent, 5000, worker, [I]}).
-define(WORKER1(N, I, A), {N, {I, start_link, A}, permanent, 5000, worker, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    DbSup = ?SUPERVISOR(etracker_db_sup),
    HttpSrv = ?CHILD(etracker_http_srv, worker),
    UdpJobs = ?WORKER1(etracker_jobs_udp, etracker_jobs, [etracker_udp_srv:job_queue_name(), udp]),
    UdpSrv = ?CHILD(etracker_udp_srv, worker),
    EventMgr = ?CHILD(etracker_event, worker),
    {ok, {{one_for_one, 5, 10}, [EventMgr, DbSup, HttpSrv, UdpJobs, UdpSrv]}}.
