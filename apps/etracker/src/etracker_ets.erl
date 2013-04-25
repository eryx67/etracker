%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_ets).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(DB_MGR, etracker_db_mgr).

-define(QUERY_CHUNK_SIZE, 100).

-record(state, {db_type}).


start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Opts) ->
    DT= gen_server:call(?DB_MGR, db_type),
    random:seed(erlang:now()),
    {ok, #state{db_type=DT}}.

handle_call({announce, Peer}, _From, S=#state{db_type=DT}) ->
	process_announce(DT, Peer),
	{reply, ok, S};
handle_call({torrent_info, InfoHash}, _From, State) when is_binary(InfoHash) ->
	case ets:lookup(torrent_info, InfoHash) of
		[] ->
			{reply, #torrent_info{}, State};

		[TI] ->
			{reply, TI, State}
	end;
handle_call({torrent_infos, InfoHashes, Callback}, _From, State) when is_list(InfoHashes) ->
    Ret = process_torrent_infos(InfoHashes, Callback),
    {reply, Ret, State};
handle_call({torrent_peers, InfoHash, Wanted}, _From, S=#state{db_type=DT}) ->
    Ret = process_torrent_peers(DT, InfoHash, Wanted),
    {reply, Ret, S};
handle_call({expire_torrent_peers, ExpireTime}, _From, S=#state{db_type=DT}) ->
    Ret = process_expire_torrent_peers(DT, ExpireTime),
    {reply, Ret, S};
handle_call({system_info, torrents}, _From, State) ->
    {reply, ets:info(torrent_info, size), State};
handle_call({system_info, peers}, _From, State) ->
    {reply, ets:info(torrent_user, size), State};
handle_call({system_info, seeders}, _From, State=#state{db_type=dict}) ->
    Reply = gen_server:call(?DB_MGR, {count, seeders}),
    {reply, Reply, State};
handle_call({system_info, leechers}, _From, State=#state{db_type=dict}) ->
    Reply = gen_server:call(?DB_MGR, {count, leechers}),
    {reply, Reply, State};
handle_call({system_info, seeders}, _From, State=#state{db_type=ets}) ->
    Reply = ets:info(torrent_seeder, size) ,
    {reply, Reply, State};
handle_call({system_info, leechers}, _From, State=#state{db_type=ets}) ->
    Reply = ets:info(torrent_leecher, size),
    {reply, Reply, State};
handle_call({write, TI}, _From, State) when is_record(TI, torrent_info) ->
    ets:insert(torrent_info, TI),
    {reply, ok, State};
handle_call({write, TU}, _From, S=#state{db_type=DT})  when is_record(TU, torrent_user) ->
    write_torrent_user(DT, TU),
    {reply, ok, S};
handle_call({delete, _TI=#torrent_info{info_hash=IH}}, _From, State) ->
    ets:delete(torrent_info, IH),
    {reply, ok, State};
handle_call({delete, TU=#torrent_user{}}, _From, S=#state{db_type=DT}) ->
    delete_torrent_user(DT, TU),
    {reply, ok, S};
handle_call(Request, _From, State) ->
    lager:debug("invalid request ~p", [Request]),
    Reply = {error, invalid_request},
    {reply, Reply, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(stop, State) ->
    {stop, shutdown, State};
handle_info({'EXIT', _, _}, State) ->
    {stop, shutdown, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
process_expire_torrent_peers(DT, ExpireTime) ->
    Q = ets:fun2ms(fun(#torrent_user{id=Id, mtime=M}) when M < ExpireTime ->
                           Id
                   end),
    QueryF = fun () ->
                     case ets:select(torrent_user, Q, ?QUERY_CHUNK_SIZE) of
                         {Data, _} ->
                             Data;
                         _ ->
                             []
                     end
             end,
    process_expire_torrent_peers1(DT, QueryF, 0).

process_expire_torrent_peers1(DT, QueryFun, Cnt) ->
    case QueryFun() of
        [] ->
            Cnt;
        Ids ->
            lists:foreach(fun (Id) ->
                                  delete_torrent_user(DT, Id)
                          end,
                          Ids),
            process_expire_torrent_peers1(DT, QueryFun, length(Ids) + Cnt)
    end.

process_torrent_infos([], Callback) ->
    Q = ets:fun2ms(fun(TI) -> TI end),
    process_torrent_infos1(ets:select(torrent_info, Q, ?QUERY_CHUNK_SIZE), Callback);
process_torrent_infos(IHs, Callback) ->
    Data = lists:foldl(fun (IH, Acc) ->
                               case ets:lookup(torrent_info, IH) of
                                   [] ->
                                       Acc;
                                   [TI] ->
                                       [TI|Acc]
                               end
                       end, [], IHs),
    Callback(Data).

process_torrent_infos1({Data, Cont}, Callback) ->
    Callback(Data),
    process_torrent_infos1(ets:select(Cont), Callback);
process_torrent_infos1('$end_of_table', _Callback) ->
    ok.

process_torrent_peers(dict, InfoHash, Wanted) ->
    Ret = {SeedersCnt, LeechersCnt, _Peers} =
        gen_server:call(?DB_MGR, {peers, InfoHash, Wanted}),
    ets:update_element(torrent_info, InfoHash,
                       [{#torrent_info.seeders, SeedersCnt},
                        {#torrent_info.leechers, LeechersCnt},
                        {#torrent_info.mtime, erlang:now()}]),
    Ret;
process_torrent_peers(ets, InfoHash, Wanted) ->
    Q =  ets:fun2ms(fun(#torrent_peer{id=Id, peer=Peer})
                          when Id > {InfoHash, ?INFOHASH_MIN},
                               Id < {InfoHash, ?INFOHASH_MAX} ->
                            {element(2, Id), Peer}
                    end),
    CntQ = ets:fun2ms(fun(#torrent_peer{id=Id})
                            when Id > {InfoHash, ?INFOHASH_MIN},
                                 Id < {InfoHash, ?INFOHASH_MAX} ->
                            true
                    end),
    SeedersCnt = ets:select_count(torrent_seeder, CntQ),
    LeechersCnt = ets:select_count(torrent_leecher, CntQ),
    ets:update_element(torrent_info, InfoHash,
                       [{#torrent_info.seeders, SeedersCnt},
                        {#torrent_info.leechers, LeechersCnt},
                        {#torrent_info.mtime, erlang:now()}]),
    Seeders = process_torrent_peers_ets(seeders, Q, Wanted, SeedersCnt),
    RestWanted = max(0, Wanted - length(Seeders)),
    Leechers = process_torrent_peers_ets(leechers, Q, RestWanted, LeechersCnt),
    {SeedersCnt, LeechersCnt, Seeders ++ Leechers}.

process_torrent_peers_ets(_PT, _Q, Wanted, Available) when Wanted == 0
                                                           orelse Available == 0 ->
    [];
process_torrent_peers_ets(PeerType, Query, Wanted, Available) ->
    Table = case PeerType of
                seeders ->
                    torrent_seeder;
                leechers ->
                    torrent_leecher
            end,
    Available1 = max(Wanted, Available),
    if Available1 =< Wanted ->
            ets:select(Table, Query);
       true ->
            Offset = random:uniform(Available1 - Wanted),
            Cursor = ets:select(Table, Query, Wanted),
            Data = process_torrent_peers_ets_seek(Cursor, Offset, Wanted, []),
            lists:nthtail(max(length(Data) - Wanted, 0), Data)
    end.

process_torrent_peers_ets_seek({Data, _C}, _O, Wanted, Last) when length(Data) < Wanted ->
    Last ++ Data;
process_torrent_peers_ets_seek({Data, _C}, Offset, _W, Last) when Offset =< 0 ->
    Last ++ Data;
process_torrent_peers_ets_seek({Data, Cont}, Offset, Wanted, _Last) ->
    process_torrent_peers_ets_seek(ets:select(Cont), Offset - length(Data), Wanted, Data);
process_torrent_peers_ets_seek('$end_of_table', _O, _W, Last) ->
    Last.

process_announce(DT, _A=#announce{
                      event = <<"stopped">>,
                      info_hash=InfoHash, peer_id=PeerId}) ->
    delete_torrent_user(DT, {InfoHash, PeerId});
process_announce(DT, _A=#announce{
                      event=Evt,
                      info_hash=InfoHash, peer_id=PeerId, ip=IP, port=Port,
                      uploaded=Upl, downloaded=Dld, left=Left
                     }) ->
    Finished = Left == 0,
    Id = {InfoHash, PeerId},
    Peer = {IP, Port},
    {Seeders, Leechers} = if Finished == true ->
                                  {1, 0};
                             true ->
                                  {0, 1}
                          end,
    Completed = if Evt == <<"completed">> ->
                        1;
                   true ->
                        0
                end,
    TI = #torrent_info{
            info_hash=InfoHash,
            seeders=Seeders,
            leechers=Leechers,
            completed=Completed
           },
    TU = #torrent_user{
            id=Id,
            peer=Peer,
            event=Evt,
            finished = Finished,
            uploaded=Upl, downloaded=Dld, left=Left
           },
    case (ets:insert_new(torrent_info, TI) == false) andalso (Completed == 1) of
        true ->
            ets:update_counter(torrent_info, InfoHash,
                               {#torrent_info.completed, Completed});
        _ ->
            ok
    end,
    write_torrent_user(DT, TU).

write_torrent_user(dict, TU=#torrent_user{id=Id, peer=Peer, finished=F}) ->
    {IH, PeerId} = Id,
    ets:insert(torrent_user, TU),
    gen_server:call(?DB_MGR, {add_peer, IH, PeerId, Peer, F});
write_torrent_user(ets, TU=#torrent_user{id=Id, peer=Peer, finished=F}) ->
    TP = #torrent_peer{
            id = Id,
            peer = Peer
           },
    ets:insert(torrent_user, TU),
    if F == true ->
            ets:delete(torrent_leecher, Id),
            ets:insert(torrent_seeder, TP);
       true ->
            ets:delete(torrent_seeder, Id),
            ets:insert(torrent_leecher, TP)
    end.

delete_torrent_user(DT, _TU=#torrent_user{id=Id}) ->
    delete_torrent_user(DT, Id);
delete_torrent_user(dict, Id) ->
    ets:delete(torrent_user, Id),
    {IH, PeerId} = Id,
    gen_server:call(?DB_MGR, {delete_peer, IH, PeerId});
delete_torrent_user(ets, Id) ->
    ets:delete(torrent_user, Id),
    ets:delete(torrent_seeder, Id),
    ets:delete(torrent_leecher, Id).
