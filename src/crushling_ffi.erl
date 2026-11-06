-module(crushling_ffi).

-export([line_at/2, uuid_v4/0, monotonic_ms/0, log_warning/1, exec/3, sha256_hex/1,
         file_exists/1, mkdir_p/1, write_private/2]).

line_at(Lines, Index) ->
    element(Index + 1, Lines).

uuid_v4() ->
    <<A:32, B:16, _:4, C:12, _:2, D:62>> = crypto:strong_rand_bytes(16),
    Bin = <<A:32, B:16, 4:4, C:12, 2:2, D:62>>,
    <<P1:8/binary, P2:4/binary, P3:4/binary, P4:4/binary, P5:12/binary>> =
        binary:encode_hex(Bin, lowercase),
    <<P1/binary, "-", P2/binary, "-", P3/binary, "-", P4/binary, "-", P5/binary>>.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

log_warning(Text) ->
    logger:warning("~ts", [Text]),
    nil.

sha256_hex(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

file_exists(Path) ->
    filelib:is_file(Path).

%% Run a program without a shell and collect its combined output. The
%% process is killed if it outlives the timeout.
exec(Program, Args, TimeoutMs) ->
    case os:find_executable(unicode:characters_to_list(Program)) of
        false ->
            {error, <<"not found: ", Program/binary>>};
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, Args}, binary, exit_status,
                              stderr_to_stdout, use_stdio, hide]),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            collect(Port, Deadline, [])
    end.

collect(Port, Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            collect(Port, Deadline, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {ok, {Status, iolist_to_binary(lists:reverse(Acc))}}
    after Left ->
        case erlang:port_info(Port, os_pid) of
            {os_pid, OsPid} -> os:cmd("kill -9 " ++ integer_to_list(OsPid));
            undefined -> ok
        end,
        try port_close(Port) catch _:_ -> ok end,
        {error, <<"timed out">>}
    end.

mkdir_p(Path) ->
    case filelib:ensure_path(Path) of
        ok -> {ok, nil};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

write_private(Path, Content) ->
    Tmp = <<Path/binary, ".tmp">>,
    case file:write_file(Tmp, Content) of
        ok ->
            _ = file:change_mode(Tmp, 8#600),
            case file:rename(Tmp, Path) of
                ok -> {ok, nil};
                {error, R} -> {error, unicode:characters_to_binary(io_lib:format("~p", [R]))}
            end;
        {error, R} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [R]))}
    end.
