-module(crushling_gun_ffi).

-export([connect_unix/2, request/6, stream/3, cancel/2, close/1,
         decode_message/1]).

connect_unix(Path, TimeoutMs) ->
    Opts = #{
        protocols => [http],
        retry => 0,
        http_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
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
    gun:get(Pid, Path, [{<<"accept">>, <<"text/event-stream">>} | Headers]).

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
    Id = case maps:get(last_event_id, Event, <<>>) of
        <<>> -> none;
        LastId -> {some, LastId}
    end,
    Data = iolist_to_binary(maps:get(data, Event, <<>>)),
    {event, Pid, Ref, {sse_event, Type, Id, Data}};
decode_message({gun_response, Pid, Ref, fin, Status, Headers}) ->
    {stream_response, Pid, Ref, Status, Headers, true};
decode_message({gun_response, Pid, Ref, nofin, Status, Headers}) ->
    {stream_response, Pid, Ref, Status, Headers, false};
decode_message({gun_data, Pid, Ref, IsFin, Data}) ->
    {data, Pid, Ref, Data, IsFin =:= fin};
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
