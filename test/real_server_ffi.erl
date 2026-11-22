-module(real_server_ffi).

%% Run and kill a real `crush server` for the gated end-to-end test.

-export([enabled/0, start/4, kill/1, wait_for_file/2, sh/2, env/2, timeout/2,
         api_key/1, expand_home/1, guarded/2, kill_on_socket/1,
         suspend/1, resume/1, close_socket/1]).

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
%% sees what the test gives it: crush lets CRUSH_<NAME> override <NAME>, so
%% CRUSH_HYPER_API_KEY would take Hyper around the proxy. It runs in Home,
%% not the project: crush loads a .env from its working directory, and the
%% project's .env holds the org's CRUSH_HYPER_API_KEY, which would replace
%% the thread token. Returns the OS pid.
start(Socket, Log, Home, Extra) ->
    Crush = case os:find_executable("crush") of
        false -> error(crush_not_on_path);
        Path -> Path
    end,
    Cmd = io_lib:format("exec '~ts' server --host 'unix://~ts' >>'~ts' 2>&1",
                        [Crush, Socket, Log]),
    Given = [list_to_tuple(string:split(unicode:characters_to_list(E), "="))
             || E <- Extra],
    Names = [N || {N, _} <- Given],
    Cleared = [{N, false} || N <- ["HYPER_URL", "HYPER_API_KEY", "CRUSH_HYPER_URL",
                                   "CRUSH_HYPER_API_KEY", "ANTHROPIC_API_KEY",
                                   "HONCHO_API_KEY"],
                             not lists:member(N, Names)],
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", lists:flatten(Cmd)]},
                      {cd, unicode:characters_to_list(Home)},
                      {env, Cleared ++
                            [{"CRUSH_SERVER_IDLE_TIMEOUT", "600"},
                             {"CRUSH_GLOBAL_CONFIG", unicode:characters_to_list([Home, "/config"])},
                             {"CRUSH_GLOBAL_DATA", unicode:characters_to_list([Home, "/data"])},
                             {"HONCHO_CONFIG_DIR", unicode:characters_to_list([Home, "/honcho"])}
                             | Given]},
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

%% A setting (such as a key) from the environment or the project's .env.
api_key(Name) ->
    case first_set([unicode:characters_to_list(Name)]) of
        {ok, V} -> {ok, unicode:characters_to_binary(V)};
        none -> {error, nil}
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

%% Pause and resume an actor. Messages for it queue up meanwhile.
suspend(Pid) ->
    sys:suspend(Pid),
    nil.

resume(Pid) ->
    sys:resume(Pid),
    nil.

%% Shut down a gun connection's socket from the client's side, as a network
%% drop would; gun then tells the connection's owner it is down.
close_socket(Conn) ->
    #{socket := Socket} = gun:info(Conn),
    ok = gen_tcp:shutdown(Socket, read_write),
    nil.
