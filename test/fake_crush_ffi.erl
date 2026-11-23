-module(fake_crush_ffi).

%% A fake `crush server` on a unix socket, enough for a thread actor to
%% connect, prompt, and stream events. The test pushes SSE frames to the
%% open event stream and can drop it. The process that started the server
%% gets a `{fake_crush, Kind, Value}` message for each request that matters:
%%
%%   created           POST /v1/workspaces
%%   got               GET /v1/workspaces/{id}
%%   events            GET .../events, attached; Value is the Last-Event-ID
%%                     or <<>>
%%   refused           GET .../events answered 404 (the workspace is gone)
%%   prompt            POST .../agent; Value is the run id
%%   busy              GET .../agent/sessions/{id}
%%   model             POST .../agent/sessions/{id}/model; Value is the
%%                     selection, decoded
%%   providers         GET .../providers
%%
%% Its catalog (GET .../providers) has three Hyper models: `alpha`, with
%% effort levels, `beta`, which can only toggle thinking, and `broken`,
%% which crush lists but can't build. The session runs `alpha` until a pin
%% says otherwise; pinning `broken` or a model not in the catalog is
%% refused, as crush does.
%%
%% `next/1` receives them.

-export([start/1, stop/1, push/2, drop/1, set_busy/2, set_exists/2,
         expire_on_get/1, next/1, suspend/1, resume/1]).

-define(WS, <<"w1">>).
-define(SESSION, <<"s1">>).

start(Path) ->
    P = unicode:characters_to_list(Path),
    _ = file:delete(P),
    Owner = self(),
    Ctl = spawn(fun() -> ctl_init(Owner, P) end),
    receive
        {Ctl, ready} -> Ctl
    after 5000 -> error(fake_crush_not_ready)
    end.

stop(Ctl) ->
    Ctl ! stop,
    nil.

%% Write a raw SSE frame (e.g. <<"id: e-1\ndata: {...}\n\n">>) to the open
%% event stream.
push(Ctl, Frame) ->
    Ctl ! {push, Frame},
    nil.

%% Close the open event stream from the server's side, after any frames
%% pushed before.
drop(Ctl) ->
    Ctl ! drop,
    nil.

set_busy(Ctl, Busy) ->
    Ctl ! {busy, Busy},
    nil.

set_exists(Ctl, Exists) ->
    Ctl ! {exists, Exists},
    nil.

%% The next GET of the workspace answers 200, then the workspace is gone, as
%% when crush's detach grace runs out between that check and the stream
%% attaching.
expire_on_get(Ctl) ->
    Ctl ! expire_on_get,
    nil.

%% Pause and resume an actor; its messages queue meanwhile.
suspend(Pid) ->
    sys:suspend(Pid),
    nil.

resume(Pid) ->
    sys:resume(Pid),
    nil.

next(TimeoutMs) ->
    receive
        {fake_crush, Kind, Value} -> {ok, {atom_to_binary(Kind), Value}}
    after TimeoutMs -> {error, nil}
    end.

%% The controller: the listening socket's owner and the fake's state.

-record(ctl, {owner, listen, events = none, busy = true, exists = false,
              expire = false, pinned = none}).

ctl_init(Owner, Path) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {ifaddr, {local, Path}},
                                      {packet, http_bin}, {active, false},
                                      {reuseaddr, true}]),
    Ctl = self(),
    spawn_link(fun() -> accept(Ctl, Listen) end),
    Owner ! {Ctl, ready},
    ctl_loop(#ctl{owner = Owner, listen = Listen}).

ctl_loop(S = #ctl{owner = Owner}) ->
    receive
        stop ->
            gen_tcp:close(S#ctl.listen),
            exit(normal);
        {push, Frame} ->
            send_events(S, {push, Frame}),
            ctl_loop(S);
        drop ->
            send_events(S, drop),
            ctl_loop(S#ctl{events = none});
        {busy, Busy} ->
            ctl_loop(S#ctl{busy = Busy});
        {exists, Exists} ->
            ctl_loop(S#ctl{exists = Exists});
        expire_on_get ->
            ctl_loop(S#ctl{expire = true});
        {request, From, Method, Path, Headers, Body} ->
            {Reply, S1} = route(S, Method, Path, Headers, Body, From),
            From ! {self(), Reply},
            ctl_loop(S1);
        {notify, Kind, Value} ->
            Owner ! {fake_crush, Kind, Value},
            ctl_loop(S)
    end.

send_events(#ctl{events = none}, _) -> ok;
send_events(#ctl{events = Pid}, Message) -> Pid ! Message.

json(Status, Body) -> {respond, Status, Body}.

gone() -> json(404, <<"{\"message\":\"workspace not found\"}">>).

route(S = #ctl{owner = Owner}, Method, Target, Headers, Body, From) ->
    [Path | _] = binary:split(Target, <<"?">>),
    WS = <<"/v1/workspaces/", ?WS/binary>>,
    Session = <<WS/binary, "/agent/sessions/", ?SESSION/binary>>,
    Events = <<WS/binary, "/events">>,
    Agent = <<WS/binary, "/agent">>,
    Init = <<WS/binary, "/agent/init">>,
    Sessions = <<WS/binary, "/sessions">>,
    case {Method, Path} of
        {'POST', <<"/v1/workspaces">>} ->
            Owner ! {fake_crush, created, nil},
            {json(200, <<"{\"id\":\"", ?WS/binary, "\"}">>), S#ctl{exists = true}};
        {'GET', WS} ->
            Owner ! {fake_crush, got, nil},
            case S#ctl.exists of
                true ->
                    {json(200, <<"{\"id\":\"", ?WS/binary, "\"}">>),
                     S#ctl{exists = not S#ctl.expire, expire = false}};
                false ->
                    {gone(), S}
            end;
        {_, <<WS:(byte_size(WS))/binary, _/binary>>} when not S#ctl.exists ->
            case Path of
                Events -> Owner ! {fake_crush, refused, nil};
                _ -> ok
            end,
            {gone(), S};
        {'GET', Events} ->
            Last = proplists:get_value(<<"last-event-id">>, Headers, <<>>),
            Owner ! {fake_crush, events, Last},
            {stream, S#ctl{events = From}};
        {'POST', Init} ->
            {json(200, <<"{}">>), S};
        {'GET', Agent} ->
            {json(200, <<"{\"is_ready\":true}">>), S};
        {'POST', Agent} ->
            #{<<"run_id">> := RunId} = json:decode(Body),
            Owner ! {fake_crush, prompt, RunId},
            {json(202, <<>>), S};
        {'GET', Sessions} ->
            {json(200, <<"[]">>), S};
        {'POST', Sessions} ->
            {json(200, <<"{\"id\":\"", ?SESSION/binary, "\"}">>), S};
        {'GET', Session} ->
            Owner ! {fake_crush, busy, S#ctl.busy},
            {Model, Cfg} = case S#ctl.pinned of
                none -> {alpha(), <<"{}">>};
                Pinned = #{<<"model">> := Id} ->
                    {catalog_model(Id), json:encode(Pinned)}
            end,
            {json(200, iolist_to_binary(["{\"is_busy\":",
                                         atom_to_binary(S#ctl.busy),
                                         ",\"model\":", Model,
                                         ",\"model_cfg\":", Cfg, "}"])), S};
        {'GET', <<WS:(byte_size(WS))/binary, "/config">>} ->
            {json(200, <<"{\"models\":{\"large\":{\"model\":\"alpha\",\"provider\":\"hyper\"}}}">>), S};
        {'GET', <<WS:(byte_size(WS))/binary, "/providers">>} ->
            Owner ! {fake_crush, providers, nil},
            {json(200, iolist_to_binary([
                "[{\"id\":\"openai\",\"models\":[]},",
                "{\"id\":\"hyper\",\"models\":[", alpha(), ",", beta(),
                ",{\"id\":\"broken\",\"name\":\"Broken\"}]}]"])), S};
        {'POST', <<Session:(byte_size(Session))/binary, "/model">>} ->
            #{<<"model">> := Selection} = json:decode(Body),
            case catalog_model(maps:get(<<"model">>, Selection, <<>>)) of
                none ->
                    {json(400, <<"{\"message\":\"model is not available\"}">>), S};
                _ ->
                    Owner ! {fake_crush, model, Selection},
                    {json(200, <<>>), S#ctl{pinned = Selection}}
            end;
        {'POST', _} ->
            case binary:longest_common_suffix([Path, <<"/shell">>]) of
                6 -> {json(200, <<"{\"output\":\"\",\"exit_code\":0}">>), S};
                _ -> {json(200, <<"{}">>), S}
            end;
        {'DELETE', _} ->
            {json(200, <<>>), S};
        _ ->
            {json(404, <<"{\"message\":\"not found\"}">>), S}
    end.

%% One process per connection, serving requests in turn.

alpha() ->
    <<"{\"id\":\"alpha\",\"name\":\"Alpha\",",
      "\"pricing\":{\"input\":1,\"output\":2.5},",
      "\"reasoning\":{\"thinking\":\"toggleable\",",
      "\"default_effort_level\":\"high\",\"effort_levels\":[",
      "{\"value\":\"low\",\"display\":\"Low\"},",
      "{\"value\":\"high\",\"display\":\"High\"}]}}">>.

beta() ->
    <<"{\"id\":\"beta\",\"name\":\"Beta\",",
      "\"pricing\":{\"input\":0.5,\"output\":1.5},",
      "\"reasoning\":{\"thinking\":\"toggleable\"}}">>.

catalog_model(<<"alpha">>) -> alpha();
catalog_model(<<"beta">>) -> beta();
catalog_model(_) -> none.

accept(Ctl, Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Sock} ->
            Pid = spawn(fun() -> receive go -> serve(Ctl, Sock) end end),
            ok = gen_tcp:controlling_process(Sock, Pid),
            Pid ! go,
            accept(Ctl, Listen);
        {error, _} ->
            ok
    end.

serve(Ctl, Sock) ->
    case read_request(Sock) of
        {ok, Method, Target, Headers, Body} ->
            Ctl ! {request, self(), Method, Target, Headers, Body},
            receive
                {Ctl, {respond, Status, RespBody}} ->
                    ok = gen_tcp:send(Sock, [
                        <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" X\r\n">>,
                        <<"content-type: application/json\r\n">>,
                        <<"content-length: ">>, integer_to_binary(byte_size(RespBody)),
                        <<"\r\n\r\n">>, RespBody]),
                    serve(Ctl, Sock);
                {Ctl, stream} ->
                    ok = gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\n"
                                              "content-type: text/event-stream\r\n"
                                              "transfer-encoding: chunked\r\n\r\n">>),
                    ok = inet:setopts(Sock, [{packet, raw}, {active, true}]),
                    stream_loop(Sock)
            end;
        closed ->
            gen_tcp:close(Sock)
    end.

stream_loop(Sock) ->
    receive
        {push, Frame} ->
            Size = integer_to_binary(byte_size(Frame), 16),
            case gen_tcp:send(Sock, [Size, <<"\r\n">>, Frame, <<"\r\n">>]) of
                ok -> stream_loop(Sock);
                {error, _} -> gen_tcp:close(Sock)
            end;
        drop ->
            gen_tcp:close(Sock);
        {tcp_closed, Sock} ->
            ok;
        {tcp_error, Sock, _} ->
            gen_tcp:close(Sock);
        {tcp, Sock, _} ->
            stream_loop(Sock)
    end.

read_request(Sock) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, {http_request, Method, {abs_path, Target}, _}} ->
            read_headers(Sock, Method, Target, []);
        _ ->
            closed
    end.

read_headers(Sock, Method, Target, Acc) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(header_name(Name)),
            read_headers(Sock, Method, Target, [{Key, Value} | Acc]);
        {ok, http_eoh} ->
            Length = binary_to_integer(proplists:get_value(<<"content-length">>, Acc, <<"0">>)),
            Body = case Length of
                0 -> <<>>;
                _ ->
                    ok = inet:setopts(Sock, [{packet, raw}]),
                    {ok, B} = gen_tcp:recv(Sock, Length),
                    ok = inet:setopts(Sock, [{packet, http_bin}]),
                    B
            end,
            {ok, Method, Target, Acc, Body};
        _ ->
            closed
    end.

header_name(Name) when is_atom(Name) -> atom_to_binary(Name);
header_name(Name) -> Name.
