-module(crushling_gun_ffi).

-export([connect_unix/2, connect_tcp/4, request/6, stream/3, stream/4,
         stream_headers/2, await_stream/3,
         cancel/2, close/1, decode_message/1]).

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
