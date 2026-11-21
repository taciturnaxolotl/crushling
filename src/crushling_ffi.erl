-module(crushling_ffi).

-export([line_at/2, uuid_v4/0, monotonic_ms/0, system_ms/0, log_warning/1, log_info/1, exec/3, sha256_hex/1,
         hmac_sha256_hex/2, equal_constant_time/2,
         file_exists/1, is_socket/1, file_stamp/1, mkdir_p/1, write_private/2, getenv/1, expand_home/1,
         read_file/1, write_bytes/2, list_dir/1, delete_file/1, is_loopback/1]).

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

hmac_sha256_hex(Secret, Data) ->
    binary:encode_hex(crypto:mac(hmac, sha256, Secret, Data), lowercase).

equal_constant_time(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
equal_constant_time(_, _) ->
    false.

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

%% Replace a file whole with a private one: the temporary file is made
%% empty and set to 0600 before any content goes in, so a secret is never
%% readable by others, even for a moment.
write_private(Path, Content) ->
    Tmp = <<Path/binary, ".tmp">>,
    _ = file:delete(Tmp),
    Steps = fun() ->
        ok = file:write_file(Tmp, <<>>, [write, exclusive]),
        ok = file:change_mode(Tmp, 8#600),
        ok = file:write_file(Tmp, Content),
        ok = file:rename(Tmp, Path)
    end,
    try Steps() of
        ok -> {ok, nil}
    catch
        error:{badmatch, {error, R}} ->
            _ = file:delete(Tmp),
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

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% Whether Host is a loopback IP address, written as one (no name lookup).
is_loopback(Host) ->
    Bare = string:trim(unicode:characters_to_list(Host), both, "[]"),
    case inet:parse_strict_address(Bare) of
        {ok, {127, _, _, _}} -> true;
        {ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true;
        {ok, {0, 0, 0, 0, 0, 16#ffff, A, _}} -> A bsr 8 =:= 127;
        _ -> false
    end.

delete_file(Path) ->
    _ = file:delete(Path),
    nil.

list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, [unicode:characters_to_binary(N) || N <- Names]};
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
