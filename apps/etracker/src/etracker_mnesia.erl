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
-export([setup/0, setup/1, start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("stdlib/include/qlc.hrl").
-include("etracker.hrl").

-define(SERVER, ?MODULE).

-define(QUERY_CHUNK_SIZE, 1000).

-define(TABLES, [torrent_info, torrent_user]).
-record(state, {}).

setup() ->
    setup([node()]).

setup(Nodes) ->
    mnesia:create_schema(Nodes),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    mnesia:start(),
    ExistingTables = mnesia:system_info(tables),
    Tables = ?TABLES -- ExistingTables,
    create_tables(Nodes, Tables),
    mnesia:wait_for_tables(?TABLES, 60000),
    ok.

create_tables(Nodes, Tables) ->
    lists:foreach(fun (Tbl) ->
                          create_table(Tbl, Nodes)
                  end, Tables).

create_table(torrent_info, Nodes) ->
    mnesia:create_table(torrent_info, [
                                       {type, set},
                                       {attributes, record_info(fields, torrent_info)},
                                       {disc_copies, Nodes}
                                      ]);
create_table(torrent_user, Nodes) ->
    mnesia:create_table(torrent_user, [
                                       {type, set},
                                       {attributes, record_info(fields, torrent_user)},
                                       {index, [info_hash, mtime]},
                                       {disc_copies, Nodes}
                                      ]),
    mnesia:add_table_index(torrent_user, info_hash),
    mnesia:add_table_index(torrent_user, mtime).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_) ->
    random:seed(erlang:now()),
    proc_lib:spawn_link(fun setup/0),
    {ok, #state{}}.

handle_call({torrent_info, InfoHash}, _From, State) when is_binary(InfoHash) ->
    F = fun() -> mnesia:read({torrent_info, InfoHash}) end,
	case mnesia:activity(sync_dirty, F) of
		[] ->
			{reply, #torrent_info{}, State};

		[TI] ->
			{reply, TI, State}
	end;
handle_call({torrent_infos, InfoHashes, _Pid}, _From, State) when is_list(InfoHashes) ->
    Fun = fun (Callback) ->
                  mnesia:activity(sync_dirty,
                                  fun () ->
                                          process_torrent_infos(InfoHashes, Callback)
                                  end)
          end,
    {reply, Fun, State};
handle_call({torrent_peers, InfoHash, Wanted, Exclude}, From, State) ->
    proc_lib:spawn(fun () ->
                           F = fun () ->
                                       process_torrent_peers(InfoHash, Wanted, Exclude)
                               end,
                           Peers = mnesia:activity(sync_dirty, F),
                           gen_server:reply(From, Peers)
                   end),
    {noreply, State};
handle_call({expire_torrent_peers, ExpireTime}, From, State) ->
    proc_lib:spawn(fun () ->
                           F = fun () ->
                                       process_expire_torrent_peers(ExpireTime)
                               end,
                           Ret = mnesia:activity(sync_dirty, F),
                           gen_server:reply(From, Ret)
                   end),
    {noreply, State};
handle_call({system_info, torrents}, _From, State) ->
    {reply, mnesia:table_info(torrent_info, size), State};
handle_call({system_info, peers}, _From, State) ->
    {reply, mnesia:table_info(torrent_user, size), State};
handle_call({system_info, Key}, From, State) when Key == seeders
                                                  orelse Key == leechers ->
    Query = qlc:q([true || #torrent_user{finished=F} <- mnesia:table(torrent_user),
                           F == (Key == seeders andalso true orelse false)]),
    proc_lib:spawn(fun () ->
                           F = fun () ->
                                       qlc:fold(fun (_V, Acc) -> Acc + 1 end, 0, Query)
                               end,
                           Ret = mnesia:activity(sync_dirty, F),
                           gen_server:reply(From, Ret)
                   end),
    {noreply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({announce, Peer}, _State) ->
	F = process_announce(Peer),
	mnesia:activity(sync_dirty, F),
	{noreply, _State};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

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
    Q = qlc:q([TU || TU=#torrent_user{mtime=M} <- mnesia:table(torrent_user),  M < ExpireTime]),
    C = qlc:cursor(Q),
    process_expire_torrent_peers(C, orddict:new()).

process_expire_torrent_peers(Cursor, Torrents) ->
    case qlc:next_answers(Cursor, ?QUERY_CHUNK_SIZE) of
        [] -> qlc:delete_cursor(Cursor),
              orddict:fold(fun (InfoHash, {Seeders, Leechers}, Acc) ->
                                   case mnesia:read({torrent_info, InfoHash}) of
                                       [] ->
                                           ok;
                                       [TI=#torrent_info{seeders=S, leechers=L}] ->
                                           mnesia:write(TI#torrent_info{
                                                          seeders=max(0, S - Seeders),
                                                          leechers=max(0, L - Leechers)
                                                         })
                                   end,
                                   Acc + 1
                           end, 0, Torrents);
        TUs ->
            Torrents1 = lists:foldl(fun (#torrent_user{id=Id={IH, _}, finished=F}, Ts) ->
                                            mnesia:delete({torrent_user, Id}),
                                            {S, L} = Val = if F == true -> {1, 0};
                                                              true -> {0, 1}
                                                           end,
                                            orddict:update(IH, fun ({SC, LC}) ->
                                                                       {SC + S, LC + L}
                                                               end, Val, Ts)
                                    end, Torrents, TUs),
            process_expire_torrent_peers(Cursor, Torrents1)
    end.

process_torrent_infos([], Callback) ->
    Q = qlc:q([TI || TI <- mnesia:table(torrent_info)]),
    C = qlc:cursor(Q),
    process_torrent_infos1(C, Callback);
process_torrent_infos(IHs, Callback) ->
    Data = lists:foldl(fun (IH, Acc) ->
                        case mnesia:read({torrent_info, IH}) of
                            [] ->
                                Acc;
                            [TI] ->
                                [TI|Acc]
                        end
                end, [], IHs),
    Callback(Data).

process_torrent_infos1(Cursor, Callback) ->
    case qlc:next_answers(Cursor, ?QUERY_CHUNK_SIZE) of
        [] -> qlc:delete_cursor(Cursor),
              [];
        Data ->
            Callback(Data),
            process_torrent_infos1(Cursor, Callback)
    end.

process_torrent_peers(InfoHash, Wanted, Exclude) ->
    case mnesia:read({torrent_info, InfoHash}) of
        [] ->
            [];
        [#torrent_info{seeders=S, leechers=L}] ->
            Seeders = process_torrent_peers(seeders, InfoHash, Wanted, S, Exclude),
            RestWanted = max(0, Wanted - length(Seeders)),
            Leechers = process_torrent_peers(leechers, InfoHash, RestWanted, L, Exclude),
            Seeders ++ Leechers
    end.

process_torrent_peers(_PeerType, _InfoHash, Wanted, Available, _Exclude) when Wanted == 0
                                                                              orelse Available == 0 ->
    [];
process_torrent_peers(PeerType, InfoHash, Wanted, Available, Exclude) ->
    PeerInfoF = fun (#torrent_user{id={_, PeerId}, peer=Peer}) ->
                        {PeerId, Peer}
                end,
    Query =
        case PeerType of
            seeders ->
                qlc:q([PeerInfoF(TU) || TU=#torrent_user{id={_, PI}, info_hash=IH, left=L}
                                            <- mnesia:table(torrent_user),
                                        IH == InfoHash, L == 0,
                                        lists:member(PI, Exclude) == false
                      ]);
            leechers ->
                qlc:q([PeerInfoF(TU) || TU=#torrent_user{id={_, PI}, info_hash=IH, left=L}
                                            <- mnesia:table(torrent_user),
                                        IH == InfoHash, L /= 0,
                                        lists:member(PI, Exclude) == false
                      ])
        end,
    Available1 = max(Wanted, Available),
    if Available1 =< Wanted ->
            qlc:e(Query);
       true ->
            Candidates = gen_random_seq(Available1, Wanted),
            {_, _, Ret} = qlc:fold(fun (PI, {[C|Cs], C, Acc}) ->
                                           {Cs, C+1, [PI|Acc]};
                                       (_PI, {Cs, Cnt, Acc}) ->
                                           {Cs, Cnt + 1, Acc}
                                   end, {Candidates, 1, []}, Query),
            Ret
    end.

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
                case mnesia:read({torrent_user, TID}) of
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

            case mnesia:read({torrent_info, InfoHash}) of
                [] -> mnesia:write(#torrent_info{
                                      seeders=AddSeeders1,
                                      leechers=AddLeechers1,
                                      info_hash=InfoHash
                                     });
                [T=#torrent_info{seeders=S, leechers=L}] ->
                    mnesia:write(T#torrent_info{
                                   seeders=max(S+AddSeeders1, 0),
                                   leechers=max(L+AddLeechers1, 0),
                                   mtime=erlang:now()})
            end,
            mnesia:write(TorrentUser#torrent_user{finished = Left == 0})
	end;
process_announce(#announce{event = <<"stopped">>, info_hash=InfoHash},
                 _TU=#torrent_user{id=TID}) ->
	fun() ->
            {SubSeeders, SubLeechers} =
                case mnesia:read({torrent_user, TID}) of
                    [] -> {0, 0};
                    [#torrent_user{finished=F}] ->
                        mnesia:delete({torrent_user, TID}),
                        if (F == true) ->
                                {1, 0}; % is seeder
                           true ->
                                {0, 1}
                        end
                end,
            case mnesia:read({torrent_info, InfoHash}) of
                [] -> mnesia:write(#torrent_info{info_hash = InfoHash});
                [T=#torrent_info{seeders=S, leechers=L}] ->
                    mnesia:write(T#torrent_info{
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
                case mnesia:read({torrent_user, TID}) of
                    [#torrent_user{event=E, finished = F}] when E == Event
                                                                orelse F == true ->
                        {0, 0}; % duplicated event or seeder was already counted
                    _ ->
                        {1, -1}
                end,
            case mnesia:read({torrent_info, InfoHash}) of
                [] -> mnesia:write(#torrent_info{
                                      info_hash = InfoHash,
                                      seeders=1, completed=1
                                     });
                [T=#torrent_info{seeders=S, leechers=L, completed=C}] ->
                    mnesia:write(T#torrent_info{
                                   leechers=max(L + AddLeechers, 0),
                                   seeders=S + AddSeeders,
                                   completed=C + AddSeeders,
                                   mtime=erlang:now()
                                  })
            end,
            mnesia:write(TorrentUser#torrent_user{finished = true})
	end;
%% Peer is making periodic announce
process_announce(#announce{left=Left, info_hash=InfoHash}, TU=#torrent_user{id=TID}) ->
	fun() ->
            {Seeders, Leechers} =
                if Left == 0 -> {1, 0}; % is seeder
                   true -> {0, 1} % is leecher
                end,
            case mnesia:read({torrent_info, InfoHash}) of
                [] -> mnesia:write(#torrent_info{
                                      info_hash = InfoHash,
                                      seeders=Seeders,
                                      leechers=Leechers
                                     });
                _ ->
                    ok
            end,
            case mnesia:read({torrent_user, TID}) of
                [] -> mnesia:write(TU#torrent_user{finished= Left == 0});
                [#torrent_user{event=Evt, finished=F}] ->
                    mnesia:write(TU#torrent_user{event=Evt, finished=F, mtime=erlang:now()})
            end
	end.

gen_random_seq(Max, Num) ->
    gen_random_seq(Max, Num, []).

gen_random_seq(_Max, 0, Acc) ->
    lists:sort(Acc);
gen_random_seq(Max, Num, Acc) ->
    V = random:uniform(Max),
    case lists:member(V, Acc) of
        true ->
            gen_random_seq(Max, Num, Acc);
        _ ->
            gen_random_seq(Max, Num - 1, [V|Acc])
    end.
