-module(fake_gun_ffi).
-export([send_all/0]).
send_all() ->
    Self = self(),
    Ref = make_ref(),
    Self ! {gun_response, Self, Ref, nofin, 200, [{<<"content-type">>, <<"text/event-stream">>}]},
    Self ! {gun_sse, Self, Ref, #{event_type => <<"message">>, data => [<<"{\"a\":">>, <<"1}">>]}},
    Self ! {gun_sse, Self, Ref, #{last_event_id => <<"7">>, event_type => <<"done">>, data => <<"x">>}},
    Self ! {gun_sse, Self, Ref, fin},
    Self ! {gun_error, Self, Ref, timeout},
    Self ! {gun_down, Self, http, closed, []},
    nil.
