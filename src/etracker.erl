-module(etracker).

-export([start/0, stop/0, stats/0, stats/1, stats_info/0, stats_info/1]).

-define(APP, etracker).
-define(STATS_MODULES, [etracker_db, etracker_event, etracker_jobs]).

start() ->
    etracker_app:start().

stop() ->
    application:stop(?APP).

stats() ->
    lists:flatten([folsom_metrics:get_metrics_value(M) || M <- ?STATS_MODULES]).

stats_info() ->
     lists:flatten([folsom_metrics:get_metric_info(M) || {M, _} <- stats()]).

stats(Module) ->
    UnwrapF = fun ({K, V}) -> {erlang:delete_element(1, K), V} end,
    [UnwrapF(KV) || KV <- folsom_metrics:get_metrics_value(Module)].

stats_info(Module) ->
    UnwrapF = fun ([{K, V}]) -> {erlang:delete_element(1, K), V} end,
    [UnwrapF(folsom_metrics:get_metric_info(K))
     || {K, _} <- folsom_metrics:get_metrics_value(Module)].
