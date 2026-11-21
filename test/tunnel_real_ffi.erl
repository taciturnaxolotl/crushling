-module(tunnel_real_ffi).

%% Run a real `crush server --dial` for the gated tunnel test.

-export([crush/0, start/5, wait_exit/2, kill/1]).

%% The crush to test: $CRUSHLING_TUNNEL_CRUSH, else the dev build.
crush() ->
    case os:getenv("CRUSHLING_TUNNEL_CRUSH") of
        V when V =:= false; V =:= "" ->
            unicode:characters_to_binary(
              [os:getenv("HOME"), "/.local/state/crushling-dev/crush"]);
        V -> unicode:characters_to_binary(V)
    end.

%% Start Crush dialing Url with Token, its config and data in Home, logging
%% to Log, in a process that holds the port and exits with
%% {crush_exit, Status} when crush does. Returns {Pid, OsPid}.
start(Crush, Url, Token, Home, Log) ->
    Cmd = io_lib:format("exec '~ts' server --dial '~ts' >>'~ts' 2>&1",
                        [Crush, Url, Log]),
    H = unicode:characters_to_list(Home),
    Parent = self(),
    Pid = spawn(fun() ->
        Port = open_port({spawn_executable, "/bin/sh"},
                         [{args, ["-c", lists:flatten(Cmd)]},
                          {cd, H},
                          {env, [{"CRUSH_SERVER_DIAL_TOKEN", unicode:characters_to_list(Token)},
                                 {"HYPER_URL", false}, {"HYPER_API_KEY", false},
                                 {"ANTHROPIC_API_KEY", false},
                                 {"CRUSH_GLOBAL_CONFIG", H ++ "/config"},
                                 {"CRUSH_GLOBAL_DATA", H ++ "/data"},
                                 {"HONCHO_CONFIG_DIR", H ++ "/honcho"},
                                 {"HONCHO_API_KEY", false}]},
                          exit_status, hide]),
        {os_pid, OsPid} = erlang:port_info(Port, os_pid),
        Parent ! {tunnel_real_os_pid, self(), OsPid},
        receive {Port, {exit_status, Status}} -> exit({crush_exit, Status}) end
    end),
    receive {tunnel_real_os_pid, Pid, OsPid} -> {Pid, OsPid} end.

%% crush's exit status, if it exits within Ms.
wait_exit(Pid, Ms) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, {crush_exit, Status}} -> {ok, Status};
        {'DOWN', Ref, process, Pid, _} -> {error, nil}
    after Ms ->
        erlang:demonitor(Ref, [flush]),
        {error, nil}
    end.

kill(OsPid) ->
    os:cmd("kill -9 " ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
    nil.
