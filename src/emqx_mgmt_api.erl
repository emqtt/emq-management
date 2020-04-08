%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_mgmt_api).

-include_lib("stdlib/include/qlc.hrl").

-export([paginate/3]).

%% first_next query APIs
-export([ params2qs/2
        , node_query/5
        , cluster_query/4
        , traverse_table/4
        ]).

paginate(Tables, Params, RowFun) ->
    Qh = query_handle(Tables),
    Count = count(Tables),
    Page = page(Params),
    Limit = limit(Params),
    Cursor = qlc:cursor(Qh),
    case Page > 1 of
        true  -> qlc:next_answers(Cursor, (Page - 1) * Limit);
        false -> ok
    end,
    Rows = qlc:next_answers(Cursor, Limit),
    qlc:delete_cursor(Cursor),
    #{meta  => #{page => Page, limit => Limit, count => Count},
      data  => [RowFun(Row) || Row <- Rows]}.

query_handle(Table) when is_atom(Table) ->
    qlc:q([R|| R <- ets:table(Table)]);
query_handle([Table]) when is_atom(Table) ->
    qlc:q([R|| R <- ets:table(Table)]);
query_handle(Tables) ->
    qlc:append([qlc:q([E || E <- ets:table(T)]) || T <- Tables]).

count(Table) when is_atom(Table) ->
    ets:info(Table, size);
count([Table]) when is_atom(Table) ->
    ets:info(Table, size);
count(Tables) ->
    lists:sum([count(T) || T <- Tables]).

count(Table, Nodes) ->
    lists:sum([rpc_call(Node, ets, info, [Table, size], 5000) || Node <- Nodes]).

page(Params) ->
    binary_to_integer(proplists:get_value(<<"_page">>, Params, <<"1">>)).

limit(Params) ->
    case proplists:get_value(<<"_limit">>, Params) of
        undefined -> emqx_mgmt:max_row_limit();
        Size      -> binary_to_integer(Size)
    end.

%%--------------------------------------------------------------------
%% Node Query
%%--------------------------------------------------------------------

node_query(Node, Params, {Tab, QsSchema}, QueryFun, FmtFun) ->
    {CodCnt, Qs} = params2qs(Params, QsSchema),
    Limit = limit(Params),
    Page  = page(Params),
    Start = if Page > 1 -> (Page-1) * Limit;
               true -> 0
            end,
    {_, Rows} = do_query(Node, Qs, QueryFun, Start, Limit+1),
    Meta = #{page => Page, limit => Limit},
    NMeta = case CodCnt =:= 0 of
                true -> Meta#{count => count(Tab), hasnext => length(Rows) > Limit};
                _ -> Meta#{count => -1, hasnext => length(Rows) > Limit}
            end,
    #{meta => NMeta, data => [FmtFun(Row) || Row <- lists:sublist(Rows, Limit)]}.

%% @private
do_query(Node, Qs, QueryFun, Start, Limit) when Node =:= node() ->
    QueryFun(Qs, Start, Limit);
do_query(Node, Qs, QueryFun, Start, Limit) ->
    rpc_call(Node, ?MODULE, do_query, [Node, Qs, QueryFun, Start, Limit], 50000).

%% @private
rpc_call(Node, M, F, A, T) ->
    case rpc:call(Node, M, F, A, T) of
        {badrpc, _} = R -> {error, R};
        Res -> Res
    end.

%%--------------------------------------------------------------------
%% Cluster Query
%%--------------------------------------------------------------------

cluster_query(Params, {Tab, QsSchema}, QueryFun, FmtFun) ->
    {CodCnt, Qs} = params2qs(Params, QsSchema),
    Limit = limit(Params),
    Page  = page(Params),
    Start = if Page > 1 -> (Page-1) * Limit;
               true -> 0
            end,
    Nodes = ekka_mnesia:running_nodes(),
    Rows = do_cluster_query(Nodes, Qs, QueryFun, Start, Limit+1, []),
    Meta = #{page => Page, limit => Limit},
    NMeta = case CodCnt =:= 0 of
                true -> Meta#{count => count(Tab, Nodes), hasnext => length(Rows) > Limit};
                _ -> Meta#{count => -1, hasnext => length(Rows) > Limit}
            end,
    #{meta => NMeta, data => [FmtFun(Row) || Row <- lists:sublist(Rows, Limit)]}.

%% @private
do_cluster_query([], _, _, _, _, Acc) ->
    lists:append(lists:reverse(Acc));
do_cluster_query([Node|Nodes], Qs, QueryFun, Start, Limit, Acc) ->
    {NStart, Rows} = do_query(Node, Qs, QueryFun, Start, Limit),
    case Limit - length(Rows) of
        Rest when Rest > 0 ->
            do_cluster_query(Nodes, Qs, QueryFun, NStart, Limit, [Rows|Acc]);
        0 ->
            lists:append(lists:reverse([Rows|Acc]))
    end.

traverse_table(Tab, MatchFun, Start, Limit) ->
    ets:safe_fixtable(Tab, true),
    Result = traverse_one_by_one(Tab, ets:first(Tab), MatchFun, Start, Limit, []),
    ets:safe_fixtable(Tab, false),
    Result.

%% @private
traverse_one_by_one(_, '$end_of_table', _, Start, _, Acc) ->
    {Start, lists:reverse(Acc)};
traverse_one_by_one(_, _, _, Start, _Limit=0, Acc) ->
    {Start, lists:reverse(Acc)};
traverse_one_by_one(Tab, K, MatchFun, Start, Limit, Acc) ->
    [E] = ets:lookup(Tab, K),
    K2 = ets:next(Tab, K),
    case MatchFun(E) of
        {ok, Return} ->
            case Start of
                0 ->
                    traverse_one_by_one(Tab, K2, MatchFun, Start, Limit-1, [Return | Acc]);
                _ ->
                    traverse_one_by_one(Tab, K2, MatchFun, Start-1, Limit, Acc)
            end;
        _ ->
            traverse_one_by_one(Tab, K2, MatchFun, Start, Limit, Acc)
    end.

params2qs(Params, QsSchema) ->
    {Qs, Fuzzy} = pick_params_to_qs(Params, QsSchema, [], []),
    {length(Qs) + length(Fuzzy), {Qs, Fuzzy}}.

%%--------------------------------------------------------------------
%% Intenal funcs

pick_params_to_qs([], _, Acc1, Acc2) ->
    NAcc2 = [E || E <- Acc2, not lists:keymember(element(1, E), 1, Acc1)],
    {lists:reverse(Acc1), lists:reverse(NAcc2)};

pick_params_to_qs([{Key, Value}|Params], QsKits, Acc1, Acc2) ->
    case proplists:get_value(Key, QsKits) of
        undefined -> pick_params_to_qs(Params, QsKits, Acc1, Acc2);
        Type ->
            case Key of
                <<Prefix:5/binary, NKey/binary>>
                  when Prefix =:= <<"_gte_">>;
                       Prefix =:= <<"_lte_">> ->
                    OpposeKey = case Prefix of
                                    <<"_gte_">> -> <<"_lte_", NKey/binary>>;
                                    <<"_lte_">> -> <<"_gte_", NKey/binary>>
                                end,
                    case lists:keytake(OpposeKey, 1, Params) of
                        false ->
                            pick_params_to_qs(Params, QsKits, [qs(Key, Value, Type) | Acc1], Acc2);
                        {value, {K2, V2}, NParams} ->
                            pick_params_to_qs(NParams, QsKits, [qs(Key, Value, K2, V2, Type) | Acc1], Acc2)
                    end;
                _ ->
                    case is_fuzzy_key(Key) of
                        true ->
                            pick_params_to_qs(Params, QsKits, Acc1, [qs(Key, Value, Type) | Acc2]);
                        _ ->
                            pick_params_to_qs(Params, QsKits, [qs(Key, Value, Type) | Acc1], Acc2)

                    end
            end
    end.

qs(<<"_gte_", Key/binary>>, Value, Type) ->
    {binary_to_existing_atom(Key, utf8), '>=', to_type(Value, Type)};
qs(<<"_lte_", Key/binary>>, Value, Type) ->
    {binary_to_existing_atom(Key, utf8), '=<', to_type(Value, Type)};
qs(<<"_like_", Key/binary>>, Value, Type) ->
    {binary_to_existing_atom(Key, utf8), like, to_type(Value, Type)};
qs(<<"_match_", Key/binary>>, Value, Type) ->
    {binary_to_existing_atom(Key, utf8), match, to_type(Value, Type)};
qs(Key, Value, Type) ->
    {binary_to_existing_atom(Key, utf8), '=:=', to_type(Value, Type)}.

qs(K1, V1, K2, V2, Type) ->
    {Key, Op1, NV1} = qs(K1, V1, Type),
    {Key, Op2, NV2} = qs(K2, V2, Type),
    {Key, Op1, NV1, Op2, NV2}.

is_fuzzy_key(<<"_like_", _/binary>>) ->
    true;
is_fuzzy_key(<<"_match_", _/binary>>) ->
    true;
is_fuzzy_key(_) ->
    false.

%%--------------------------------------------------------------------
%% Types

to_type(V, atom) -> to_atom(V);
to_type(V, integer) -> to_integer(V);
to_type(V, timestamp) -> to_timestamp(V);
to_type(V, ip) -> aton(V);
to_type(V, _) -> V.

to_atom(A) when is_atom(A) ->
    A;
to_atom(B) when is_binary(B) ->
    binary_to_atom(B, utf8).

to_integer(I) when is_integer(I) ->
    I;
to_integer(B) when is_binary(B) ->
    binary_to_integer(B).

to_timestamp(I) when is_integer(I) ->
    I;
to_timestamp(B) when is_binary(B) ->
    binary_to_integer(B).

aton(B) when is_binary(B) ->
    list_to_tuple([binary_to_integer(T) || T <- re:split(B, "[.]")]).
