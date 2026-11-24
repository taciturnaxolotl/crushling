-module(test_fs_ffi).
-export([write/2, read/1, rsa_pem/0, rs256_ok/3]).
write(Path, Content) -> ok = file:write_file(Path, Content), nil.
read(Path) -> {ok, Bin} = file:read_file(Path), Bin.

%% A fresh RSA key as PKCS#1 PEM, and whether Sig is Data signed by it.
rsa_pem() ->
    Key = public_key:generate_key({rsa, 2048, 65537}),
    public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Key)]).

rs256_ok(Pem, Data, Sig) ->
    [Entry] = public_key:pem_decode(Pem),
    Key = public_key:pem_entry_decode(Entry),
    Pub = {'RSAPublicKey', element(3, Key), element(4, Key)},
    public_key:verify(Data, sha256, Sig, Pub).
