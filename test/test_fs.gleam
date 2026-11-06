//// Tiny file helpers for tests.

@external(erlang, "test_fs_ffi", "write")
pub fn write(path: String, content: String) -> Nil

@external(erlang, "test_fs_ffi", "read")
pub fn read(path: String) -> String
