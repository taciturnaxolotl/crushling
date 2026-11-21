-module(fake_gun_ffi).
-export([send_all/0, sse/1, sse_fin/1]).

%% Feed SSE bytes, in the chunks given, through crushling_sse_h, which sends
%% its gun_sse messages to this process.
sse(Chunks) ->
    Ref = make_ref(),
    {ok, State0} = crushling_sse_h:init(self(), Ref, 200,
        [{<<"content-type">>, <<"text/event-stream">>}], #{}),
    lists:foldl(fun(Chunk, State) ->
        {done, _, Next} = crushling_sse_h:handle(nofin, Chunk, State),
        Next
    end, State0, Chunks),
    nil.

%% As sse/1, with the last chunk sent as the end of the stream.
sse_fin(Chunks) ->
    Ref = make_ref(),
    {ok, State0} = crushling_sse_h:init(self(), Ref, 200,
        [{<<"content-type">>, <<"text/event-stream">>}], #{}),
    {Init, [Last]} = lists:split(length(Chunks) - 1, Chunks),
    State = lists:foldl(fun(Chunk, S) ->
        {done, _, Next} = crushling_sse_h:handle(nofin, Chunk, S),
        Next
    end, State0, Init),
    {done, _, _} = crushling_sse_h:handle(fin, Last, State),
    nil.
send_all() ->
    Self = self(),
    Ref = make_ref(),
    Self ! {gun_response, Self, Ref, nofin, 200, [{<<"content-type">>, <<"text/event-stream">>}]},
    Self ! {gun_sse, Self, Ref, #{event_type => <<"message">>, data => [<<"{\"a\":">>, <<"1}">>]}},
    Self ! {gun_sse, Self, Ref, #{id => <<"7">>, event_type => <<"done">>, data => <<"x">>}},
    Self ! {gun_sse, Self, Ref, fin},
    Self ! {gun_error, Self, Ref, timeout},
    Self ! {gun_down, Self, http, closed, []},
    nil.
