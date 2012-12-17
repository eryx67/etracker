-define(ANNOUNCE_ANSWER_INTERVAL, 60 * 30).
-define(ANNOUNCE_ANSWER_MAX_PEERS, 50).

-record(announce, {
          info_hash, %% urlencoded 20-byte SHA1 hash of the value of the info key from the Metainfo file
          peer_id, %% urlencoded 20-byte string used as a unique ID for the client
          port, %% The port number that the client is listening on.
          uploaded, %% The total amount uploaded in base ten ASCII.
          downloaded, %%: The total amount downloaded in base ten ASCII.
          left, %% The number of bytes this client still has to download in base ten ASCII.
          compact = false, %% Setting this to 1 indicates that the client accepts a compact response.
          no_peer_id = false, %% Indicates that the tracker can omit peer id field in peers dictionary.
          event,  %% <<"started">> | <<"completed">>| <<"stopped">> | undefined
          ip, %% Optional. The true IP address of the client machine
          numwant = 50, %% Optional. Number of peers that the client would like to receive.
          key, %% Optional. An additional client identification mechanism that is not shared with any peers. It is intended to allow a client to prove their identity should their IP address change.
          trackerid %% Optional. If a previous announce contained a tracker id, it should be set here.
         }).

-record(scrape, {
          files = []
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
          info_hash,
          event,
          downloaded = 0,
          uploaded = 0,
          left = 0,
          finished = false, % client sent <<completed>> or connected as seeder
          mtime = erlang:now()
         }).
