%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 24 Apr 2013 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_ets_mgr).

-behaviour(gen_server).

%% API
-export([start_link/1]).
                                                % internal exports
-export([dump_tables/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(DUMP_INTERVAL, 3600). % sec
-define(TABLES, [torrent_info, torrent_user, torrent_leecher, torrent_seeder]).
-define(PERSISTENT_TABLES, [torrent_info, torrent_user]).

-record(state, {
          store=dict:new(),
          dump_interval=?DUMP_INTERVAL,
          dumper_pid,
          tref,
          db_type=dict
         }).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, [{timeout, infinity}]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    {ok, Store} = setup(Opts),
    DumpIval = proplists:get_value(dump_interval, Opts, ?DUMP_INTERVAL) * 1000,
    DbType = proplists:get_value(db_type, Opts, dict),
    random:seed(erlang:now()),
    process_flag(trap_exit, true),
    Self = self(),
    TRef = erlang:send_after(DumpIval, Self, dump_tables),
    {ok, #state{dump_interval=DumpIval,
                tref=TRef,
                store=Store,
                db_type=DbType
               }}.

handle_call({peers, InfoHash, Wanted}, _From, S=#state{store=Store}) ->
    Reply = process_torrent_peers(InfoHash, Wanted, Store),
    {reply, Reply, S};
handle_call({add_peer, InfoHash, PeerId, Peer, Finished}, _F,
            S=#state{store=Store, db_type=dict}) ->
    NxtStore = add_peer(InfoHash, PeerId, Peer, Finished, Store),
    {reply, ok, S#state{store=NxtStore}};
handle_call({delete_peer, InfoHash, PeerId}, _F,
            S=#state{store=Store, db_type=dict}) ->
    NxtStore = delete_peer(InfoHash, PeerId, Store),
    {reply, ok, S#state{store=NxtStore}};
handle_call({count, What}, _F,
            S=#state{store=Store, db_type=dict}) ->
    Reply = count(What, Store),
    {reply, Reply, S};
handle_call(db_type, _F, S=#state{db_type=DT}) ->
    Reply = DT,
    {reply, Reply, S};
handle_call(_Msg, _F, State) ->
    {reply, {error, invalid_message}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(dump_tables, S=#state{dumper_pid=undefined}) ->
    lager:info("~p table dumper started", [?MODULE]),
    DumperPid = spawn_link(fun () -> dump_tables() end),
    {noreply, S#state{dumper_pid=DumperPid}};
handle_info({'EXIT', Pid, _Reason}, S=#state{dumper_pid=Pid, dump_interval=DumpIval}) ->
    lager:info("~p table dumper finished", [?MODULE]),
    Self = self(),
    TRef = erlang:send_after(DumpIval, Self, dump_tables),
    {noreply, S#state{dumper_pid=undefined, tref=TRef}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _S=#state{tref=TRef,dumper_pid=DP}) ->
    erlang:cancel_timer(TRef),
    if DP /= undefined ->
            receive
                {'EXIT', DP, _R} ->
                    ok
            end;
       true ->
            dump_tables()
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
count(What, Store) ->
    dict:fold(fun (_K, {S, L}, Acc) ->
                      case What of
                          seeders ->
                              Acc + gb_trees:size(S);
                          leechers ->
                              Acc + gb_trees:size(L)
                      end
              end, 0, Store).

add_peer(InfoHash, PeerId, Peer, Finished, Dict) ->
    UpdF = fun ({S, L}) ->
                   if Finished == true ->
                           {gb_trees:enter(PeerId, Peer, S),
                            gb_trees:delete_any(PeerId, L)
                           };
                      true ->
                           {gb_trees:delete_any(PeerId, S),
                            gb_trees:enter(PeerId, Peer, L)
                           }
                   end
           end,
    try
        dict:update(InfoHash, UpdF, Dict)
    catch
        error:badarg ->
            L = gb_trees:empty(),
            S = gb_trees:empty(),
            SL = if Finished == true ->
                         {gb_trees:enter(PeerId, Peer, S), L};
                    true ->
                         {S, gb_trees:enter(PeerId, Peer, L)}
                 end,
            dict:store(InfoHash, SL, Dict)
    end.

delete_peer(InfoHash, PeerId, Dict) ->
    UpdF = fun ({S, L}) ->
                   {gb_trees:delete_any(PeerId, S),
                    gb_trees:delete_any(PeerId, L)
                   }
           end,
    L = gb_trees:empty(),
    S = gb_trees:empty(),
    dict:update(InfoHash, UpdF, {S, L}, Dict).

process_torrent_peers(InfoHash, Wanted, Store) ->
    case dict:find(InfoHash, Store) of
        {ok, {S, L}} ->
            process_peers(Wanted, S, L);
        _ ->
            {0, 0, []}
    end.

process_peers(Wanted, Seeders, Leechers) ->
    S = process_peers_fetch(Wanted, Seeders),
    L = process_peers_fetch(max(0, Wanted - length(S)), Leechers),
    {gb_trees:size(Seeders), gb_trees:size(Leechers), S ++ L}.

process_peers_fetch(0, _Store) ->
    [];
process_peers_fetch(Wanted, Store) ->
    Size = gb_trees:size(Store),
    if Size =< Wanted ->
            gb_trees:to_list(Store);
       true ->
            Offset = random:uniform(Size - Wanted) - 1,
            Iter = gb_trees:iterator(Store),
            process_peers_fetch(Offset, Wanted, Iter, [])
    end.

process_peers_fetch(0, 0, _Iter, Acc) ->
    Acc;
process_peers_fetch(0, Wanted, Iter, Acc) ->
    case gb_trees:next(Iter) of
        {Key, Val, NxtIter} ->
            process_peers_fetch(0, Wanted - 1, NxtIter, [{Key, Val}|Acc]);
        none ->
            Acc
    end;
process_peers_fetch(Offset, Wanted, Iter, Acc) ->
    case gb_trees:next(Iter) of
        {_Key, _Val, NxtIter} ->
            process_peers_fetch(Offset - 1, Wanted, NxtIter, Acc);
        none ->
            Acc
    end.

setup(Opts) ->
    DbType = proplists:get_value(db_type, Opts, dict),
    {ok, Cwd} = file:get_cwd(),
    DataDir = filename:absname(proplists:get_value(dir, Opts, "etracker_data"),
                               Cwd),
    Tables = ?TABLES,
    open_tables(Tables, DataDir),
    {ok, fill_data(DbType)}.

fill_data(dict) ->
    ets:foldl(fun (#torrent_user{id={IH, PeerId}, peer=Peer, finished=F}, D) ->
                      add_peer(IH, PeerId, Peer, F, D)
              end, dict:new(), torrent_user);
fill_data(ets) ->
    ets:foldl(fun (#torrent_user{id=Id, peer=Peer, finished=F}, Acc) ->
                      Tbl = case F of
                                true ->
                                    torrent_seeder;
                                _ ->
                                    torrent_leecher
                            end,
                      TP = #torrent_peer{id = Id, peer=Peer},
                      ets:insert(Tbl, TP),
                      Acc
              end, [], torrent_user).

open_tables(Tables, DataDir) ->
    lists:foreach(fun (Tbl) ->
                          open_table(Tbl, DataDir)
                  end, Tables).

dump_tables() ->
    lists:foreach(fun (TN) ->
                          save_table(TN)
                  end, ?PERSISTENT_TABLES).

open_table(TN=torrent_info, DataDir) ->
    Type = ordered_set,
    TblOpts = [{keypos, #torrent_info.info_hash}],
    EtsOpts = [Type|TblOpts] ++ [public, named_table,
                                 {write_concurrency, true}, {read_concurrency, true}
                                ],
    ets:new(TN, EtsOpts),
    ok = open_dets(TN, [{type, set}|TblOpts], DataDir),
    true = ets:from_dets(TN, TN);
open_table(TN=torrent_user, DataDir) ->
    Type = ordered_set,
    TblOpts = [{keypos, #torrent_user.id}],
    EtsOpts = [Type|TblOpts] ++ [public, named_table,
                                 {write_concurrency, true}, {read_concurrency, true}
                                ],
    ets:new(TN, EtsOpts),
    ok = open_dets(TN, [{type, set}|TblOpts], DataDir),
    true = ets:from_dets(TN, TN);
open_table(TN, _DataDir) when TN == torrent_seeder
                              orelse TN == torrent_leecher ->
    TblOpts = [ordered_set, {keypos, #torrent_peer.id}],
    EtsOpts = TblOpts ++ [public, named_table,
                          {read_concurrency, true}
                         ],
    ets:new(TN, EtsOpts).

save_table(TN) ->
    ets:to_dets(TN, TN).

open_dets(TableName, Opts, DataDir) ->
    FileName = dets_file_name(TableName, DataDir),
    ok = filelib:ensure_dir(FileName),
    {ok, _} = dets:open_file(TableName, [{file, FileName} | Opts]),
    ok.

dets_file_name(TableName, DataDir) ->
    filename:absname(atom_to_list(TableName) ++ ".dets", DataDir).
