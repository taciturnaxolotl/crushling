-module(crushling_store_ffi).

-export([seal/3, open/3, random_key/0, rename/2, dir_exists/1]).

%% AES-256-GCM with a fresh 12-byte nonce per value. The sealed form is
%% nonce (12) | tag (16) | ciphertext. `Aad` binds the value to its row, so
%% a token copied onto another team's row doesn't decrypt.
seal(Key, Aad, Plain) when byte_size(Key) =:= 32 ->
    Nonce = crypto:strong_rand_bytes(12),
    {Cipher, Tag} =
        crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, Aad, 16, true),
    <<Nonce/binary, Tag/binary, Cipher/binary>>.

open(Key, Aad, <<Nonce:12/binary, Tag:16/binary, Cipher/binary>>) when byte_size(Key) =:= 32 ->
    try crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Cipher, Aad, Tag, false) of
        error -> {error, nil};
        Plain when is_binary(Plain) -> {ok, Plain}
    catch
        _:_ -> {error, nil}
    end;
open(_, _, _) ->
    {error, nil}.

random_key() ->
    crypto:strong_rand_bytes(32).

rename(From, To) ->
    case file:rename(From, To) of
        ok -> {ok, nil};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

dir_exists(Path) ->
    filelib:is_dir(Path).
