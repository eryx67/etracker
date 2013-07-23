-module(etracker_types).

-export_type([infohash/0,
              peerid/0,
              peerinfo/0,
              ipaddr/0,
              portnum/0,
              trackerid/0,
              timestamp/0,
              filepath/0,
              filename/0,
              bcode/0,
              event/0
             ]).

-type bcode() ::
    integer() | binary() | [bcode(),...] | [{binary(), bcode()},...] | {}.
-type infohash() :: <<_:20>>.
-type peerid() :: <<_:20>>.
-type ipaddr() :: {byte(), byte(), byte(), byte()}.
-type portnum() :: 1..16#FFFF.
-type peerinfo() :: {ipaddr(), portnum()}.
-type trackerid() :: {infohash(), peerinfo()}.
-type timestamp() :: {integer(), integer(), integer()}.
-type filepath() :: string().
-type filename() :: string().
-type event() :: binary() | undefined.
