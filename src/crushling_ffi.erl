-module(crushling_ffi).

-export([line_at/2, uuid_v4/0, monotonic_ms/0, system_ms/0, log_warning/1, log_info/1, exec/3, sha256_hex/1,
         file_exists/1, is_socket/1, file_stamp/1, mkdir_p/1, write_private/2, getenv/1, expand_home/1,
         claude_version/0, read_file/1, write_bytes/2]).

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

system_ms() ->
    erlang:system_time(millisecond).

%% Logged at notice, the lowest level the default handler prints.
log_info(Text) ->
    logger:notice("~ts", [Text]),
    nil.

log_warning(Text) ->
    logger:warning("~ts", [Text]),
    nil.

sha256_hex(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

%% A file's size and modification time, which change when it is replaced.
file_stamp(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} ->
            {ok, unicode:characters_to_binary(io_lib:format("~b-~b", [element(2, Info), element(6, Info)]))};
        {error, _} -> {error, nil}
    end.

%% Whether something listens-capable exists at Path: filelib:is_file/1 is
%% false for a unix socket.
is_socket(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(3, Info) =:= other;
        {error, _} -> false
    end.

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

%% A setting from the environment, else from ./.env.
getenv(Name) ->
    N = unicode:characters_to_list(Name),
    case os:getenv(N) of
        false -> dotenv(N);
        "" -> dotenv(N);
        V -> {ok, unicode:characters_to_binary(V)}
    end.

dotenv(Name) ->
    case file:read_file(".env") of
        {ok, Bin} ->
            Lines = string:split(unicode:characters_to_list(Bin), "\n", all),
            Found = [unquote(string:trim(V))
                     || Line <- Lines,
                        [K, V] <- [string:split(Line, "=")],
                        string:trim(K) =:= Name],
            case [V || V <- Found, V =/= ""] of
                [V | _] -> {ok, unicode:characters_to_binary(V)};
                [] -> {error, nil}
            end;
        {error, _} ->
            {error, nil}
    end.

unquote([$" | Rest]) -> string:trim(Rest, trailing, "\"");
unquote([$' | Rest]) -> string:trim(Rest, trailing, "'");
unquote(Value) -> Value.

expand_home(<<"~/", Rest/binary>>) ->
    unicode:characters_to_binary([os:getenv("HOME"), "/", Rest]);
expand_home(Path) ->
    Path.

%% The installed Claude Code's version, or crush's floor without one.
claude_version() ->
    case os:find_executable("claude") of
        false -> <<"2.1.282">>;
        Claude ->
            Out = os:cmd(Claude ++ " --version 2>/dev/null"),
            case re:run(Out, "[0-9]+\\.[0-9]+\\.[0-9]+", [{capture, first, binary}]) of
                {match, [V]} -> V;
                nomatch -> <<"2.1.282">>
            end
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% Write bytes, creating the parent directory.
write_bytes(Path, Bytes) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Bytes) of
                ok -> {ok, nil};
                {error, R} -> {error, unicode:characters_to_binary(io_lib:format("~p", [R]))}
            end;
        {error, R} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [R]))}
    end.
