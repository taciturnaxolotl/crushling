-module(crushling_token_ffi).

%% Logins and managed tokens, stored in crush's own config format:
%% `{"providers": {Id: {"api_key": Access, "oauth": {...}}}}`.
%%
%% A login (read_login/write_login) is the full token, refresh token
%% included, and lives only on the host, seeded with
%% `CRUSH_GLOBAL_DATA=<dir> crush login claude|hyper`.
%%
%% A managed token (write_managed) is what a container gets: the access
%% token with an empty refresh token. crush adopts a newer token from disk
%% before each turn and on a 401, so the host only has to keep the file
%% fresh. Every write keeps the file's other keys and replaces it atomically.

-export([read_login/2, write_login/6, write_managed/5, decode_grant/1]).

read_login(Path, Provider) ->
    case file:read_file(Path) of
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~ts: ~p", [Path, Reason]))};
        {ok, Bin} ->
            try
                Doc = json:decode(Bin),
                OAuth = maps:get(<<"oauth">>,
                                 maps:get(Provider, maps:get(<<"providers">>, Doc))),
                {ok, {token,
                      maps:get(<<"access_token">>, OAuth),
                      maps:get(<<"refresh_token">>, OAuth, <<>>),
                      maps:get(<<"expires_at">>, OAuth, 0),
                      maps:get(<<"expires_in">>, OAuth, 0)}}
            catch _:_ ->
                {error, <<"no ", Provider/binary, " login in ", Path/binary>>}
            end
    end.

write_login(Path, Provider, Access, Refresh, ExpiresAt, ExpiresIn) ->
    write(Path, Provider, Access, Refresh, ExpiresAt, ExpiresIn).

write_managed(Path, Provider, Access, ExpiresAt, ExpiresIn) ->
    write(Path, Provider, Access, <<>>, ExpiresAt, ExpiresIn).

write(Path, Provider, Access, Refresh, ExpiresAt, ExpiresIn) ->
    Doc = case file:read_file(Path) of
        {ok, Bin} -> try json:decode(Bin) catch _:_ -> #{} end;
        {error, _} -> #{}
    end,
    Providers = maps:get(<<"providers">>, Doc, #{}),
    Entry = maps:get(Provider, Providers, #{}),
    OAuth0 = maps:get(<<"oauth">>, Entry, #{}),
    OAuth = OAuth0#{<<"access_token">> => Access,
                    <<"refresh_token">> => Refresh,
                    <<"expires_at">> => ExpiresAt,
                    <<"expires_in">> => ExpiresIn},
    New = Doc#{<<"providers">> =>
                   Providers#{Provider =>
                                  Entry#{<<"api_key">> => Access,
                                         <<"oauth">> => OAuth}}},
    Tmp = <<Path/binary, ".tmp">>,
    case file:write_file(Tmp, json:encode(New)) of
        ok ->
            _ = file:change_mode(Tmp, 8#600),
            case file:rename(Tmp, Path) of
                ok -> {ok, nil};
                {error, R} -> {error, iolist_to_binary(io_lib:format("~p", [R]))}
            end;
        {error, R} ->
            {error, iolist_to_binary(io_lib:format("~p", [R]))}
    end.

%% Parse a token endpoint response.
decode_grant(Body) ->
    try
        M = json:decode(Body),
        {ok, {grant,
              maps:get(<<"access_token">>, M),
              maps:get(<<"refresh_token">>, M, <<>>),
              maps:get(<<"expires_in">>, M, 0)}}
    catch _:_ ->
        {error, nil}
    end.
