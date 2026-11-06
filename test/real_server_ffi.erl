-module(real_server_ffi).

%% Run and kill a real `crush server` for the gated end-to-end test.

-export([enabled/0, start/3, kill/1, wait_for_file/2, sh/2, env/2, timeout/2,
         isolated_config/4, guarded/2, kill_on_socket/1]).

enabled() ->
    case os:getenv("CRUSHLING_REAL") of
        false -> false;
        "" -> false;
        "0" -> false;
        _ -> true
    end.

env(Name, Default) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> Default;
        Value -> unicode:characters_to_binary(Value)
    end.

%% Start `crush server` on Socket, logging to Log, with its global config
%% and data in Home. Returns the OS pid.
start(Socket, Log, Home) ->
    Crush = case os:find_executable("crush") of
        false -> error(crush_not_on_path);
        Path -> Path
    end,
    Cmd = io_lib:format("exec '~ts' server --host 'unix://~ts' >>'~ts' 2>&1",
                        [Crush, Socket, Log]),
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", lists:flatten(Cmd)]},
                      {env, [{"CRUSH_SERVER_IDLE_TIMEOUT", "600"},
                             {"HYPER_URL", hyper_url()},
                             {"CRUSH_GLOBAL_CONFIG", unicode:characters_to_list([Home, "/config"])},
                             {"CRUSH_GLOBAL_DATA", unicode:characters_to_list([Home, "/data"])}]},
                      exit_status, hide]),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    unlink(Port),
    OsPid.

kill(OsPid) ->
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    nil.

%% Wait until Path exists and accepts a connection.
wait_for_file(Path, TimeoutMs) when TimeoutMs =< 0 ->
    error({never_appeared, Path});
wait_for_file(Path, TimeoutMs) ->
    P = unicode:characters_to_list(Path),
    case gen_tcp:connect({local, P}, 0, [binary, {active, false}], 200) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            nil;
        {error, _} ->
            timer:sleep(100),
            wait_for_file(Path, TimeoutMs - 100)
    end.

sh(Dir, Command) ->
    Cmd = io_lib:format("cd '~ts' && ~ts 2>&1", [Dir, Command]),
    unicode:characters_to_binary(os:cmd(lists:flatten(Cmd))).

%% An EUnit test with its own timeout in seconds.
timeout(Seconds, Fun) ->
    {timeout, Seconds, Fun}.

%% Write a global config into Home holding only Provider, with the given
%% large and small models. Keeps the user's MCP servers, skills and context
%% files out of the test prompt.
%%
%% The provider's settings are copied from the user's real data config, but
%% never its credentials: OAuth refresh tokens are single use, so a copy that
%% refreshes would revoke the user's real login. The key comes from
%% CRUSHLING_TEST_API_KEY or CRUSH_<PROVIDER>_API_KEY instead, from the
%% environment or the project's .env.
isolated_config(Home, Provider, Large, Small) ->
    ProviderVar = "CRUSH_" ++ string:uppercase(unicode:characters_to_list(Provider)) ++ "_API_KEY",
    Key = case first_set(["CRUSHLING_TEST_API_KEY", ProviderVar]) of
        none -> error({set_one_of, ["CRUSHLING_TEST_API_KEY", ProviderVar]});
        {ok, K} -> unicode:characters_to_binary(K)
    end,
    Real = filename:join([os:getenv("HOME"), ".local/share/crush"]),
    Entry0 = case file:read_file(filename:join(Real, "crush.json")) of
        {ok, Bin} ->
            maps:get(Provider, maps:get(<<"providers">>, json:decode(Bin), #{}), #{});
        {error, _} ->
            #{}
    end,
    Entry = (maps:without([<<"oauth">>, <<"api_key">>], Entry0))#{<<"api_key">> => Key},
    Pick = fun(Model) ->
        #{<<"provider">> => Provider, <<"model">> => Model, <<"max_tokens">> => 8192}
    end,
    Config = #{<<"providers">> => #{Provider => Entry},
               <<"models">> => #{<<"large">> => Pick(Large), <<"small">> => Pick(Small)}},
    Data = filename:join(Home, "data"),
    ok = filelib:ensure_path(filename:join(Home, "config")),
    ok = filelib:ensure_path(Data),
    ok = file:change_mode(Home, 8#700),
    Path = filename:join(Data, "crush.json"),
    ok = file:write_file(Path, json:encode(Config)),
    ok = file:change_mode(Path, 8#600),
    %% The provider catalog, so the server needn't fetch it.
    Catalog = filename:join(Real, "providers.json"),
    case filelib:is_file(Catalog) of
        true -> {ok, _} = file:copy(Catalog, filename:join(Data, "providers.json"));
        false -> ok
    end,
    nil.

first_set(Names) ->
    Dotenv = dotenv(".env"),
    Found = [V || N <- Names,
                  V <- [case os:getenv(N) of
                            false -> proplists:get_value(N, Dotenv, "");
                            Value -> Value
                        end],
                  V =/= ""],
    case Found of
        [V | _] -> {ok, V};
        [] -> none
    end.

dotenv(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = string:split(unicode:characters_to_list(Bin), "\n", all),
            [{string:trim(K), unquote(string:trim(V))}
             || Line <- Lines,
                [K, V] <- [string:split(Line, "=")],
                not lists:prefix("#", string:trim(K))];
        {error, _} ->
            []
    end.

unquote([$" | Rest]) -> string:trim(Rest, trailing, "\"");
unquote([$' | Rest]) -> string:trim(Rest, trailing, "'");
unquote(Value) -> Value.

%% Hyper's base URL for the test server, from HYPER_URL in the environment
%% or .env. Unset (false) leaves crush on its production default.
hyper_url() ->
    case first_set(["HYPER_URL"]) of
        {ok, Url} -> Url;
        none -> false
    end.

%% Run Body, then Cleanup even if Body fails, re-raising the failure.
guarded(Body, Cleanup) ->
    try Body() after Cleanup() end.

%% Kill every server listening on Socket, whichever restart started it.
kill_on_socket(Socket) ->
    os:cmd("pkill -9 -f 'crush server --host unix://" ++ unicode:characters_to_list(Socket) ++ "'"),
    nil.
