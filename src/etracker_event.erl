%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 19 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_event).

%% API
-export([start_link/0, add_handler/2, add_sup_handler/2, delete_handler/2]).

-export([announce/1, scrape/1, invalid_query/1, failed_query/1, unknown_query/1, cleanup_completed/2]).
-export([subscribe/0, subscribe/1, unsubscribe/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-export_type([event/0, event_handler/0, event_filter/0, notify_event/0, handler_ref/0]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(STATS_TAG, ?MODULE).

-record(state, {handler, handler_state}).

-define(STATS_COUNTERS, [announces,
                         scrapes,
                         full_scrapes,
                         invalid_queries,
                         failed_queries,
                         unknown_queries,
                         deleted_peers,
                         udp_connections,
                         udp_deleted_connections
                        ]).

-type event() :: {announce, #announce{}} | {scrape, #scrape{}} | {invalid_query, term()}
                 | {failed_query, term()} | {unknown_query, term()}
                 |{cleanup_completed, udp_connections | peers, integer()}.
-type event_handler_state() :: term().
-type event_handler() :: fun((event(), event_handler_state()) -> event_handler_state()).
-type event_filter() :: fun((event()) -> boolean()).
-type notify_event() :: {etracker_event, event()}.
-type handler_ref() :: term().

-spec subscribe() -> handler_ref() | no_return().
subscribe() ->
    Self = self(),
    gen_event:add_sup_handler(?SERVER, {?MODULE, pid_to_list(Self)}, #state{handler=Self}).

-spec subscribe(event_filter()) -> handler_ref() | no_return().
subscribe(FilterF) ->
    Self = self(),
    HlrF = fun (Event, Pid) ->
                   case FilterF(Event) of
                       true ->
                           send_event(Pid, Event);
                       false ->
                           ok
                   end,
                   Pid
           end,
    State = #state{handler=HlrF, handler_state=Self},
    gen_event:add_sup_handler(?SERVER, {?MODULE, pid_to_list(Self)}, State).

unsubscribe() ->
    Self = self(),
    gen_event:delete_handler(?SERVER, {?MODULE,  pid_to_list(Self)}, []).

%% @doc Publish event about received announce.
%% @end
%% @equiv notify({announce, #announce{}}).
-spec announce(#announce{}) -> ok.
announce(Ann) ->
    notify({announce, Ann}).

scrape(InfoHashes) ->
    notify({scrape, InfoHashes}).

cleanup_completed(Type, Deleted) ->
    notify({cleanup_completed, Type, Deleted}).

invalid_query(Error) ->
    notify({invalid_query, Error}).

failed_query(Error) ->
    notify({failed_query, Error}).

unknown_query(Path) ->
    notify({unknown_query, Path}).

%% @doc Creates an event manager
%% @end
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    {ok, _} = Ret = gen_event:start_link({local, ?SERVER}),
    ok = add_handler(?MODULE, []),
    Ret.

%% @doc Adds an supervised event handler
%% @end
-spec add_sup_handler(event_handler(), event_handler_state()) -> ok | no_return();
                 (pid(), {atom(), term()}) -> ok | no_return();
                 (atom(), {atom(), term()}) -> ok | no_return() .
add_sup_handler(HlrF, HlrState) when is_function(HlrF)->
    HlrRef = {?MODULE, make_ref()},
    gen_event:add_sup_handler(?SERVER, HlrRef, #state{handler=HlrF, handler_state=HlrState}),
    HlrRef;
add_sup_handler(Hlr, Args) ->
    gen_event:add_sup_handler(?SERVER, Hlr, Args).

%% @doc Adds an event handler
%% @end
-spec add_handler(event_handler(), event_handler_state()) -> ok | no_return();
                 (pid(), {atom(), term()}) -> ok | no_return();
                 (atom(), {atom(), term()}) -> ok | no_return() .
add_handler(HlrF, HlrState) when is_function(HlrF)->
    HlrRef = {?MODULE, make_ref()},
    gen_event:add_handler(?SERVER, HlrRef, #state{handler=HlrF, handler_state=HlrState}),
    HlrRef;
add_handler(Hlr, Args) ->
    gen_event:add_handler(?SERVER, Hlr, Args).

%% @doc Adds an event handler
%% @end
-spec delete_handler(atom() | {atom(), term()}, term()) -> term() | {error,module_not_found} | {'EXIT', term()}.
delete_handler(Hlr, Args) ->
    gen_event:delete_handler(?SERVER, Hlr, Args).

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================

init(S=#state{}) ->
    {ok, S};
init([]) ->
    init_stats(),
    {ok, #state{}}.
handle_event(Event, S=#state{handler=HlrPid}) when is_pid(HlrPid) ->
    HlrPid ! {etracker_event, Event},
    {ok, S};
handle_event(Event, S=#state{handler=HlrF, handler_state=HlrState})
  when is_function(HlrF) ->
    {ok, S=#state{handler_state=HlrF(Event, HlrState)}};
handle_event({announce, #announce{protocol=Proto}}, State)->
    stats_inc(announces, 1),
    case Proto of
        udp ->
            stats_inc(udp_connections, 1);
        _ ->
            ok
    end,
    {ok, State};
handle_event({scrape, #scrape{info_hashes=IHs, protocol=Proto}}, State)->
    stats_inc(scrapes, 1),

    case IHs of
        [] ->
            stats_inc(full_scrapes, 1);
        _ ->
            ok
    end,

    case Proto of
        udp ->
            stats_inc(udp_connections, 1);
        _ ->
            ok
    end,
    {ok, State};
handle_event({invalid_query, _Data}, State)->
    stats_inc(invalid_queries, 1),
    {ok, State};
handle_event({failed_query, _Data}, State)->
    stats_inc(failed_queries, 1),
    {ok, State};
handle_event({unknown_query, _Data}, State)->
    stats_inc(unknown_queries, 1),
    {ok, State};
handle_event({cleanup_completed, peers, Deleted}, State)->
    stats_inc(deleted_peers, Deleted),
    {ok, State};
handle_event({cleanup_completed, udp_connections, Deleted}, State)->
    stats_inc(udp_deleted_connections, Deleted),
    {ok, State};
handle_event(_, State) ->
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%% Internal functions
%%%===================================================================
send_event(Pid, Event) ->
    Pid ! {?MODULE, Event}.

init_stats() ->
    lists:foreach(fun (CN) ->
                          Cnt = {?STATS_TAG, CN},
                          case folsom_metrics:metric_exists(Cnt) of
                              false ->
                                  folsom_metrics:new_spiral(Cnt),
                                  folsom_metrics:tag_metric(Cnt, ?STATS_TAG);
                              true ->
                                  ok
                          end
                  end, ?STATS_COUNTERS).

stats_inc(Name, Val) ->
    Cnt = {?STATS_TAG, Name},
    ok = folsom_metrics:notify({Cnt, Val}).

%% @doc Notify the event system of an event
%% <p>The system accepts any term as the event.</p>
%% @end
-spec notify(term()) -> ok.
notify(What) ->
    gen_event:notify(?SERVER, What),
    ok.
