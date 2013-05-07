-module(etracker_http_static).
-behaviour(cowboy_http_handler).

-export([init/3, handle/2, terminate/2]).

-export([html/2, css/2, js/2]).

-record(state, {application, www_dir, path}).

init({tcp, http}, Req, {Params, Path}) ->
    {ok, Req, #state{
                 application=proplists:get_value(application, Params),
                 www_dir=proplists:get_value(www_dir, Params),
                 path=Path
                }
    }.

handle(Req, S=#state{path=P}) when P == []
                                       orelse P == undefined ->
    {Path, Req2} = cowboy_http_req:path(Req),
    handle(Req2, S#state{path=Path});
handle(Req, S=#state{path=PathBins}) ->
    send(Req, [ binary_to_list(P) || P <- PathBins ], S).

send(Req, Path, State=#state{www_dir=WwwDir}) ->
    case file(filename:join(Path), WwwDir) of
        {ok, Body} ->
            Headers = [{<<"content-type">>, <<"text/html">>}],
            {ok, Req2} = cowboy_http_req:reply(200, Headers, Body, Req),
            {ok, Req2, State};
        _ ->
            etracker_event:unknown_query(Path),
            {ok, Req2} = cowboy_http_req:reply(404, [], <<"404'd">>, Req),
            {ok, Req2, State}
    end.

terminate(_Req, _State) ->
    ok.

html(Name, WwwDir) ->
    type("html", Name, WwwDir).
css(Name, WwwDir) ->
    type("css", Name, WwwDir).
js(Name, WwwDir) ->
    type("js", Name, WwwDir).

type(Type, Name, WwwDir) ->
    file(filename:join([Type, Name ++ Type]), WwwDir).

file(Path, WwwDir) ->
    file:read_file(filename:join(WwwDir, Path)).
