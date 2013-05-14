%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 10 Apr 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_env).

-export([get/1, get/2, set/2]).

-define(APP, etracker).

get(Key) ->
    case gproc:get_env(l, ?APP, Key, [app_env, {default, '_undefined_'}]) of
        '_undefined_' ->
            undefined;
        Val ->
            {ok, Val}
    end.

get(Key, Default) ->
    gproc:get_set_env(l, ?APP, Key, [app_env, {default, Default}]).

set(Key, Value) ->
    gproc:set_env(l, ?APP, Key, Value, [app_env]).
