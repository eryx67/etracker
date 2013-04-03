%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2012, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 14 Nov 2012 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------
-module(etracker_db).

%% API
-export([start_link/0]).
-export([system_info/0, system_info/1, system_info_update_counter/2]).
-export([announce/1, torrent_info/1, torrent_infos/1, torrent_peers/2, torrent_peers/3]).
-export([expire_torrent_peers/1]).

-define(SERVER, ?MODULE).
-define(INFO_TBL, etracker_info).

-define(INFO_DB_KEYS, [torrents,
                       seeders,
                       leechers,
                       peers
                      ]).

-define(INFO_COUNTERS, [announces,
                        scrapes,
                        invalid_queries,
                        failed_queries,
                        unknown_queries,
                        deleted_peers
                       ]).

-define(INFO_KEYS, (?INFO_COUNTERS ++ ?INFO_DB_KEYS)).

start_link() ->
    ets:new(?INFO_TBL, [named_table, set, public, {write_concurrency, true}]),
    ets:insert(?INFO_TBL, [{K, 0} || K <- ?INFO_COUNTERS]),
    {Module, Opts} = case confval(db_module, etracker_mnesia) of
                         ModOpts = {_M, _Os} -> ModOpts;
                         Mod when is_atom(Mod) ->
                             {Mod, []}
                     end,
    Module:start_link({local, ?SERVER}, Opts).

announce(Ann) ->
	gen_server:cast(?SERVER, {announce, Ann}).

torrent_peers(InfoHash, Num) ->
    torrent_peers(InfoHash, Num, []).
torrent_peers(InfoHash, Num, Exclude) ->
	gen_server:call(?SERVER, {torrent_peers, InfoHash, Num, Exclude}).

expire_torrent_peers(ExpireTime) ->
    gen_server:call(?SERVER, {expire_torrent_peers, ExpireTime}).

torrent_info(InfoHash) when is_binary(InfoHash) ->
	gen_server:call(?SERVER, {torrent_info, InfoHash}).

torrent_infos(InfoHashes) when is_list(InfoHashes) ->
	gen_server:call(?SERVER, {torrent_infos, InfoHashes, self()}).

system_info() ->
    [{K, system_info(K)} || K <- ?INFO_DB_KEYS] ++ ets:tab2list(?INFO_TBL).

system_info(info_keys) -> ?INFO_KEYS;
system_info(Key) when Key == torrents
                      orelse Key == seeders
                      orelse Key == leechers
                      orelse Key == peers ->
    gen_server:call(?SERVER, {system_info, Key});
system_info(Key) when Key == announces
                      orelse Key == scrapes
                      orelse Key == unknown_queries
                      orelse Key == failed_queries
                      orelse Key == invalid_queries
                      orelse Key == deleted_peers ->
    case ets:lookup(?INFO_TBL, Key) of
        [{_, Val}] ->
            Val;
        _ ->
            0
    end;
system_info(Key) ->
    error({invalid_key, Key}).

system_info_update_counter(Key, Inc) when Key == announces
                                          orelse Key == scrapes
                                          orelse Key == unknown_queries
                                          orelse Key == failed_queries
                                          orelse Key == invalid_queries
                                          orelse Key == deleted_peers ->
    ets:update_counter(?INFO_TBL, Key, Inc).

confval(Key, Default) ->
    case application:get_env(Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.
