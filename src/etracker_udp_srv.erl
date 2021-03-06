%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 12 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_udp_srv).

-behaviour(gen_server).

%% API
-export([start_link/0, job_queue_name/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SECRET_TIMEOUT, 3600000).

-include("etracker.hrl").

-record(state, {pool_pid,
                socket,
                secrets={<<0>>, <<0>>}
               }).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

job_queue_name() ->
    etracker_udp.

init([]) ->
    Self = self(),
    Port = confval(udp_port, 8080),
    SocketOpts = [binary, {active, once}, {buffer, 2048}],
    SocketOpts1 = confopts(udp_ip, ip, SocketOpts, {127, 0, 0, 1}),
    {ok, Socket} = gen_udp:open(Port, SocketOpts1),
    WorkerParams = lists:map(fun ({Attr, Default}) ->
                                     {Attr, confval(Attr, Default)}
                             end,
                             [
                              {answer_max_peers, ?ANNOUNCE_ANSWER_MAX_PEERS},
                              {answer_interval, ?ANNOUNCE_ANSWER_INTERVAL},
                              {scrape_request_interval, 60 * 30}
                             ]),
    {ok, PoolPid} = etracker_udp_sup:start_link(etracker_udp_request, WorkerParams),
    IpStr = inet_parse:ntoa(proplists:get_value(ip, SocketOpts1)),
    lager:info("listening on udp://~s:~B/~n", [IpStr, Port]),
    Secret = gen_secret(),
    erlang:send_after(?SECRET_TIMEOUT, Self, expire_secrets),
    {ok, #state{pool_pid=PoolPid,
                socket=Socket,
                secrets={Secret, Secret}
               }}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({answer, Peer, Answer}, S=#state{socket=Socket}) ->
    {Ip, Port} = Peer,
    ok = gen_udp:send(Socket, Ip, Port, Answer),
    {noreply, S};
handle_cast(Msg, State) ->
    lager:debug("unknown cast ~w", [Msg]),
    {noreply, State}.

handle_info(expire_secrets, S) ->
    Self = self(),
    erlang:send_after(?SECRET_TIMEOUT, Self, expire_secrets),
    {noreply, expire_secrets(S)};
handle_info({udp, Socket, Ip, PortNo, Packet}, S=#state{socket=Socket})
  when size(Packet) >= 16 ->
    inet:setopts(Socket, [{active, once}]),
    << ConnId:8/binary, Action:4/binary, Data/binary >> = Packet,
    lager:debug("received packet from ~w, action ~w, connection id ~w",
                [{Ip, PortNo}, Action, ConnId]),
    Req =
        case check_connection_id(Action, ConnId, Ip, PortNo, S) of
            {ok, ConnId1} ->
                {request, {Ip, PortNo}, {Action, ConnId1, Data}};
            {error, Reason} ->
                {bad_request, {Ip, PortNo}, {Action, ConnId, Reason}}
        end,
    start_worker(Req, S),
    {noreply, S};
handle_info({udp, Socket, Ip, PortNo, Packet}, S=#state{socket=Socket}) ->
    lager:debug("bad packet ~w from ~w", [Packet, {Ip, PortNo}]),
    inet:setopts(Socket, [{active, once}]),
    {noreply, S};
handle_info(Info, State) ->
    lager:debug("unknown info ~w", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_worker(Msg, _S=#state{pool_pid=PoolPid}) ->
    Self = self(),
    etracker_jobs:add_job(job_queue_name(),
                          fun () ->
                                  {ok, _WorkerPid} = supervisor:start_child(PoolPid, [Self, Msg])
                          end).

check_connection_id(?UDP_ACTION_CONNECT, ?UDP_CONNECTION_ID, Ip, PortNo,
                    _S=#state{secrets={S1, _S2}}) ->
    {ok, gen_connection_id(Ip, PortNo, S1)};
check_connection_id(?UDP_ACTION_CONNECT, ConnId, Ip, PortNo, _S) ->
    lager:debug("invalid initial connection id ~w, peer ~w", [ConnId, {Ip, PortNo}]),
    {error, << "invalid_connection_id" >>};
check_connection_id(_A, ConnId, Ip, PortNo, _S=#state{secrets={S1, S2}}) ->
    case (ConnId == gen_connection_id(Ip, PortNo, S1)
          orelse ConnId == gen_connection_id(Ip, PortNo, S2)) of
        true ->
            {ok, ConnId};
        false ->
            {error, << "invalid_connection_id" >>}
    end.

expire_secrets(S=#state{secrets={S1, _S2}}) ->
    S#state{secrets={gen_secret(), S1}}.

gen_connection_id(Ip, PortNo, Secret) ->
    crypto:sha_mac(Secret, << (list_to_binary(tuple_to_list(Ip)))/binary, PortNo:16 >>, 8).

gen_secret() ->
    crypto:rand_bytes(8).

confopts(Key, Name, Opts) ->
    case etracker_env:get(Key) of
        udefined ->
            Opts;
        {ok, Val} ->
            [{Name, Val} | Opts]
    end.

confopts(Key, Name, Opts, Default) ->
    [{Name, confval(Key, Default)} | Opts].

confval(Key) ->
    case etracker_env:get(Key) of
        undefined ->
            undefined;
        {ok, Val} ->
            parse_option(Key, Val)
    end.

confval(Key, Default) ->
    case confval(Key) of
        undefined ->
            Default;
        Val ->
            parse_option(Key, Val)
    end.

parse_option(udp_ip, Val) when is_list(Val) ->
    {ok, Ip} = inet_parse:address(Val),
    Ip;
parse_option(_, Val) ->
    Val.
