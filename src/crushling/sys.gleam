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
