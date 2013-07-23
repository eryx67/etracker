%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 22 May 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_jobs).

-export([start_link/0, start_link/2, stop/0]).
-export([run_job/1, run_job/3, run_jobs/1]).
-export([run_job/2, run_job/4, run_jobs/2]).

-export([add_job/1, add_job/3, add_link_job/1, add_link_job/3]).
-export([add_job/2, add_job/4, add_link_job/2, add_link_job/4]).
-export([info/0]).

-define(QNAME, ?MODULE).

-define(STATS_TAG, ?MODULE).
-define(STATS_NAME(N), {?STATS_TAG, N}).
-define(STATS_COUNTER_NAME(N, NC), {?STATS_TAG, N, NC}).
-define(STATS_COUNTERS, [overload, queue_full, concurrency_full]).

-spec start_link() -> {ok, pid()} | no_return().
start_link() ->
    start_link(?QNAME, common).

start_link(Name, QueueName) ->
    Default = [{hz, 1000},
               {rate, 1024},
               {token_limit, 1024},
               {size, 131072},
               {concurrency, 65536},
               {queue_type, sv_codel},
               {queue_args, [100, 10000]}
              ],
    Conf = proplists:get_value(QueueName, etracker_env:get(jobs, []), Default),
    C = sv_queue:parse_configuration(Conf),
    {ok, _} = Ret = sv_queue:start_link(Name, C),
    stats_add_queue(Name, QueueName, Conf),
    Ret.

stats_add_queue(Name, QueueName, Conf) ->
    StatsName = ?STATS_NAME(Name),
    gproc:add_local_name(StatsName),
    gproc:set_value({n, l, StatsName}, [{name, QueueName}|Conf]),
    lists:foreach(fun (CN) ->
                          folsom_metrics:new_spiral(?STATS_COUNTER_NAME(Name, CN)),
                          folsom_metrics:tag_metric(?STATS_COUNTER_NAME(Name, CN), ?STATS_TAG)
                  end, ?STATS_COUNTERS).

stats_inc(Name, Counter) ->
    folsom_metrics:notify({?STATS_COUNTER_NAME(Name, Counter), 1}).

-spec stop() -> ok.
stop() ->
    %% etracker_jobs_srv:stop(),
    ok.

-spec run_jobs(list([function() | {module(), atom(), list(term())}])) ->
                           [term()|{error, term()}].
run_jobs(Funs) ->
    run_jobs(?QNAME, Funs).

run_jobs(Name, Funs) ->
    Self = self(),
    [wait_job_result(W) || W <- [spawn_job_worker(Self, Name, F) || F <- Funs]].

spawn_job_worker(Parent, Name, Fun) ->
    ExecF = fun () ->
                    case Fun of
                        {M, F, A} ->
                            run_job(Name, M, F, A);
                        _ ->
                            run_job(Name, Fun)
                    end
            end,
    erlang:spawn_monitor(fun() -> Parent ! {self(), ExecF()} end).

wait_job_result({Pid, Ref}) ->
    receive
        {'DOWN', Ref, _, _, normal} -> receive {Pid, Result} -> Result end;
        {'DOWN', Ref, _, _, Reason} -> {error, Reason}
    end.

run_job(M, F, Args) ->
    run_job(?QNAME, M, F, Args).

-spec run_job(atom(), module(), function(), list(term())) -> term().
run_job(Name, M, F, Args) ->
    Fun = fun () -> erlang:apply(M, F, Args) end,
    run_job(Name, Fun).

run_job(Fun) ->
    run_job(?QNAME, Fun).

-spec run_job(atom(), function()) -> term().
run_job(Name, Fun) ->
    case sv:run(Name, Fun) of
        {ok, Res} ->
            Res;
        Error={error, Reason} ->
            stats_inc(Name, Reason),
            Error
    end.

add_job(M, F, Args) ->
    add_job(?QNAME, M, F, Args).

-spec add_job(atom(), module(), function(), list(term())) -> ok.
add_job(Name, M, F, Args) ->
    add_job(Name, fun () -> erlang:apply(M, F, Args) end).

add_job(Fun) ->
    add_job(?QNAME, Fun).

-spec add_job(atom(), function()) -> ok.
add_job(Name, Fun) ->
    spawn(fun () -> run_job(Name, Fun) end).

add_link_job(M, F, Args) ->
    add_link_job(?QNAME, M, F, Args).

-spec add_link_job(atom(), module(), function(), list(term())) -> ok.
add_link_job(Name, M, F, Args) ->
    add_link_job(Name, fun () -> erlang:apply(M, F, Args) end).

add_link_job(Fun) ->
    add_link_job(?QNAME, Fun).

-spec add_link_job(atom(), function()) -> ok.
add_link_job(Name, Fun) ->
    spawn_link(fun () -> run_job(Name, Fun) end).

info() ->
    [{tokens, sv_queue:q(?QNAME, tokens)}].
