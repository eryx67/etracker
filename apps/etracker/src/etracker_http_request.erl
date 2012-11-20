-module(etracker_http_request).
-behaviour(cowboy_http_handler).
-export([init/3, handle/2, terminate/2]).

-include("etracker.hrl").

-record(state, {
          request_type,
          params = []
         }).

init({tcp, http}, Req, [ReqType, ReqParams]) ->
    {ok, Req, #state{request_type = ReqType, params=ReqParams}}.

handle(Req, State=#state{request_type=announce,
                         params=Params
                        }) ->
    {QsVals, Req1} = cowboy_http_req:qs_vals(Req),
    lager:debug("received announce ~p", [QsVals]),
    {Body, Code, Req2} = announce_request_reply(Req1, Params),
    Headers = [{<<"Content-Type">>, <<"text/plain">>}],
    {ok, Req3} = cowboy_http_req:reply(Code, Headers, Body, Req2),
    {ok, Req3, State};
handle(Req, State) ->
    Body = <<"<h1>404</h1>">>,
    {ok, Req2} = cowboy_http_req:reply(404, [], Body, Req),
    {ok, Req2, State}.

terminate(_Req, _State) ->
    ok.

%% Internal functions
announce_request_reply(Req, Params) ->
    try parse_request(announce, Req) of
        {Ann, Req1} ->
            #announce{
               info_hash=IH,
               peer_id=PI,
               numwant=NW,
               compact=C,
               no_peer_id=NPI
              } = Ann,
            etracker_db:announce(Ann),
            etracker_event:announce(Ann),
            ClntInterval = client_random_interval(proplists:get_value(answer_interval, Params)),
            ClntMinInterval = ClntInterval div 2,
            MaxPeers = proplists:get_value(answer_max_peers, Params),
            Compact = proplists:get_value(answer_compact, Params, C),
            NW1 = if NW == 0 -> MaxPeers;
                     true -> NW
                  end,
            #torrent_info{
               seeders = Complete,
               leechers = Incomplete
              } = etracker_db:torrent_info(IH),
            Peers = etracker_db:torrent_peers(IH, NW1, [PI]),
            Body = etorrent_bcoding:encode([
                                            {<<"interval">>, ClntInterval},
                                            {<<"min interval">>, ClntMinInterval},
                                            {<<"complete">>, Complete},
                                            {<<"incomplete">>, Incomplete},
                                            {<<"peers">>, announce_reply_peers(Peers, NPI, Compact)}
                                           ]),
            {Body, 200, Req1}
    catch
        throw:Error ->
            {etorrent_bcoding:encode([{<<"failure reason">>, Error}]), 200, Req};
        error:Error ->
            error_logger:error_msg("Error when parsing announce ~w, backtrace ~p~n",
                                   [Error,erlang:get_stacktrace()]),
            {<<"Invalid request">>, 400, Req}
    end.

parse_request(announce, HttpReq) ->
    Attrs = record_info(fields, announce),
    {Values, Req1} = lists:mapfoldl(fun parse_request_attr/2, HttpReq, Attrs),
    AttrIdxs = lists:seq(2, 1 + length(Attrs)),
    Ann = lists:foldl(fun ({Val, Idx}, Rec) ->
                              setelement(Idx, Rec, Val)
                      end,
                      #announce{},
                      lists:zip(Values, AttrIdxs)),
    {Ann, Req1}.

parse_request_attr(Attr, Req) ->
    {Val1, Req1} = cowboy_http_req:qs_val(list_to_binary(atom_to_list(Attr)), Req),
    {Val2, Req2} = case Val1 of
                       undefined ->
                           request_attr_default(Attr, Req1);
                       _ ->
                           {request_attr_value(Attr, Val1), Req1}
                   end,
    case request_attr_validate(Attr, Val2) of
        true ->
            ok;
        Error ->
            throw(list_to_binary([atom_to_list(Attr), " ", Error]))
    end,
    {Val2, Req2}.

request_attr_default(ip, Req) ->
    cowboy_http_req:peer_addr(Req);
request_attr_default(key, Req) ->
    cowboy_http_req:qs_val(<<"peer_id">>, Req);
request_attr_default(compact, Req) ->
    {false, Req};
request_attr_default(no_peer_id, Req) ->
    {false, Req};
request_attr_default(Attr, Req) when Attr == uploaded
                                     orelse Attr == downloaded
                                     orelse Attr == left
                                     orelse Attr == numwant ->
    {0, Req};
request_attr_default(_Attr, Req) ->
    {undefined, Req}.

request_attr_value(_Attr=ip, Val) ->
    {ok, IP} = inet_parse:address(Val),
    IP;
request_attr_value(_Attr=compact, Val) ->
    Val == <<"1">>;
request_attr_value(Attr, Val) when Attr == port
                                   orelse Attr == uploaded
                                   orelse Attr == downloaded
                                   orelse Attr == left
                                   orelse Attr == numwant ->
    {Int, []} = string:to_integer(binary_to_list(Val)),
    Int;
request_attr_value(_Attr=no_peer_id, Val) ->
    Val /= undefined;
request_attr_value(_Attr, Val) ->
    Val.

request_attr_validate(Attr, _Val=undefined) when Attr == info_hash
                                                 orelse Attr == peer_id
                                                 orelse Attr == port ->
    <<"required">>;
request_attr_validate(Attr, Val) when (Attr == info_hash
                                       orelse Attr == peer_id)
                                      andalso size(Val) /= 20 ->
    <<"invalid value">>;
request_attr_validate(_Attr=port, Val) when Val > 16#ffff ->
    <<"invalid value">>;
request_attr_validate(Attr, Val) when Val < 0
                                      andalso (Attr == port
                                               orelse Attr == uploaded
                                               orelse Attr == downloaded
                                               orelse Attr == left
                                               orelse Attr == numwant) ->
    <<"must be positive">>;
request_attr_validate(_Attr=event, _Val=undefined)->
    true;
request_attr_validate(_Attr=event, _Val= <<"started">>)->
    true;
request_attr_validate(_Attr=event, _Val= <<"completed">>)->
    true;
request_attr_validate(_Attr=event, _Val= <<"stopped">>)->
    true;
request_attr_validate(_Attr=event, Val)->
    error_logger:warning_msg("Invalid announce request event ~w", [Val]),
    true;
request_attr_validate(_Attr, _Val) ->
    true.

announce_reply_peers(Peers, _NPI, _Compact=true) ->
    list_to_binary([announce_pack_peer_compact(P) || P <- Peers]);
announce_reply_peers(Peers, NoPeerId, _Compact=false) ->
    [announce_pack_peer(P, NoPeerId) || P <- Peers].

announce_pack_peer({_PeerId, {IP, Port}}, _NPI=true) ->
    [{<<"ip">>, list_to_binary(inet_parse:ntoa(IP))}, {<<"port">>, Port}];
announce_pack_peer({PeerId, {IP, Port}}, _NPI=false) ->
    [{<<"peer_id">>, PeerId},{<<"ip">>, list_to_binary(inet_parse:ntoa(IP))}, {<<"port">>, Port}].

announce_pack_peer_compact({_PI, {IP, Port}}) when size(IP) == 4 ->
    <<(list_to_binary(tuple_to_list(IP)))/binary, Port:16>>;
announce_pack_peer_compact(_P) ->
    <<>>.

client_random_interval(Val) ->
    random:seed(now()),
    VarPart = Val div 5,
    Val - VarPart + random:uniform(VarPart).
