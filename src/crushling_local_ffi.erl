-module(crushling_local_ffi).

%% Runs `crush server` directly on this machine, for the local launcher.

-export([start/4, stop/1, wait_until_serving/3]).

-define(KEPT, ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
               "TERM", "TMPDIR", "TZ"]).

%% Start `crush server` on Socket with only Env ("K=V" strings) and a few
%% basics from this process's environment, logging to Log. Returns the OS
%% pid. Everything else is cleared: API keys, HYPER_URL, a parent crush's
%% sockets and memory settings must not reach an agent driven from Slack.
start(Socket, Workdir, Log, Env) ->
    case os:find_executable("crush") of
        false ->
            {error, <<"crush is not on PATH">>};
        Crush ->
            Cmd = io_lib:format("exec '~ts' server --host 'unix://~ts' >>'~ts' 2>&1",
                                [Crush, Socket, Log]),
            Given = [list_to_tuple(string:split(unicode:characters_to_list(E), "="))
                     || E <- Env],
            Port = open_port({spawn_executable, "/bin/sh"},
                             [{args, ["-c", lists:flatten(Cmd)]},
                              {cd, unicode:characters_to_list(Workdir)},
                              {env, clean_env(Given)},
                              exit_status, hide]),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            unlink(Port),
            {ok, OsPid}
    end.

clean_env(Given) ->
    Names = [Name || Entry <- os:getenv(),
                     [Name, _] <- [string:split(Entry, "=")]],
    GivenNames = [N || {N, _} <- Given],
    Cleared = [{N, false} || N <- Names,
                             not lists:member(N, ?KEPT),
                             not lists:member(N, GivenNames)],
    Cleared ++ Given.

%% Stop whatever crush server is listening on Socket and wait until it has
%% exited. One still shutting down keeps the socket: it answers 503, and a
%% server started in its place can't bind. After 20s it is killed, and any
%% socket file left behind is removed.
stop(Socket) ->
    Pattern = "crush server --host unix://" ++ unicode:characters_to_list(Socket),
    _ = os:cmd("pkill -TERM -f '" ++ Pattern ++ "'"),
    wait_gone(Pattern, 200),
    _ = file:delete(Socket),
    nil.

wait_gone(Pattern, 0) ->
    _ = os:cmd("pkill -KILL -f '" ++ Pattern ++ "'"),
    timer:sleep(200);
wait_gone(Pattern, Tries) ->
    case string:trim(os:cmd("pgrep -f '" ++ Pattern ++ "'")) of
        "" -> ok;
        _ -> timer:sleep(100), wait_gone(Pattern, Tries - 1)
    end.

%% Wait until the server we started (OsPid) accepts connections on Path.
%% Fails at once if it exits, rather than mistaking another server's socket
%% for ours.
wait_until_serving(_Path, _OsPid, TimeoutMs) when TimeoutMs =< 0 ->
    {error, <<"crush server did not start">>};
wait_until_serving(Path, OsPid, TimeoutMs) ->
    case string:trim(os:cmd("kill -0 " ++ integer_to_list(OsPid) ++ " 2>/dev/null && echo up")) of
        "up" ->
            P = unicode:characters_to_list(Path),
            case gen_tcp:connect({local, P}, 0, [binary, {active, false}], 200) of
                {ok, Sock} ->
                    gen_tcp:close(Sock),
                    {ok, nil};
                {error, _} ->
                    timer:sleep(100),
                    wait_until_serving(Path, OsPid, TimeoutMs - 100)
            end;
        _ ->
            {error, <<"crush server exited while starting; see server.log">>}
    end.
