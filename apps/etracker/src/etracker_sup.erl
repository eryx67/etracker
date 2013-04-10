
-module(etracker_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    DbSrv = ?CHILD(etracker_db, worker),
    DbCache = ?CHILD(etracker_db_cache, worker),
    HttpSrv = ?CHILD(etracker_http_srv, worker),
    EventMgr = ?CHILD(etracker_event, worker),
    Cleaner = ?CHILD(etracker_cleaner, worker),
    {ok, {{one_for_one, 5, 10}, [EventMgr, DbSrv, DbCache, HttpSrv, Cleaner]}}.
