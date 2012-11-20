-module(etracker_test).

-include_lib("eunit/include/eunit.hrl").

start_apps() ->
    etorrent:start_app(),
    etracker:start(),
    timer:sleep(5000),
    [].

setup_announce() ->
    random:seed(now()),
    random_announce().

stop(_SD) ->
    ok.

etracker_test_() ->
    {setup,
     fun start_apps/0,
     fun stop/1,
     fun(_SetupData) ->
             [{foreach, fun setup_announce/0,
               [
                fun leecher_started_first/1
               ]}]
     end
    }.

leecher_started_first(Ann) ->
    %[IH, PeerId, Port] = [orddict:fetch(K, Ann) || K <- [info_hash, peer_id, port]],
    Ann1 = lists:foldl(fun ({K, V}, D) -> orddict:store(K, V, D) end,
                       Ann, [{left, 12345}, {event, <<"started">>}, {compact, 0}]),
    {ok, Resp} = send_announce(orddict:to_list(Ann1)),
    [
     ?_assertEqual(proplists:get_value(<<"incomplete">>, Resp), 1),
     ?_assertEqual(proplists:get_value(<<"complete">>, Resp), 0),
     ?_assertEqual(proplists:get_value(<<"peers">>, Resp), [])
    ].

send_announce(PL) ->
    TrackerUrl = "http://localhost:8080/announce",
    contact_tracker_http(TrackerUrl, started, PL).

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

contact_tracker_http(Url, Event, PL) ->
    RequestUrl = build_tracker_url(Url, Event, PL),
    case etorrent_http:request(RequestUrl) of
        {ok, {{200, _}, _, Body}} ->
            etorrent_bcoding:decode(Body);
        Error -> Error
    end.

build_tracker_url(Url, Event, PL) ->
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
               started -> [{"event", "started"} | Request];
               stopped -> [{"event", "stopped"} | Request];
               completed -> [{"event", "completed"} | Request]
           end,
    FlatUrl = lists:flatten(Url),
    Delim = case lists:member($?, FlatUrl) of
                true -> "&";
                false -> "?"
            end,

    lists:concat([Url, Delim, etorrent_http:mk_header(EReq)]).

random_string(Len) ->
    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    ChrsSize = size(Chrs),
    F = fun(_, R) -> [element(random:uniform(ChrsSize), Chrs) | R] end,
    lists:foldl(F, "", lists:seq(1, Len)).
