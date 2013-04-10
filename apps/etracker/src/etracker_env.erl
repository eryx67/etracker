%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 10 Apr 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_env).

-export([get/2, set/2]).

-define(APP, etracker).

get(Key, Default) ->
    case application:get_env(?APP, Key) of
        {ok, Value} -> Value;
        undefined -> Default
    end.

set(Key, Value) ->
    application:set_env(?APP, Key, Value).
