-module(tunnel_test_ffi).

%% Raw sockets for the tunnel tests: a unix client for the shim, and a
%% websocket client that never answers pings.

-export([unix_closed_within/2, silent_ws/3, closed_within/2, upgrade/3,
         receives/3]).

%% Connect to the unix socket at Path and say whether the other end closes
%% it within Ms.
unix_closed_within(Path, Ms) ->
    {ok, S} = gen_tcp:connect({local, unicode:characters_to_list(Path)}, 0,
                              [binary, {active, false}], 1000),
    closed_within(S, Ms).

%% Open a websocket at Path on 127.0.0.1:Port with Token, and then ignore
%% everything, pings included.
silent_ws(Port, Path, Token) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000),
    Req = ["GET ", Path, " HTTP/1.1\r\n",
           "Host: 127.0.0.1\r\n",
           "Upgrade: websocket\r\n",
           "Connection: Upgrade\r\n",
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
           "Sec-WebSocket-Version: 13\r\n",
           "Authorization: Bearer ", Token, "\r\n\r\n"],
    ok = gen_tcp:send(S, Req),
    {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(S, 0, 2000),
    S.

%% Read and drop everything until the socket closes, or Ms pass.
closed_within(S, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    drain(S, Deadline).

drain(S, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left =< 0 of
        true -> gen_tcp:close(S), false;
        false ->
            case gen_tcp:recv(S, 0, Left) of
                {ok, _} -> drain(S, Deadline);
                {error, timeout} -> gen_tcp:close(S), false;
                {error, _} -> true
            end
    end.

%% Ask to upgrade Path to a websocket, returning the status and the socket.
upgrade(Port, Path, Token) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000),
    Req = ["GET ", Path, " HTTP/1.1\r\n",
           "Host: 127.0.0.1\r\n",
           "Upgrade: websocket\r\n",
           "Connection: Upgrade\r\n",
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
           "Sec-WebSocket-Version: 13\r\n",
           "Authorization: Bearer ", Token, "\r\n\r\n"],
    ok = gen_tcp:send(S, Req),
    {ok, <<"HTTP/1.1 ", Code:3/binary, _/binary>>} = gen_tcp:recv(S, 0, 2000),
    {binary_to_integer(Code), S}.

%% Whether Needle arrives on S within Ms.
receives(S, Needle, Ms) ->
    receives(S, Needle, Ms, <<>>).

receives(S, Needle, Ms, Acc) ->
    case binary:match(Acc, Needle) of
        {_, _} -> true;
        nomatch ->
            case gen_tcp:recv(S, 0, Ms) of
                {ok, More} -> receives(S, Needle, Ms, <<Acc/binary, More/binary>>);
                {error, _} -> false
            end
    end.
