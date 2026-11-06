-module(real_server_ffi).

%% Run and kill a real `crush server` for the gated end-to-end test.

-export([enabled/0, start/4, kill/1, wait_for_file/2, sh/2, env/2, timeout/2,
         api_key/1, claude_version/0, expand_home/1, guarded/2, kill_on_socket/1]).

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
%% and data in Home and Extra ("K=V" strings) in its environment. Provider
%% variables from the caller's environment are cleared so the server only
%% sees what the test gives it. Returns the OS pid.
start(Socket, Log, Home, Extra) ->
    Crush = case os:find_executable("crush") of
        false -> error(crush_not_on_path);
        Path -> Path
    end,
    Cmd = io_lib:format("exec '~ts' server --host 'unix://~ts' >>'~ts' 2>&1",
                        [Crush, Socket, Log]),
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", lists:flatten(Cmd)]},
                      {env, [{"HYPER_URL", false}, {"HYPER_API_KEY", false},
                             {"ANTHROPIC_API_KEY", false},
                             {"CRUSH_SERVER_IDLE_TIMEOUT", "600"},
                             {"CRUSH_GLOBAL_CONFIG", unicode:characters_to_list([Home, "/config"])},
                             {"CRUSH_GLOBAL_DATA", unicode:characters_to_list([Home, "/data"])},
                             {"HONCHO_CONFIG_DIR", unicode:characters_to_list([Home, "/honcho"])},
                             {"HONCHO_API_KEY", false}
                             | [list_to_tuple(string:split(unicode:characters_to_list(E), "="))
                                || E <- Extra]]},
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

%% A key from the environment or the project's .env.
api_key(Name) ->
    case first_set([unicode:characters_to_list(Name)]) of
        {ok, V} -> {ok, unicode:characters_to_binary(V)};
        none -> {error, nil}
    end.

%% The installed Claude Code's version, or crush's floor without one.
claude_version() ->
    case first_set(["CRUSHLING_CLAUDE_VERSION"]) of
        {ok, V} -> unicode:characters_to_binary(V);
        none ->
            case os:find_executable("claude") of
                false -> <<"2.1.282">>;
                Claude ->
                    Out = os:cmd(Claude ++ " --version 2>/dev/null"),
                    case re:run(Out, "[0-9]+\\.[0-9]+\\.[0-9]+", [{capture, first, binary}]) of
                        {match, [V]} -> V;
                        nomatch -> <<"2.1.282">>
                    end
            end
    end.

expand_home(<<"~/", Rest/binary>>) ->
    unicode:characters_to_binary([os:getenv("HOME"), "/", Rest]);
expand_home(Path) ->
    Path.

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

%% Run Body, then Cleanup even if Body fails, re-raising the failure.
guarded(Body, Cleanup) ->
    try Body() after Cleanup() end.

%% Kill every server listening on Socket, whichever restart started it.
kill_on_socket(Socket) ->
    os:cmd("pkill -9 -f 'crush server --host unix://" ++ unicode:characters_to_list(Socket) ++ "'"),
    nil.
