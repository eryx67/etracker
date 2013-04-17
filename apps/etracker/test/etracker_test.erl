-module(etracker_test).

-include_lib("eunit/include/eunit.hrl").
-include("etracker.hrl").

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
    etracker:stop(),
    etorrent:stop_app() .

cleaner_test_start() ->
    application:load(etracker),
    application:set_env(etracker, clean_interval, 5),
    etracker:start(),
    timer:sleep(1000),
    cleaner_test_start1().

cleaner_test_start1() ->
    InfoHash = list_to_binary(random_string(20)),
    PeerId1 = list_to_binary(random_string(20)),
    PeerId2 = list_to_binary(random_string(20)),
    Mtime = {Mega, Sec, Micro} = now(),
    TI = #torrent_info{
            info_hash=InfoHash,
            leechers=3,
            seeders=3
           },
    SeederMtime = Mtime = {Mega, Sec, Micro},
    Seeder = #torrent_user{
                id={InfoHash, PeerId1},
                peer={{127, 0, 0, 1}, 6969},
                info_hash=InfoHash,
                finished=true,
                mtime=SeederMtime
               },
    LeecherMtime = {Mega, Sec + 10, Micro},
    Leecher = #torrent_user{
                 id={InfoHash, PeerId2},
                 peer={{127, 0, 0, 1}, 6969},
                 info_hash=InfoHash,
                 finished=false,
                 mtime=LeecherMtime
                },
    ok = write_record(TI),
    ok = write_record(Seeder),
    ok = write_record(Leecher),
    [TI, [Seeder, Leecher]].

cleaner_test_stop([TI, TUs]) ->
    application:set_env(etracker, clean_interval, 2700),
    delete_record(TI),
    lists:foreach(fun (TU) ->
                          delete_record(TU)
                  end, TUs),
    etracker:stop().

etracker_test_() ->
    {setup,
     fun start_apps/0,
     fun stop/1,
     fun(_SetupData) ->
             [{setup, fun setup_announce/0,
               fun (Ann) -> {inorder,
                             [Fun(Ann) || Fun <-
                                              [fun leecher_first_started/1,
                                               fun leecher_first_invalid_requests/1,
                                               fun leecher_second_started/1,
                                               fun seeder_first_started/1,
                                               fun leecher_first_completed/1,
                                               fun scrape_all/1,
                                               fun scrape_some/1,
                                               fun leecher_second_stopped/1,
                                               fun check_stats_after_test/1
                                              ]
                             ]}
               end
              }]
     end
    }.

etracker_cleaner_test_() ->
    {setup,
     fun cleaner_test_start/0,
     fun cleaner_test_stop/1,
     fun (SD) ->
             {inorder,
              [{timeout, 60,
                [
                 cleaner_checks(SD)
                ]},
               check_stats_after_clean()
              ]}
     end
    }.

cleaner_checks([TI, TUs]) ->
    mnesia:subscribe({table, torrent_info, simple}),
    mnesia:subscribe({table, torrent_user, simple}),
    cleaner_checks(TI, TUs, []).

cleaner_checks(_TI, [], Acc) ->
    mnesia:unsubscribe({table, torrent_info, simple}),
    mnesia:unsubscribe({table, torrent_user, simple}),
    Acc;
cleaner_checks(TI, [TU|Rest], Acc) ->
    {TI1, Tests} = cleaner_check_user(TI, TU, [false, false], []),
    cleaner_checks(TI1, Rest, Acc ++ Tests).

cleaner_check_user(TI, _TU, [ok, ok], Acc) ->
    {TI, Acc};
cleaner_check_user(TI=#torrent_info{info_hash=IH, seeders=S, leechers=L},
                   TU=#torrent_user{id=Id, finished=F},
                   [TIOk, TUOk], Acc) ->
    receive
        {mnesia_table_event, {delete, {torrent_user, Id}, _}} ->
            cleaner_check_user(TI, TU, [TIOk, ok], Acc);
        {mnesia_table_event, {write,
                              TI1=#torrent_info{info_hash=IH, seeders=S1, leechers=L1}, _}} ->
            Tests = if F == true ->
                            [?_assertEqual(S1, S - 1),
                             ?_assertEqual(L1, L)];
                       true ->
                            [?_assertEqual(S1, S),
                             ?_assertEqual(L1, L - 1)]
                    end,
            cleaner_check_user(TI1, TU, [ok, TUOk], Acc ++ Tests);
        _ ->
            cleaner_check_user(TI, TU, [TIOk, TUOk], Acc)
    end.

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

leecher_first_invalid_requests(Ann) ->
    Ann1 = orddict:store(info_hash, <<"bad_hash">>, Ann),
    Ann2 = orddict:store(port, "bad_port", Ann),
    Ann3 = orddict:erase(info_hash, Ann),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann2)),
    {ok, Resp3} = (catch send_announce(orddict:to_list(Ann3))),

    [?_assertEqual([{<<"failure reason">>,<<"info_hash invalid value">>}], Resp1),
     ?_assertMatch({{400, _R}, _H, _B}, Resp2),
     ?_assertEqual([{<<"failure reason">>,<<"info_hash invalid value">>}], Resp3)
    ].

check_stats_after_clean() ->
    KV = [{<<"seeders">>,0},
          {<<"leechers">>,0},
          {<<"peers">>,0},
          {<<"unknown_queries">>,0},
          {<<"invalid_queries">>,0},
          {<<"scrapes">>,0},
          {<<"announces">>,0},
          {<<"failed_queries">>,0},
          {<<"deleted_peers">>,3}],
    check_stats(KV).

check_stats_after_test(_) ->
    KV = [{<<"seeders">>,1},
          {<<"leechers">>,0},
          {<<"peers">>,1},
          {<<"unknown_queries">>,0},
          {<<"invalid_queries">>,2},
          {<<"scrapes">>,2},
          {<<"announces">>,15},
          {<<"failed_queries">>,1},
          {<<"deleted_peers">>,0}],
    check_stats(KV).

check_stats(KV) ->
    {ok, {{200, _}, _, Resp}} = lhttpc:request("http://localhost:8080/stats", get,
                                               [{"Content-Type", "application/json"}], "", 1000),

    Res = jiffy:decode(Resp),
    ?debugVal(Res),
    {[{<<"value">>, {KV2}}]} = Res,
    [?_assertMatch({[{<<"value">>, _}]}, Res),
     [?_assertEqual({K, V}, {K, proplists:get_value(K, KV2)}) || {K, V} <- KV]
    ].

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
    [IH, PeerId, Port] = [orddict:fetch(K, Ann) || K <- [info_hash, peer_id, port]],
    PeerId1 = random_string(20),
    ets:insert(?PEERS, {leecher_second, PeerId1, Port}),
    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{peer_id, PeerId1}, {left, 456}, {event, started}, {compact, 0}]),
    {ok, Resp1} = send_announce(orddict:to_list(Ann1)),
    {ok, Resp2} = send_announce(orddict:to_list(Ann1)),

    ?debugVal(etracker_db:torrent_peers(IH, 50)),
    GenF = fun (R) ->
                   Peers = proplists:get_value(<<"peers">>, R),
                   [
                    ?_assertEqual(2, proplists:get_value(<<"incomplete">>, R)),
                    ?_assertEqual(0, proplists:get_value(<<"complete">>, R)),
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
    IHs = all_torrent_info_hashes(),
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
    IHs = all_torrent_info_hashes(),
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
    InfoHash = proplists:get_value(info_hash, PL, []),
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
               completed -> [{"event", "completed"} | Request];
               _ -> [{"event", atom_to_list(Event)} | Request]
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

all_torrent_info_hashes() ->
    {ok, {WorkerArgs, _}} = etracker_env:get(db_pool),
    Mod = proplists:get_value(worker_module, WorkerArgs),
    case Mod of
        etracker_mnesia ->
            mnesia:activity(transaction, fun () -> mnesia:all_keys(torrent_info) end);
        etracker_pgsql ->
            Q = "select info_hash from torrent_info",
            {ok, _C, Rows} = etracker_db:db_call({equery, Q, []}),
            [IH || {IH} <- Rows]
    end.

write_record(Rec) ->
    {ok, {WorkerArgs, _}} = etracker_env:get(db_pool),
    Mod = proplists:get_value(worker_module, WorkerArgs),
    case Mod of
        etracker_mnesia ->
            mnesia:activity(transaction, fun () -> mnesia:write(Rec) end);
        etracker_pgsql ->
            ok = etracker_db:db_call({write, Rec})
    end.

delete_record(Rec) ->
    {ok, {WorkerArgs, _}} = etracker_env:get(db_pool),
    Mod = proplists:get_value(worker_module, WorkerArgs),
    case Mod of
        etracker_mnesia ->
            mnesia:activity(transaction, fun () -> mnesia:delete_object(Rec) end);
        etracker_pgsql ->
            etracker_db:db_call({delete, Rec})
    end.
