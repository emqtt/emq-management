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

-module(emqx_mgmt_cli).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-include_lib("emqx_rule_engine/include/rule_engine.hrl").

-define(PRINT_CMD(Cmd, Descr), io:format("~-48s# ~s~n", [Cmd, Descr])).

-import(lists, [foreach/2]).

-export([load/0]).

-export([ status/1
        , broker/1
        , cluster/1
        , clients/1
        , routes/1
        , subscriptions/1
        , plugins/1
        , listeners/1
        , vm/1
        , mnesia/1
        , trace/1
        , log/1
        , mgmt/1
        , data/1
        , modules/1
        ]).

-define(PROC_INFOKEYS, [status,
                        memory,
                        message_queue_len,
                        total_heap_size,
                        heap_size,
                        stack_size,
                        reductions]).

-define(MAX_LIMIT, 10000).

-define(MAIN_APP, emqx).

-spec(load() -> ok).
load() ->
    Cmds = [Fun || {Fun, _} <- ?MODULE:module_info(exports), is_cmd(Fun)],
    lists:foreach(fun(Cmd) -> emqx_ctl:register_command(Cmd, {?MODULE, Cmd}, []) end, Cmds).

is_cmd(Fun) ->
    not lists:member(Fun, [init, load, module_info]).

mgmt(["insert", AppId, Name]) ->
    case emqx_mgmt_auth:add_app(list_to_binary(AppId), list_to_binary(Name)) of
        {ok, Secret} ->
            emqx_ctl:print("AppSecret: ~s~n", [Secret]);
        {error, already_existed} ->
            emqx_ctl:print("Error: already existed~n");
        {error, Reason} ->
            emqx_ctl:print("Error: ~p~n", [Reason])
    end;

mgmt(["lookup", AppId]) ->
    case emqx_mgmt_auth:lookup_app(list_to_binary(AppId)) of
        {AppId1, AppSecret, Name, Desc, Status, Expired} ->
            emqx_ctl:print("app_id: ~s~nsecret: ~s~nname: ~s~ndesc: ~s~nstatus: ~s~nexpired: ~p~n",
                           [AppId1, AppSecret, Name, Desc, Status, Expired]);
        undefined ->
            emqx_ctl:print("Not Found.~n")
    end;

mgmt(["update", AppId, Status]) ->
    case emqx_mgmt_auth:update_app(list_to_binary(AppId), list_to_atom(Status)) of
        ok ->
            emqx_ctl:print("update successfully.~n");
        {error, Reason} ->
            emqx_ctl:print("Error: ~p~n", [Reason])
    end;

mgmt(["delete", AppId]) ->
    case emqx_mgmt_auth:del_app(list_to_binary(AppId)) of
        ok -> emqx_ctl:print("ok~n");
        {error, not_found} ->
            emqx_ctl:print("Error: app not found~n");
        {error, Reason} ->
            emqx_ctl:print("Error: ~p~n", [Reason])
    end;

mgmt(["list"]) ->
    lists:foreach(fun({AppId, AppSecret, Name, Desc, Status, Expired}) ->
                      emqx_ctl:print("app_id: ~s, secret: ~s, name: ~s, desc: ~s, status: ~s, expired: ~p~n",
                                    [AppId, AppSecret, Name, Desc, Status, Expired])
                  end, emqx_mgmt_auth:list_apps());

mgmt(_) ->
    emqx_ctl:usage([{"mgmt list",                    "List Applications"},
                    {"mgmt insert <AppId> <Name>",   "Add Application of REST API"},
                    {"mgmt update <AppId> <status>", "Update Application of REST API"},
                    {"mgmt lookup <AppId>",          "Get Application of REST API"},
                    {"mgmt delete <AppId>",          "Delete Application of REST API"}]).

%%--------------------------------------------------------------------
%% @doc Node status

status([]) ->
    {InternalStatus, _ProvidedStatus} = init:get_status(),
        emqx_ctl:print("Node ~p is ~p~n", [node(), InternalStatus]),
    case lists:keysearch(?MAIN_APP, 1, application:which_applications()) of
        false ->
            emqx_ctl:print("~s is not running~n", [?MAIN_APP]);
        {value, {?MAIN_APP, _Desc, Vsn}} ->
            emqx_ctl:print("~s ~s is running~n", [?MAIN_APP, Vsn])
    end;
status(_) ->
     emqx_ctl:usage("status", "Show broker status").

%%--------------------------------------------------------------------
%% @doc Query broker

broker([]) ->
    Funs = [sysdescr, version, uptime, datetime],
    [emqx_ctl:print("~-10s: ~s~n", [Fun, emqx_sys:Fun()]) || Fun <- Funs];

broker(["stats"]) ->
    [emqx_ctl:print("~-30s: ~w~n", [Stat, Val]) || {Stat, Val} <- lists:sort(emqx_stats:getstats())];

broker(["metrics"]) ->
    [emqx_ctl:print("~-30s: ~w~n", [Metric, Val]) || {Metric, Val} <- lists:sort(emqx_metrics:all())];

broker(_) ->
    emqx_ctl:usage([{"broker",         "Show broker version, uptime and description"},
                    {"broker stats",   "Show broker statistics of clients, topics, subscribers"},
                    {"broker metrics", "Show broker metrics"}]).

%%-----------------------------------------------------------------------------
%% @doc Cluster with other nodes

cluster(["join", SNode]) ->
    case ekka:join(ekka_node:parse_name(SNode)) of
        ok ->
            emqx_ctl:print("Join the cluster successfully.~n"),
            cluster(["status"]);
        ignore ->
            emqx_ctl:print("Ignore.~n");
        {error, Error} ->
            emqx_ctl:print("Failed to join the cluster: ~p~n", [Error])
    end;

cluster(["leave"]) ->
    case ekka:leave() of
        ok ->
            emqx_ctl:print("Leave the cluster successfully.~n"),
            cluster(["status"]);
        {error, Error} ->
            emqx_ctl:print("Failed to leave the cluster: ~p~n", [Error])
    end;

cluster(["force-leave", SNode]) ->
    case ekka:force_leave(ekka_node:parse_name(SNode)) of
        ok ->
            emqx_ctl:print("Remove the node from cluster successfully.~n"),
            cluster(["status"]);
        ignore ->
            emqx_ctl:print("Ignore.~n");
        {error, Error} ->
            emqx_ctl:print("Failed to remove the node from cluster: ~p~n", [Error])
    end;

cluster(["status"]) ->
    emqx_ctl:print("Cluster status: ~p~n", [ekka_cluster:info()]);

cluster(_) ->
    emqx_ctl:usage([{"cluster join <Node>",       "Join the cluster"},
                    {"cluster leave",             "Leave the cluster"},
                    {"cluster force-leave <Node>","Force the node leave from cluster"},
                    {"cluster status",            "Cluster status"}]).

%%--------------------------------------------------------------------
%% @doc Query clients

clients(["list"]) ->
    dump(emqx_channel, client);

clients(["show", ClientId]) ->
    if_client(ClientId, fun print/1);

clients(["kick", ClientId]) ->
    case emqx_cm:kick_session(bin(ClientId)) of
        ok -> emqx_ctl:print("ok~n");
        _ -> emqx_ctl:print("Not Found.~n")
    end;

clients(_) ->
    emqx_ctl:usage([{"clients list",            "List all clients"},
                    {"clients show <ClientId>", "Show a client"},
                    {"clients kick <ClientId>", "Kick out a client"}]).

if_client(ClientId, Fun) ->
    case ets:lookup(emqx_channel, (bin(ClientId))) of
        [] -> emqx_ctl:print("Not Found.~n");
        [Channel]    -> Fun({client, Channel})
    end.

%%--------------------------------------------------------------------
%% @doc Routes Command

routes(["list"]) ->
    dump(emqx_route);

routes(["show", Topic]) ->
    Routes = ets:lookup(emqx_route, bin(Topic)),
    [print({emqx_route, Route}) || Route <- Routes];

routes(_) ->
    emqx_ctl:usage([{"routes list",         "List all routes"},
                    {"routes show <Topic>", "Show a route"}]).

subscriptions(["list"]) ->
    lists:foreach(fun(Suboption) ->
                        print({emqx_suboption, Suboption})
                  end, ets:tab2list(emqx_suboption));

subscriptions(["show", ClientId]) ->
    case ets:lookup(emqx_subid, bin(ClientId)) of
        [] ->
            emqx_ctl:print("Not Found.~n");
        [{_, Pid}] ->
            case ets:match_object(emqx_suboption, {{Pid, '_'}, '_'}) of
                [] -> emqx_ctl:print("Not Found.~n");
                Suboption ->
                    [print({emqx_suboption, Sub}) || Sub <- Suboption]
            end
    end;

subscriptions(["add", ClientId, Topic, QoS]) ->
   if_valid_qos(QoS, fun(IntQos) ->
                        case ets:lookup(emqx_channel, bin(ClientId)) of
                            [] -> emqx_ctl:print("Error: Channel not found!");
                            [{_, Pid}] ->
                                {Topic1, Options} = emqx_topic:parse(bin(Topic)),
                                Pid ! {subscribe, [{Topic1, Options#{qos => IntQos}}]},
                                emqx_ctl:print("ok~n")
                        end
                     end);

subscriptions(["del", ClientId, Topic]) ->
    case ets:lookup(emqx_channel, bin(ClientId)) of
        [] -> emqx_ctl:print("Error: Channel not found!");
        [{_, Pid}] ->
            Pid ! {unsubscribe, [emqx_topic:parse(bin(Topic))]},
            emqx_ctl:print("ok~n")
    end;

subscriptions(_) ->
    emqx_ctl:usage([{"subscriptions list",                         "List all subscriptions"},
                    {"subscriptions show <ClientId>",              "Show subscriptions of a client"},
                    {"subscriptions add <ClientId> <Topic> <QoS>", "Add a static subscription manually"},
                    {"subscriptions del <ClientId> <Topic>",       "Delete a static subscription manually"}]).

if_valid_qos(QoS, Fun) ->
    try list_to_integer(QoS) of
        Int when ?IS_QOS(Int) -> Fun(Int);
        _ -> emqx_ctl:print("QoS should be 0, 1, 2~n")
    catch _:_ ->
        emqx_ctl:print("QoS should be 0, 1, 2~n")
    end.

plugins(["list"]) ->
    foreach(fun print/1, emqx_plugins:list());

plugins(["load", Name]) ->
    case emqx_plugins:load(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Plugin ~s loaded successfully.~n", [Name]);
        {error, Reason}   ->
            emqx_ctl:print("Load plugin ~s error: ~p.~n", [Name, Reason])
    end;

plugins(["unload", "emqx_management"])->
    emqx_ctl:print("Plugin emqx_management can not be unloaded.~n");

plugins(["unload", Name]) ->
    case emqx_plugins:unload(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Plugin ~s unloaded successfully.~n", [Name]);
        {error, Reason} ->
            emqx_ctl:print("Unload plugin ~s error: ~p.~n", [Name, Reason])
    end;

plugins(["reload", Name]) ->
    try list_to_existing_atom(Name) of
        PluginName ->
            case emqx_mgmt:reload_plugin(node(), PluginName) of
                ok ->
                    emqx_ctl:print("Plugin ~s reloaded successfully.~n", [Name]);
                {error, Reason} ->
                    emqx_ctl:print("Reload plugin ~s error: ~p.~n", [Name, Reason])
            end
    catch
        error:badarg ->
            emqx_ctl:print("Reload plugin ~s error: The plugin doesn't exist.~n", [Name])
    end;

plugins(_) ->
    emqx_ctl:usage([{"plugins list",            "Show loaded plugins"},
                    {"plugins load <Plugin>",   "Load plugin"},
                    {"plugins unload <Plugin>", "Unload plugin"},
                    {"plugins reload <Plugin>", "Reload plugin"}
                   ]).

%%--------------------------------------------------------------------
%% @doc Modules Command
modules(["list"]) ->
    foreach(fun(Module) -> print({module, Module}) end, emqx_modules:list());

modules(["load", Name]) ->
    case emqx_modules:load(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Module ~s loaded successfully.~n", [Name]);
        {error, Reason}   ->
            emqx_ctl:print("Load module ~s error: ~p.~n", [Name, Reason])
    end;

modules(["unload", Name]) ->
    case emqx_modules:unload(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Module ~s unloaded successfully.~n", [Name]);
        {error, Reason} ->
            emqx_ctl:print("Unload module ~s error: ~p.~n", [Name, Reason])
    end;

modules(["reload", "emqx_mod_acl_internal" = Name]) ->
    case emqx_modules:reload(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Module ~s reloaded successfully.~n", [Name]);
        {error, Reason} ->
            emqx_ctl:print("Reload module ~s error: ~p.~n", [Name, Reason])
    end;
modules(["reload", Name]) ->
    emqx_ctl:print("Module: ~p does not need to be reloaded.~n", [Name]);

modules(_) ->
    emqx_ctl:usage([{"modules list",            "Show loaded modules"},
                    {"modules load <Module>",   "Load module"},
                    {"modules unload <Module>", "Unload module"},
                    {"modules reload <Module>", "Reload module"}
                   ]).

%%--------------------------------------------------------------------
%% @doc vm command

vm([]) ->
    vm(["all"]);

vm(["all"]) ->
    [vm([Name]) || Name <- ["load", "memory", "process", "io", "ports"]];

vm(["load"]) ->
    [emqx_ctl:print("cpu/~-20s: ~s~n", [L, V]) || {L, V} <- emqx_vm:loads()];

vm(["memory"]) ->
    [emqx_ctl:print("memory/~-17s: ~w~n", [Cat, Val]) || {Cat, Val} <- erlang:memory()];

vm(["process"]) ->
    [emqx_ctl:print("process/~-16s: ~w~n", [Name, erlang:system_info(Key)]) || {Name, Key} <- [{limit, process_limit}, {count, process_count}]];

vm(["io"]) ->
    IoInfo = lists:usort(lists:flatten(erlang:system_info(check_io))),
    [emqx_ctl:print("io/~-21s: ~w~n", [Key, proplists:get_value(Key, IoInfo)]) || Key <- [max_fds, active_fds]];

vm(["ports"]) ->
    [emqx_ctl:print("ports/~-16s: ~w~n", [Name, erlang:system_info(Key)]) || {Name, Key} <- [{count, port_count}, {limit, port_limit}]];

vm(_) ->
    emqx_ctl:usage([{"vm all",     "Show info of Erlang VM"},
                    {"vm load",    "Show load of Erlang VM"},
                    {"vm memory",  "Show memory of Erlang VM"},
                    {"vm process", "Show process of Erlang VM"},
                    {"vm io",      "Show IO of Erlang VM"},
                    {"vm ports",   "Show Ports of Erlang VM"}]).

%%--------------------------------------------------------------------
%% @doc mnesia Command

mnesia([]) ->
    mnesia:system_info();

mnesia(_) ->
    emqx_ctl:usage([{"mnesia", "Mnesia system info"}]).

%%--------------------------------------------------------------------
%% @doc Logger Command

log(["set-level", Level]) ->
    case emqx_logger:set_log_level(list_to_atom(Level)) of
        ok -> emqx_ctl:print("~s~n", [Level]);
        Error -> emqx_ctl:print("[error] set overall log level failed: ~p~n", [Error])
    end;

log(["primary-level"]) ->
    Level = emqx_logger:get_primary_log_level(),
    emqx_ctl:print("~s~n", [Level]);

log(["primary-level", Level]) ->
    emqx_logger:set_primary_log_level(list_to_atom(Level)),
    emqx_ctl:print("~s~n", [emqx_logger:get_primary_log_level()]);

log(["handlers", "list"]) ->
    [emqx_ctl:print("LogHandler(id=~s, level=~s, destination=~s)~n", [Id, Level, Dst])
        || {Id, Level, Dst} <- emqx_logger:get_log_handlers()],
    ok;

log(["handlers", "set-level", HandlerId, Level]) ->
    case emqx_logger:set_log_handler_level(list_to_atom(HandlerId), list_to_atom(Level)) of
        ok ->
            {_Id, NewLevel, _Dst} = emqx_logger:get_log_handler(list_to_atom(HandlerId)),
            emqx_ctl:print("~s~n", [NewLevel]);
        {error, Error} ->
            emqx_ctl:print("[error] ~p~n", [Error])
    end;

log(_) ->
    emqx_ctl:usage([{"log set-level <Level>", "Set the overall log level"},
                    {"log primary-level", "Show the primary log level now"},
                    {"log primary-level <Level>","Set the primary log level"},
                    {"log handlers list", "Show log handlers"},
                    {"log handlers set-level <HandlerId> <Level>", "Set log level of a log handler"}]).

%%--------------------------------------------------------------------
%% @doc Trace Command

trace(["list"]) ->
    foreach(fun({{Who, Name}, {Level, LogFile}}) ->
                emqx_ctl:print("Trace(~s=~s, level=~s, destination=~p)~n", [Who, Name, Level, LogFile])
            end, emqx_tracer:lookup_traces());

trace(["stop", "client", ClientId]) ->
    trace_off(clientid, ClientId);

trace(["start", "client", ClientId, LogFile]) ->
    trace_on(clientid, ClientId, all, LogFile);

trace(["start", "client", ClientId, LogFile, Level]) ->
    trace_on(clientid, ClientId, list_to_atom(Level), LogFile);

trace(["stop", "topic", Topic]) ->
    trace_off(topic, Topic);

trace(["start", "topic", Topic, LogFile]) ->
    trace_on(topic, Topic, all, LogFile);

trace(["start", "topic", Topic, LogFile, Level]) ->
    trace_on(topic, Topic, list_to_atom(Level), LogFile);

trace(_) ->
    emqx_ctl:usage([{"trace list", "List all traces started"},
                    {"trace start client <ClientId> <File> [<Level>]", "Traces for a client"},
                    {"trace stop  client <ClientId>", "Stop tracing for a client"},
                    {"trace start topic  <Topic>    <File> [<Level>] ", "Traces for a topic"},
                    {"trace stop  topic  <Topic> ", "Stop tracing for a topic"}]).

trace_on(Who, Name, Level, LogFile) ->
    case emqx_tracer:start_trace({Who, iolist_to_binary(Name)}, Level, LogFile) of
        ok ->
            emqx_ctl:print("trace ~s ~s successfully~n", [Who, Name]);
        {error, Error} ->
            emqx_ctl:print("[error] trace ~s ~s: ~p~n", [Who, Name, Error])
    end.

trace_off(Who, Name) ->
    case emqx_tracer:stop_trace({Who, iolist_to_binary(Name)}) of
        ok ->
            emqx_ctl:print("stop tracing ~s ~s successfully~n", [Who, Name]);
        {error, Error} ->
            emqx_ctl:print("[error] stop tracing ~s ~s: ~p~n", [Who, Name, Error])
    end.

%%--------------------------------------------------------------------
%% @doc Listeners Command

listeners([]) ->
    foreach(fun({{Protocol, ListenOn}, Pid}) ->
                Info = [{acceptors,      esockd:get_acceptors(Pid)},
                        {max_conns,      esockd:get_max_connections(Pid)},
                        {current_conn,   esockd:get_current_connections(Pid)},
                        {shutdown_count, esockd:get_shutdown_count(Pid)}],
                    emqx_ctl:print("listener on ~s:~s~n", [Protocol, esockd:to_string(ListenOn)]),
                foreach(fun({Key, Val}) ->
                            emqx_ctl:print("  ~-16s: ~w~n", [Key, Val])
                        end, Info)
            end, esockd:listeners()),
    foreach(fun({Protocol, Opts}) ->
                Info = [{acceptors,      maps:get(num_acceptors, proplists:get_value(transport_options, Opts, #{}), 0)},
                        {max_conns,      proplists:get_value(max_connections, Opts)},
                        {current_conn,   proplists:get_value(all_connections, Opts)},
                        {shutdown_count, []}],
                    emqx_ctl:print("listener on ~s:~p~n", [Protocol, proplists:get_value(port, Opts)]),
                foreach(fun({Key, Val}) ->
                            emqx_ctl:print("  ~-16s: ~w~n", [Key, Val])
                        end, Info)
            end, ranch:info());

listeners(["stop",  Name = "http" ++ _N, ListenOn]) ->
    case minirest:stop_http(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Stop ~s listener on ~s successfully.~n", [Name, ListenOn]);
        {error, Error} ->
            emqx_ctl:print("Failed to stop ~s listener on ~s, error:~p~n", [Name, ListenOn, Error])
    end;

listeners(["stop", Proto, ListenOn]) ->
    ListenOn1 = case string:tokens(ListenOn, ":") of
        [Port]     -> list_to_integer(Port);
        [IP, Port] -> {IP, list_to_integer(Port)}
    end,
    case emqx_listeners:stop_listener({list_to_atom(Proto), ListenOn1, []}) of
        ok ->
            emqx_ctl:print("Stop ~s listener on ~s successfully.~n", [Proto, ListenOn]);
        {error, Error} ->
            emqx_ctl:print("Failed to stop ~s listener on ~s, error:~p~n", [Proto, ListenOn, Error])
    end;

listeners(_) ->
    emqx_ctl:usage([{"listeners",                        "List listeners"},
                    {"listeners stop    <Proto> <Port>", "Stop a listener"}]).

%%--------------------------------------------------------------------
%% @doc data Command

data(["export"]) ->
    {ok, Dir} = file:get_cwd(),
    data(["export", filename:join([Dir, "data"])]);

data(["export", Directory]) ->
    case filelib:is_dir(Directory) of
        false ->
            emqx_ctl:print("Please enter an existing directory.~n");
        true ->
            case list_to_binary(Directory) of
                <<"/", _/binary>> ->
                    Rules = export_rules(),
                    Resources = export_resources(),
                    Blacklist = export_blacklist(),
                    Apps = export_applications(),
                    Users = export_users(),
                    AuthMnesia = export_auth_mnesia(),
                    AclMnesia = export_acl_mnesia(),
                    Schemas = export_schemas(),
                    Seconds = erlang:system_time(second),
                    {{Y, M, D}, _} = emqx_mgmt_util:datetime(Seconds),
                    Filename = io_lib:format("emqx-export-~p-~p-~p.json", [Y, M, D]),
                    NFilename = filename:join([Directory, Filename]),
                    Data = [{version, erlang:list_to_binary(string:sub_string(emqx_sys:version(), 1, 3))},
                            {date, erlang:list_to_binary(emqx_mgmt_util:strftime(Seconds))},
                            {rules, Rules},
                            {resources, Resources},
                            {blacklist, Blacklist},
                            {apps, Apps},
                            {users, Users},
                            {auth_mnesia, AuthMnesia},
                            {acl_mnesia, AclMnesia},
                            {schemas, Schemas}],
                    case file:write_file(NFilename, emqx_json:encode(Data)) of
                        ok ->
                            emqx_ctl:print("The emqx data has been successfully exported to ~s.~n", [NFilename]);
                        {error, Reason} ->
                            emqx_ctl:print("The emqx data export failed due to ~p.~n", [Reason])
                    end;
                _ ->
                    emqx_ctl:print("Please enter a directory using an absolute path.~n")
            end
    end;

data(["import", Filename]) ->
    case file:read_file(Filename) of
        {ok, Json} ->
            Data = emqx_json:decode(Json, [return_maps]),
            CurVersion = erlang:list_to_binary(string:sub_string(emqx_sys:version(), 1, 3)),
            case maps:get(<<"version">>, Data) of
                CurVersion ->
                    try
                        import_resources(maps:get(<<"resources">>, Data)),
                        import_rules(maps:get(<<"rules">>, Data)),
                        import_blacklist(maps:get(<<"blacklist">>, Data)),
                        import_applications(maps:get(<<"apps">>, Data)),
                        import_users(maps:get(<<"users">>, Data)),
                        import_auth_mnesia(maps:get(<<"auth_mnesia">>, Data)),
                        import_acl_mnesia(maps:get(<<"acl_mnesia">>, Data)),
                        import_schemas(maps:get(<<"schemas">>, Data)),
                        emqx_ctl:print("The emqx data has been imported successfully.~n")
                    catch _Class:_Reason:Stack ->
                        emqx_ctl:print("The emqx data import failed due to ~p.~n", [Stack])
                    end;
                Version ->
                    emqx_ctl:print("Unsupported version: ~p~n", [Version])
            end;
        {error, Reason} ->
            emqx_ctl:print("The emqx data import failed due to ~p while reading ~s.~n", [Reason, Filename])
    end;

data(_) ->
    emqx_ctl:usage([{"import <File>",   "Import data from the specified file"},
                    {"export [<Path>]", "Export data to the specified path"}]).

export_rules() ->
    lists:foldl(fun({_, RuleId, _, RawSQL, _, _, _, _, _, Actions, Enabled, Desc}, Acc) ->
                    NActions = [[{id, ActionInstId},
                                 {name, Name},
                                 {args, Args}] || #action_instance{id = ActionInstId, name = Name, args = Args} <- Actions],
                    [[{id, RuleId},
                      {rawsql, RawSQL},
                      {actions, NActions},
                      {enabled, Enabled},
                      {description, Desc}] | Acc]
               end, [], emqx_rule_registry:get_rules()).

export_resources() ->
    lists:foldl(fun({_, Id, Type, Config, CreatedAt, Desc}, Acc) ->
                    NCreatedAt = case CreatedAt of
                                     undefined -> null;
                                     _ -> CreatedAt
                                 end,
                    [[{id, Id},
                      {type, Type},
                      {config, maps:to_list(Config)},
                      {created_at, NCreatedAt},
                      {description, Desc}] | Acc]
               end, [], emqx_rule_registry:get_resources()).

export_blacklist() ->
    lists:foldl(fun(#banned{who = Who, by = By, reason = Reason, at = At, until = Until}, Acc) ->
                    NWho = case Who of
                               {peerhost, Peerhost} -> {peerhost, inet:ntoa(Peerhost)};
                               _ -> Who
                           end,
                    [[{who, [NWho]}, {by, By}, {reason, Reason}, {at, At}, {until, Until}] | Acc]
                end, [], ets:tab2list(emqx_banned)).

export_applications() ->
    lists:foldl(fun({_, AppID, AppSecret, Name, Desc, Status, Expired}, Acc) ->
                    [[{id, AppID}, {secret, AppSecret}, {name, Name}, {desc, Desc}, {status, Status}, {expired, Expired}] | Acc]
                end, [], ets:tab2list(mqtt_app)).

export_users() ->
    lists:foldl(fun({_, Username, Password, Tags}, Acc) ->
                    [[{username, Username}, {password, base64:encode(Password)}, {tags, Tags}] | Acc]
                end, [], ets:tab2list(mqtt_admin)).

export_auth_mnesia() ->
    case ets:info(emqx_user) of
        undefined -> [];
        _ ->
            lists:foldl(fun({_, Login, Password, IsSuperuser}, Acc) ->
                            [[{login, Login}, {password, Password}, {is_superuser, IsSuperuser}] | Acc]
                        end, [], ets:tab2list(emqx_user))
    end.

export_acl_mnesia() ->
    case ets:info(emqx_user) of
        undefined -> [];
        _ ->
            lists:foldl(fun({_, Login, Topic, Action, Allow}, Acc) ->
                            [[{login, Login}, {topic, Topic}, {action, Action}, {allow, Allow}] | Acc]
                        end, [], ets:tab2list(emqx_acl))
    end.

export_schemas() ->
    case ets:info(emqx_schema) of
        undefined -> [];
        _ ->
            [emqx_schema_api:format_schema(Schema) || Schema <- emqx_schema_registry:get_all_schemas()]
    end.

import_rules(Rules) ->
    lists:foreach(fun(#{<<"id">> := RuleId,
                        <<"rawsql">> := RawSQL,
                        <<"actions">> := Actions,
                        <<"enabled">> := Enabled,
                        <<"description">> := Desc}) ->
                      NActions = lists:foldl(fun(#{<<"id">> := ActionInstId, <<"name">> := Name, <<"args">> := Args}, Acc) ->
                                                 [#action_instance{id = ActionInstId, name = any_to_atom(Name), args = Args} | Acc]
                                             end, [], Actions),
                      case emqx_rule_sqlparser:parse_select(RawSQL) of
                          {ok, Select} ->
                              Rule = #rule{id = RuleId,
                                           rawsql = RawSQL,
                                           for = emqx_rule_sqlparser:select_from(Select),
                                           is_foreach = emqx_rule_sqlparser:select_is_foreach(Select),
                                           fields = emqx_rule_sqlparser:select_fields(Select),
                                           doeach = emqx_rule_sqlparser:select_doeach(Select),
                                           incase = emqx_rule_sqlparser:select_incase(Select),
                                           conditions = emqx_rule_sqlparser:select_where(Select),
                                           actions = NActions,
                                           enabled = Enabled,
                                           description = Desc},
                              ok = emqx_rule_registry:add_rule(Rule);
                          Error ->
                              error(Error)
                      end
                  end, Rules).

import_resources(Reources) ->
    lists:foreach(fun(#{<<"id">> := Id,
                        <<"type">> := Type,
                        <<"config">> := Config,
                        <<"created_at">> := CreatedAt,
                        <<"description">> := Desc}) ->
                      NCreatedAt = case CreatedAt of
                                       null -> undefined;
                                       _ -> CreatedAt
                                   end,
                      emqx_rule_registry:add_resource(#resource{id = Id, type = any_to_atom(Type), config = Config, created_at = NCreatedAt, description = Desc})
                  end, Reources).

import_blacklist(Blacklist) ->
    lists:foreach(fun(#{<<"who">> := Who,
                        <<"by">> := By,
                        <<"reason">> := Reason,
                        <<"at">> := At,
                        <<"until">> := Until}) ->
                      NWho = case Who of
                                 #{<<"peerhost">> := Peerhost} ->
                                     {ok, NPeerhost} = inet:parse_address(Peerhost),
                                     {peerhost, NPeerhost};
                                 #{<<"clientid">> := ClientId} -> {clientid, ClientId};
                                 #{<<"username">> := Username} -> {username, Username}
                             end,
                     emqx_banned:create(#banned{who = NWho, by = By, reason = Reason, at = At, until = Until})
                  end, Blacklist).

import_applications(Apps) ->
    lists:foreach(fun(#{<<"id">> := AppID,
                        <<"secret">> := AppSecret,
                        <<"name">> := Name,
                        <<"desc">> := Desc,
                        <<"status">> := Status,
                        <<"expired">> := Expired}) ->
                      NExpired = case is_integer(Expired) of
                                     true -> Expired;
                                     false -> undefined
                                 end,
                      emqx_mgmt_auth:force_add_app(AppID, Name, AppSecret, Desc, Status, NExpired)
                  end, Apps).

import_users(Users) ->
    lists:foreach(fun(#{<<"username">> := Username,
                        <<"password">> := Password,
                        <<"tags">> := Tags}) ->
                      NPassword = base64:decode(Password),
                      emqx_dashboard_admin:force_add_user(Username, NPassword, Tags)
                  end, Users).

import_auth_mnesia(Auths) ->
    case ets:info(emqx_acl) of
        undefined -> ok;
        _ ->
            [ mnesia:dirty_write({emqx_user, Login, Password, IsSuperuser}) || #{<<"login">> := Login,
                                                                                 <<"password">> := Password,
                                                                                 <<"is_superuser">> := IsSuperuser} <- Auths ]
    end.

import_acl_mnesia(Acls) ->
    case ets:info(emqx_acl) of
        undefined -> ok;
        _ ->
            [ mnesia:dirty_write({emqx_acl ,Login, Topic, Action, Allow}) || #{<<"login">> := Login,
                                                                               <<"topic">> := Topic,
                                                                               <<"action">> := Action,
                                                                               <<"allow">> := Allow} <- Acls ]
    end.

import_schemas(Schemas) ->
    case ets:info(emqx_schema) of
        undefined -> ok;
        _ -> [emqx_schema_registry:add_schema(emqx_schema_api:make_schema_params(Schema)) || Schema <- Schemas]
    end.


%%--------------------------------------------------------------------
%% Dump ETS
%%--------------------------------------------------------------------

dump(Table) ->
    dump(Table, Table, ets:first(Table), []).

dump(Table, Tag) ->
    dump(Table, Tag, ets:first(Table), []).

dump(_Table, _, '$end_of_table', Result) ->
    lists:reverse(Result);

dump(Table, Tag, Key, Result) ->
    PrintValue = [print({Tag, Record}) || Record <- ets:lookup(Table, Key)],
    dump(Table, Tag, ets:next(Table, Key), [PrintValue | Result]).

print({_, []}) ->
    ok;

print({client, {ClientId, ChanPid}}) ->
    Attrs = case emqx_cm:get_chan_info(ClientId, ChanPid) of
                undefined -> #{};
                Attrs0 -> Attrs0
            end,
    Stats = case emqx_cm:get_chan_stats(ClientId, ChanPid) of
                undefined -> #{};
                Stats0 -> maps:from_list(Stats0)
            end,
    ClientInfo = maps:get(clientinfo, Attrs, #{}),
    ConnInfo = maps:get(conninfo, Attrs, #{}),
    Session = maps:get(session, Attrs, #{}),
    Connected = case maps:get(conn_state, Attrs) of
                    connected -> true;
                    _ -> false
                end,
    Info = lists:foldl(fun(Items, Acc) ->
                               maps:merge(Items, Acc)
                       end, #{connected => Connected},
                       [maps:with([subscriptions_cnt, inflight_cnt, awaiting_rel_cnt,
                                   mqueue_len, mqueue_dropped, send_msg], Stats),
                        maps:with([clientid, username], ClientInfo),
                        maps:with([peername, clean_start, keepalive, expiry_interval,
                                   connected_at, disconnected_at], ConnInfo),
                        maps:with([created_at], Session)]),
    InfoKeys = [clientid, username, peername,
                clean_start, keepalive, expiry_interval,
                subscriptions_cnt, inflight_cnt, awaiting_rel_cnt, send_msg, mqueue_len, mqueue_dropped,
                connected, created_at, connected_at] ++ case maps:is_key(disconnected_at, Info) of
                                                            true  -> [disconnected_at];
                                                            false -> []
                                                        end,
    emqx_ctl:print("Client(~s, username=~s, peername=~s, "
                    "clean_start=~s, keepalive=~w, session_expiry_interval=~w, "
                    "subscriptions=~w, inflight=~w, awaiting_rel=~w, delivered_msgs=~w, enqueued_msgs=~w, dropped_msgs=~w, "
                    "connected=~s, created_at=~w, connected_at=~w" ++ case maps:is_key(disconnected_at, Info) of
                                                                          true  -> ", disconnected_at=~w)~n";
                                                                          false -> ")~n"
                                                                      end,
                    [format(K, maps:get(K, Info)) || K <- InfoKeys]);

print({emqx_route, #route{topic = Topic, dest = {_, Node}}}) ->
    emqx_ctl:print("~s -> ~s~n", [Topic, Node]);
print({emqx_route, #route{topic = Topic, dest = Node}}) ->
    emqx_ctl:print("~s -> ~s~n", [Topic, Node]);

print(#plugin{name = Name, descr = Descr, active = Active}) ->
    emqx_ctl:print("Plugin(~s, description=~s, active=~s)~n",
                  [Name, Descr, Active]);

print({module, {Name, Active}}) ->
    emqx_ctl:print("Module(~s, description=~s, active=~s)~n",
                  [Name, Name:description(), Active]);

print({emqx_suboption, {{Pid, Topic}, Options}}) when is_pid(Pid) ->
    emqx_ctl:print("~s -> ~s~n", [maps:get(subid, Options), Topic]).

format(_, undefined) ->
    undefined;

format(peername, {IPAddr, Port}) ->
    IPStr = emqx_mgmt_util:ntoa(IPAddr),
    io_lib:format("~s:~p", [IPStr, Port]);

format(_, Val) ->
    Val.

bin(S) -> iolist_to_binary(S).

any_to_atom(L) when is_list(L) -> list_to_atom(L);
any_to_atom(B) when is_binary(B) -> binary_to_atom(B, utf8);
any_to_atom(A) when is_atom(A) -> A.
