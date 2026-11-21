-module(crushling_sse_h).
-behaviour(gun_content_handler).

%% A gun content handler for server-sent events, in place of gun_sse_h.
%%
%% gun_sse_h (through cow_sse) reports the stream's last event id with every
%% event, as the SSE spec's "last event ID buffer" says, so an event sent
%% without an id looks like a repeat of the one before. To resume a stream
%% and drop duplicates we need to know which frames really carried an id,
%% so this handler sends `id` only for a frame with its own `id:` line:
%%
%%   {gun_sse, ConnPid, StreamRef, #{event_type := binary(), data := iodata(),
%%                                   id => binary()}}
%%   {gun_sse, ConnPid, StreamRef, fin}

-export([init/5, handle/3]).

-record(state, {
    reply_to,
    stream_ref,
    buffer = <<>> :: binary(),
    bom = true :: boolean(),
    %% Whether the last byte taken was a CR, so an LF that starts the next
    %% chunk ends no line of its own.
    cr = false :: boolean(),
    event_type = <<>> :: binary(),
    data = [] :: [binary()],
    id = none :: none | {some, binary()}
}).

init(ReplyTo, StreamRef, _Status, Headers, _Opts) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
        {_, ContentType} ->
            try cow_http_hd:parse_content_type(ContentType) of
                {<<"text">>, <<"event-stream">>, _} ->
                    {ok, #state{reply_to = ReplyTo, stream_ref = StreamRef}};
                _ ->
                    disable
            catch _:_ ->
                disable
            end;
        false ->
            disable
    end.

handle(IsFin, Data, State0 = #state{buffer = Buffer}) ->
    State1 = strip_bom(State0#state{buffer = <<Buffer/binary, Data/binary>>}),
    {Flow, State} = lines(State1, 0),
    case IsFin of
        fin ->
            gun:reply(State#state.reply_to,
                      {gun_sse, self(), State#state.stream_ref, fin}),
            {done, Flow + 1, State};
        nofin ->
            {done, Flow, State}
    end.

strip_bom(State = #state{bom = false}) ->
    State;
strip_bom(State = #state{buffer = <<16#EF, 16#BB, 16#BF, Rest/binary>>}) ->
    State#state{buffer = Rest, bom = false};
strip_bom(State = #state{buffer = Buffer})
        when Buffer =:= <<>>; Buffer =:= <<16#EF>>; Buffer =:= <<16#EF, 16#BB>> ->
    State;
strip_bom(State) ->
    State#state{bom = false}.

%% Take each complete line off the buffer. A CR ends a line at once; an LF
%% right after it, in this chunk or the next, is part of the same ending.
lines(State = #state{bom = true}, Flow) ->
    {Flow, State};
lines(State = #state{cr = true, buffer = <<"\n", Rest/binary>>}, Flow) ->
    lines(State#state{cr = false, buffer = Rest}, Flow);
lines(State = #state{cr = true, buffer = <<>>}, Flow) ->
    {Flow, State};
lines(State = #state{buffer = Buffer}, Flow) ->
    case binary:match(Buffer, [<<"\r">>, <<"\n">>]) of
        nomatch ->
            {Flow, State#state{cr = false}};
        {Pos, 1} ->
            Line = binary:part(Buffer, 0, Pos),
            CR = binary:at(Buffer, Pos) =:= $\r,
            Rest = binary:part(Buffer, Pos + 1, byte_size(Buffer) - Pos - 1),
            {Inc, Next} = line(Line, State#state{buffer = Rest, cr = CR}),
            lines(Next, Flow + Inc)
    end.

line(<<>>, State) ->
    dispatch(State);
line(<<$:, _/binary>>, State) ->
    {0, State};
line(Line, State) ->
    {Field, Value} = case binary:split(Line, <<":">>) of
        [F, <<" ", V/binary>>] -> {F, V};
        [F, V] -> {F, V};
        [F] -> {F, <<>>}
    end,
    {0, field(Field, Value, State)}.

field(<<"event">>, Value, State) ->
    State#state{event_type = Value};
field(<<"data">>, Value, State = #state{data = Data}) ->
    State#state{data = [Value | Data]};
field(<<"id">>, Value, State) ->
    case binary:match(Value, <<0>>) of
        nomatch -> State#state{id = {some, Value}};
        _ -> State
    end;
field(_, _, State) ->
    State.

%% A frame with neither data nor an id is nothing.
dispatch(State = #state{data = [], id = none}) ->
    {0, reset(State)};
dispatch(State = #state{reply_to = ReplyTo, stream_ref = Ref,
                        event_type = Type, data = Data, id = Id}) ->
    Event0 = #{
        event_type => case Type of <<>> -> <<"message">>; _ -> Type end,
        data => lists:join(<<"\n">>, lists:reverse(Data))
    },
    Event = case Id of
        {some, Value} -> Event0#{id => Value};
        none -> Event0
    end,
    gun:reply(ReplyTo, {gun_sse, self(), Ref, Event}),
    {1, reset(State)}.

reset(State) ->
    State#state{event_type = <<>>, data = [], id = none}.
