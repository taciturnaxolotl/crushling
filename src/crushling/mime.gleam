//// File types: what a file is from its name, its declared type and its
//// first bytes. The one table the bridge goes by, for prompts and uploads.

import gleam/list
import gleam/result
import gleam/string

/// Image types models take directly.
const seen_images = ["image/png", "image/jpeg", "image/gif", "image/webp"]

/// Non-`text/*` types that are text.
const text_types = [
  "application/json", "application/x-ndjson", "application/xml",
  "application/yaml", "application/x-yaml", "application/toml",
  "application/javascript", "application/x-javascript", "application/typescript",
  "application/x-sh", "application/x-shellscript", "application/sql",
  "application/graphql", "application/x-diff", "application/x-patch",
]

/// Extensions of text files, for when Slack gives a vague type.
const text_extensions = [
  "txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonl", "ndjson",
  "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "xml", "html", "htm",
  "css", "scss", "svg", "diff", "patch", "sh", "bash", "zsh", "fish", "py", "rb",
  "go", "rs", "c", "h", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "swift",
  "m", "js", "mjs", "cjs", "jsx", "ts", "tsx", "gleam", "erl", "hrl", "ex",
  "exs", "hs", "ml", "lua", "php", "pl", "r", "scala", "sql", "graphql", "proto",
  "nix", "zig", "vue", "svelte", "dockerfile", "makefile", "gradle", "tf",
  "lock",
]

/// The type an upload is sent to Slack as, from its name.
const by_extension = [
  #("png", "image/png"),
  #("jpg", "image/jpeg"),
  #("jpeg", "image/jpeg"),
  #("gif", "image/gif"),
  #("svg", "image/svg+xml"),
  #("pdf", "application/pdf"),
  #("json", "application/json"),
  #("html", "text/html"),
  #("csv", "text/csv"),
  #("diff", "text/x-diff"),
  #("patch", "text/x-diff"),
  #("txt", "text/plain"),
  #("log", "text/plain"),
  #("md", "text/plain"),
]

pub const octet_stream = "application/octet-stream"

/// A file name's extension, lowercased; a name without a dot is its own.
pub fn extension(name: String) -> String {
  case string.split(string.lowercase(name), ".") {
    [whole] -> whole
    parts -> list.last(parts) |> result.unwrap("")
  }
}

/// The type to send a file named `name` as.
pub fn of_name(name: String) -> String {
  list.key_find(by_extension, extension(name)) |> result.unwrap(octet_stream)
}

/// Types that say nothing about what a file is, so its name and first
/// bytes are what to go by.
pub fn is_generic(mimetype: String) -> Bool {
  case string.lowercase(mimetype) {
    "" | "application/octet-stream" | "binary/octet-stream" | "text/plain" ->
      True
    _ -> False
  }
}

/// Whether a file is text, by its type, or by its name when the type is
/// generic. The bytes are checked separately.
pub fn is_text(name: String, mimetype: String) -> Bool {
  let lower = string.lowercase(mimetype)
  string.starts_with(lower, "text/")
  || list.contains(text_types, lower)
  || string.ends_with(lower, "+json")
  || string.ends_with(lower, "+xml")
  || is_generic(lower)
  && list.contains(text_extensions, extension(name))
}

/// The image type `bytes` start with, if they are PNG, JPEG, GIF or WebP.
pub fn sniff_image(bytes: BitArray) -> Result(String, Nil) {
  case bytes {
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> -> Ok("image/png")
    <<0xFF, 0xD8, 0xFF, _:bits>> -> Ok("image/jpeg")
    <<"GIF87a", _:bits>> | <<"GIF89a", _:bits>> -> Ok("image/gif")
    <<"RIFF", _:bytes-size(4), "WEBP", _:bits>> -> Ok("image/webp")
    _ -> Error(Nil)
  }
}

/// The image type a model can see this file as: its own type if it is one,
/// or what its bytes say when its type is generic.
pub fn image_type(mimetype: String, bytes: BitArray) -> Result(String, Nil) {
  let lower = string.lowercase(mimetype)
  case list.contains(seen_images, lower), is_generic(lower) {
    True, _ -> Ok(lower)
    False, True -> sniff_image(bytes)
    False, False -> Error(Nil)
  }
}
