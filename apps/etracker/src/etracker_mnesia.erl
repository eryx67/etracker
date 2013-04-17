%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_mnesia).

-behaviour(gen_server).

%% API
-export([setup/1, setup/2, start_link/1, dump_tables/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("etracker.hrl").

-define(SERVER, ?MODULE).

-define(QUERY_CHUNK_SIZE, 10000).

-define(TABLES, [torrent_info, torrent_user]).
-define(TABLES_TIMEOUT, 60000).
-record(state, {}).

setup(Opts) ->
    setup([node()], Opts).

setup(Nodes, Opts) ->
    TablesTimeout = proplists:get_value(timeout, Opts, ?TABLES_TIMEOUT),
    mnesia:create_schema(Nodes),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    mnesia:start(),
    ExistingTables = mnesia:system_info(tables),
    Tables = ?TABLES -- ExistingTables,
    create_tables(Nodes, Tables),
    mnesia:wait_for_tables(?TABLES, TablesTimeout),
    ok.

dump_tables() ->
    mnesia:dump_tables(?TABLES).

create_tables(Nodes, Tables) ->
    lists:foreach(fun (Tbl) ->
                          create_table(Tbl, Nodes)
                  end, Tables).

create_table(torrent_info, Nodes) ->
    mnesia:create_table(torrent_info, [
                                       {type, set},
                                       {local_content, true},
                                       {attributes, record_info(fields, torrent_info)},
                                       {ram_copies, Nodes},
                                       {storage_properties,
                                        [{ets, [{read_concurrency, true},
                                                {write_concurrency, true}]}]
                                       }
                                      ]);
create_table(torrent_user, Nodes) ->
    mnesia:create_table(torrent_user, [
                                       {type, set},
                                       {local_content, true},
                                       {attributes, record_info(fields, torrent_user)},
                                       {index, [info_hash, mtime]},
                                       {ram_copies, Nodes},
                                       {storage_properties,
                                        [{ets, [{read_concurrency, true},
                                                {write_concurrency, true}]}]
                                       }
                                      ]),
    mnesia:add_table_index(torrent_user, info_hash),
    mnesia:add_table_index(torrent_user, mtime).

start_link(Opts) ->
    TablesTimeout = proplists:get_value(timeout, Opts, ?TABLES_TIMEOUT),
    gen_server:start_link(?MODULE, Opts, [{timeout, TablesTimeout}]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    random:seed(erlang:now()),
    setup(Opts),
    {ok, #state{}}.

handle_call({torrent_info, InfoHash}, _From, State) when is_binary(InfoHash) ->
    F = fun() -> mnesia:dirty_read({torrent_info, InfoHash}) end,
	case mnesia:activity(ets, F) of
		[] ->
			{reply, #torrent_info{}, State};

		[TI] ->
			{reply, TI, State}
	end;
handle_call({torrent_infos, InfoHashes, Callback}, _From, State) when is_list(InfoHashes) ->
    mnesia:activity(ets,
                    fun () ->
                            process_torrent_infos(InfoHashes, Callback)
                    end),
    {reply, ok, State};
handle_call({torrent_peers, InfoHash, Wanted}, _From, State) ->
    F = fun () ->
                process_torrent_peers(InfoHash, Wanted)
        end,
    Peers = mnesia:activity(ets, F),
    {reply, Peers, State};
handle_call({expire_torrent_peers, ExpireTime}, _From, State) ->
    F = fun () ->
                process_expire_torrent_peers(ExpireTime)
        end,
    Reply = mnesia:activity(ets, F),
    {reply, Reply, State};
handle_call({system_info, torrents}, _From, State) ->
    {reply, mnesia:table_info(torrent_info, size), State};
handle_call({system_info, peers}, _From, State) ->
    {reply, mnesia:table_info(torrent_user, size), State};
handle_call({system_info, seeders}, _From, State) ->
    Fun = fun (#torrent_user{finished=F}, Acc) when F == true ->
                  Acc + 1;
              (_, Acc) -> Acc
          end,
    Reply = mnesia:activity(ets, fun () -> mnesia:foldl(Fun, 0, torrent_user) end),
    {reply, Reply, State};
handle_call({system_info, leechers}, _From, State) ->
    Fun = fun (#torrent_user{finished=F}, Acc) when F == false ->
                  Acc + 1;
              (_, Acc) ->
                  Acc
          end,
    Reply = mnesia:activity(ets, fun () -> mnesia:foldl(Fun, 0, torrent_user) end),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({announce, Peer}, State) ->
	F = process_announce(Peer),
    mnesia:activity(ets, F),
	{noreply, State};
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
process_expire_torrent_peers(ExpireTime) ->
    Q = ets:fun2ms(fun(#torrent_user{id=Id, finished=F, mtime=M}) when M < ExpireTime ->
                           {Id, F}
                   end),
    case mnesia:select(torrent_user, Q, ?QUERY_CHUNK_SIZE, read) of
        {Res, _Cont} ->
            {Torrents, Users} =
                lists:foldl(fun ({Id={IH, _}, F}, {Ts, Us}) ->
                                    {S, L} = Val = if F == true -> {1, 0};
                                                      true -> {0, 1}
                                                   end,
                                    {orddict:update(IH, fun ({SC, LC}) ->
                                                                {SC + S, LC + L}
                                                        end, Val, Ts),
                                     [Id|Us]
                                    }
                            end, {orddict:new(), []}, Res),
            lists:foreach(fun (Id) -> mnesia:dirty_delete({torrent_user, Id}) end, Users),
            orddict:fold(fun (InfoHash, {Seeders, Leechers}, Acc) ->
                                 case mnesia:dirty_read({torrent_info, InfoHash}) of
                                     [] ->
                                         ok;
                                     [TI=#torrent_info{seeders=S, leechers=L}] ->
                                         mnesia:dirty_write(TI#torrent_info{
                                                        seeders=max(0, S - Seeders),
                                                        leechers=max(0, L - Leechers)
                                                       })
                                 end,
                                 Acc + 1
                         end, 0, Torrents);
        '$end_of_table' ->
            0
    end.

process_torrent_infos([], Callback) ->
    Q = ets:fun2ms(fun(TI) -> TI end),
    process_torrent_infos1(mnesia:select(torrent_info, Q, ?QUERY_CHUNK_SIZE, read),
                           Callback);
process_torrent_infos(IHs, Callback) ->
    Data = lists:foldl(fun (IH, Acc) ->
                               case mnesia:dirty_read({torrent_info, IH}) of
                                   [] ->
                                       Acc;
                                   [TI] ->
                                       [TI|Acc]
                               end
                       end, [], IHs),
    Callback(Data).

process_torrent_infos1({Data, Cont}, Callback) ->
    Callback(Data),
    process_torrent_infos1(mnesia:select(Cont), Callback);
process_torrent_infos1('$end_of_table', _Callback) ->
    ok.

process_torrent_peers(InfoHash, Wanted) ->
    case mnesia:dirty_read({torrent_info, InfoHash}) of
        [] ->
            [];
        [#torrent_info{seeders=S, leechers=L}] ->
            Seeders = process_torrent_peers(seeders, InfoHash, Wanted, S),
            RestWanted = max(0, Wanted - length(Seeders)),
            Leechers = process_torrent_peers(leechers, InfoHash, RestWanted, L),
            Seeders ++ Leechers
    end.

process_torrent_peers(_PeerType, _InfoHash, Wanted, Available) when Wanted == 0
                                                                    orelse Available == 0 ->
    [];
process_torrent_peers(PeerType, InfoHash, Wanted, Available) ->
    Query =
        case PeerType of
            seeders ->
                ets:fun2ms(fun(#torrent_user{id={_, PeerId}, peer=Peer,
                                                 info_hash=IH, left=L}) when IH == InfoHash,
                                                                             L == 0 ->
                                       {PeerId, Peer}
                           end);
            leechers ->
                ets:fun2ms(fun(#torrent_user{id={_, PeerId}, peer=Peer,
                                             info_hash=IH, left=L}) when IH == InfoHash,
                                                                         L /= 0 ->
                                   {PeerId, Peer}
                           end)
        end,
    Available1 = max(Wanted, Available),
    if Available1 =< Wanted ->
            mnesia:dirty_select(torrent_user, Query);
       true ->
            Offset = random:uniform(Available1 - Wanted),
            Cursor = mnesia:select(torrent_user, Query, Wanted, read),
            Data = process_torrent_peers_seek(Cursor, Offset, Wanted, []),
            lists:nthtail(max(length(Data) - Wanted, 0), Data)
    end.

process_torrent_peers_seek({Data, _C}, _O, Wanted, Last) when length(Data) < Wanted ->
    Last ++ Data;
process_torrent_peers_seek({Data, _C}, Offset, _W, Last) when Offset =< 0 ->
    Last ++ Data;
process_torrent_peers_seek({Data, Cont}, Offset, Wanted, _Last) ->
    process_torrent_peers_seek(mnesia:select(Cont), Offset - length(Data), Wanted, Data);
process_torrent_peers_seek('$end_of_table', _O, _W, Last) ->
    Last.

process_announce(A=#announce{
                      event=Evt,
                      info_hash=InfoHash, peer_id=PeerId, ip=IP, port=Port,
                      uploaded=Upl, downloaded=Dld, left=Left
                     }) ->
    process_announce(A, #torrent_user{
                           id={InfoHash, PeerId},
                           info_hash=InfoHash,
                           peer={IP, Port},
                           event=Evt,
                           uploaded=Upl, downloaded=Dld, left=Left
                          }).

process_announce(#announce{event = <<"started">>, left=Left, info_hash=InfoHash},
                 TorrentUser=#torrent_user{id=TID, event=Event}) ->
	fun() ->
            {AddSeeders, AddLeechers} =
                if Left == 0 -> {1, 0}; % is seeder
                   true -> {0, 1} % is leecher
                end,

            {AddSeeders1, AddLeechers1} =
                case mnesia:dirty_read({torrent_user, TID}) of
                    %% duplicated event
                    [#torrent_user{event=Event, left=OldLeft}] ->
                        if OldLeft == Left ->
                                {0, 0}; % client status is unchanged
                           (OldLeft > 0) and (Left > 0) ->
                                {0, 0};  % client status is unchanged, leecher
                           Left == 0 ->
                                {1, -1}; % client changed from leecher to seeder
                           true ->
                                {-1, 1} % client changed from seeder to leecher
                        end;
                    _ -> {AddSeeders, AddLeechers}
                end,

            case mnesia:dirty_read({torrent_info, InfoHash}) of
                [] -> mnesia:dirty_write(#torrent_info{
                                      seeders=AddSeeders1,
                                      leechers=AddLeechers1,
                                      info_hash=InfoHash
                                     });
                [T=#torrent_info{seeders=S, leechers=L}] ->
                    mnesia:dirty_write(T#torrent_info{
                                   seeders=max(S+AddSeeders1, 0),
                                   leechers=max(L+AddLeechers1, 0),
                                   mtime=erlang:now()})
            end,
            mnesia:dirty_write(TorrentUser#torrent_user{finished = Left == 0})
	end;
process_announce(#announce{event = <<"stopped">>, info_hash=InfoHash},
                 _TU=#torrent_user{id=TID}) ->
	fun() ->
            {SubSeeders, SubLeechers} =
                case mnesia:dirty_read({torrent_user, TID}) of
                    [] -> {0, 0};
                    [#torrent_user{finished=F}] ->
                        mnesia:delete({torrent_user, TID}),
                        if (F == true) ->
                                {1, 0}; % is seeder
                           true ->
                                {0, 1}
                        end
                end,
            case mnesia:dirty_read({torrent_info, InfoHash}) of
                [] -> mnesia:dirty_write(#torrent_info{info_hash = InfoHash});
                [T=#torrent_info{seeders=S, leechers=L}] ->
                    mnesia:dirty_write(T#torrent_info{
                                   seeders=max(S - SubSeeders, 0),
                                   leechers=max(L - SubLeechers, 0),
                                   mtime=erlang:now()
                                  })
            end
	end;
%% Peer completed download
process_announce(#announce{event = <<"completed">>, info_hash=InfoHash},
                 TorrentUser=#torrent_user{id=TID, event=Event}) ->
	fun() ->
            {AddSeeders, AddLeechers} =
                case mnesia:dirty_read({torrent_user, TID}) of
                    [#torrent_user{event=E, finished = F}] when E == Event
                                                                orelse F == true ->
                        {0, 0}; % duplicated event or seeder was already counted
                    _ ->
                        {1, -1}
                end,
            case mnesia:dirty_read({torrent_info, InfoHash}) of
                [] -> mnesia:dirty_write(#torrent_info{
                                      info_hash = InfoHash,
                                      seeders=1, completed=1
                                     });
                [T=#torrent_info{seeders=S, leechers=L, completed=C}] ->
                    mnesia:dirty_write(T#torrent_info{
                                   leechers=max(L + AddLeechers, 0),
                                   seeders=S + AddSeeders,
                                   completed=C + AddSeeders,
                                   mtime=erlang:now()
                                  })
            end,
            mnesia:dirty_write(TorrentUser#torrent_user{finished = true})
	end;
%% Peer is making periodic announce
process_announce(#announce{left=Left, info_hash=InfoHash}, TU=#torrent_user{id=TID}) ->
	fun() ->
            {Seeders, Leechers} =
                if Left == 0 -> {1, 0}; % is seeder
                   true -> {0, 1} % is leecher
                end,
            case mnesia:dirty_read({torrent_info, InfoHash}) of
                [] -> mnesia:dirty_write(#torrent_info{
                                      info_hash = InfoHash,
                                      seeders=Seeders,
                                      leechers=Leechers
                                     });
                _ ->
                    ok
            end,
            case mnesia:dirty_read({torrent_user, TID}) of
                [] -> mnesia:dirty_write(TU#torrent_user{finished= Left == 0});
                [#torrent_user{event=Evt, finished=F}] ->
                    mnesia:dirty_write(TU#torrent_user{event=Evt, finished=F, mtime=erlang:now()})
            end
	end.
