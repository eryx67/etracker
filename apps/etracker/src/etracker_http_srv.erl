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
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).
-include("etracker.hrl").

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Port = confval(http_port, 8080),
    Ip = confval(http_ip, "127.0.0.1"),
    NumAcceptors = confval(http_num_acceptors, 16),
    IpStr = case is_list(Ip) of true -> Ip; false -> inet_parse:ntoa(Ip) end,
    error_logger:info_msg("~s listening on http://~s:~B/~n", [?SERVER, IpStr,Port]),
    {ok, App} = application:get_application(),
    cowboy:start_listener({App, http}, NumAcceptors,
                          cowboy_tcp_transport, [{port, Port}],
                          cowboy_http_protocol, [{dispatch, dispatch_rules()}]
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
    {ok, App} = application:get_application(),
    cowboy:stop_listener({App, http}),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

dispatch_rules() ->
    {ok, App} = application:get_application(),
    PrivDir = case code:priv_dir(App) of
                  {error,_} -> filename:absname("priv");
                  Priv -> Priv
              end,
    WwwDir = filename:join([PrivDir, confval(www_dir, "www")]),
    CommonParams = [{www_dir, WwwDir}, {application, App}],
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
    [{'_', [

            {[], etracker_http_static, {CommonParams, [<<"html">>,<<"index.html">>]}}
            , {[<<"announce">>], etracker_http_request, {announce, AnnounceParams}}
            , {[<<"scrape">>], etracker_http_request, {scrape, ScrapeParams}}
            , {[<<"stats">>], etracker_http_request, {stats, CommonParams}}
           ]}].

confval(Key, Default) ->
    case application:get_env(Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.
