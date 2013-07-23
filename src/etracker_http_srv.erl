%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 12 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_http_srv).

-behaviour(gen_server).

%% API
-export([start_link/0, dispatch_rules/0, dispatch_rules/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(HTTP_LISTENER, etracker_http).
-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

dispatch_rules(Disp) ->
    cowboy:set_env(?HTTP_LISTENER, dispatch, cowboy_router:compile(Disp)).

dispatch_rules() ->
    {ok, App} = application:get_application(),
    PrivDir = case code:priv_dir(App) of
                  {error,_} -> filename:absname("priv");
                  Priv -> Priv
              end,
    WwwDir = filename:join([PrivDir, confval(www_dir, "www")]),
    CommonParams = [{www_dir, WwwDir}],
    AnnounceParams = lists:map(fun ({Attr, Default}) ->
                                       {Attr, confval(Attr, Default)}
                               end,
                               [
                                {answer_compact, false},
                                {answer_max_peers, ?ANNOUNCE_ANSWER_MAX_PEERS},
                                {answer_interval, ?ANNOUNCE_ANSWER_INTERVAL}
                               ]) ++ CommonParams,
    ScrapeParams = lists:map(fun ({Attr, Default}) ->
                                       {Attr, confval(Attr, Default)}
                               end,
                               [
                                {scrape_request_interval, 60 * 30}
                               ]) ++ CommonParams,
    %% {Host, list({Path, Handler, Opts})}
    [{'_', [{"/", cowboy_static, [{directory, WwwDir}
                                  , {file, <<"html/index.html">>}
                                  , {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
                                 ]}
            , {"/announce", etracker_http_request, {announce, AnnounceParams}}
            , {"/scrape", etracker_http_request, {scrape, ScrapeParams}}
            , {"/_stats", etracker_http_request, {stats, CommonParams}}
            , {"/_stats/[:metric_id]", etracker_http_request, {stats, CommonParams}}
           ]}].

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port = confval(http_port, 8181),
    Ip = confval(http_ip, "127.0.0.1"),
    NumAcceptors = confval(http_num_acceptors, 16),
    IpStr = case is_list(Ip) of true -> Ip; false -> inet_parse:ntoa(Ip) end,
    lager:info("listening on http://~s:~B/~n", [IpStr,Port]),
    Dispatch = cowboy_router:compile(dispatch_rules()),
    {ok, _Pid} = cowboy:start_http(?HTTP_LISTENER, NumAcceptors,
                                   [{port, Port}
                                    , {max_connections, infinity}
                                   ],
                                   [{env, [{dispatch, Dispatch}]}]
                                  ),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok = cowboy:stop_listener(?HTTP_LISTENER),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

confval(Key, Default) ->
    etracker_env:get(Key, Default).
