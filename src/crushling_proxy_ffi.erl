-module(crushling_proxy_ffi).

%% The upstream side of the inference proxy, and helpers for its downstream
%% side and for metering.

-export([request/6, update_flow/3, split_lines/1, socket/1, wait_closed/1,
         loopback/1]).

%% One request on a gun connection opened with
%% crushling_gun_ffi:connect_tcp/4. The calling process receives the
%% response as gun messages, at most Flow body messages ahead of
%% update_flow/3.
request(Pid, Method, Path, Headers, Body, Flow) ->
    gun:request(Pid, Method, Path, Headers, Body, #{flow => Flow}).

update_flow(Pid, Ref, Flow) ->
    gun:update_flow(Pid, Ref, Flow),
    nil.

%% The complete lines in Data, and the bytes after the last newline.
split_lines(Data) ->
    Parts = binary:split(Data, <<"\n">>, [global]),
    [Rest | RevLines] = lists:reverse(Parts),
    {lists:reverse(RevLines), Rest}.

%% The socket under a mist connection.
socket(Connection) ->
    element(3, Connection).

%% Block until the peer closes Socket. Only for a passive TCP socket whose
%% request has been read in full: a client sends nothing more while its
%% response is being written, and any stray bytes are dropped. Other
%% sockets are never reported closed.
wait_closed(Socket) when is_port(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, _} -> wait_closed(Socket);
        {error, einval} -> receive after infinity -> nil end;
        {error, _} -> nil
    end;
wait_closed(_) ->
    receive after infinity -> nil end.

%% Whether Host is "localhost" or parses as an address in 127.0.0.0/8 or
%% ::1. Names that merely look like addresses are not loopback.
loopback(<<"localhost">>) -> true;
loopback(Host) ->
    Bare = string:trim(unicode:characters_to_list(Host), both, "[]"),
    case inet:parse_strict_address(Bare) of
        {ok, {127, _, _, _}} -> true;
        {ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true;
        _ -> false
    end.
