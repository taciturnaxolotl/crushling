-module(lying_server_ffi).
-export([start/2, raw/2, start_echo/0, start_redirect/1]).

%% An HTTP server on 127.0.0.1 that answers every request with Total bytes
%% of body. With Declared = chunked it sends them chunked, a MiB at a time,
%% without a length; otherwise it declares Declared as the Content-Length.
%% Returns the port.
start(Declared, Total) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Owner = spawn(fun() -> accept(Listen, Declared, Total) end),
    ok = gen_tcp:controlling_process(Listen, Owner),
    Port.

%% A server that answers with the request's head as its body.
start_echo() ->
    listen(fun(Socket) ->
        Head = read_head(Socket, <<>>),
        _ = gen_tcp:send(Socket, [<<"HTTP/1.1 200 OK\r\ncontent-length: ">>,
                                 integer_to_binary(byte_size(Head)), <<"\r\n\r\n">>, Head])
    end).

%% A server that redirects every request to Location.
start_redirect(Location) ->
    listen(fun(Socket) ->
        _ = read_head(Socket, <<>>),
        _ = gen_tcp:send(Socket, [<<"HTTP/1.1 302 Found\r\nlocation: ">>, Location,
                                 <<"\r\ncontent-length: 0\r\n\r\n">>])
    end).

listen(Serve) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Owner = spawn(fun() -> accept_with(Listen, Serve) end),
    ok = gen_tcp:controlling_process(Listen, Owner),
    Port.

accept_with(Listen, Serve) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Pid = spawn(fun() -> receive go -> Serve(Socket), gen_tcp:close(Socket) end end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! go,
            accept_with(Listen, Serve);
        {error, _} ->
            ok
    end.

accept(Listen, Declared, Total) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Pid = spawn(fun() -> receive go -> serve(Socket, Declared, Total) end end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! go,
            accept(Listen, Declared, Total);
        {error, _} ->
            ok
    end.

serve(Socket, Declared, Total) ->
    _ = read_head(Socket, <<>>),
    case Declared of
        chunked ->
            _ = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n">>),
            send_chunks(Socket, Total);
        {length, Length} ->
            _ = gen_tcp:send(Socket, [<<"HTTP/1.1 200 OK\r\ncontent-length: ">>,
                                     integer_to_binary(Length), <<"\r\n\r\n">>]),
            _ = gen_tcp:send(Socket, binary:copy(<<"x">>, Total))
    end,
    gen_tcp:close(Socket).

send_chunks(Socket, 0) ->
    gen_tcp:send(Socket, <<"0\r\n\r\n">>);
send_chunks(Socket, Left) ->
    Size = min(Left, 1048576),
    Chunk = [integer_to_binary(Size, 16), <<"\r\n">>, binary:copy(<<"x">>, Size), <<"\r\n">>],
    case gen_tcp:send(Socket, Chunk) of
        ok -> send_chunks(Socket, Left - Size);
        {error, _} -> ok
    end.

read_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> read_head(Socket, <<Acc/binary, Data/binary>>);
                {error, _} -> Acc
            end;
        _ -> Acc
    end.

%% Send Request as is to 127.0.0.1:Port and return the response's status
%% line.
raw(Port, Request) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, Request),
    Reply = recv_line(Socket, <<>>),
    gen_tcp:close(Socket),
    Reply.

recv_line(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n">>) of
        [Line, _] -> Line;
        _ ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> recv_line(Socket, <<Acc/binary, Data/binary>>);
                {error, _} -> Acc
            end
    end.
