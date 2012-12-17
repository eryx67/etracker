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

-export([announce/1, cleanup_completed/0]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).

%% @doc Publish event about received announce.
%% @end
%% @equiv notify({announce, #announce{}}).
-spec announce(#announce{}) -> ok.
announce(Ann) ->
    notify({announce, Ann}).

cleanup_completed() ->
    notify(cleanup_completed).

%% @doc Creates an event manager
%% @end
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_event:start_link({local, ?SERVER}).

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
%% Internal functions
%%%===================================================================

%% @doc Notify the event system of an event
%% <p>The system accepts any term as the event.</p>
%% @end
-spec notify(term()) -> ok.
notify(What) ->
    gen_event:notify(?SERVER, What).
