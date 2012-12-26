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
-export([start_link/0, add_handler/2, delete_handler/2]).

-export([announce/1, scrape/1, invalid_query/1, failed_query/1, unknown_query/1, cleanup_completed/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

%% @doc Publish event about received announce.
%% @end
%% @equiv notify({announce, #announce{}}).
-spec announce(#announce{}) -> ok.
announce(Ann) ->
    notify({announce, Ann}).

scrape(InfoHashes) ->
    notify({scrape, InfoHashes}).

cleanup_completed(Deleted) ->
    notify({cleanup_completed, Deleted}).

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

%% @doc Adds an event handler
%% @end
-spec add_handler(atom() | {atom(), term()}, term()) -> ok | {'EXIT', term()} | term().
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

init([]) ->
    {ok, #state{}}.

handle_event({announce, _Data}, State)->
    etracker_db:system_info_update_counter(announces, 1),
    {ok, State};
handle_event({scrape, _Data}, State)->
    etracker_db:system_info_update_counter(scrapes, 1),
    {ok, State};
handle_event({invalid_query, _Data}, State)->
    etracker_db:system_info_update_counter(invalid_queries, 1),
    {ok, State};
handle_event({failed_query, _Data}, State)->
    etracker_db:system_info_update_counter(failed_queries, 1),
    {ok, State};
handle_event({unknown_query, _Data}, State)->
    etracker_db:system_info_update_counter(unknown_queries, 1),
    {ok, State};
handle_event({cleanup_completed, Deleted}, State)->
    etracker_db:system_info_update_counter(deleted_peers, Deleted),
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

%% @doc Notify the event system of an event
%% <p>The system accepts any term as the event.</p>
%% @end
-spec notify(term()) -> ok.
notify(What) ->
    gen_event:notify(?SERVER, What).
