//// Logging, ids and clocks from the Erlang runtime, for every module to share.

@external(erlang, "crushling_ffi", "log_warning")
pub fn warn(text: String) -> Nil

@external(erlang, "crushling_ffi", "log_info")
pub fn info(text: String) -> Nil

@external(erlang, "crushling_ffi", "uuid_v4")
pub fn uuid() -> String

/// Milliseconds on a clock that only goes forward, for measuring time.
@external(erlang, "crushling_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// Milliseconds since the epoch, for comparing with Slack's timestamps.
@external(erlang, "crushling_ffi", "system_ms")
pub fn system_ms() -> Int

@external(erlang, "crushling_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

/// The names in a directory, or an error when it can't be read.
@external(erlang, "crushling_ffi", "list_dir")
pub fn list_dir(path: String) -> Result(List(String), Nil)

@external(erlang, "crushling_ffi", "mkdir_p")
pub fn mkdir_p(path: String) -> Result(Nil, String)

/// Write a file readable only by the service's own user.
@external(erlang, "crushling_ffi", "write_private")
pub fn write_private(path: String, content: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "sha256_hex")
pub fn sha256_hex(data: String) -> String
