//// Files a thread keeps on the bridge, under `<root>/<key>/files` as
//// `<file_id>-<name>`.
////
//// A sandbox shares no filesystem with the bridge, so files cross over
//// HTTP: every Slack attachment is kept here (`attachments`), the agent
//// fetches one with `crushling-fetch <file_id>` and shares one with
//// `crushling-share <path>` (the scripts in `sandbox/bin`), through
//// `files/route`. A file id only resolves inside its own thread's
//// directory.

import crushling/sys
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The biggest file the bridge keeps or takes as an upload.
pub const max_upload_bytes = 67_108_864

/// The directory that keeps a thread's files.
pub fn dir(root: String, key: String) -> String {
  root <> "/" <> key <> "/files"
}

/// Keep only characters that are safe in a file name.
pub fn safe_name(name: String) -> String {
  let cleaned =
    string.to_graphemes(name)
    |> list.map(fn(g) {
      case is_name_char(g) {
        True -> g
        False -> "_"
      }
    })
    |> string.concat
  case cleaned {
    "" | "." | ".." -> "file"
    cleaned -> cleaned
  }
}

fn is_name_char(g: String) -> Bool {
  g != ""
  && string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-",
    g,
  )
}

/// Whether `id` can name a file: letters and digits only, as Slack's file
/// ids and the ones uploads get.
pub fn valid_id(id: String) -> Bool {
  id != ""
  && string.length(id) <= 64
  && list.all(string.to_graphemes(id), fn(g) {
    g != ""
    && string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
      g,
    )
  })
}

pub fn valid_key(key: String) -> Bool {
  key != ""
  && key != "."
  && key != ".."
  && list.all(string.to_graphemes(key), is_name_char)
}

@external(erlang, "crushling_ffi", "write_bytes")
fn write_bytes(path: String, bytes: BitArray) -> Result(Nil, String)

/// Keep `bytes` as the thread's file `id`, named `name`.
pub fn store(
  root: String,
  key: String,
  id: String,
  name: String,
  bytes: BitArray,
) -> Result(Nil, String) {
  case valid_key(key) && valid_id(id) {
    False -> Error("bad file id")
    True ->
      write_bytes(dir(root, key) <> "/" <> id <> "-" <> safe_name(name), bytes)
  }
}

/// The path of the thread's file `id`, and its name.
pub fn find(
  root: String,
  key: String,
  id: String,
) -> Result(#(String, String), Nil) {
  case valid_key(key) && valid_id(id) {
    False -> Error(Nil)
    True -> {
      let dir = dir(root, key)
      use names <- result.try(sys.list_dir(dir))
      list.find_map(names, fn(entry) {
        case string.split_once(entry, "-") {
          Ok(#(found, name)) if found == id -> Ok(#(dir <> "/" <> entry, name))
          _ -> Error(Nil)
        }
      })
    }
  }
}

pub fn human_size(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string(b / 1024) <> " KB"
    b -> int.to_string(b / 1_048_576) <> " MB"
  }
}

@external(erlang, "crushling_ffi", "delete_file")
fn delete_file(path: String) -> Nil

/// Delete the thread's file `id`, if it is there.
pub fn remove(root: String, key: String, id: String) -> Nil {
  case find(root, key, id) {
    Ok(#(path, _)) -> delete_file(path)
    Error(Nil) -> Nil
  }
}
