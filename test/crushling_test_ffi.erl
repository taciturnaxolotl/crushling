-module(crushling_test_ffi).
-export([listen_unix/1]).

%% Bind a unix socket at Path and keep it open for the rest of the run.
listen_unix(Path) ->
    _ = file:delete(Path),
    case gen_tcp:listen(0, [{ifaddr, {local, unicode:characters_to_list(Path)}}]) of
        {ok, Socket} ->
            Owner = spawn(fun() -> receive stop -> ok end end),
            ok = gen_tcp:controlling_process(Socket, Owner),
            {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.
