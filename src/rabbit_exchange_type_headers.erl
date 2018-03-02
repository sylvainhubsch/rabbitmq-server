%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_exchange_type_headers).
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-behaviour(rabbit_exchange_type).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, validate_binding/2,
         create/2, delete/3, policy_changed/2, add_binding/3,
         remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type headers"},
                    {mfa,         {rabbit_registry, register,
                                   [exchange, <<"headers">>, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

info(_X) -> [].
info(_X, _) -> [].

description() ->
    [{description, <<"AMQP headers exchange, as per the AMQP specification">>}].

serialise_events() -> false.

route(#exchange{name = Name},
      #delivery{message = #basic_message{content = Content}}) ->
    Headers = case (Content#content.properties)#'P_basic'.headers of
                  undefined -> [];
                  H         -> rabbit_misc:sort_field_table(H)
              end,
    CurrentOrderedBindings = case mnesia:dirty_read(rabbit_headers_bindings, Name) of
        [] -> [];
        [#headers_bindings{bindings = E}] -> E
    end,
    get_routes(Headers, CurrentOrderedBindings, []).

get_routes(_, [], Dests) -> Dests;
% Binding type is 'all'
get_routes(Headers, [ {_, _, all, Dest, Args} | T ], Dests) ->
    case lists:member(Dest, Dests) of
        true -> get_routes(Headers, T, Dests);
        _    ->
            case headers_match_all(Args, Headers) of
                true -> get_routes(Headers, T, [ Dest | Dests]);
                _    -> get_routes(Headers, T, Dests)
            end
    end;
% Binding type is 'any'
get_routes(Headers, [ {_, _, any, Dest, Args} | T ], Dests) ->
    case lists:member(Dest, Dests) of
        true -> get_routes(Headers, T, Dests);
        _    ->
            case headers_match_any(Args, Headers) of
                true -> get_routes(Headers, T, [ Dest | Dests]);
                _    -> get_routes(Headers, T, Dests)
            end
    end.


validate_binding(_X, #binding{args = Args}) ->
    case rabbit_misc:table_lookup(Args, <<"x-match">>) of
        {longstr, <<"all">>} -> validate_binding_order(Args);
        {longstr, <<"any">>} -> validate_binding_order(Args);
        {longstr, Other}     -> {error,
                                 {binding_invalid,
                                  "Invalid x-match field value ~p; "
                                  "expected all or any", [Other]}};
        {Type,    Other}     -> {error,
                                 {binding_invalid,
                                  "Invalid x-match field type ~p (value ~p); "
                                  "expected longstr", [Type, Other]}};
        undefined            -> validate_binding_order(Args)
    end.

validate_binding_order(Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-match-order">>) of
        undefined     -> ok;
        {number, _}   -> ok;
        {Type, _} -> {error,
                          {binding_invalid,
                           "Invalid x-match-order field type ~p; "
                                  "expected number", [Type]}}
    end.

%% [0] spec is vague on whether it can be omitted but in practice it's
%% useful to allow people to do this

parse_x_match({longstr, <<"all">>}) -> all;
parse_x_match({longstr, <<"any">>}) -> any;
parse_x_match(_)                    -> all. %% legacy; we didn't validate

%%
%% !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
%% REQUIRES BOTH PATTERN AND DATA TO BE SORTED ASCENDING BY KEY.
%% !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
%%

%% Binding type 'all' match

% No more match operator to check; return true
headers_match_all([], _) -> true;
% Purge nx op on no data as all these are true
headers_match_all([{_, nx, _} | BNext], []) ->
    headers_match_all(BNext, []);
% No more message header but still match operator to check; return false
headers_match_all(_, []) -> false;
% Current header key not in match operators; go next header with current match operator
headers_match_all(BCur = [{BK, _, _} | _], [{HK, _, _} | HNext])
    when BK > HK -> headers_match_all(BCur, HNext);
% Current binding key must not exist in data, go next binding
headers_match_all([{BK, nx, _} | BNext], HCur = [{HK, _, _} | _])
    when BK < HK -> headers_match_all(BNext, HCur);
% Current match operator does not exist in message; return false
headers_match_all([{BK, _, _} | _], [{HK, _, _} | _])
    when BK < HK -> false;
%
% From here, BK == HK (keys are the same)
%
% Current values must match and do match; ok go next
headers_match_all([{_, eq, BV} | BNext], [{_, _, HV} | HNext])
    when BV == HV -> headers_match_all(BNext, HNext);
% Current values must match but do not match; return false
headers_match_all([{_, eq, _} | _], _) -> false;
% Key must not exist, return false
headers_match_all([{_, nx, _} | _], _) -> false;
% Current header key must exist; ok go next
headers_match_all([{_, ex, _} | BNext], [ _ | HNext]) ->
    headers_match_all(BNext, HNext);
% <= < = != > >=
headers_match_all([{_, ne, BV} | BNext], HCur = [{_, _, HV} | _])
    when BV /= HV -> headers_match_all(BNext, HCur);
headers_match_all([{_, ne, _} | _], _) -> false;
headers_match_all([{_, gt, BV} | BNext], HCur = [{_, _, HV} | _])
    when HV > BV -> headers_match_all(BNext, HCur);
headers_match_all([{_, gt, _} | _], _) -> false;
headers_match_all([{_, ge, BV} | BNext], HCur = [{_, _, HV} | _])
    when HV >= BV -> headers_match_all(BNext, HCur);
headers_match_all([{_, ge, _} | _], _) -> false;
headers_match_all([{_, lt, BV} | BNext], HCur = [{_, _, HV} | _])
    when HV < BV -> headers_match_all(BNext, HCur);
headers_match_all([{_, lt, _} | _], _) -> false;
headers_match_all([{_, le, BV} | BNext], HCur = [{_, _, HV} | _])
    when HV =< BV -> headers_match_all(BNext, HCur);
headers_match_all([{_, le, _} | _], _) -> false.



%% Binding type 'any' match

% No more match operator to check; return false
headers_match_any([], _) -> false;
% On no data left, only nx operator can return true
headers_match_any([{_, nx, _} | _], []) -> true;
% No more message header but still match operator to check; return false
headers_match_any(_, []) -> false;
% Current header key not in match operators; go next header with current match operator
headers_match_any(BCur = [{BK, _, _} | _], [{HK, _, _} | HNext])
    when BK > HK -> headers_match_any(BCur, HNext);
% nx operator : current binding key must not exist in data, return true
headers_match_any([{BK, nx, _} | _], [{HK, _, _} | _])
    when BK < HK -> true;
% Current binding key does not exist in message; go next binding
headers_match_any([{BK, _, _} | BNext], HCur = [{HK, _, _} | _])
    when BK < HK -> headers_match_any(BNext, HCur);
%
% From here, BK == HK
%
% Current values must match and do match; return true
headers_match_any([{_, eq, BV} | _], [{_, _, HV} | _]) when BV == HV -> true;
% Current header key must exist; return true
headers_match_any([{_, ex, _} | _], _) -> true;
headers_match_any([{_, ne, BV} | _], [{_, _, HV} | _]) when HV /= BV -> true;
headers_match_any([{_, gt, BV} | _], [{_, _, HV} | _]) when HV > BV -> true;
headers_match_any([{_, ge, BV} | _], [{_, _, HV} | _]) when HV >= BV -> true;
headers_match_any([{_, lt, BV} | _], [{_, _, HV} | _]) when HV < BV -> true;
headers_match_any([{_, le, BV} | _], [{_, _, HV} | _]) when HV =< BV -> true;
% No match yet; go next
headers_match_any([_ | BNext], HCur) ->
    headers_match_any(BNext, HCur).


get_match_operators(BindingArgs) ->
    MatchOperators = get_match_operators(BindingArgs, []),
    rabbit_misc:sort_field_table(MatchOperators).

get_match_operators([], Result) -> Result;
%% It's not properly specified, but a "no value" in a
%% pattern field is supposed to mean simple presence of
%% the corresponding data field. I've interpreted that to
%% mean a type of "void" for the pattern field.
%
% Maybe should we consider instead a "no value" as beeing a real no value of type longstr ?
% In other words, from where does the "void" type appears ?
get_match_operators([ {K, void, _V} | T ], Res) ->
    get_match_operators (T, [ {K, ex, nil} | Res]);
% the new match operator is 'ex' (like in << must EXist >>)
get_match_operators([ {<<"x-?ex">>, longstr, K} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, ex, nil} | Res]);
% operator "key not exist"
get_match_operators([ {<<"x-?nx">>, longstr, K} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, nx, nil} | Res]);
% operators <= < = != > >=
get_match_operators([ {<<"x-?<= ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, le, V} | Res]);
get_match_operators([ {<<"x-?< ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, lt, V} | Res]);
get_match_operators([ {<<"x-?= ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, eq, V} | Res]);
get_match_operators([ {<<"x-?!= ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, ne, V} | Res]);
get_match_operators([ {<<"x-?> ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, gt, V} | Res]);
get_match_operators([ {<<"x-?>= ", K/binary>>, _, V} | Tail ], Res) ->
    get_match_operators (Tail, [ {K, ge, V} | Res]);
% skip all x-* args..
get_match_operators([ {<<"x-", _/binary>>, _, _} | T ], Res) ->
    get_match_operators (T, Res);
% for all other cases, the match operator is 'eq'
get_match_operators([ {K, _, V} | T ], Res) ->
    get_match_operators (T, [ {K, eq, V} | Res]).


%% Flatten one level for list of values (array)
flatten_binding_args(Args) ->
        flatten_binding_args(Args, []).

flatten_binding_args([], Result) -> Result;
flatten_binding_args ([ {K, array, Vs} | Tail ], Result) ->
        Res = [ { K, T, V } || {T, V} <- Vs ],
        flatten_binding_args (Tail, lists:append ([ Res , Result ]));
flatten_binding_args ([ {K, T, V} | Tail ], Result) ->
        flatten_binding_args (Tail, [ {K, T, V} | Result ]).


validate(_X) -> ok.
create(_Tx, _X) -> ok.

delete(transaction, #exchange{name = XName}, _) ->
    ok = mnesia:delete (rabbit_headers_bindings, XName, write);
delete(_, _, _) -> ok.

policy_changed(_X1, _X2) -> ok.

add_binding(transaction, #exchange{name = XName}, BindingToAdd = #binding{destination = Dest, args = BindingArgs}) ->
% BindingId is used to track original binding definition so that it is used when deleting later
    BindingId = crypto:hash(md5, term_to_binary(BindingToAdd)),
% Let's doing that heavy lookup one time only
    BindingType = parse_x_match(rabbit_misc:table_lookup(BindingArgs, <<"x-match">>)),
    BindingOrder = parse_x_match(rabbit_misc:table_lookup(BindingArgs, <<"x-match-order">>)),
    FlattenedBindindArgs = flatten_binding_args(BindingArgs),
    MatchOperators = get_match_operators(FlattenedBindindArgs),
    CurrentOrderedBindings = case mnesia:read(rabbit_headers_bindings, XName, write) of
        [] -> [];
        [#headers_bindings{bindings = E}] -> E
    end,
    NewBinding = {BindingOrder, BindingId, BindingType, Dest, MatchOperators},
    NewBindings = lists:keysort(1, [NewBinding | CurrentOrderedBindings]),
    NewRecord = #headers_bindings{exchange_name = XName, bindings = NewBindings},
    ok = mnesia:write(rabbit_headers_bindings, NewRecord, write);
add_binding(_, _, _) ->
    ok.

remove_bindings(transaction, #exchange{name = XName}, BindingsToDelete) ->
    CurrentOrderedBindings = case mnesia:read(rabbit_headers_bindings, XName, write) of
        [] -> [];
        [#headers_bindings{bindings = E}] -> E
    end,
    BindingIdsToDelete = [crypto:hash(md5, term_to_binary(B)) || B <- BindingsToDelete],
    NewOrderedBindings = [Bind || Bind={_,BId,_,_,_} <- CurrentOrderedBindings, lists:member(BId, BindingIdsToDelete) == false],
    NewRecord = #headers_bindings{exchange_name = XName, bindings = NewOrderedBindings},
    ok = mnesia:write(rabbit_headers_bindings, NewRecord, write);
remove_bindings(_, _, _) ->
    ok.

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).
