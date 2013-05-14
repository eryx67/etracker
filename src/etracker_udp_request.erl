%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 12 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_udp_request).

-export([start_link/3, init/4]).

-include("etracker.hrl").

start_link(Params, Srv, Req) ->
    Self = self(),
    proc_lib:start_link(?MODULE, init, [Self, Params, Srv, Req]).

init(Parent, Params, Srv, Req) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    case process_request(Req, Params) of
        {ok, Answer} ->
            gen_server:cast(Srv, Answer);
        ok ->
            ok
    end.

process_request({request, Peer, {Action, ConnId, Data}}, Params) ->
    case process_request(Action, ConnId, Peer, Data, Params) of
        false ->
            ok;
        Answer ->
            {ok, {answer, Peer, Answer}}
    end;
process_request({bad_request, Peer, {_Action, _ConnId, Reason}}, _Args) ->
    lager:error("invalid query ~p, peer ~w", [Reason, Peer]),
    etracker_event:invalid_query({udp, Peer, Reason}),
    ok.

process_request(ActionCode, ConnId, Peer, Data, Params) ->
    Action = code_to_action(ActionCode),
    case Action of
        undefined ->
            lager:error("invalid action ~p, peer ~w", [ActionCode, Peer]),
            etracker_event:unknown_query({udp, Peer, ActionCode});
        _ ->
            <<TrId:4/binary, Rest/binary >> = Data,
            case check_connection_id(Action, ConnId) of
                true ->
                    try
                        case process_action(Action, ConnId, Peer, Rest, Params) of
                            {ok, Body} ->
                                pack_answer(ActionCode, TrId, Body);
                            {error, Reason} ->
                                etracker_event:invalid_query({udp, Peer, Reason}),
                                answer_error(TrId, Reason)
                        end
                    catch
                        throw:Error ->
                            lager:error("invalid request, error ~p, action ~p, connection ~w, peer ~w, data ~w",
                                        [Error, Action, ConnId, Peer, Data]),
                            etracker_event:invalid_query({udp, Peer, Error}),
                            answer_error(TrId, Error);
                        error:Error ->
                            etracker_event:failed_query({udp, Peer, Error}),
                            lager:error("error when parsing request ~w, backtrace ~p~n",
                                         [Error,erlang:get_stacktrace()]),
                            answer_error(TrId, << "internal error" >>)
                    end;
                false ->
                    etracker_event:invalid_query({udp, Peer, << "connection id" >>}),
                    lager:error("peer ~w, connection id ~w, action ~p",
                                [Peer, ConnId, Action]),
                    false
            end
    end.

process_action(connect, ConnId, _Peer, _Data, _Params) ->
    {ok, ConnId};
process_action(announce, _ConnId, Peer,
               << InfoHash:20/binary,
                  PeerId:20/binary,
                  Downloaded:64/integer,
                  Left:64/integer,
                  Uploaded:64/integer,
                  EventCode:4/binary,
                  IpData:4/binary,
                  Key:4/binary,
                  NumWant:32/integer-signed,
                  Port:16/integer,
                  _Rest/binary >>,
               Params) ->
    Event = parse_request_attr(event, EventCode),
    {Ip1, Port1} = parse_request_attr(peer, {IpData, Port}, Peer),
    MaxPeers = proplists:get_value(answer_max_peers, Params),
    NumWant1 = min(MaxPeers,
                   parse_request_attr(numwant, NumWant, MaxPeers)),
    lists:foreach(fun ({K, V}) ->
                         request_attr_validate(K, V)
                 end,
                 [{downloaded, Downloaded}, {left, Left}, {uploaded, Uploaded}]),
    Ann = #announce{
             info_hash=InfoHash,
             peer_id=PeerId,
             ip=Ip1,
             port=Port1,
             event=Event,
             numwant=NumWant1,
             downloaded=Downloaded,
             uploaded=Uploaded,
             left=Left,
             key=Key,
             protocol=udp
            },
    {ok, announce_request_reply(Ann, Params)};
process_action(scrape, _ConnId, _Peer, Data, _Params) ->
    MaxTorrents = ?UDP_SCRAPE_MAX_TORRENTS,
    {ok, scrape_request_reply(Data, MaxTorrents)};
process_action(_A, _C, _P, _D, _Ps) ->
    {error, << "invalid action" >>}.

announce_request_reply(Ann=#announce{
                              info_hash=IH,
                              peer_id=PI,
                              numwant=NW
                             },
                       Params) ->
    etracker_db:announce(Ann),
    etracker_event:announce(Ann),
    ClntInterval = client_random_interval(proplists:get_value(answer_interval, Params)),
    {Complete, Incomplete, Peers1} = etracker_db:torrent_peers(IH, NW + 1),
    Peers2 = [P || P <- Peers1, element(1, P) /= PI],
    Peers3 = << << (encode(ip, IP))/binary, (encode(port, Port))/binary >>
                || {_PeerId, {IP, Port}} <- lists:sublist(Peers2, NW) >>,
    Body = << ClntInterval:32, Incomplete:32, Complete:32, Peers3/binary >>,
    Body.

scrape_request_reply(Data, MaxTorrents) ->
    MaxTorrentsSize = MaxTorrents * 20,
    DataSize = size(Data) - size(Data) rem 20,
    IhSize = min(MaxTorrentsSize, DataSize),
    << Data1:IhSize/binary, _/binary >> = Data,
    IHs = [ IH || << IH:20/binary >> <= Data1 ],
    etracker_event:scrape(#scrape{info_hashes=IHs, protocol=udp}),
    ResultsFun = fun (TIs) ->
                         Bins = << << (scrape_pack_torrent_info(TI))/binary >> || TI <- TIs >>,
                         Bins
                 end,
    etracker_db:torrent_infos(IHs, ResultsFun).

scrape_pack_torrent_info(#torrent_info{
                            seeders=Seeders,
                            leechers=Leechers,
                            completed=Complete
                           }) ->
    << Seeders:32, Complete:32, Leechers:32 >>;
scrape_pack_torrent_info(undefined) ->
    << 0:32, 0:32, 0:32 >>.

answer_error(TrId, Reason) ->
    pack_answer(error, TrId, Reason).

parse_request_attr(event, EventCode) ->
    case code_to_event(EventCode) of
        none ->
            undefined;
        undefined ->
            lager:error("~s invalid event code ~w", [?MODULE, EventCode]),
            throw(<< "invalid event" >>);
        Event ->
            Event
    end.

parse_request_attr(numwant, Val, Default) when Val =< 0 ->
    Default;
parse_request_attr(numwant, Val, _D) ->
    Val;
parse_request_attr(peer, {IpData, Port}, Default) ->
    << A1:8/integer, A2:8/integer, A3:8/integer, A4:8/integer >> = IpData,
    if (A1 == 0 andalso A2 == 0 andalso A3 == 0 andalso A4 == 0) ->
            Default;
       true ->
            request_attr_validate(port, Port),
            {{A1, A2, A3, A4}, Port}
    end.

request_attr_validate(port, Val) when Val > 0,
                                      Val < 16#ffff ->
    true;
request_attr_validate(Attr, Val) when (Attr == downloaded
                                       orelse Attr == uploaded
                                       orelse Attr == left)
                                      andalso Val >= 0 ->
    true;
request_attr_validate(Attr, _V) ->
    throw(list_to_binary([atom_to_list(Attr), " ", << "invalid value" >>])).

pack_answer(Action, TrId, Data) when is_atom(Action) ->
    pack_answer(action_to_code(Action), TrId, Data);
pack_answer(ActionCode, TrId, Data) ->
    << ActionCode/binary, TrId/binary, Data/binary >>.

check_connection_id(connect, ConnId) ->
    etracker_db:write(#udp_connection_info{
                         id = ConnId
                        }),
    true;
check_connection_id(_A, ConnId) ->
    case etracker_db:member(udp_connection_info, ConnId) of
        true ->
            etracker_db:write(#udp_connection_info{
                                 id = ConnId
                                }),
            true;
        _ ->
            false
    end.

code_to_action(?UDP_ACTION_CONNECT) ->
    connect;
code_to_action(?UDP_ACTION_ANNOUNCE) ->
    announce;
code_to_action(?UDP_ACTION_SCRAPE) ->
    scrape;
code_to_action(?UDP_ACTION_ERROR) ->
    error;
code_to_action(_) ->
    undefined.

action_to_code(connect) ->
    ?UDP_ACTION_CONNECT;
action_to_code(announce) ->
    ?UDP_ACTION_ANNOUNCE;
action_to_code(scrape) ->
    ?UDP_ACTION_SCRAPE;
action_to_code(error) ->
    ?UDP_ACTION_ERROR.

code_to_event(?UDP_EVENT_NONE) ->
    none;
code_to_event(?UDP_EVENT_COMPLETED) ->
    <<"completed">>;
code_to_event(?UDP_EVENT_STARTED) ->
    <<"started">>;
code_to_event(?UDP_EVENT_STOPPED) ->
    <<"stopped">>;
code_to_event(_) ->
    undefined.

encode(ip, {A1, A2, A3, A4}) ->
    << A1:8, A2:8, A3:8, A4:8 >>;
encode(port, Port) ->
    << Port:16 >>.

client_random_interval(Val) ->
    VarPart = Val div 5,
    Val - VarPart + crypto:rand_uniform(1, VarPart).
