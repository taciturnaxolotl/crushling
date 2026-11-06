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
    /// `!pause`d: only mentions reach the agent, even where it would
    /// otherwise answer everything, until `!resume`.
    paused: Bool,
    /// The ts of the last message sent to the agent; later messages are
    /// new to it. "" when it has read nothing.
    cursor: String,
    /// The code channel the work moved to once the agent cloned a repo,
    /// and the repo's directory in the workspace. "" until then.
    code_channel: String,
    repo: String,
    /// Set on a code channel's own entry: the thread whose workspace it
    /// shares, so the channel's messages reach that thread's agent.
    origin_channel: String,
    origin_ts: String,
  )
}

pub fn new(follow: Bool) -> Meta {
  Meta(
    follow:,
    paused: False,
    cursor: "",
    code_channel: "",
    repo: "",
    origin_channel: "",
    origin_ts: "",
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
    use paused <- decode.optional_field("paused", False, decode.bool)
    use cursor <- decode.optional_field("cursor", "", decode.string)
    use code_channel <- decode.optional_field("code_channel", "", decode.string)
    use repo <- decode.optional_field("repo", "", decode.string)
    use origin_channel <- decode.optional_field(
      "origin_channel",
      "",
      decode.string,
    )
    use origin_ts <- decode.optional_field("origin_ts", "", decode.string)
    decode.success(Meta(
      follow:,
      paused:,
      cursor:,
      code_channel:,
      repo:,
      origin_channel:,
      origin_ts:,
    ))
  })
  |> result.replace_error(Nil)
}

pub fn write(path: String, meta: Meta) -> Result(Nil, String) {
  json.object([
    #("follow", json.bool(meta.follow)),
    #("paused", json.bool(meta.paused)),
    #("cursor", json.string(meta.cursor)),
    #("code_channel", json.string(meta.code_channel)),
    #("repo", json.string(meta.repo)),
    #("origin_channel", json.string(meta.origin_channel)),
    #("origin_ts", json.string(meta.origin_ts)),
  ])
  |> json.to_string
  |> bit_array.from_string
  |> write_bytes(path, _)
}
