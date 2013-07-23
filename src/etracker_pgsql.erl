%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_pgsql).

-behaviour(gen_server).

%% API
-export([start_link/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(QUERY_CHUNK_SIZE, 1000).
-define(TORRENT_INFO_LIMIT, 10000).

-record(state, {
          connection,
          statements = orddict:new()
         }).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    random:seed(erlang:now()),
    Hostname = proplists:get_value(hostname, Opts),
    Database = proplists:get_value(database, Opts),
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts),
    Timeout = proplists:get_value(timeout, Opts, 5000),
    Port = proplists:get_value(port, Opts, 5432),
    {ok, Conn} = pgsql:connect(Hostname, Username, Password,
                               [{port, Port}, {database, Database}, {timeout, Timeout}]),
    {ok, setup(#state{connection=Conn})}.

handle_call({announce, Peer}, _From, State) ->
	ok = process_announce(Peer, State),
	{reply, ok, State};
handle_call({torrent_info, InfoHash}, _From, State) when is_binary(InfoHash) ->
    {reply, read_torrent_info(InfoHash, State), State};
handle_call({torrent_infos, [], Period, Callback}, _From, State) ->
    process_torrent_infos_all(Callback, Period, State),
    {reply, ok, State};
handle_call({torrent_infos, InfoHashes, Period, Callback}, _From, State) ->
    FromTime = if Period == infinity -> Period;
                  true -> etracker_time:now_sub_sec(now(), Period)
               end,
    Data = lists:map(fun (IH) ->
                             case read_torrent_info(IH, State) of
                                 #torrent_info{info_hash=undefined} ->
                                     undefined;
                                 TI=#torrent_info{mtime=MT} ->
                                     if MT > FromTime ->
                                             TI;
                                        true ->
                                             undefined
                                     end
                             end
                     end, InfoHashes),
    Ret = Callback(Data),
    {reply, Ret, State};
handle_call({torrent_peers, InfoHash, Wanted}, _From, State) ->
    Peers =  process_torrent_peers(InfoHash, Wanted, State),
    {reply, Peers, State};
handle_call({expire, torrent_user, ExpireTime}, _From, State) ->
    Reply = process_expire_torrent_peers(ExpireTime, State),
    {reply, Reply, State};
handle_call({expire, udp_connection_info, ExpireTime}, _From, State) ->
    Reply = process_expire_udp_connections(ExpireTime, State),
    {reply, Reply, State};
handle_call({stats_info, torrents}, _From, S=#state{connection=C, statements=Ss}) ->
    {ok, Cnt} = exec_statement(C, torrent_info_count_all, [], Ss),
    {reply, Cnt, S};
handle_call({stats_info, alive_torrents, Period},
            _From, S=#state{connection=C, statements=Ss}) ->
    FromTime = etracker_time:now_to_timestamp(etracker_time:now_sub_sec(now(), Period)),
    {ok, Cnt} = exec_statement(C, torrent_info_alive_count, [FromTime], Ss),
    {reply, Cnt, S};
handle_call({stats_info, seederless_torrents, Period},
            _From, S=#state{connection=C, statements=Ss}) ->
    FromTime = etracker_time:now_to_timestamp(etracker_time:now_sub_sec(now(), Period)),
    {ok, Cnt} = exec_statement(C, torrent_info_seederless_count, [FromTime], Ss),
    {reply, Cnt, S};
handle_call({stats_info, peerless_torrents, Period},
            _From, S=#state{connection=C, statements=Ss}) ->
    FromTime = etracker_time:now_to_timestamp(etracker_time:now_sub_sec(now(), Period)),
    {ok, Cnt} = exec_statement(C, torrent_info_peerless_count, [FromTime], Ss),
    {reply, Cnt, S};
handle_call({stats_info, peers}, _From, S=#state{connection=C, statements=Ss} ) ->
    {ok, Cnt} = exec_statement(C, peers_count_all, [], Ss),
    {reply, Cnt, S};
handle_call({stats_info, seeders}, _From, S=#state{connection=C, statements=Ss} ) ->
    {ok, Cnt} = exec_statement(C, peers_seeders_count_all, [], Ss),
    {reply, Cnt, S};
handle_call({stats_info, leechers}, _From, S=#state{connection=C, statements=Ss} ) ->
    {ok, Cnt} = exec_statement(C, peers_leechers_count_all, [], Ss),
    {reply, Cnt, S};
handle_call({equery, Query, Params}, _From, S=#state{connection=C}) ->
    {reply, pgsql:equery(C, Query, Params), S};
handle_call({write, _TI=#torrent_info{
                           info_hash=InfoHash,
                           leechers=Leechers,
                           seeders=Seeders,
                           completed=Completed}},
            _From, S=#state{connection=C, statements=Ss}) ->
    MT = etracker_time:now_to_timestamp(now()),
    Args = [InfoHash, Completed, Seeders, Leechers, MT],
    case exec_statement(C, update_torrent_info, Args, Ss) of
        {ok, 0} ->
            exec_statement(C, insert_torrent_info, Args, Ss);
        {ok, 1} ->
            ok
    end,
    {reply, ok, S};
handle_call({write, _TU=#torrent_user{id={IH, PeerId},
                                      peer={Address, Port},
                                      event=Evt,
                                      downloaded = D,
                                      uploaded = U,
                                      left = L,
                                      finished=F
                                     }},
            _From, S=#state{connection=C, statements=Ss}) ->
    MT = etracker_time:now_to_timestamp(now()),
    Args = [IH, PeerId, address_from_erl(Address), Port, U, D, L, Evt, F, MT],
    case exec_statement(C, update_peer, Args, Ss) of
        {ok, 0} ->
            exec_statement(C, insert_peer, Args, Ss);
        {ok, 1} ->
            ok
    end,
    {reply, ok, S};
handle_call({write, _CI=#udp_connection_info{id=Id}},
            _From, S=#state{connection=C, statements=Ss}) ->
    MT = etracker_time:now_to_timestamp(now()),
    Args = [Id, MT],
    case exec_statement(C, update_udp_connection_info, Args, Ss) of
        {ok, 0} ->
            exec_statement(C, insert_udp_connection_info, Args, Ss);
        {ok, 1} ->
            ok
    end,
    {reply, ok, S};
handle_call({member, Tbl, Key}, _From, S=#state{connection=C, statements=Ss}) ->
    {Args, Stmt} = case Tbl of
                       torrent_info ->
                           {[Key], torrent_info_exists};
                       torrent_user ->
                           {IH, PeerId} = Key,
                           {[IH, PeerId], torrent_user_exists};
                       udp_connection_info ->
                           {[Key], udp_connection_info_exists}
                   end,
    {ok, Ret} = exec_statement(C, Stmt, Args, Ss),
    {reply, Ret, S};
handle_call({delete, _TI=#torrent_info{info_hash=InfoHash}},
            _From, S=#state{connection=C, statements=Ss}) ->
    {ok, Cnt} = exec_statement(C, delete_torrent_info, [InfoHash], Ss),
    {reply, Cnt, S};
handle_call({delete, _TU=#torrent_user{id={IH, PeerId}}},
            _From, S=#state{connection=C, statements=Ss}) ->
    {ok, Cnt} = exec_statement(C, delete_peer, [IH, PeerId], Ss),
    {reply, Cnt, S};
handle_call({fold, Table, Acc, Callback}, _From, State) ->
    Ret = fold_table(Table, Acc, Callback, State),
    {reply, Ret, State};
handle_call(_Request, _From, State) ->
    Reply = {error, invalid_request},
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _S=#state{connection=C}) ->
    ok = pgsql:close(C),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
setup(State=#state{connection=_C, statements=Ss}) ->
    RowToTorrentInfoF = fun ({InfoHash, Leechers, Seeders, Completed, Name, Mtime, Ctime}) ->
                                #torrent_info{
                                   info_hash=InfoHash,
                                   leechers=Leechers,
                                   seeders=Seeders,
                                   completed=Completed,
                                   name=Name,
                                   mtime=etracker_time:timestamp_to_now(Mtime),
                                   ctime=etracker_time:timestamp_to_now(Ctime)
                                  }
                        end,
    RowToTorrentUserF = fun ({InfoHash, PeerId, Address, Port,
                              Uploaded, Downloaded, Left, Event,
                              Finished, Mtime}) ->
                                #torrent_user{
                                   id={InfoHash,PeerId},
                                   peer={address_to_erl(Address), Port},
                                   uploaded=Uploaded,
                                   downloaded=Downloaded,
                                   left=Left,
                                   event=Event,
                                   finished=Finished,
                                   mtime=etracker_time:timestamp_to_now(Mtime)
                                  }
                        end,
    TorrentInfoF = fun ([Row], _Cnt) ->
                           RowToTorrentInfoF(Row);
                       ([], 0) ->
                           undefined
                   end,
    TorrentUsersF = fun (Rows, _Cnt) ->
                            [RowToTorrentUserF(Row) || Row <- Rows]
                    end,
    TorrentInfosF = fun (Rows, _Cnt) ->
                            [RowToTorrentInfoF(Row) || Row <- Rows]
                    end,
    CountF = fun ([{Cnt}], _Cnt) ->
                     Cnt
             end,
    TorrentPeersF = fun (Rows, _Cnt) ->
                            [{PeerId, {address_to_erl(Address), Port}}
                             || {PeerId, Address, Port} <- Rows]
                    end,
    MemberF = fun (_, 0) ->
                      false;
                  (_, _) ->
                       true
              end,
    Queries =
        [
         {torrent_info_exists,
          "select 1 from torrent_info where info_hash = $1",
          [bytea],
          MemberF
         },
         {torrent_user_exists,
          "select 1 from torrent_user where info_hash = $1 and peer_id = $2",
          [bytea, bytea],
          MemberF
         },
         {udp_connection_info_exists,
          "select 1 from udp_connection_info where id = $1",
          [bytea, bytea],
          MemberF
         },
         {torrent_info,
          "select info_hash, leechers, seeders, completed, name, mtime, ctime"
          " from torrent_info where info_hash = $1",
          [bytea],
          TorrentInfoF
         },
         {torrent_infos_all,
          "select info_hash, leechers, seeders, completed, name, mtime, ctime"
          " from torrent_info order by mtime desc limit $1",
          [int4],
          TorrentInfosF
         },
         {torrent_infos_from_mtime,
          "select info_hash, leechers, seeders, completed, name, mtime, ctime"
          " from torrent_info where mtime > $1 order by mtime desc"
          " offset $2 limit $3",
          [timestamp, int4, int4],
          TorrentInfosF
         },
         {torrent_peers_seeders_count,
          "select count(*) from torrent_user"
          " where info_hash = $1 and finished = true and event != 'stopped'",
          [bytea],
          CountF
         },
         {torrent_peers_leechers_count,
          "select count(*) from torrent_user"
          " where info_hash = $1 and finished = false and event != 'stopped'",
          [bytea],
          CountF
         },
         {torrent_peers_seeders,
          "select peer_id, address, port from torrent_user"
          " where info_hash = $1 and finished = true and event != 'stopped'"
          " offset $2 limit $3",
          [bytea, int4, int4],
          TorrentPeersF
         },
         {torrent_peers_leechers,
          "select peer_id, address, port from torrent_user"
          " where info_hash = $1 and finished = false and event != 'stopped'"
          " offset $2 limit $3",
          [bytea, int4, int4],
          TorrentPeersF
         },
         {update_torrent_peers_counters,
          "update torrent_info set seeders = $2, leechers = $3, mtime = now()"
          " where info_hash = $1",
          [bytea, int4, int4],
          fun (Cnt) -> Cnt end
         },
         {peers_all,
          "select info_hash, peer_id, address, port, uploaded, downloaded, left_bytes, event, finished, mtime"
          " from torrent_user order by mtime desc limit $1",
          [int4],
          TorrentUsersF
         },
         {delete_expired_peers,
          "delete from torrent_user where mtime < $1 or event = 'stopped'",
          [timestamp],
          fun (Cnt) -> Cnt end
         },
         {delete_expired_udp_connections,
          "delete from udp_connection_info where mtime < $1",
          [timestamp],
          fun (Cnt) -> Cnt end
         },
         {delete_peer,
          "delete from torrent_user where info_hash = $1 and peer_id = $2",
          [bytea, bytea],
          fun (Cnt) -> Cnt end
         },
         {update_peer,
          "update torrent_user set address = $3, port = $4, uploaded = $5,"
          " downloaded = $6, left_bytes = $7, event = $8, finished = $9,"
          " mtime = $10"
          " where info_hash = $1 and peer_id = $2",
          [bytea, bytea, int2array, int4, int4, int4, int4, varchar, bool, timestamp],
          fun (Cnt) -> Cnt end
         },
         {insert_peer,
          "insert into torrent_user(info_hash, peer_id, address, port, uploaded, downloaded, left_bytes, event, finished, mtime)"
          " values($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
          [bytea, bytea, int2array, int4, int4, int4, int4, varchar, bool, timestamp],
          fun (Cnt) -> Cnt end
         },
         {udp_connections_count_all,
          "select count(*) from udp_connection_info",
          [],
          CountF
         },
         {update_udp_connection_info,
          "update udp_connection_info set mtime = $2 where id = $1",
          [bytea, timestamp]
         },
         {insert_udp_connection_info,
          "insert into udp_connection_info(id, mtime) values($1, $2)",
          [bytea, timestamp]
         },
         {peers_count_all,
          "select count(*) from torrent_user",
          [],
          CountF
         },
         {peers_seeders_count_all,
          "select count(*) from torrent_user where finished = true",
          [],
          CountF
         },
         {peers_leechers_count_all,
          "select count(*) from torrent_user where finished = false",
          [],
          CountF
         },
         {delete_torrent_info,
          "delete from torrent_info"
          " where info_hash = $1",
          [bytea],
          fun (Cnt) -> Cnt end
         },
         {update_torrent_info_completed,
          "update torrent_info set completed = completed + $2, mtime = now()"
          " where info_hash = $1",
          [bytea, int4],
          fun (Cnt) -> Cnt end
         },
         {insert_torrent_info,
          "insert into torrent_info(info_hash, completed, seeders, leechers, mtime)"
          " values($1, $2, $3, $4, $5)",
          [bytea, int4, int4, int4, timestamp],
          fun (Cnt) -> Cnt end
         },
         {update_torrent_info,
          "update torrent_info set completed = $2, seeders = $3, leechers = $4, mtime = $5"
          " where info_hash = $1",
          [bytea, int4, int4, int4, timestamp],
          fun (Cnt) -> Cnt end
         },
         {torrent_info_count_all,
          "select count(*) from torrent_info",
          [],
          CountF
         },
         {torrent_info_seederless_count,
          "select count(*) from torrent_info"
          " where mtime > $1",
          [timestamp],
          CountF
         },
         {torrent_info_seederless_count,
          "select count(*) from torrent_info"
          " where mtime > $1 and seeders = 0 and leechers > 0",
          [timestamp],
          CountF
         },
         {torrent_info_peerless_count,
          "select count(*) from torrent_info"
          " where mtime > $1 and seeders = 0 and leechers = 0",
          [timestamp],
          CountF
         },
                                                % for tests
         {torrent_info_hashes_all,
          "select info_hash from torrent_info",
          [],
          fun (Rows) -> [IH || {IH} <- Rows] end
         }
        ],
    Ss1 = lists:foldl(fun ({Name, Query, Types, ResFun}, Statements) ->
                              orddict:store(Name, {Query, ResFun, Types}, Statements)
                      end, Ss, Queries),
    State#state{statements=Ss1}.

process_expire_udp_connections(ExpireTime,#state{connection=C, statements=Ss}) ->
    {ok, Cnt} = exec_statement(C, delete_expired_udp_connections,
                               [etracker_time:now_to_timestamp(ExpireTime)], Ss),
    Cnt.
process_expire_torrent_peers(ExpireTime,#state{connection=C, statements=Ss}) ->
    {ok, Cnt} = exec_statement(C, delete_expired_peers,
                               [etracker_time:now_to_timestamp(ExpireTime)], Ss),
    Cnt.

process_torrent_peers(InfoHash, Wanted, State=#state{connection=C, statements=Ss}) ->
    {ok, SeedersCnt} = exec_statement(C, torrent_peers_seeders_count, [InfoHash], Ss),
    {ok, LeechersCnt} = exec_statement(C, torrent_peers_leechers_count, [InfoHash], Ss),
    {ok, _} = exec_statement(C, update_torrent_peers_counters,
                             [InfoHash, SeedersCnt, LeechersCnt], Ss),
    Seeders = read_torrent_seeders(InfoHash, SeedersCnt, Wanted, State),
    Leechers = read_torrent_leechers(InfoHash, LeechersCnt, max(0, Wanted - length(Seeders)), State),
    {SeedersCnt, LeechersCnt, Seeders ++ Leechers}.

process_announce(_A=#announce{
                       event=Evt,
                       info_hash=InfoHash, peer_id=PeerId, ip=IP, port=Port,
                       uploaded=Upl, downloaded=Dld, left=Left
                      }, State) ->
    Finished = Left == 0,
    case Evt of
        <<"stopped">> ->
            %% delete_peer(InfoHash, PeerId, State);
            write_peer(InfoHash, PeerId, IP, Port, Upl, Dld, Left, Evt, Finished, State);
        _ ->
            write_peer(InfoHash, PeerId, IP, Port, Upl, Dld, Left, Evt, Finished, State),
            write_torrent_info(InfoHash, Evt == <<"completed">>, Finished, State)
    end,
    ok.

process_torrent_infos_all(Callback, Period, #state{connection=C, statements=Ss}) ->
    FromTime = case Period of
                   infinity ->
                       {0, 0, 0};
                   _ ->
                       etracker_time:now_sub_sec(now(), Period)
               end,
    FromTimestamp = etracker_time:now_to_timestamp(FromTime),
    process_torrent_infos_all1(C, Ss, Callback, FromTimestamp, 0).

process_torrent_infos_all1(Conn, Statements, Callback, FromTimestamp, Offset) ->
    case exec_statement(Conn, torrent_infos_from_mtime,
                        [FromTimestamp, Offset, ?TORRENT_INFO_LIMIT],
                        Statements) of
        {ok, []} ->
            ok;
        {ok, Rows} ->
            Callback(Rows),
            NxtOffset = Offset + length(Rows),
            process_torrent_infos_all1(Conn, Statements, Callback, FromTimestamp, NxtOffset)
    end.

write_torrent_info(InfoHash, Completed, Finished,
                   #state{connection=C, statements=Ss}) ->
    AddCompleted = if Completed == true -> 1;
                      true -> 0
                   end,
    case exec_statement(C, update_torrent_info_completed, [InfoHash, AddCompleted], Ss) of
        {ok, 0} ->
            {Seeders, Leechers} = case Finished of
                                      true ->
                                          {1, 0};
                                      _ ->
                                          {0, 1}
                                  end,
            MT = etracker_time:now_to_timestamp(now()),
            Args = [InfoHash, AddCompleted, Seeders, Leechers, MT],
            exec_statement(C, insert_torrent_info, Args, Ss),
            ok;
        {ok, 1} ->
            ok
	end.

read_torrent_info(InfoHash, #state{connection=C, statements=Ss}) ->
    case exec_statement(C, torrent_info, [InfoHash], Ss) of
        {ok, undefined} ->
            #torrent_info{};
        {ok, TI} ->
            TI
	end.

read_torrent_seeders(_IH, _A, 0, _S) ->
    [];
read_torrent_seeders(InfoHash, Available, Wanted, #state{connection=C, statements=Ss}) ->
    Offset = if Available =< Wanted ->
                     0;
                true ->
                     random:uniform(Available - Wanted)
             end,
    {ok, Seeders} = exec_statement(C, torrent_peers_seeders,
                                   [InfoHash, Offset, Wanted], Ss),
    Seeders.

read_torrent_leechers(_IH, _A, 0, _S) ->
    [];
read_torrent_leechers(InfoHash, Available, Wanted, #state{connection=C, statements=Ss}) ->
    Offset = if Available =< Wanted ->
                     0;
                true ->
                     random:uniform(Available - Wanted)
             end,
    {ok, Leechers} = exec_statement(C, torrent_peers_leechers,
                                    [InfoHash, Offset, Wanted], Ss),
    Leechers.

%%delete_peer(InfoHash, PeerId, #state{connection=C, statements=Ss}) ->
%%    exec_statement(C, delete_peer, [InfoHash, PeerId], Ss).

write_peer(InfoHash, PeerId, IP, Port, Upl, Dld, Left, Event, Finished,
           #state{connection=C, statements=Ss}) ->
    MT = etracker_time:now_to_timestamp(now()),
    Address = address_from_erl(IP),
    Args = [InfoHash, PeerId, Address, Port, Upl, Dld, Left, Event, Finished, MT],
    case exec_statement(C, update_peer, Args, Ss) of
        {ok, 1} ->
            ok;
        {ok, 0} ->
            exec_statement(C, insert_peer, Args, Ss),
            ok
    end.

fold_table(Table, Acc, Callback, #state{connection=C, statements=Ss}) ->
    QName = case Table of
                torrent_info ->
                    torrent_infos_all;
                torrent_user ->
                    peers_all
            end,
    fold_table(exec_parsed_statement(C, QName, [10000000000], Ss), Acc, Callback).

fold_table({ok, Rows}, Acc, Cb) ->
    lists:foldl(Cb, Acc, Rows);
fold_table({ok, Rows, Cont}, Acc, Cb) ->
    Acc1 = lists:foldl(Cb, Acc, Rows),
    fold_table(Cont(), Acc1, Cb).

exec_statement(Conn, Name, Params, Statements) ->
    {Query, ResFun, _T} = orddict:fetch(Name, Statements),
    Res = pgsql:equery(Conn, Query, Params),
    case Res of
        {ok, _Col, Rows} ->
            {ok, ResFun(Rows, length(Rows))};
        {ok, Cnt, _Cols, Rows} ->
            {ok, ResFun(Rows, Cnt)};
        {ok, Cnt} ->
            {ok, ResFun(Cnt)};
        {error, Error} ->
            {error, {Name, Error}}
	end.

exec_parsed_statement(Conn, Name, Params, Statements) ->
    exec_parsed_statement(Conn, Name, Params, 0, Statements).

exec_parsed_statement(Conn, Name, Params, MaxRows, Statements) ->
    {Query, ResFun, Types} = orddict:fetch(Name, Statements),
    SName = atom_to_list(Name),
    {ok, S} = pgsql:parse(Conn, SName, Query, Types),
    ok = pgsql:bind(Conn, S, Params),
    Ret = exec_parsed_statement_fetch(Conn, S, Name, MaxRows, ResFun),
    ok = pgsql:close(Conn, statement, SName),
    pgsql:sync(Conn),
    Ret.

exec_parsed_statement_fetch(Conn, Statement, Name, MaxRows, ResFun) ->
    Res = pgsql:execute(Conn, Statement, MaxRows),
    case Res of
        {ok, Cnt, Rows} ->
            {ok, ResFun(Rows, Cnt)};
        {ok, Rows} when is_list(Rows)->
            {ok, ResFun(Rows, length(Rows))};
        {ok, Cnt} ->
            {ok, ResFun(Cnt)};
        {partitial, Rows} ->
            ContF = fun () ->
                            exec_parsed_statement_fetch(Conn, Statement, Name, MaxRows, ResFun)
                    end,
			{ok, ResFun(Rows, length(Rows)), ContF};
        {error, Error} ->
            exit({error, {Name, Error}})
	end.

address_to_erl(Address) ->
    list_to_tuple(Address).

address_from_erl(Address) ->
    tuple_to_list(Address).
