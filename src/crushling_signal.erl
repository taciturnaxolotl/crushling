-module(crushling_signal).
-behaviour(gen_event).

%% Turns SIGTERM into a message for the bridge, in place of the runtime's
%% default of stopping at once, so it can finish turns and stop its agents.

-export([install/1]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

%% Deliver `Message` to `Subject` (a Gleam subject) on SIGTERM.
install(Subject) ->
    os:set_signal(sigterm, handle),
    Swapped = gen_event:swap_handler(erl_signal_server,
                                     {erl_signal_handler, []},
                                     {?MODULE, Subject}),
    case Swapped of
        ok -> {ok, nil};
        {error, _} ->
            %% No default handler to replace (it was already removed): add ours.
            case gen_event:add_handler(erl_signal_server, ?MODULE, Subject) of
                ok -> {ok, nil};
                Other -> {error, unicode:characters_to_binary(io_lib:format("~p", [Other]))}
            end
    end.

init({Subject, _OldHandlerResult}) -> {ok, Subject};
init(Subject) -> {ok, Subject}.

handle_event(sigterm, Subject) ->
    'gleam@erlang@process':send(Subject, nil),
    {ok, Subject};
handle_event(_Other, Subject) ->
    {ok, Subject}.

handle_call(_Request, Subject) -> {ok, ok, Subject}.
handle_info(_Info, Subject) -> {ok, Subject}.
terminate(_Reason, _Subject) -> ok.
