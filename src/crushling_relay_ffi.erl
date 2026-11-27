-module(crushling_relay_ffi).

-export([relay/2]).

%% Forward the gun messages of Conns to Owner until both are gone: a stream's
%% messages go to the process that opened it, which is not the thread actor.
%% Closes them if Owner exits first, as gun would when its owner dies.
relay(Owner, Conns) ->
    OwnerRef = erlang:monitor(process, Owner),
    Mons = [erlang:monitor(process, C) || C <- Conns],
    loop(Owner, OwnerRef, Mons, Conns).

loop(Owner, OwnerRef, Mons, Conns) ->
    receive
        {'DOWN', OwnerRef, process, _, _} ->
            [gun:close(C) || C <- Conns],
            nil;
        {'DOWN', Mon, process, _, _} ->
            case lists:delete(Mon, Mons) of
                [] -> nil;
                Rest -> loop(Owner, OwnerRef, Rest, Conns)
            end;
        Msg when is_tuple(Msg), tuple_size(Msg) >= 2 ->
            case lists:member(element(1, Msg),
                              [gun_sse, gun_response, gun_data, gun_trailers,
                               gun_error, gun_down]) of
                true -> Owner ! Msg;
                false -> ok
            end,
            loop(Owner, OwnerRef, Mons, Conns);
        _ ->
            loop(Owner, OwnerRef, Mons, Conns)
    end.
