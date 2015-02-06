%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%%
%%% @end
%%% Created :  3 Jul 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(etracker_db_frag_hash).

-export([
         init_state/2,
         add_frag/1,
         del_frag/1,
         key_to_frag_number/2,
         match_spec_to_frag_numbers/2
        ]).

%% -behaviour(mnesia_frag_hash).

-record(hash_state,
        {table,
         n_fragments,
         next_n_to_split,
         n_doubles,
         function}).

init_state(Tab, State) when State == undefined ->
    #hash_state{table = Tab,
                n_fragments = 1,
                next_n_to_split = 1,
                n_doubles = 0,
                function = phash2}.

add_frag(#hash_state{next_n_to_split = SplitN, n_doubles = L, n_fragments = N} = State) ->
    P = SplitN + 1,
    NewN = N + 1,
    State2 = case power2(L) + 1 of
                 P2 when P2 == P ->
                     State#hash_state{n_fragments      = NewN,
                                      n_doubles        = L + 1,
                                      next_n_to_split = 1};
                 _ ->
                     State#hash_state{n_fragments     = NewN,
                                      next_n_to_split = P}
             end,
    {State2, [SplitN], [NewN]}.

del_frag(#hash_state{next_n_to_split = SplitN, n_doubles = L, n_fragments = N} = State) ->
    P = SplitN - 1,
    if
        P < 1 ->
            L2 = L - 1,
            MergeN = power2(L2),
            State2 = State#hash_state{n_fragments     = N - 1,
                                      next_n_to_split = MergeN,
                                      n_doubles       = L2},
            {State2, [N], [MergeN]};
        true ->
            MergeN = P,
            State2 = State#hash_state{n_fragments     = N - 1,
                                      next_n_to_split = MergeN},
            {State2, [N], [MergeN]}
	end.

key_to_frag_number(#hash_state{table = Tbl,
                               function = phash2,
                               n_fragments = N,
                               n_doubles = L}, Key) ->
    A = erlang:phash2(etracker_mnesia_mgr:frag_key(Tbl, Key), power2(L + 1)) + 1,
    if
        A > N ->
            A - power2(L);
        true ->
            A
    end.

match_spec_to_frag_numbers(#hash_state{n_fragments = N} = State, MatchSpec) ->
    case MatchSpec of
        [{HeadPat, _, _}] when is_tuple(HeadPat), tuple_size(HeadPat) > 2 ->
            KeyPat = element(2, HeadPat),
            case has_var(KeyPat) of
                false ->
                    [key_to_frag_number(State, KeyPat)];
                true ->
                    lists:seq(1, N)
            end;
        _ ->
            lists:seq(1, N)
    end.

power2(Y) ->
    1 bsl Y. % trunc(math:pow(2, Y)).

has_var(Pat) ->
    mnesia:has_var(Pat).
