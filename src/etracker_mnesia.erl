%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2015, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 5 Feb 2015 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_mnesia).

-behaviour(gen_server).

%% API
-export([start_link/1, db_write/2, db_read/2, db_select/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-import(etracker_mnesia_mgr, [table_name/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(DB_MGR, etracker_db_mgr).

-define(QUERY_CHUNK_SIZE, 1000).

-record(state, {}).


start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Opts) ->
    process_flag(trap_exit, true),
    random:seed(erlang:now()),
    {ok, #state{}}.

handle_call({announce, Peer}, _From, S=#state{}) ->
        process_announce(Peer),
        {reply, ok, S};
handle_call({torrent_info, InfoHash}, _From, State) when is_binary(InfoHash) ->
    case db_read(torrent_info, InfoHash) of
        [] ->
            {reply, #torrent_info{}, State};

        [TI] ->
            {reply, TI, State}
    end;
handle_call({torrent_infos, InfoHashes, Period, Callback}, _From, State) when is_list(InfoHashes) ->
    Ret = process_torrent_infos(InfoHashes, Period, Callback),
    {reply, Ret, State};
handle_call({torrent_peers, InfoHash, Wanted}, _From, S=#state{}) ->
    Ret = process_torrent_peers(InfoHash, Wanted),
    {reply, Ret, S};
handle_call({expire, torrent_user, ExpireTime}, _From, S=#state{}) ->
    Ret = process_expire_torrent_peers(ExpireTime),
    {reply, Ret, S};
handle_call({expire, udp_connection_info, ExpireTime}, _From, S) ->
    Ret = process_expire_udp_connections(ExpireTime),
    {reply, Ret, S};
handle_call({stats_info, torrents}, _From, State) ->
    {reply, db_table_info(torrent_info, size), State};
handle_call({stats_info, alive_torrents, Period}, _From, State) ->
    Reply = count_alive_torrents(Period),
    {reply, Reply, State};
handle_call({stats_info, seederless_torrents, Period}, _From, State) ->
    Reply = count_seederless_torrents(Period),
    {reply, Reply, State};
handle_call({stats_info, peerless_torrents, Period}, _From, State) ->
    Reply = count_peerless_torrents(Period),
    {reply, Reply, State};
handle_call({stats_info, peers}, _From, State) ->
    {reply, db_table_info(torrent_user, size), State};
handle_call({stats_info, seeders}, _From, State=#state{}) ->
    Reply = db_table_info(torrent_seeder, size) ,
    {reply, Reply, State};
handle_call({stats_info, leechers}, _From, State=#state{}) ->
    Reply = db_table_info(torrent_leecher, size),
    {reply, Reply, State};
handle_call({write, TI}, _From, State) when is_record(TI, torrent_info) ->
    db_write(torrent_info, TI),
    {reply, ok, State};
handle_call({member, Tbl, Key}, _From, State) ->
    Ret = db_member(Tbl, Key),
    {reply, Ret, State};
handle_call({write, CI}, _From, State) when is_record(CI, udp_connection_info) ->
    mnesia:ets(fun ets:insert/2, [table_name(udp_connection_info), CI]),
    {reply, ok, State};
handle_call({write, TU}, _From, S=#state{})  when is_record(TU, torrent_user) ->
    write_torrent_user(TU),
    {reply, ok, S};
handle_call({delete, _TI=#torrent_info{info_hash=IH}}, _From, State) ->
    db_delete(torrent_info, IH),
    {reply, ok, State};
handle_call({delete, TU=#torrent_user{}}, _From, S=#state{}) ->
    delete_torrent_user(TU),
    {reply, ok, S};
handle_call(Request, _From, State) ->
    lager:debug("invalid request ~p", [Request]),
    Reply = {error, invalid_request},
    {reply, Reply, State}.

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
process_expire_udp_connections(ExpireTime) ->
    ConnQ = ets:fun2ms(fun(#udp_connection_info{mtime=M}) when M < ExpireTime ->
                               true
                   end),
    ConnCnt = mnesia:ets(fun ets:select_delete/2, [table_name(udp_connection_info), ConnQ]),
    ConnCnt.

process_expire_torrent_peers(ExpireTime) ->
    Q = ets:fun2ms(fun(#torrent_user{id=Id, mtime=M}) when M < ExpireTime ->
                           Id
                   end),
    F = fun ('$end_of_table', Cnt) ->
                Cnt;
            (Id, Cnt) ->
                delete_torrent_user(Id),
                Cnt + 1
        end,
    PeersCnt = db_fold(torrent_user, Q, 0, F),
    PeersCnt.

process_torrent_infos([], Period, Callback) ->
    Q = case Period of
            infinity ->
                ets:fun2ms(fun(TI) -> TI end);
            _ ->
                FromTime = now_sub_sec(now(), Period),
                ets:fun2ms(fun(TI=#torrent_info{mtime=MT}) when MT > FromTime -> TI end)
        end,
    F = fun ('$end_of_table', _) ->
                ok;
            (Rec, Acc) -> 
                Callback([Rec]),
                Acc
        end,
    db_fold(torrent_info, Q, undefined, F);
process_torrent_infos(IHs, Period, Callback) ->
    FromTime = if Period == infinity -> Period;
                  true -> now_sub_sec(now(), Period)
               end,
    Data = lists:map(fun (IH) ->
                             case db_read(torrent_info, IH) of
                                 [] ->
                                     undefined;
                                 [TI=#torrent_info{mtime=MT}] ->
                                     if MT > FromTime ->
                                             TI;
                                        true ->
                                             undefined
                                     end
                             end
                     end, IHs),
    Callback(Data).

count_alive_torrents(Period) ->
    FromTime = now_sub_sec(now(), Period),
    Q = ets:fun2ms(fun(#torrent_info{mtime=MT})
                         when MT > FromTime ->
                           true
                   end),
    count_query(torrent_info, Q).

count_seederless_torrents(Period) ->
    FromTime = now_sub_sec(now(), Period),
    Q = ets:fun2ms(fun(#torrent_info{mtime=MT, seeders=S, leechers=L})
                         when MT > FromTime,
                              S == 0,
                              L > 0 ->
                           true
                   end),
    count_query(torrent_info, Q).

count_peerless_torrents(Period) ->
    FromTime = now_sub_sec(now(), Period),
    Q = ets:fun2ms(fun(#torrent_info{mtime=MT, seeders=S, leechers=L})
                         when MT > FromTime,
                              S == 0,
                              L == 0 ->
                           true
                   end),
    count_query(torrent_info, Q).

process_torrent_peers(InfoHash, Wanted) ->
    %% Q =  ets:fun2ms(fun(#torrent_peer{id={IH, Id}, peer=Peer}) when IH == InfoHash ->
    %%                         {Id, Peer}
    %%                 end),
    %% CntQ =  ets:fun2ms(fun(#torrent_peer{id={IH, _}}) when IH == InfoHash ->
    %%                            true
    %%                    end),
    Q = [{#torrent_peer{id = {InfoHash,'$2'},peer = '$3'},
          [],
          [{{'$2','$3'}}]}],

    CntQ = [{#torrent_peer{id = {InfoHash,'_'},peer = '_'}, [], [true]}],

    SeedersCnt = count_query(torrent_seeder, CntQ),
    LeechersCnt = count_query(torrent_leecher, CntQ),
    TI = db_get(torrent_info, InfoHash, #torrent_info{info_hash=InfoHash}),
    db_write(torrent_info, TI#torrent_info{seeders=SeedersCnt,
                                           leechers=LeechersCnt,
                                           mtime=erlang:now()
                                          }),
    Seeders = process_torrent_peers_1(torrent_seeder, Q, Wanted, SeedersCnt),
    RestWanted = max(0, Wanted - length(Seeders)),
    Leechers = process_torrent_peers_1(torrent_leecher, Q, RestWanted, LeechersCnt),
    {SeedersCnt, LeechersCnt, Seeders ++ Leechers}.

process_torrent_peers_1(_PT, _Q, Wanted, Available) when Wanted == 0
                                                         orelse Available == 0 ->
    [];
process_torrent_peers_1(Table, Query, Wanted, Available) ->
    Available1 = max(Wanted, Available),
    if Available1 =< Wanted ->
            db_select(Table, Query);
       true ->
            Offset = random:uniform(Available1 - Wanted),
            Data = db_select(Table, Query, Offset, Wanted),
            Data
    end.

process_announce(_A=#announce{
                       event = <<"stopped">>,
                       info_hash=InfoHash, peer_id=PeerId}) ->
    delete_torrent_user({InfoHash, PeerId});
process_announce(_A=#announce{
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
    case db_read(torrent_info, InfoHash) of
        [] ->
            db_write(torrent_info, TI);
        [OldTI] when Completed == 1 ->
            #torrent_info{completed=OldCompleted} = OldTI,
            db_write(torrent_info, OldTI#torrent_info{completed=OldCompleted+1});
        [_] ->
            ok
    end,
    write_torrent_user(TU).

write_torrent_user(TU=#torrent_user{id=Id, peer=Peer, finished=F}) ->
    TP = #torrent_peer{
            id = Id,
            peer = Peer
           },
    db_write(torrent_user, TU),
    if F == true ->
            db_delete(torrent_leecher, Id),
            db_write(torrent_seeder, TP);
       true ->
            db_delete(torrent_seeder, Id),
            db_write(torrent_leecher, TP)
    end.

delete_torrent_user(_TU=#torrent_user{id=Id}) ->
    delete_torrent_user(Id);
delete_torrent_user(Id) ->
    db_delete(torrent_user, Id),
    db_delete(torrent_seeder, Id),
    db_delete(torrent_leecher, Id).

now_sub_sec(Now, Seconds) ->
    {Mega, Sec, Micro} = Now,
    SubMega = Seconds div 1000000,
    SubSec = Seconds rem 1000000,
    Mega1 = Mega - SubMega,
    Sec1 = Sec - SubSec,
    {Mega2, Sec2} = if Mega1 < 0 ->
                            exit(badarg);
                       (Sec1 < 0) ->
                            {Mega1 - 1, 1000000 + Sec1};
                       true ->
                            {Mega1, Sec1}
                    end,
    if (Mega2 < 0) ->
            exit(badarg);
       true ->
            {Mega2, Sec2, Micro}
    end.

db_read(Tbl, Key) ->
    mnesia:activity(ets, fun mnesia:read/2, [table_name(Tbl), Key], mnesia_frag).

db_get(Tbl, Key, Default) ->
    case db_read(Tbl, Key) of
        [] ->
            Default;
        [V] ->
            V
    end.

db_write(Tbl, Data) ->
    mnesia:activity(ets, fun mnesia:write/3, [table_name(Tbl), Data, write], mnesia_frag).

db_delete(Tbl, Key) ->
    mnesia:activity(ets, fun mnesia:delete/3, [table_name(Tbl), Key, write], mnesia_frag).

db_table_info(Tbl, What) ->
    mnesia:activity(ets, fun mnesia:table_info/2, [table_name(Tbl), What], mnesia_frag).

db_member(Tbl, Key) ->
    db_read(Tbl, Key) =/= [].

db_select(Tbl, Query) ->
    F = fun ('$end_of_table', Acc) ->
                lists:reverse(Acc);
            (R, Acc) -> 
                [R|Acc]
        end,
    db_fold(Tbl, Query, [], F).

db_select(Tbl, Query, Offset, Num) ->
    F = fun ('$end_of_table', {Acc, _, _}) ->
                lists:reverse(Acc);
            (_R, {Acc, O, N}) when O > 0 ->
                {Acc, O - 1, N};
            (R, {Acc, _, N}) when N >= Num ->
                db_fold_end(lists:reverse([R|Acc]));
            (R, {Acc, 0, N}) ->
                {[R|Acc], 0, N + 1}
        end,
    db_fold(Tbl, Query, {[], Offset, 1}, F).

count_query(Tbl, Q) ->
    F = fun ('$end_of_table', Cnt) ->
                Cnt;
            (_, Cnt) ->
                Cnt + 1
        end,
    db_fold(Tbl, Q, 0, F).

db_fold_end(Res) ->
    throw({db_fold_end, Res}).

-spec db_fold(atom(), term(), term(), fun((term() | '$end_of_table', term()) -> term())) -> term().
db_fold(Table, Query, Acc, Fun) ->
    db_fold(Table, Query, Acc, Fun, mnesia_frag).

db_fold(Table, Query, Acc, Fun, AM) ->
    ReqF = fun () -> mnesia:select(table_name(Table), Query, ?QUERY_CHUNK_SIZE, read) end,
    ReqRes = case AM of
                 undefined ->
                     mnesia:activity(ets, ReqF, []);
                 _ ->
                     mnesia:activity(ets, ReqF, [], AM)
             end,
    try walk_table(ReqRes, Fun, Acc, AM)
    catch
        throw:{db_fold_end, Res} ->
            Res
    end.

walk_table('$end_of_table', Fun, Args, _AM) ->
    Fun('$end_of_table', Args);
walk_table({Recs, Cont}, Fun, Args, AM) ->
    NxtArgs = lists:foldl(Fun, Args, Recs),
    ReqF= fun () -> mnesia:select(Cont) end,
    ReqRes = case AM of
                 undefined ->
                     mnesia:activity(ets, ReqF, []);
                 _ ->
                     mnesia:activity(ets, ReqF, [], AM)
             end,
    walk_table(ReqRes, Fun, NxtArgs, AM).
