-module(crushling_test_ffi).
-export([make_executable/1]).

%% Mark a file executable by its owner.
make_executable(Path) ->
    ok = file:change_mode(Path, 8#700),
    nil.
