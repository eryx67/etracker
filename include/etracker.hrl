%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 26 Apr 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-define(ANNOUNCE_ANSWER_INTERVAL, 60 * 30).
-define(ANNOUNCE_ANSWER_MAX_PEERS, 50).
-define(INFOHASH_MAX, << 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                         16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                         16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                         16#ff, 16#ff, 16#ff, 16#ff, 16#ff >>).
-define(INFOHASH_MIN, << 16#00, 16#00, 16#00, 16#00, 16#00,
                         16#00, 16#00, 16#00, 16#00, 16#00,
                         16#00, 16#00, 16#00, 16#00, 16#00,
                         16#00, 16#00, 16#00, 16#00, 16#00 >>).

-define(INFOHASH_LENGTH, 20).

-define(UDP_ACTION_CONNECT,  << 0:32 >>).
-define(UDP_ACTION_ANNOUNCE, << 1:32 >>).
-define(UDP_ACTION_SCRAPE,   << 2:32 >>).
-define(UDP_ACTION_ERROR,    << 3:32 >>).

-define(UDP_EVENT_NONE,      << 0:32 >>).
-define(UDP_EVENT_COMPLETED, << 1:32 >>).
-define(UDP_EVENT_STARTED,   << 2:32 >>).
-define(UDP_EVENT_STOPPED,   << 3:32 >>).

-define(UDP_CONNECTION_ID, << 16#41727101980:64 >>).
-define(UDP_SCRAPE_MAX_TORRENTS, 74).

-record(announce, {
          info_hash :: etracker:infohash(), %% urlencoded 20-byte SHA1 hash of the value of the info key from the Metainfo file
          peer_id :: etracker:peerid(), %% urlencoded 20-byte string used as a unique ID for the client
          port :: etracker:portnum(), %% The port number that the client is listening on.
          uploaded :: integer(), %% The total amount uploaded in base ten ASCII.
          downloaded :: integer(), %%: The total amount downloaded in base ten ASCII.
          left, %% The number of bytes this client still has to download in base ten ASCII.
          compact = false :: boolean(), %% Setting this to 1 indicates that the client accepts a compact response.
          no_peer_id = false :: boolean(), %% Indicates that the tracker can omit peer id field in peers dictionary.
          event :: etracker:event(),  %% <<"started">> | <<"completed">>| <<"stopped">> | undefined
          ip :: etracker:ipaddr(), %% Optional. The true IP address of the client machine
          numwant = 50 :: integer(), %% Optional. Number of peers that the client would like to receive.
          key :: binary(), %% Optional. An additional client identification mechanism that is not shared with any peers. It is intended to allow a client to prove their identity should their IP address change.
          trackerid :: binary(), %% Optional. If a previous announce contained a tracker id, it should be set here.
          protocol = http :: 'http' | 'udp'

         }).

-record(scrape, {
          info_hashes = [],
          protocol = http
         }).

%% Database schema
-record(torrent_info, {
          info_hash,
          leechers = 0,
          seeders = 0,
          completed = 0,
          name,
          mtime = erlang:now(),
          ctime = erlang:now()
         }).

-record(torrent_user, {
          id = {undefined, undefined},   % {info_hash, peer_id}
          peer = {undefined, undefined}, % {address, port}
          event,
          downloaded = 0,
          uploaded = 0,
          left = 0,
          finished = false, % client sent <<completed>> or connected as seeder
          mtime = erlang:now()
         }).

-record(torrent_peer, {
          id = {undefined, undefined},   % {info_hash, peer_id}
          peer = {undefined, undefined}  % {address, port}
         }).

-record(udp_connection_info, {
          id,
          mtime = erlang:now()
         }).
