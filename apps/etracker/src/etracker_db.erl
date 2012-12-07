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
-export([announce/1, torrent_info/1, torrent_infos/1, torrent_peers/2, torrent_peers/3]).

-define(SERVER, ?MODULE).

start_link() ->
    Module = confval(db_module, etracker_mnesia),
    gen_server:start_link({local, ?SERVER}, Module, [], []).

announce(Ann) ->
	gen_server:cast(?SERVER, {announce, Ann}).

torrent_peers(InfoHash, Num) ->
    torrent_peers(InfoHash, Num, []).
torrent_peers(InfoHash, Num, Exclude) ->
	gen_server:call(?SERVER, {torrent_peers, InfoHash, Num, Exclude}).

torrent_info(InfoHash) when is_binary(InfoHash) ->
	gen_server:call(?SERVER, {torrent_info, InfoHash}).

torrent_infos(InfoHashes) when is_list(InfoHashes) ->
	gen_server:call(?SERVER, {torrent_infos, InfoHashes, self()}).

confval(Key, Default) ->
    case application:get_env(Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.
