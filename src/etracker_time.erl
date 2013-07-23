%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created : 23 Jul 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_time).

-export([now_sub_sec/2, now_to_timestamp/1, timestamp_to_now/1]).

now_to_timestamp(Time) ->
    calendar:now_to_local_time(Time).

timestamp_to_now({D, {HH, MM, SSMS}}) ->
    SS = erlang:trunc(SSMS),
    Seconds = calendar:datetime_to_gregorian_seconds({D, {HH, MM, SS}}) - 62167219200,
    %% 62167219200 == calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    {Seconds div 1000000, Seconds rem 1000000, erlang:trunc((SSMS - SS) * 1000000)}.

now_sub_sec(Now, Seconds) ->
    {Mega, Sec, Micro} = Now,
    SubMega = Seconds div 1000000,
    SubSec = Seconds rem 1000000,
    Mega1 = Mega - SubMega,
    Sec1 = Sec - SubSec,
    {Mega2, Sec2} = if Mega1 < 0 ->
                            exit(badarg);
                       (Sec1 < 0) ->
                            {Mega1 - 1, 1000000 + Sec1};
                       true ->
                            {Mega1, Sec1}
                    end,
    if (Mega2 < 0) ->
            exit(badarg);
       true ->
            {Mega2, Sec2, Micro}
    end.
