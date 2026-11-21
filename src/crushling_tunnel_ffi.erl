-module(crushling_tunnel_ffi).

-include_lib("kernel/include/file.hrl").

%% Unix sockets for the tunnel's shim, and the websocket control frames mist
%% has no public API for.

-export([listen/2, identity/1, remove_if_same/2, serve/5, send/2, close/1, active_once/1,
         ws_ping/1, ws_close/3, ws_received/1]).

%% Listen on a unix socket at Path, replacing a stale socket file. A write
%% to an accepted connection that blocks for SendTimeout ms fails and
%% closes it, so a reader that stops reading can't wedge the writer.
listen(Path, SendTimeout) ->
    P = unicode:characters_to_list(Path),
    _ = file:delete(P),
    case gen_tcp:listen(0, [binary, {ifaddr, {local, P}}, {active, false},
                            {packet, raw}, {backlog, 128},
                            {send_timeout, SendTimeout},
                            {send_timeout_close, true}]) of
        {ok, Listen} -> {ok, Listen};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% What makes the socket file at Path this listener's: its inode and
%% change time, recorded right after binding, plus a token registered for
%% the path in this VM. Inodes are reused and change times only have
%% second resolution, so the token tells apart two sockets bound at the
%% same path in the same second.
identity(Path) ->
    case file_identity(Path) of
        {ok, {Inode, Ctime}} ->
            Token = make_ref(),
            persistent_term:put({crushling_shim, Path}, Token),
            {ok, {Inode, Ctime, Token}};
        error -> {error, nil}
    end.

file_identity(Path) ->
    case file:read_file_info(unicode:characters_to_list(Path),
                             [raw, {time, posix}]) of
        {ok, Info} ->
            {ok, {element(#file_info.inode, Info), element(#file_info.ctime, Info)}};
        {error, _} -> error
    end.

%% Delete the socket file at Path only if it is still the one with
%% Identity, so an old listener never removes its replacement's socket.
remove_if_same(Path, {Inode, Ctime, Token}) ->
    Key = {crushling_shim, Path},
    case {file_identity(Path), persistent_term:get(Key, undefined)} of
        {{ok, {Inode, Ctime}}, Token} ->
            _ = file:delete(unicode:characters_to_list(Path)),
            _ = persistent_term:erase(Key);
        _ -> ok
    end,
    nil.

%% Accept connections on Listen, running Handle(Socket) in a process that
%% owns the socket. Connections are linked to this process, which traps
%% exits so one dying takes down neither the listener nor its siblings,
%% while the listener dying (killed, or Owner gone) takes them all down.
%% Whenever it stops short of being killed, it removes its socket file if
%% the file is still its own.
serve(Listen, Handle, Owner, Path, Identity) ->
    process_flag(trap_exit, true),
    Ref = erlang:monitor(process, Owner),
    try accept_loop(Listen, Handle, Ref)
    after remove_if_same(Path, Identity)
    end.

accept_loop(Listen, Handle, Ref) ->
    case gen_tcp:accept(Listen, 500) of
        {ok, Socket} ->
            Pid = spawn_link(fun() ->
                receive {crushling_shim_owned, Socket} -> Handle(Socket) end
            end),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok -> Pid ! {crushling_shim_owned, Socket};
                {error, _} -> gen_tcp:close(Socket), exit(Pid, kill)
            end;
        {error, timeout} -> ok;
        {error, closed} -> exit(shutdown);
        {error, _} -> timer:sleep(100)
    end,
    housekeeping(Ref),
    accept_loop(Listen, Handle, Ref).

%% Drop connections' exit messages; stop with the owner.
housekeeping(Ref) ->
    receive
        {'DOWN', Ref, process, _, _} -> exit(shutdown);
        {'EXIT', _, _} -> housekeeping(Ref)
    after 0 -> ok
    end.

send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

close(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.

active_once(Socket) ->
    case inet:setopts(Socket, [{active, once}]) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% mist's websocket connection is {websocket_connection, Socket, Transport,
%% Deflate}; control frames are never compressed, so they can be written
%% straight to the socket.
ws_ping({websocket_connection, Socket, Transport, _}) ->
    _ = 'glisten@transport':send(Transport, Socket,
                                 'gramps@websocket':encode_ping_frame(<<>>, none)),
    nil.

%% Send a close frame with Code and Reason, then stop writing, so the close
%% mist sends when the handler stops goes nowhere.
ws_close({websocket_connection, Socket, Transport, _}, Code, Reason) ->
    Frame = 'gramps@websocket':encode_close_frame(
              {custom_close_reason, Code, Reason}, none),
    _ = 'glisten@transport':send(Transport, Socket, Frame),
    _ = case Transport of
        tcp -> gen_tcp:shutdown(Socket, write);
        ssl -> ssl:shutdown(Socket, write)
    end,
    nil.

%% Bytes received on the websocket's socket so far.
ws_received({websocket_connection, Socket, Transport, _}) ->
    Stats = case Transport of
        tcp -> inet:getstat(Socket, [recv_oct]);
        ssl -> ssl:getstat(Socket, [recv_oct])
    end,
    case Stats of
        {ok, [{recv_oct, N}]} -> N;
        _ -> 0
    end.
