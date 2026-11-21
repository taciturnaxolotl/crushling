-module(crushling_gun_ffi).

-export([connect_unix/2, connect_tcp/4, request/6, request_capped/6, stream/3, stream/4,
         stream_headers/2, await_stream/3,
         cancel/2, close/1, close_and_flush/1, decode_message/1]).

%% How many chunks gun may send ahead in a capped request.
-define(CAPPED_FLOW, 8).

connect_unix(Path, TimeoutMs) ->
    Opts = #{
        protocols => [http],
        retry => 0,
        http_opts => #{content_handlers => [crushling_sse_h, gun_data_h]}
    },
    case gun:open_unix(unicode:characters_to_list(Path), Opts) of
        {ok, Pid} ->
            case gun:await_up(Pid, TimeoutMs) of
                {ok, _Protocol} ->
                    {ok, Pid};
                {error, Reason} ->
                    gun:close(Pid),
                    {error, reason(Reason)}
            end;
        {error, Reason} ->
            {error, reason(Reason)}
    end.

%% A plain or TLS connection over TCP. TLS verifies the peer against the
%% system trust store and checks the hostname.
connect_tcp(Host, Port, Tls, TimeoutMs) ->
    HostStr = unicode:characters_to_list(Host),
    Base = #{protocols => [http], retry => 0,
             http_opts => #{content_handlers => [gun_data_h]}},
    Opts = case Tls of
        true ->
            Base#{transport => tls,
                  tls_opts => [{verify, verify_peer},
                               {cacerts, public_key:cacerts_get()},
                               {server_name_indication, HostStr},
                               {customize_hostname_check,
                                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]};
        false ->
            Base
    end,
    case gun:open(HostStr, Port, Opts) of
        {ok, Pid} ->
            case gun:await_up(Pid, TimeoutMs) of
                {ok, _} -> {ok, Pid};
                {error, Reason} -> gun:close(Pid), {error, reason(Reason)}
            end;
        {error, Reason} ->
            {error, reason(Reason)}
    end.

request(Pid, Method, Path, Headers, Body, TimeoutMs) ->
    Ref = gun:request(Pid, Method, Path, Headers, Body),
    case gun:await(Pid, Ref, TimeoutMs) of
        {response, fin, Status, RespHeaders} ->
            {ok, {Status, RespHeaders, <<>>}};
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(Pid, Ref, TimeoutMs) of
                {ok, RespBody} ->
                    {ok, {Status, RespHeaders, RespBody}};
                {ok, RespBody, _Trailers} ->
                    {ok, {Status, RespHeaders, RespBody}};
                {error, Reason} ->
                    {error, reason(Reason)}
            end;
        {error, Reason} ->
            gun:cancel(Pid, Ref),
            {error, reason(Reason)}
    end.

%% A request whose body is read only up to Max bytes: past that, or when the
%% response declares more, the stream is cancelled and too_large returned.
%% A redirect's body is not read.
request_capped(Pid, Method, Path, Headers, Max, TimeoutMs) ->
    %% With flow control gun sends at most ?CAPPED_FLOW chunks ahead of what
    %% has been counted, so a fast server can't fill this mailbox.
    Ref = gun:request(Pid, Method, Path, Headers, <<>>, #{flow => ?CAPPED_FLOW}),
    case gun:await(Pid, Ref, TimeoutMs) of
        {response, fin, Status, RespHeaders} ->
            {ok, {Status, RespHeaders, <<>>}};
        {response, nofin, Status, RespHeaders} when Status >= 300, Status < 400 ->
            gun:cancel(Pid, Ref),
            {ok, {Status, RespHeaders, <<>>}};
        {response, nofin, Status, RespHeaders} ->
            case declared_length(RespHeaders) of
                N when is_integer(N), N > Max ->
                    gun:cancel(Pid, Ref),
                    {error, too_large};
                _ ->
                    case collect_capped(Pid, Ref, Max, TimeoutMs, 0, []) of
                        {ok, Body} -> {ok, {Status, RespHeaders, Body}};
                        Error -> Error
                    end
            end;
        {error, Reason} ->
            gun:cancel(Pid, Ref),
            {error, {failed, reason(Reason)}}
    end.

declared_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Value} ->
            try binary_to_integer(string:trim(Value)) catch _:_ -> unknown end;
        false ->
            unknown
    end.

collect_capped(Pid, Ref, Max, TimeoutMs, Size, Acc) ->
    case gun:await(Pid, Ref, TimeoutMs) of
        {data, IsFin, Data} ->
            Total = Size + byte_size(Data),
            if
                Total > Max ->
                    gun:cancel(Pid, Ref),
                    {error, too_large};
                IsFin =:= fin ->
                    {ok, iolist_to_binary(lists:reverse([Data | Acc]))};
                true ->
                    %% Counted and kept: let gun send one more.
                    gun:update_flow(Pid, Ref, 1),
                    collect_capped(Pid, Ref, Max, TimeoutMs, Total, [Data | Acc])
            end;
        {trailers, _} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, Reason} ->
            gun:cancel(Pid, Ref),
            {error, {failed, reason(Reason)}}
    end.

stream(Pid, Path, Headers) ->
    stream(Pid, Path, Headers, none).

%% A stream resumed after LastEventId ({some, Id} or none): the server
%% replays the events after it, or sends a resync.
stream(Pid, Path, Headers, LastEventId) ->
    gun:get(Pid, Path, stream_headers(Headers, LastEventId)).

stream_headers(Headers, LastEventId) ->
    Resume = case LastEventId of
        {some, Id} -> [{<<"last-event-id">>, Id}];
        none -> []
    end,
    [{<<"accept">>, <<"text/event-stream">>} | Resume ++ Headers].

%% Wait for a stream's response status. The events that follow stay in the
%% mailbox for the owner's selector. A refused stream is cancelled, so its
%% body is not delivered.
await_stream(Pid, Ref, TimeoutMs) ->
    case gun:await(Pid, Ref, TimeoutMs) of
        {response, _IsFin, 200, _Headers} ->
            {ok, 200};
        {response, _IsFin, Status, _Headers} ->
            gun:cancel(Pid, Ref),
            {ok, Status};
        {error, Reason} ->
            gun:cancel(Pid, Ref),
            {error, reason(Reason)};
        Other ->
            gun:cancel(Pid, Ref),
            {error, reason({unexpected, Other})}
    end.

cancel(Pid, Ref) ->
    gun:cancel(Pid, Ref),
    nil.

close(Pid) ->
    gun:close(Pid),
    nil.

%% Close, and drop any messages the connection left for this process.
close_and_flush(Pid) ->
    gun:close(Pid),
    gun:flush(Pid),
    nil.

decode_message({gun_sse, Pid, Ref, fin}) ->
    {stream_end, Pid, Ref};
decode_message({gun_sse, Pid, Ref, Event}) when is_map(Event) ->
    Type = maps:get(event_type, Event, <<"message">>),
    %% Only an id the frame itself carried; see crushling_sse_h.
    Id = case maps:find(id, Event) of
        {ok, Value} -> {some, Value};
        error -> none
    end,
    Data = iolist_to_binary(maps:get(data, Event, <<>>)),
    {event, Pid, Ref, {sse_event, Type, Id, Data}};
decode_message({gun_response, Pid, Ref, fin, Status, Headers}) ->
    {stream_response, Pid, Ref, Status, Headers, true};
decode_message({gun_response, Pid, Ref, nofin, Status, Headers}) ->
    {stream_response, Pid, Ref, Status, Headers, false};
decode_message({gun_data, Pid, Ref, IsFin, Data}) ->
    {data, Pid, Ref, Data, IsFin =:= fin};
decode_message({gun_trailers, Pid, Ref, Headers}) ->
    {trailers, Pid, Ref, Headers};
decode_message({gun_error, Pid, Ref, Reason}) ->
    {stream_error, Pid, Ref, reason(Reason)};
decode_message({gun_error, Pid, Reason}) ->
    {conn_down, Pid, reason(Reason)};
decode_message({gun_down, Pid, _Protocol, Reason, _Killed}) ->
    {conn_down, Pid, reason(Reason)};
decode_message(_) ->
    ignored.

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
