-module(etracker_test).

-include_lib("eunit/include/eunit.hrl").

-define(PEERS, test_peers).
-define(TRACKER_URL, "http://localhost:8080").

start_apps() ->
    etorrent:start_app(),
    etracker:start(),
    timer:sleep(5000),
    [].

setup_announce() ->
    ets:new(?PEERS, [named_table, public]),
    random:seed(now()),
    random_announce().

stop(_SD) ->
    ok.

etracker_test_() ->
    {setup,
     fun start_apps/0,
     fun stop/1,
     fun(_SetupData) ->
             [{setup, fun setup_announce/0,
               fun (Ann) -> {inorder,
                             [Fun(Ann) || Fun <-
                                              [fun leecher_first_started/1,
                                               fun leecher_second_started/1,
                                               fun seeder_first_started/1,
                                               fun leecher_first_completed/1,
                                               fun scrape_all/1,
                                               fun scrape_some/1,
                                               fun leecher_second_stopped/1
                                              ]
                             ]}
               end
              }]
     end
    }.

leecher_first_started(Ann) ->
    [_Ih, PeerId, Port] = [orddict:fetch(K, Ann) || K <- [info_hash, peer_id, port]],
    ets:insert(?PEERS, {leecher_first, PeerId, Port}),
    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 12345}, {event, started}, {compact, 0}]),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    Checks = [{<<"incomplete">>, 1}, {<<"complete">>, 0}, {<<"peers">>, []}],
    GenF = fun (R) ->
                   [?_assertEqual(proplists:get_value(K, R), V) || {K, V} <- Checks]
           end,
    [GenF(Resp1), GenF(Resp2)].

leecher_first_completed(Ann) ->
    [{_, PeerId1, Port1}] = ets:lookup(?PEERS, leecher_second),
    [{_, PeerId2, Port2}] = ets:lookup(?PEERS, seeder_first),

    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 0}, {event, completed}, {compact, 0}]),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    Ann2 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 0}, {event, ""}, {compact, 1}]),
    {ok, Resp3} = send_announce(orddict:to_list(Ann2)),

    Ann3 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 0}, {event, stopped}, {compact, 0}]),
    {ok, Resp4} = send_announce(orddict:to_list(Ann3)),
    {ok, Resp5} = send_announce(orddict:to_list(Ann3)),

    Checks1 = [{<<"incomplete">>, 1}, {<<"complete">>, 2}],
    Checks2 = [{<<"incomplete">>, 1}, {<<"complete">>, 2}],
    Checks3 = [{<<"incomplete">>, 1}, {<<"complete">>, 1}],

    GenF1 = fun (R, Checks) ->
                   Peers = proplists:get_value(<<"peers">>, R),
                   PeersIds = lists:filter(
                                fun (P) ->
                                        PI = binary_to_list(proplists:get_value(<<"peer_id">>, P)),
                                        lists:member(PI, [PeerId1, PeerId2])
                                end, Peers),
                   [?_assertMatch([_, _], Peers), ?_assertEqual(length(PeersIds), 2) |
                    [?_assertEqual(proplists:get_value(K, R), V) || {K, V} <- Checks]]
           end,
    GenF2 = fun (R, Checks) ->
                    Peers = decode_compact_peers(proplists:get_value(<<"peers">>, R)),

                    [[?_assertEqual({127, 0, 0, 1}, proplists:get_value(<<"ip">>, P))
                      || P <- Peers],
                     [?_assertEqual(P1, P2)
                      || {P1, P2} <- lists:zip(lists:sort([Port1, Port2]),
                                               lists:sort([proplists:get_value(<<"port">>, P)
                                                           || P <- Peers]))],
                     [?_assertEqual(proplists:get_value(K, R), V) || {K, V} <- Checks]]
           end,

    [GenF1(Resp1, Checks1), GenF1(Resp2, Checks1), GenF2(Resp3, Checks2), GenF1(Resp4, Checks3), GenF1(Resp5, Checks3)].

leecher_second_started(Ann) ->
    [_Ih, PeerId, Port] = [orddict:fetch(K, Ann) || K <- [info_hash, peer_id, port]],
    PeerId1 = random_string(20),
    ets:insert(?PEERS, {leecher_second, PeerId1, Port}),
    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{peer_id, PeerId1}, {left, 456}, {event, started}, {compact, 0}]),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    GenF = fun (R) ->
                   Peers = proplists:get_value(<<"peers">>, R),
                   [
                    ?_assertEqual(proplists:get_value(<<"incomplete">>, R), 2),
                    ?_assertEqual(proplists:get_value(<<"complete">>, R), 0),
                    ?_assertMatch([_], Peers),
                    [?_assertEqual(proplists:get_value(K, lists:nth(1, Peers)), V)
                     || {K, V} <- [{<<"ip">>,<<"127.0.0.1">>},
                                   {<<"peer_id">>,list_to_binary(PeerId)},
                                   {<<"port">>, Port}]
                    ]
                   ]
           end,
    [GenF(Resp1), GenF(Resp2)].

leecher_second_stopped(Ann) ->
    [{_, PeerId1, _}] = ets:lookup(?PEERS, leecher_second),
    [{_, PeerId2, _}] = ets:lookup(?PEERS, seeder_first),

    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 0}, {peer_id, PeerId1}, {event, stopped}, {compact, 0}]),

    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    Checks1 = [{<<"incomplete">>, 0}, {<<"complete">>, 1}],

    GenF = fun (R, Checks) ->
                   Peers = proplists:get_value(<<"peers">>, R),
                   PeersIds = lists:filter(
                                fun (P) ->
                                        PI = binary_to_list(proplists:get_value(<<"peer_id">>, P)),
                                        lists:member(PI, [PeerId2])
                                end, Peers),
                   [?_assertMatch([_], Peers), ?_assertEqual(length(PeersIds), 1) |
                    [?_assertEqual(proplists:get_value(K, R), V) || {K, V} <- Checks]]
           end,
    [GenF(Resp1, Checks1), GenF(Resp2, Checks1)].

seeder_first_started(Ann) ->
    [_Ih, _PeerId, Port] = [orddict:fetch(K, Ann) || K <- [info_hash, peer_id, port]],
    PeerId = random_string(20),
    ets:insert(?PEERS, {seeder_first, PeerId, Port}),
    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{peer_id, PeerId}, {left, 0}, {event, started}, {compact, 0}]),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    Ann2 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{peer_id, PeerId}, {left, 0}, {event, completed}, {compact, 0}]),
    {ok, Resp3} = send_announce(orddict:to_list(Ann2)),
    {ok, Resp4} = send_announce(orddict:to_list(Ann2)),

    GenF = fun (R) ->
                   Peers = proplists:get_value(<<"peers">>, R),
                   [
                    ?_assertEqual(proplists:get_value(<<"incomplete">>, R), 2),
                    ?_assertEqual(proplists:get_value(<<"complete">>, R), 1),
                    ?_assertMatch([_, _], Peers)
                   ]
           end,
    [GenF(Resp1), GenF(Resp2), GenF(Resp3), GenF(Resp4)].

scrape_all(_Ann) ->
    {ok, Resp} = send_scrape([]),
    Keys = lists:sort([K || {K, _} <- Resp]),
    IHs = mnesia:activity(transaction, fun () -> mnesia:all_keys(torrent_info) end),
    Files = proplists:get_value(<<"files">>, Resp, []),
    Flags = lists:sort([K || {K, _} <- proplists:get_value(<<"flags">>, Resp, [])]),
    Info = proplists:get_value(lists:nth(1, IHs), Files),
    InfoKeys = lists:sort([K || {K, _} <- Info]),
    GenF = fun (_R) ->
                   [
                    ?_assertEqual([<<"files">>, <<"flags">>], Keys),
                    ?_assertEqual(length(Files), length(IHs)),
                    ?_assertEqual([<<"complete">>, <<"downloaded">>, <<"incomplete">>], InfoKeys),
                    ?_assertEqual([<<"min_request_interval">>], Flags)
                   ]
           end,
    [GenF(Resp)].

scrape_some(_Ann) ->
    IHs = mnesia:activity(transaction, fun () -> mnesia:all_keys(torrent_info) end),
    IH1 = lists:nth(random:uniform(length(IHs)), IHs),
    IH2 = lists:nth(random:uniform(length(IHs)), IHs),
    ReqIHs = lists:sort([IH1, IH2]),
    {ok, Resp} = send_scrape([{info_hash, ReqIHs}]),
    Keys = lists:sort([K || {K, _} <- Resp]),
    FileKeys = lists:sort([K || {K, _} <- proplists:get_value(<<"files">>, Resp, [])]),
    GenF = fun (_R) ->
                   [
                    ?_assertEqual([<<"files">>, <<"flags">>], Keys),
                    ?_assertEqual(ReqIHs, FileKeys)
                   ]
           end,
    [GenF(Resp)].

send_announce(PL) ->
    contact_tracker_http(announce, ?TRACKER_URL, PL).

send_scrape(PL) ->
    contact_tracker_http(scrape, ?TRACKER_URL, PL).

random_announce() ->
    [
     {info_hash, random_string(20)},
     {peer_id, random_string(20)},
     {compact, 1},
     {port, 12345},
     {uploaded, random:uniform(10000000000)},
     {downloaded, random:uniform(10000000000)},
     {left, random:uniform(10000000000)}
    ].

contact_tracker_http(Request, Url, PL) ->
    RequestStr = atom_to_list(Request),
    Url1 = case lists:last(Url) of
               $/ -> Url ++ RequestStr;
               _ -> Url ++ [$/|RequestStr]
           end,
    RequestUrl = build_tracker_url(Request, Url1, PL),
    case etorrent_http:request(RequestUrl) of
        {ok, {{200, _}, _, Body}} ->
            etorrent_bcoding:decode(Body);
        Error -> Error
    end.

build_tracker_url(announce, Url, PL) ->
    Event = proplists:get_value(event, PL),
    InfoHash = proplists:get_value(info_hash, PL),
    PeerId = proplists:get_value(peer_id, PL),
    Uploaded   = proplists:get_value(uploaded, PL),
    Downloaded = proplists:get_value(downloaded, PL),
    Left       = proplists:get_value(left, PL),
    Port = proplists:get_value(port, PL),
    Compact = proplists:get_value(compact, PL),
    Request = [{"info_hash",
                etorrent_http:build_encoded_form_rfc1738(InfoHash)},
               {"peer_id",
                etorrent_http:build_encoded_form_rfc1738(PeerId)},
               {"uploaded", Uploaded},
               {"downloaded", Downloaded},
               {"left", Left},
               {"port", Port},
               {"compact", Compact}],
    EReq = case Event of
               none -> Request;
               "" -> Request;
               started -> [{"event", "started"} | Request];
               stopped -> [{"event", "stopped"} | Request];
               completed -> [{"event", "completed"} | Request]
           end,
    FlatUrl = lists:flatten(Url),
    Delim = case lists:member($?, FlatUrl) of
                true -> "&";
                false -> "?"
            end,

    lists:concat([Url, Delim, etorrent_http:mk_header(EReq)]);
build_tracker_url(scrape, Url, PL) ->
    InfoHash = proplists:get_value(info_hash, PL, []),
    InfoHashes = if is_binary(InfoHash) ->
                         [InfoHash];
                    true ->
                         InfoHash
                 end,
    Request = [{"info_hash", etorrent_http:build_encoded_form_rfc1738(IH)}
               || IH <- InfoHashes],
    FlatUrl = lists:flatten(Url),
    Delim = if Request == [] -> "";
               true ->
                    case lists:member($?, FlatUrl) of
                        true -> "&";
                        false -> "?"
                    end
            end,
    lists:concat([Url, Delim, etorrent_http:mk_header(Request)]).

random_string(Len) ->
    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    ChrsSize = size(Chrs),
    F = fun(_, R) -> [element(random:uniform(ChrsSize), Chrs) | R] end,
    lists:foldl(F, "", lists:seq(1, Len)).

decode_compact_peers(Peers) ->
    decode_compact_peers(Peers, []).

decode_compact_peers(<<>>, Acc) ->
    Acc;
decode_compact_peers(<<I1:8,I2:8,I3:8,I4:8,Port:16,Rest/binary>>, Acc) ->
    decode_compact_peers(Rest, [[{<<"ip">>, {I1, I2, I3, I4}}, {<<"port">>, Port}] | Acc]).
