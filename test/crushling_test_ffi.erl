-module(crushling_test_ffi).
-export([make_executable/1, file_mode/1]).

%% Mark a file executable by its owner.
make_executable(Path) ->
    ok = file:change_mode(Path, 8#700),
    nil.

%% A file's permission bits.
file_mode(Path) ->
    {ok, Info} = file:read_file_info(Path),
    element(8, Info) band 8#777.
