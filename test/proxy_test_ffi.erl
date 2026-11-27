-module(proxy_test_ffi).

%% Helpers for the inference proxy tests.

-export([run/5, tmp_dir/0, raw_exchange/2, raw_open/2, raw_close/1,
         trailer_upstream/1, max_queue/1, raw_send/2, raw_read_line/1,
         peer_owner/1, alive/1]).

%% Run Program with Args in Cwd, with Env ("K=V" strings, or "K=" to
%% unset K) on top of this environment. Returns the exit status and the
%% combined output, or times out with status -1.
run(Program, Args, Env, Cwd, TimeoutMs) ->
    Vars = [case string:split(unicode:characters_to_list(E), "=") of
                [K, ""] -> {K, false};
                [K, V] -> {K, V}
            end || E <- Env],
    %% Through sh, with stdin closed: `crush run` reads a prompt from a
    %% piped stdin and would wait for it forever.
    Quoted = [[" '", unicode:characters_to_list(A), "'"] || A <- [Program | Args]],
    Cmd = lists:flatten(["exec", Quoted, " </dev/null"]),
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", Cmd]},
                      {env, Vars}, {cd, unicode:characters_to_list(Cwd)},
                      exit_status, stderr_to_stdout, binary, hide]),
    collect(Port, [], erlang:monotonic_time(millisecond) + TimeoutMs).

collect(Port, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc], Deadline);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after Left ->
        try port_close(Port) catch _:_ -> ok end,
        {-1, iolist_to_binary(lists:reverse(Acc))}
    end.

tmp_dir() ->
    %% unique_integer restarts with each VM; the pid and clock keep runs apart.
    Dir = filename:join("/tmp", lists:concat(["crushling-proxy-", os:getpid(), "-",
                            erlang:system_time(microsecond), "-",
                            erlang:unique_integer([positive])])),
    ok = filelib:ensure_path(Dir),
    unicode:characters_to_binary(Dir).

%% Raw HTTP, for what gun won't send or read the way the tests need.


%% Send Request to 127.0.0.1:Port and return the response's status line.
raw_exchange(Port, Request) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 2000),
    ok = gen_tcp:send(S, Request),
    Line = read_line(S, <<>>),
    gen_tcp:close(S),
    Line.

read_line(S, Acc) ->
    case binary:split(Acc, <<"\r\n">>) of
        [Line, _] -> Line;
        [_] ->
            case gen_tcp:recv(S, 0, 5000) of
                {ok, More} -> read_line(S, <<Acc/binary, More/binary>>);
                {error, _} -> Acc
            end
    end.

%% Send Request on a connection with a tiny receive buffer that is then
%% never read: a client that has stopped reading.
raw_open(Port, Request) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}, {recbuf, 1024}], 2000),
    ok = gen_tcp:send(S, Request),
    Owner = spawn(fun() -> receive stop -> ok end end),
    ok = gen_tcp:controlling_process(S, Owner),
    S.

raw_close(S) ->
    gen_tcp:close(S),
    nil.

%% An upstream that answers every request with Body as one chunk followed
%% by trailers, then keeps the connection open: the trailers are the only
%% sign the response is over.
trailer_upstream(Body) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Owner = spawn(fun() -> accept(L, Body) end),
    ok = gen_tcp:controlling_process(L, Owner),
    Port.

accept(L, Body) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            Pid = spawn(fun() -> receive go -> answer(S, Body) end end),
            ok = gen_tcp:controlling_process(S, Pid),
            Pid ! go,
            accept(L, Body);
        {error, _} -> ok
    end.

answer(S, Body) ->
    _ = read_request(S, <<>>),
    Size = integer_to_binary(byte_size(Body), 16),
    ok = gen_tcp:send(S, [<<"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
                            "transfer-encoding: chunked\r\ntrailer: x-prism-dollar-savings\r\n\r\n">>,
                          Size, <<"\r\n">>, Body, <<"\r\n">>,
                          <<"0\r\nx-prism-dollar-savings: 0.01\r\n\r\n">>]),
    timer:sleep(60000).

read_request(S, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            Length = case re:run(Head, "(?i)content-length: *([0-9]+)", [{capture, [1], binary}]) of
                {match, [N]} -> binary_to_integer(N);
                nomatch -> 0
            end,
            read_rest(S, Length - byte_size(Rest));
        [_] ->
            {ok, More} = gen_tcp:recv(S, 0, 5000),
            read_request(S, <<Acc/binary, More/binary>>)
    end.

read_rest(_, N) when N =< 0 -> ok;
read_rest(S, N) ->
    {ok, More} = gen_tcp:recv(S, 0, 5000),
    read_rest(S, N - byte_size(More)).

%% The longest message queue of any process but Except.
max_queue(Except) ->
    lists:max([0 | [N || P <- erlang:processes(), P =/= Except,
                         {message_queue_len, N} <- [erlang:process_info(P, message_queue_len)]]]).

raw_send(S, Data) ->
    ok = gen_tcp:send(S, Data),
    nil.

raw_read_line(S) ->
    read_line(S, <<>>).

%% The process that owns the server end of the client socket S.
peer_owner(S) ->
    {ok, Local} = inet:sockname(S),
    [Pid | _] = [Owner || P <- erlang:ports(),
                          {name, "tcp_inet"} =:= erlang:port_info(P, name),
                          {ok, Local} =:= inet:peername(P),
                          {connected, Owner} <- [erlang:port_info(P, connected)]],
    Pid.

alive(Pid) ->
    is_process_alive(Pid).
