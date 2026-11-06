-module(test_fs_ffi).
-export([write/2, read/1]).
write(Path, Content) -> ok = file:write_file(Path, Content), nil.
read(Path) -> {ok, Bin} = file:read_file(Path), Bin.
