-module(crushling_local_ffi).

%% Runs `crush server` directly on this machine, for the local launcher.

-export([start/4, stop/1, wait_for_socket/2]).

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
            Vars = clean_env(Given),
            Port = open_port({spawn_executable, "/bin/sh"},
                             [{args, ["-c", lists:flatten(Cmd)]},
                              {cd, unicode:characters_to_list(Workdir)},
                              {env, Vars},
                              exit_status, hide]),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            unlink(Port),
            {ok, OsPid}
    end.

%% Stop whatever crush server is listening on Socket.
stop(Socket) ->
    os:cmd("pkill -TERM -f 'crush server --host unix://"
           ++ unicode:characters_to_list(Socket) ++ "'"),
    nil.

wait_for_socket(_Path, TimeoutMs) when TimeoutMs =< 0 ->
    {error, <<"crush server did not start">>};
wait_for_socket(Path, TimeoutMs) ->
    P = unicode:characters_to_list(Path),
    case gen_tcp:connect({local, P}, 0, [binary, {active, false}], 200) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            {ok, nil};
        {error, _} ->
            timer:sleep(100),
            wait_for_socket(Path, TimeoutMs - 100)
    end.

-define(KEPT, ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
               "TERM", "TMPDIR", "TZ"]).

clean_env(Given) ->
    Names = [Name || Entry <- os:getenv(),
                     [Name, _] <- [string:split(Entry, "=")]],
    GivenNames = [N || {N, _} <- Given],
    Cleared = [{N, false} || N <- Names,
                             not lists:member(N, ?KEPT),
                             not lists:member(N, GivenNames)],
    Cleared ++ Given.
