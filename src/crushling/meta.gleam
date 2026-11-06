//// What the bridge remembers about a thread between restarts, kept next to
//// its workspace: whether it answers every reply, and how far into the
//// thread it has read.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Meta {
  Meta(
    /// Answer every reply in the thread, not just mentions. Set when the
    /// bot was mentioned in the thread's first message, or in a DM.
    follow: Bool,
    /// The ts of the last message sent to the agent; later messages are
    /// new to it. "" when it has read nothing.
    cursor: String,
  )
}

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "write_bytes")
fn write_bytes(path: String, content: BitArray) -> Result(Nil, String)

pub fn read(path: String) -> Result(Meta, Nil) {
  use text <- result.try(read_file(path))
  json.parse(text, {
    use follow <- decode.optional_field("follow", False, decode.bool)
    use cursor <- decode.optional_field("cursor", "", decode.string)
    decode.success(Meta(follow:, cursor:))
  })
  |> result.replace_error(Nil)
}

pub fn write(path: String, meta: Meta) -> Result(Nil, String) {
  json.object([
    #("follow", json.bool(meta.follow)),
    #("cursor", json.string(meta.cursor)),
  ])
  |> json.to_string
  |> bit_array.from_string
  |> write_bytes(path, _)
}
