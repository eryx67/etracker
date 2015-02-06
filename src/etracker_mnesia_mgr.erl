%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2015, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 5 Feb 2015 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_mnesia_mgr).

-behaviour(gen_server).

%% API
-export([start_link/1]).
                                                % internal exports
-export([dump_tables/0, frag_key/2, table_name/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("etracker.hrl").

-define(SERVER, ?MODULE).
-define(DUMP_INTERVAL, 3600). % sec

-record(state, {
          dump_interval=?DUMP_INTERVAL,
          dumper_pid,
          tref
         }).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, [{timeout, infinity}]).


table_name(torrent_user) -> torrent_user_mz;
table_name(torrent_info) -> torrent_info_mz;
table_name(torrent_leecher) -> torrent_leecher_mz;
table_name(torrent_seeder) -> torrent_seeder_mz;
table_name(udp_connection_info) -> udp_connection_info_mz.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    ok = setup(Opts),
    DumpIval = proplists:get_value(dump_interval, Opts, ?DUMP_INTERVAL) * 1000,
    random:seed(erlang:now()),
    process_flag(trap_exit, true),
    process_flag(priority, high),
    Self = self(),
    TRef = erlang:send_after(DumpIval, Self, dump_tables),
    {ok, #state{dump_interval=DumpIval,
                tref=TRef
               }}.

handle_call(_Msg, _F, State) ->
    {reply, {error, invalid_message}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(dump_tables, S=#state{dumper_pid=undefined}) ->
    lager:info("table dumper started", []),
    DumperPid = spawn_link(fun () -> dump_tables() end),
    {noreply, S#state{dumper_pid=DumperPid}};
handle_info({'EXIT', Pid, _Reason}, S=#state{dumper_pid=Pid, dump_interval=DumpIval}) ->
    lager:info("table dumper finished", []),
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

dump_tables() ->
    TNs1 = lists:flatten([TNs || TNs <- [mnesia:activity(transaction,
                                                         fun mnesia:table_info/2, [TN, frag_names],
                                                         mnesia_frag)
                                         || TN <- table_names()]
                         ]),
    TNs2 = [TN || TN <- TNs1, mnesia:table_info(TN, ram_copies) =/= []],
    mnesia:dump_tables(TNs2).

setup(Opts) ->
    setup([node()], Opts).

setup(Nodes, Opts) ->
    SelfNode = node(),
    IsOwnTableF = fun (T) ->
                          lists:any(fun (A) ->
                                            lists:member(SelfNode, mnesia:table_info(T, A))
                                    end, [disc_only_copies, disc_copies])
                  end,
    Master = master_node(Opts),
    case Master of
        SelfNode ->
            create_schema(Nodes);
        _ ->
            join_schema(Master)
    end,
    TableNames = all_table_names(true),
    OwnTables = [T || T <- TableNames, IsOwnTableF(T)],
    OtherTables = TableNames -- OwnTables,
    mnesia:wait_for_tables(OwnTables, infinity),
    mnesia:wait_for_tables(OtherTables, infinity),
    ok.

create_schema(Nodes) ->
    mnesia:create_schema(Nodes),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    mnesia:start(),
    ExistingTables = mnesia:system_info(tables),
    Tables = table_names() -- ExistingTables,
    create_tables(Nodes, Tables),
    ok.

join_schema(Master) ->
    SelfNode = node(),
    pong = net_adm:ping(Master),
    MustCreateSchema = case mnesia:create_schema([SelfNode]) of
                           {error, _} ->
                               false;
                           ok ->
                               true
                       end,
    if MustCreateSchema ->
            mnesia:stop(),
            ok = mnesia:delete_schema([SelfNode]),
            ok = mnesia:start(),
            rpc:call(Master, mnesia, add_table_copy, [schema, SelfNode, ram_copies]),
            {ok, _NodeList} = rpc:call(Master, mnesia, change_config, [extra_db_nodes, [SelfNode]]),
            mnesia:change_table_copy_type(schema, SelfNode, disc_copies),
            Tables = rpc:call(Master, ?MODULE, all_table_names, []),
            [begin
                 mnesia:add_table_copy(TN, SelfNode, ram_copies),
                 mnesia:set_master_nodes(TN, [Master])
             end || TN <- Tables];
       true ->
            ok
    end.

create_tables(Nodes, TableNames) ->
    TableSpecs = [T || T={N, _} <- tables(Nodes), lists:member(N, TableNames)],
    [create_table(N, Spec) || {N, Spec} <- TableSpecs].

create_table(Name, Spec) ->
    {atomic, ok} = mnesia:create_table(Name, Spec).

table_names() ->
    [N || {N, _} <- tables([])].

all_table_names(WithFrag) ->
    PredF = fun (_TNs) when WithFrag == true ->
                    true;
                (TNs) ->
                    length(TNs) == 1
            end,
    lists:flatten([TNs || TNs <- [mnesia:activity(transaction,
                                                  fun mnesia:table_info/2, [TN, frag_names],
                                                  mnesia_frag) || TN <- table_names()],
                          PredF(TNs)
                  ]).

tables(Nodes) ->
    [{table_name(torrent_info), [
                                 {type, ordered_set},
                                 {attributes, record_info(fields, torrent_info)},
                                 {record_name, torrent_info},
                                 {storage_properties, [{ets, [{write_concurrency, true},
                                                              {read_concurrency, true}]}
                                                      ]},
                                 {frag_properties, [{node_pool, Nodes},
                                                    {n_fragments, 128},
                                                    {n_ram_copies, 1},
                                                    {hash_module, etracker_db_frag_hash}
                                                   ]}
                                ]}
    , {table_name(torrent_user), [
                                  {type, ordered_set},
                                  {attributes, record_info(fields, torrent_user)},
                                  {record_name, torrent_user},
                                  {storage_properties, [{ets, [{write_concurrency, true},
                                                               {read_concurrency, true}]}
                                                       ]},
                                  {frag_properties, [{node_pool, Nodes},
                                                     {n_fragments, 128},
                                                     {n_ram_copies, 1},
                                                     {hash_module, etracker_db_frag_hash}
                                                    ]}
                                 ]}
    , {table_name(udp_connection_info), [
                                         {type, set},
                                         {local_content, true},
                                         {attributes, record_info(fields, udp_connection_info)},
                                         {record_name, udp_connection_info},
                                         {storage_properties, [{ets, [{read_concurrency, true}]}
                                                              ]}
                                        ]}
    , {table_name(torrent_seeder), [
                                    {type, ordered_set},
                                    {attributes, record_info(fields, torrent_peer)},
                                    {record_name, torrent_peer},
                                    {storage_properties, [{ets, [{read_concurrency, true}]}
                                                         ]},
                                    {frag_properties, [{node_pool, Nodes},
                                                       {n_fragments, 128},
                                                       {n_ram_copies, 1},
                                                       {hash_module, etracker_db_frag_hash}
                                                      ]}
                                   ]}
    , {table_name(torrent_leecher), [
                                     {type, ordered_set},
                                     {attributes, record_info(fields, torrent_peer)},
                                     {record_name, torrent_peer},
                                     {storage_properties, [{ets, [{read_concurrency, true}]}
                                                          ]},
                                     {frag_properties, [{node_pool, Nodes},
                                                        {n_fragments, 128},
                                                        {n_ram_copies, 1},
                                                        {hash_module, etracker_db_frag_hash}
                                                       ]}
                                    ]}

    ].

master_node(Opts) ->
    SelfNode = node(),
    Master = proplists:get_value(master_node, Opts, node()),
    if Master == true ->
            SelfNode;
       true ->
            Master
    end.

frag_key(torrent_user_mz, {IH, _}) ->
    IH;
frag_key(torrent_seeder_mz, {IH, _}) ->
    IH;
frag_key(torrent_leecher_mz, {IH, _}) ->
    IH;
frag_key(_, Key) ->
    Key.
