-module(etracker_http_request).
-behaviour(cowboy_http_handler).

-export([init/3, handle/2, terminate/3]).
-export([rest_init/2, allowed_methods/2, content_types_provided/2]).
-export([stats_reply_json/2, stats_reply_html/2]).

-include("etracker.hrl").

-define(FULL_SCRAPE_FILE, "full_scrape.txt").

-record(state, {
          request_type,
          params = []
         }).
init({tcp, http}, _Req, {stats, _ReqParams}) ->
    {upgrade, protocol, cowboy_rest};
init({tcp, http}, Req, {ReqType, ReqParams}) ->
    {ok, Req, #state{request_type = ReqType, params=ReqParams}}.

%% rest handler callbacks
rest_init(Req, {ReqType, ReqParams}) ->
    {ok, Req, #state{request_type = ReqType, params=ReqParams}}.

allowed_methods(Req, S=#state{request_type=stats}) ->
    {[<<"HEAD">>, <<"GET">>, <<"POST">>], Req, S}.

content_types_provided(Req, S=#state{request_type=stats}) ->
    Types = [
             {<<"application/json">>, stats_reply_json},
             {<<"text/html">>, stats_reply_html}
            ],
    {Types, Req, S}.

%% rest handlers
stats_reply_json(Req, State) ->
    {Answer, Req1} = stats_process(json, Req),
    Resp = jiffy:encode(Answer),
    {Resp, Req1, State}.

stats_reply_html(Req, State) ->
    {Answer, Req1} = stats_process(html, Req),
    {ok, Resp} = stats_dtl:render(Answer),
    {Resp, Req1, State}.

stats_process(Type, Req) ->
    {QVs, Req1} = cowboy_req:qs_vals(Req),
    ValidKeys = [atom_to_list(K) || K <- etracker:info(info_keys)],
    Answer =
        try
            Keys =
                lists:foldl(fun ({K, V}, Acc) ->
                                    case string:to_lower(binary_to_list(K)) of
                                        "id" ->
                                            V2 = string:to_lower(binary_to_list(V)),
                                            case lists:member(V2, ValidKeys) of
                                                true ->
                                                    [list_to_atom(V2)|Acc];
                                                _ ->
                                                    error({invalid_key, V2})
                                            end;
                                        _ ->
                                            Acc
                                    end
                            end, [], QVs),

            case {Type, etracker:info(Keys)} of
                {json, Res} -> {[{value, {Res}}]};
                {html, Res} -> [{value, [[{name, K}, {value, V}] || {K, V} <- Res]}]
            end
        catch
            error:E ->
                case Type of
                    json ->
                        {[{error, {[E]}}]};
                    html ->
                        [{error, io_lib:format("~p", [E])}]
                end
        end,
    {Answer, Req1}.

%% http handler callbacks
handle(Req, State=#state{request_type=announce,
                         params=Params
                        }) ->
    {QsVals, Req1} = cowboy_req:qs_vals(Req),
    lager:debug("received announce ~p", [QsVals]),
    {Body, Code, Req2} = announce_request_reply(Req1, Params),
    Headers = [{<<"content-type">>, <<"text/plain">>}],
    {ok, Req3} = cowboy_req:reply(Code, Headers, Body, Req2),
    {ok, Req3, State};
handle(Req, State=#state{request_type=scrape,
                         params=Params
                        }) ->
    {QsVals, Req1} = cowboy_req:qs_vals(Req),
    lager:debug("received scrape request ~p", [QsVals]),
    {ok, Req2} = scrape_request_reply(Req1, Params),
    {ok, Req2, State};
handle(Req, State) ->
    Body = <<"<h1>404</h1>">>,
    {ok, Req2} = cowboy_req:reply(404, [], Body, Req),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% Internal functions
scrape_request_reply(Req, Params) ->
    Headers = [{<<"content-type">>, <<"text/plain">>}],
    try parse_request(scrape, Req) of
        {IHs, Req1} ->
            etracker_event:scrape(#scrape{info_hashes=IHs, protocol=http}),
            SRI = proplists:get_value(scrape_request_interval, Params),
            Preamble = ["d",
                        etorrent_bcoding:encode(<<"files">>),
                        "d"],
            Postamble = ["e",
                         etorrent_bcoding:encode(<<"flags">>),
                         etorrent_bcoding:encode([{<<"min_request_interval">>, SRI}]),
                         "e"],
            Req2 = lists:foldl(fun ({K, V}, R) ->
                                       cowboy_req:set_resp_header(K, V, R)
                               end, Req1, Headers),
            case IHs of
                [] ->
                    scrape_request_reply_file(Preamble, Postamble, Req2);
                _ ->
                    scrape_request_reply_write(IHs, Preamble, Postamble, Req2)
            end
    catch
        throw:Error ->
            lager:error("invalid scrape, error ~w~n** Request was ~w~n", [Error, Req]),
            etracker_event:invalid_query({scrape, Error}),
            Body = etorrent_bcoding:encode([{<<"failure reason">>, Error}]),
            cowboy_req:reply(200, Headers, Body, Req);
        error:Error ->
            etracker_event:failed_query({scrape, Error}),
            lager:error("error when parsing scrape ~w, backtrace ~p~n",
                         [Error,erlang:get_stacktrace()]),
            cowboy_req:reply(400, Headers, <<"Invalid request">>, Req)
    end.

scrape_request_reply_file(Preamble, Postamble, Req) ->
    EncodeF = fun scrape_pack_torrent_infos/1,
    case etracker_db:full_scrape(?FULL_SCRAPE_FILE, EncodeF) of
        false ->
            scrape_request_reply_write([], Preamble, Postamble, Req);
        {error, Reason} ->
            lager:error("~s error on full scrape generation ~w", [?MODULE, Reason]),
            cowboy_req:reply(400, Req);
        {ok, FileName} ->
            WriteFs = [{fun gen_tcp:send/2, Preamble},
                       {fun (S, FN) -> file:sendfile(FN, S) end, FileName},
                       {fun gen_tcp:send/2, Postamble}
                      ],
            RespBodyF =
                fun (Socket, _M) ->
                        lists:foreach(
                          fun ({Fn, Arg}) ->
                                  case Fn(Socket, Arg) of
                                      ok ->
                                          ok;
                                      {ok, _} ->
                                          ok;
                                      {error, closed} ->
                                          ok;
                                      {error, etimedout} ->
                                          ok
                                  end
                          end, WriteFs)
                end,
            Req1 = cowboy_req:set_resp_body_fun(RespBodyF, Req),
            cowboy_req:reply(200, Req1)
    end.

scrape_request_reply_write(IHs, Preamble, Postamble, Req) ->
    {ok, Req1} = cowboy_req:chunked_reply(200, Req),
    ok = cowboy_req:chunk(Preamble, Req1),
    ResultsFun = fun ([]) ->
                         ok;
                     (TorrentInfos) ->
                         Data = scrape_pack_torrent_infos(TorrentInfos),
                         ok = cowboy_req:chunk(Data, Req1)
                 end,
    ok = etracker_db:torrent_infos(IHs, ResultsFun),
    ok = cowboy_req:chunk(Postamble, Req1),
    {ok, Req1}.

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
            Compact = case proplists:get_value(answer_compact, Params, false) of
                          true -> true;
                          false -> C
                      end,
            NW1 = if NW == 0 orelse NW > MaxPeers -> MaxPeers;
                     true -> NW
                  end,
            {Complete, Incomplete, Peers1} = etracker_db:torrent_peers(IH, MaxPeers + 1),
            Peers2 = [P || P <- Peers1, element(1, P) /= PI],
            Peers3 = lists:sublist(Peers2, NW1),
            Body = etorrent_bcoding:encode([
                                            {<<"interval">>, ClntInterval},
                                            {<<"min interval">>, ClntMinInterval},
                                            {<<"complete">>, Complete},
                                            {<<"incomplete">>, Incomplete},
                                            {<<"peers">>, announce_reply_peers(Peers3, NPI, Compact)}
                                           ]),
            {Body, 200, Req1}
    catch
        throw:Error ->
            lager:error("invalid announce, error ~w~n** Request was ~w~n", [Error, Req]),
            etracker_event:invalid_query({announce, Error}),
            {RetCode, Reason} =
                case Error of
                    {_RCode, _Reason} ->
                        Error;
                    _ ->
                        {200, Error}
                end,
            {etorrent_bcoding:encode([{<<"failure reason">>, Reason}]), RetCode, Req};
        error:Error ->
            etracker_event:failed_query({announce, Error}),
            lager:error("Error when parsing announce ~w~n** Request was ~w~n**Backtrace ~p~n",
                        [Error, Req, erlang:get_stacktrace()]),
            {<<"Invalid request">>, 400, Req}
    end.

scrape_pack_torrent_infos(TorrentInfos) ->
    PackInfoHashFun = fun (#torrent_info{
                              info_hash=IH,
                              seeders=Complete,
                              leechers=Incomplete,
                              completed=Downloaded,
                              name=Name
                             }) ->
                              Val1 = if is_binary(Name) ->
                                             [{<<"name">>, Name}];
                                        true ->
                                             []
                                     end,
                              Val2 = [
                                      {<<"complete">>, Complete},
                                      {<<"incomplete">>, Incomplete},
                                      {<<"downloaded">>, Downloaded}
                                      | Val1
                                     ],
                              [etorrent_bcoding:encode(IH), etorrent_bcoding:encode(Val2)]
                      end,
    [PackInfoHashFun(TI) || TI <- TorrentInfos, is_record(TI, torrent_info)].

parse_request(scrape, HttpReq) ->
    parse_request_attr(info_hash, HttpReq, true);

parse_request(announce, HttpReq) ->
    Attrs = record_info(fields, announce),
    {Values, Req1} = lists:mapfoldl(fun parse_request_attr/2, HttpReq, Attrs),
    AttrIdxs = lists:seq(2, 1 + length(Attrs)),
    Ann = lists:foldl(fun ({Val, Idx}, Rec) ->
                              setelement(Idx, Rec, Val)
                      end,
                      #announce{protocol=http},
                      lists:zip(Values, AttrIdxs)),
    {Ann, Req1}.

parse_request_attr(Attr, Req) ->
    parse_request_attr(Attr, Req, false).

parse_request_attr(Attr, Req, _Multi=false) ->
    {Val1, Req1} = cowboy_req:qs_val(request_attr_key(Attr), Req),
    request_attr_process(Attr, Val1, Req1);
parse_request_attr(Attr, Req, _Multi=true) ->
    AttrName = list_to_binary(atom_to_list(Attr)),
    {Vals1, Req1} = cowboy_req:qs_vals(Req),
    lists:foldl(fun ({K, V}, {A, R}) when K == AttrName ->
                        {V1, R1} = request_attr_process(Attr, V, R),
                        {[V1|A], R1};
                    (_, Acc) ->
                        Acc
                end, {[], Req1}, Vals1).

request_attr_process(Attr, Val, Req) ->
    {Val1, Req1} = case Val of
                       undefined ->
                           request_attr_default(Attr, Req);
                       _ ->
                           {request_attr_value(Attr, Val), Req}
                   end,
    case request_attr_validate(Attr, Val1) of
        true ->
            ok;
        {RetCode, Error} ->
            throw({RetCode, list_to_binary([atom_to_list(Attr), " ", Error])});
        Error ->
            throw(list_to_binary([atom_to_list(Attr), " ", Error]))
    end,
    {Val1, Req1}.

-define(REQUEST_ATTR_KEY(Attr), request_attr_key(Attr) -> <<??Attr>>).

?REQUEST_ATTR_KEY(event);
?REQUEST_ATTR_KEY(info_hash);
?REQUEST_ATTR_KEY(ip);
?REQUEST_ATTR_KEY(port);
?REQUEST_ATTR_KEY(peer_id);
?REQUEST_ATTR_KEY(key);
?REQUEST_ATTR_KEY(compact);
?REQUEST_ATTR_KEY(no_peer_id);
?REQUEST_ATTR_KEY(uploaded);
?REQUEST_ATTR_KEY(downloaded);
?REQUEST_ATTR_KEY(left);
?REQUEST_ATTR_KEY(numwant);
request_attr_key(Attr) ->
    list_to_binary(atom_to_list(Attr)).

request_attr_default(ip, Req) ->
    {{IP, _Port}, Req1} = cowboy_req:peer(Req),
    {IP, Req1};
request_attr_default(key, Req) ->
    cowboy_req:qs_val(<<"peer_id">>, Req);
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

request_attr_value(_Attr=ip, Val) when is_binary(Val) ->
    {ok, IP} = inet_parse:address(binary_to_list(Val)),
    IP;
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
request_attr_value(_Attr=event, _Val= <<"paused">>) ->
    <<"stopped">>;
request_attr_value(_Attr, Val) ->
    Val.

request_attr_validate(info_hash, undefined) ->
    {200, <<"required">>};
request_attr_validate(peer_id, undefined) ->
    {200, <<"required">>};
request_attr_validate(port, undefined) ->
    {200, <<"required">>};
request_attr_validate(info_hash, Val) when size(Val) /= ?INFOHASH_LENGTH ->
    {200, <<"invalid value">>};
request_attr_validate(peer_id, Val) when size(Val) /= ?INFOHASH_LENGTH ->
    {200, <<"invalid value">>};
request_attr_validate(_Attr=port, Val) when Val > 16#ffff ->
    <<"invalid value">>;
request_attr_validate(Attr, Val) when Val < 0
                                      andalso (Attr == port
                                               orelse Attr == uploaded
                                               orelse Attr == downloaded
                                               orelse Attr == left
                                               orelse Attr == numwant) ->
    <<"must be positive">>;
request_attr_validate(_Attr=event, _Val=undefined) ->
    true;
request_attr_validate(_Attr=event, _Val= <<"">>) ->
    true;
request_attr_validate(_Attr=event, _Val= <<"started">>) ->
    true;
request_attr_validate(_Attr=event, _Val= <<"completed">>) ->
    true;
request_attr_validate(_Attr=event, _Val= <<"stopped">>) ->
    true;
request_attr_validate(_Attr=event, Val)->
    lager:error("Invalid announce request event ~w", [Val]),
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
announce_pack_peer_compact({_PI, {IP, Port}}) when length(IP) == 4 ->
    <<(list_to_binary(IP)/binary), Port:16>>;
announce_pack_peer_compact(_P) ->
    <<>>.

client_random_interval(Val) ->
    VarPart = Val div 5,
    Val - VarPart + crypto:rand_uniform(1, VarPart).