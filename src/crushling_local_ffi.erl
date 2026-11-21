-module(crushling_local_ffi).

%% Runs `crush server --dial` directly on this machine, for the local
%% launcher.

-export([start/6, stop/1, alive/1]).

-define(KEPT, ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
               "TERM", "TMPDIR", "TZ"]).

%% Start `crush server --dial DialUrl` with only Env ("K=V" strings) and a
%% few basics from this process's environment, logging to Log. Crush is the
%% binary, or "" for the one on PATH. Returns the OS pid. Everything else is
%% cleared: API keys, HYPER_URL, CRUSH_HYPER_*, a parent crush's sockets and
%% memory settings must not reach an agent driven from Slack.
%%
%% PidFile records the server's identity: its pid, its start time (from
%% `ps -o lstart=`, which doesn't change across the shell's exec) and the
%% dial URL, which names the thread. `stop` only signals a process that
%% still matches all three. Any failure to spawn comes back as an error,
%% so the launch is rolled back.
start(Crush, DialUrl, Workdir, Log, Env, PidFile) ->
    Found = case Crush of
        <<>> -> os:find_executable("crush");
        Path -> unicode:characters_to_list(Path)
    end,
    Dir = unicode:characters_to_list(Workdir),
    case Found of
        false ->
            {error, <<"crush is not on PATH">>};
        Bin ->
            case {executable(Bin), filelib:is_dir(Dir)} of
                {false, _} ->
                    {error, unicode:characters_to_binary(
                              ["not an executable file: ", Bin])};
                {_, false} ->
                    {error, unicode:characters_to_binary(
                              ["no working directory: ", Dir])};
                {true, true} ->
                    spawn_server(Bin, DialUrl, Dir, Log, Env, PidFile)
            end
    end.

executable(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            element(3, Info) =:= regular andalso element(8, Info) band 8#111 =/= 0;
        {error, _} -> false
    end.

spawn_server(Bin, DialUrl, Dir, Log, Env, PidFile) ->
    try
        Cmd = io_lib:format("exec '~ts' server --dial '~ts' >>'~ts' 2>&1",
                            [Bin, DialUrl, Log]),
        Given = [list_to_tuple(string:split(unicode:characters_to_list(E), "="))
                 || E <- Env],
        Port = open_port({spawn_executable, "/bin/sh"},
                         [{args, ["-c", lists:flatten(Cmd)]},
                          {cd, Dir},
                          {env, clean_env(Given)},
                          exit_status, hide]),
        {os_pid, OsPid} = erlang:port_info(Port, os_pid),
        unlink(Port),
        Identity = [integer_to_list(OsPid), "\n", started_at(OsPid), "\n",
                    unicode:characters_to_list(DialUrl), "\n"],
        case file:write_file(PidFile, unicode:characters_to_binary(Identity)) of
            ok -> {ok, OsPid};
            {error, Reason} ->
                signal("KILL", OsPid),
                {error, describe("writing the pid file", Reason)}
        end
    catch
        Class:Error ->
            {error, iolist_to_binary(
                      io_lib:format("could not start crush server: ~p:~p",
                                    [Class, Error]))}
    end.

started_at(OsPid) ->
    string:trim(os:cmd("ps -o lstart= -p " ++ integer_to_list(OsPid))).

clean_env(Given) ->
    Names = [Name || Entry <- os:getenv(),
                     [Name, _] <- [string:split(Entry, "=")]],
    GivenNames = [N || {N, _} <- Given],
    Cleared = [{N, false} || N <- Names,
                             not lists:member(N, ?KEPT),
                             not lists:member(N, GivenNames)],
    Cleared ++ Given.

%% Stop the server recorded in PidFile, if that process is still the one we
%% started: TERM, then KILL after a 20s grace period, then confirm it has
%% exited. Identity (pid, start time, dial URL) is checked again before
%% TERM, before KILL and at every poll, so a reused pid is never signalled.
stop(PidFile) ->
    case file:read_file(PidFile) of
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, describe("reading the pid file", Reason)};
        {ok, Bin} ->
            case string:split(string:trim(unicode:characters_to_list(Bin)), "\n", all) of
                [PidText, Started, Url] ->
                    case string:to_integer(PidText) of
                        {OsPid, ""} when OsPid > 0 ->
                            stop_identified({OsPid, Started, Url}, PidFile);
                        _ -> forget(PidFile)
                    end;
                _ -> forget(PidFile)
            end
    end.

stop_identified({OsPid, _, _} = Id, PidFile) ->
    case same(Id) andalso signal("TERM", OsPid) =:= ok of
        false -> forget(PidFile);
        true ->
            case wait_exit(Id, 200) of
                ok -> forget(PidFile);
                still_running ->
                    case same(Id) andalso signal("KILL", OsPid) =:= ok of
                        false -> forget(PidFile);
                        true ->
                            case wait_exit(Id, 50) of
                                ok -> forget(PidFile);
                                still_running ->
                                    {error, iolist_to_binary(
                                              ["pid ", integer_to_list(OsPid),
                                               " survived SIGKILL"])}
                            end
                    end
            end
    end.

%% Whether the process is still the server we started: the same pid, start
%% time and dial URL (at the end of its command line once crush runs, or
%% quoted in the shell's command just before).
same({OsPid, Started, Url}) ->
    Started =/= "" andalso
        started_at(OsPid) =:= Started andalso
        begin
            Command = string:trim(os:cmd("ps -o command= -p " ++ integer_to_list(OsPid))),
            Dial = "server --dial ",
            lists:suffix(Dial ++ Url, Command) orelse
                string:find(Command, Dial ++ "'" ++ Url ++ "'") =/= nomatch
        end.

signal(Name, OsPid) ->
    _ = os:cmd("kill -" ++ Name ++ " " ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
    ok.

wait_exit(_Id, 0) -> still_running;
wait_exit(Id, Tries) ->
    case same(Id) of
        false -> ok;
        true -> timer:sleep(100), wait_exit(Id, Tries - 1)
    end.

forget(PidFile) ->
    _ = file:delete(PidFile),
    {ok, nil}.

describe(What, Reason) ->
    iolist_to_binary(io_lib:format("~s: ~p", [What, Reason])).

%% Whether the process OsPid is still running.
alive(OsPid) ->
    string:trim(os:cmd("kill -0 " ++ integer_to_list(OsPid) ++ " 2>/dev/null && echo up")) =:= "up".
