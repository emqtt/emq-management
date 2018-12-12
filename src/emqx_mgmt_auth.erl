%%--------------------------------------------------------------------
%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_mgmt_auth).

%% Mnesia Bootstrap
-export([mnesia/1]).
-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

%% APP Management API
-export([add_app/3,
         add_app/6,
         lookup_app/1,
         get_appsecret/1,
         update_app/2,
         update_app/5,
         del_app/1,
         list_apps/0]).

%% APP Auth/ACL API
-export([is_authorized/2]).

-record(mqtt_app, {id, secret, name, desc, status, expired}).

-type(appid() :: binary()).

-type(appsecret() :: binary()).

%%--------------------------------------------------------------------
%% Mnesia Bootstrap
%%--------------------------------------------------------------------

mnesia(boot) ->
    ok = ekka_mnesia:create_table(mqtt_app, [
                {disc_copies, [node()]},
                {record_name, mqtt_app},
                {attributes, record_info(fields, mqtt_app)}]);

mnesia(copy) ->
    ok = ekka_mnesia:copy_table(mqtt_app, disc_copies).

%%--------------------------------------------------------------------
%% Manage Apps
%%--------------------------------------------------------------------
-spec(add_app(appid(), binary(), binary() | undefined) -> {ok, appsecret()} | {error, term()}).
add_app(AppId, Name, Secret) when is_binary(AppId) ->
    add_app(AppId, Name, <<"Application user">>, true, undefined, Secret).

-spec(add_app(appid(), binary(), binary(), boolean(), integer() | undefined, binary() | undefined) -> {ok, appsecret()} | {error, term()}).
add_app(AppId, Name, Desc, Status, Expired, Secret) when is_binary(AppId) ->
    ActualSecret = secret(Secret),
    App = #mqtt_app{id = AppId,
                    secret = ActualSecret,
                    name = Name,
                    desc = Desc,
                    status = Status,
                    expired = Expired},
    AddFun = fun() ->
                 case mnesia:wread({mqtt_app, AppId}) of
                     [] -> mnesia:write(App);
                     _  -> mnesia:abort(alread_existed)
                 end
             end,
    case mnesia:transaction(AddFun) of
        {atomic, ok} -> {ok, ActualSecret};
        {aborted, Reason} -> {error, Reason}
    end.

-spec(get_appsecret(appid()) -> {appsecret() | undefined}).
get_appsecret(AppId) when is_binary(AppId) ->
    case mnesia:dirty_read(mqtt_app, AppId) of
        [#mqtt_app{secret = Secret}] -> Secret;
        [] -> undefined
    end.

-spec(lookup_app(appid()) -> {{appid(), appsecret(), binary(), binary(), boolean(), integer() | undefined} | undefined}).
lookup_app(AppId) when is_binary(AppId) ->
    case mnesia:dirty_read(mqtt_app, AppId) of
        [#mqtt_app{id = AppId,
                   secret = AppSecret,
                   name = Name,
                   desc = Desc,
                   status = Status,
                   expired = Expired}] -> {AppId, AppSecret, Name, Desc, Status, Expired};
        [] -> undefined
    end.

-spec(update_app(appid(), boolean()) -> ok | {error, term()}).
update_app(AppId, Status) ->
    case mnesia:dirty_read(mqtt_app, AppId) of
        [App = #mqtt_app{}] ->
            case mnesia:transaction(fun() -> mnesia:write(App#mqtt_app{status = Status}) end) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end;
        [] ->
            {error, ont_found}
    end.

-spec(update_app(appid(), binary(), binary(), boolean(), integer() | undefined) -> ok | {error, term()}).
update_app(AppId, Name, Desc, Status, Expired) ->
    case mnesia:dirty_read(mqtt_app, AppId) of
        [App = #mqtt_app{}] ->
            case mnesia:transaction(fun() -> mnesia:write(App#mqtt_app{name = Name,
                                                                       desc = Desc,
                                                                       status = Status,
                                                                       expired = Expired}) end) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end;
        [] ->
            {error, ont_found}
    end.

-spec(del_app(appid()) -> ok | {error, term()}).
del_app(AppId) when is_binary(AppId) ->
    case mnesia:transaction(fun mnesia:delete/1, [{mqtt_app, AppId}]) of
        {atomic, Ok} -> Ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec(list_apps() -> [{appid(), appsecret(), binary(), binary(), boolean(), integer() | undefined}]).
list_apps() ->
    [ {AppId, AppSecret, Name, Desc, Status, Expired} || #mqtt_app{id = AppId,
                                                                   secret = AppSecret,
                                                                   name = Name,
                                                                   desc = Desc,
                                                                   status = Status,
                                                                   expired = Expired} <- ets:tab2list(mqtt_app) ].
secret(undefined) -> emqx_guid:to_base62(emqx_guid:gen());
secret(Secret) -> Secret.

%%--------------------------------------------------------------------
%% Authenticate App
%%--------------------------------------------------------------------

-spec(is_authorized(appid(), appsecret()) -> boolean()).
is_authorized(AppId, AppSecret) ->
    case lookup_app(AppId) of
        {_, AppSecret1, _, _, Status, Expired} ->
            Status andalso is_expired(Expired) andalso AppSecret =:= AppSecret1;
        _ ->
            false
    end.

is_expired(undefined) -> true;
is_expired(Expired)   -> Expired >= emqx_time:now_secs().
