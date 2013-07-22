%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @author Vladimir Sekissov<eryx67@gmail.com>
%% @doc Encode/Decode bcoded data.

-module(etracker_bcoding).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-author("Vladimir Sekissov<eryx67@gmail.com>").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
% Encoding and parsing
-export([encode/1, decode/1, decode_extra/1, parse_file/1]).

% Retrieval
-export([get_value/2, get_value/3, get_info_value/2, get_info_value/3,
         get_binary_value/2, get_binary_value/3,
         get_string_value/2, get_string_value/3]).

-type bcode() :: etracker_types:bcode().

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a bcode structure to an iolist()
%%  two special-cases empty_list and empty_dict designates the difference
%%  between an empty list and dict for a client for which it matter. We don't
%%  care and take both to be []
%% @end
-spec encode(etracker_types:bcode()) -> iolist().
encode(N) when is_integer(N) -> ["i", integer_to_list(N), "e"];
encode(B) when is_binary(B) -> [integer_to_list(byte_size(B)), ":", B];
encode({}) -> "de";
encode([{B,_}|_] = D) when is_binary(B) ->
    SortedD = lists:keysort(1, D),
    ["d", [[encode(K), encode(V)] || {K,V} <- SortedD], "e"];
encode([]) -> "le";
encode(L) when is_list(L) -> ["l", [encode(I) || I <- L], "e"].

%% @doc Decode a string or binary to a bcode() structure
%% @end
-spec decode(string() | binary()) -> {ok, bcode()} | {error, _Reason}.
decode(Bin) ->
    case decode_extra(Bin) of
        Error={error, _} ->
            Error;
        {Res, _} ->
            {ok, Res}
    end.
%% @doc Decode a string or binary to a bcode() structure and
%% undecoded rest bytes.
%% This bytes are usually attached to messages in protocols extensions.
%% @end
-spec decode_extra(string() | binary()) -> {bcode(), bcode()} | {error, _Reason}.
decode_extra(String) when is_list(String) -> decode_extra(list_to_binary(String));
decode_extra(Bin) when is_binary(Bin) ->
    try
        decode_b(Bin)
    catch
        error:Reason -> {error, Reason}
    end.

%% @doc Get a value from the dictionary
%% @end
get_value(_Key, {}) ->
    undefined;
get_value(Key, PL) when is_list(Key) ->
    get_value(list_to_binary(Key), PL);
get_value(Key, PL) when is_binary(Key) ->
    proplists:get_value(Key, PL).

%% @doc Get a value from the dictionary returning Default on error
%% @end
get_value(_Key, {}, Default) ->
    Default;
get_value(Key, PL, Default) when is_list(Key) ->
    get_value(list_to_binary(Key), PL, Default);
get_value(Key, PL, Default) when is_binary(Key) ->
    proplists:get_value(Key, PL, Default).


%% @doc Get a value from the "info" part of the dictionary
%% @end
get_info_value(_Key, {}) ->
    undefined;
get_info_value(Key, PL) when is_list(Key) ->
    get_info_value(list_to_binary(Key), PL);
get_info_value(Key, PL) when is_binary(Key) ->
    PL2 = proplists:get_value(<<"info">>, PL),
    proplists:get_value(Key, PL2).

%% @doc Get a value from the "info" part, with a Default
%%   the 'info' dictionary is expected to be present.
%% @end
get_info_value(_Key, {}, Def) ->
    Def;
get_info_value(Key, PL, Def) when is_list(Key) ->
    get_info_value(list_to_binary(Key), PL, Def);
get_info_value(Key, PL, Def) when is_binary(Key) ->
    PL2 = proplists:get_value(<<"info">>, PL),
    proplists:get_value(Key, PL2, Def).

%% @doc Read a binary Value indexed by Key from the PL dict
%% @end
get_binary_value(Key, PL) ->
    V = get_value(Key, PL),
    true = is_binary(V),
    V.

%% @doc Read a binary Value indexed by Key from the PL dict with default.
%%   <p>Will return Default upon non-existence</p>
%% @end
get_binary_value(_Key, {}, Default) ->
    Default;
get_binary_value(Key, PL, Default) ->
    case get_value(Key, PL) of
        undefined -> Default;
        B when is_binary(B) -> B
    end.

%% @doc Read a string Value indexed by Key from the PL dict
%% @end
get_string_value(Key, PL) -> binary_to_list(get_binary_value(Key, PL)).

%% @doc Read a binary Value indexed by Key from the PL dict with default.
%%   <p>Will return Default upon non-existence</p>
%% @end
get_string_value(_Key, {}, Default) ->
    Default;
get_string_value(Key, PL, Default) ->
    case get_value(Key, PL) of
        undefined -> Default;
        V when is_binary(V) -> binary_to_list(V)
    end.

%% @doc Parse a file into a Torrent structure.
%% @end
-spec parse_file(string()) -> {ok, bcode()} | {error, _Reason}.
parse_file(File) ->
    {ok, Bin} = file:read_file(File),
    decode(Bin).

%%====================================================================
decode_b(<<>>) ->
    {<<>>, <<>>};
decode_b(Bin = << H, Rest/binary >>) ->
    case H of
        $i ->
            decode_integer(Rest);
        $l ->
            decode_list(Rest);
        $d ->
            decode_dict(Rest);
        $e ->
            {end_of_data, Rest};
        _ ->
            %% This might fail, and so what ;)
            attempt_string_decode(Bin)
    end.

attempt_string_decode(<<$:, Rest/binary>>) ->
    attempt_string_decode(Rest);
attempt_string_decode(Bin) ->
    [BinNumber, Data] = binary:split(Bin, <<$:>>),
    {ok, Number} = string_to_int(binary_to_list(BinNumber)),
    << BinData:Number/binary, Rest/binary >> = Data,
    {BinData, Rest}.

decode_integer(Bin) ->
    [IntegerPart, RestPart] = binary:split(Bin, <<$e>>),
    {ok, Int} = string_to_int(binary_to_list(IntegerPart)),
    {Int, RestPart}.

decode_list(Bin) ->
    {ItemTree, Rest} = decode_list_items(Bin, []),
    {ItemTree, Rest}.

decode_list_items(<<>>, Accum) -> {lists:reverse(Accum), <<>>};
decode_list_items(Bin, Accum) ->
    case decode_b(Bin) of
        {end_of_data, Rest} ->
            {lists:reverse(Accum), Rest};
        {I, Rest} -> decode_list_items(Rest, [I | Accum])
    end.

decode_dict(Bin) ->
    decode_dict_items(Bin, []).

decode_dict_items(<<>>, Accum) ->
    {Accum, <<>>};
decode_dict_items(Bin, Accum) ->
    case decode_b(Bin) of
        {end_of_data, Rest} when Accum == [] -> {{}, Rest};
        {end_of_data, Rest} -> {lists:reverse(Accum), Rest};
        {Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
                        decode_dict_items(Rest2, [{Key, Value} | Accum])
    end.

string_to_int([]) ->
    {error, no_integer};
string_to_int(Str) ->
    case string:to_integer(Str) of
        {error, _} ->
            string_to_int(tl(Str));
        {Int, _} ->
            {ok, Int}
    end.

-ifdef(EUNIT).
-ifdef(PROPER).

prop_inv() ->
    ?FORALL(BC, bcode(),
            begin
                Enc = iolist_to_binary(encode(BC)),
                {ok, Dec} = decode(Enc),
                encode(BC) =:= encode(Dec)
            end).

eqc_test() ->
    ?assert(proper:quickcheck(prop_inv())).

-endif.
-endif.
