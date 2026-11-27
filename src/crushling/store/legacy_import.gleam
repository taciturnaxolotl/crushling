//// Before the store, meta and links were files under `<root>`. The first
//// start imports them (`import_files`) and never reads them again. Kept
//// for self-hosters upgrading from then; it can go once none are left.

import crushling/meta
import crushling/store.{type Migration, type Store, Migration}
import crushling/store/threads.{Thread}
import crushling/sys
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight

pub fn migrations() -> List(Migration) {
  [
    // Facts about the bridge itself, such as whether the files were
    // imported.
    Migration(
      id: "bridge.1",
      legacy_version: 1,
      sql: "CREATE TABLE bridge (name TEXT PRIMARY KEY, value TEXT NOT NULL);",
    ),
  ]
}

/// What `import_files` brought in.
pub type Imported {
  /// `skipped` names each directory not imported, and why.
  Imported(
    threads: List(String),
    links: List(String),
    skipped: List(#(String, String)),
  )
  /// The store had already imported them once.
  AlreadyImported
}

const imported_marker = "imported_files"

/// Import the meta and link files the bridge kept before the store, once:
/// `<root>/<key>/crushling.json` for threads, and
/// `<root>/<channel>-code/crushling.json` for code channels, all for `team`.
/// Rows already in the store win. The files stay where they are; later
/// starts skip this.
pub fn import_files(
  store: Store,
  root: String,
  team: String,
) -> Result(Imported, String) {
  use connection, _ <- store.run(store)
  use done <- result.try(store.query(
    connection,
    "SELECT value FROM bridge WHERE name = ?",
    [sqlight.text(imported_marker)],
    decode.field(0, decode.string, decode.success),
  ))
  case done {
    [_, ..] -> Ok(AlreadyImported)
    [] -> {
      let entries =
        sys.list_dir(root) |> result.unwrap([]) |> list.sort(string.compare)
      use found <- result.try(
        list.try_fold(entries, #([], [], []), fn(found, entry) {
          import_entry(connection, root, team, entry, found)
        }),
      )
      use _ <- result.map(
        store.exec(
          connection,
          "INSERT INTO bridge (name, value) VALUES (?, ?)",
          [
            sqlight.text(imported_marker),
            sqlight.text(int.to_string(sys.now())),
          ],
        ),
      )
      let #(threads, links, skipped) = found
      Imported(
        threads: list.reverse(threads),
        links: list.reverse(links),
        skipped: list.reverse(skipped),
      )
    }
  }
}

fn import_entry(
  connection: sqlight.Connection,
  root: String,
  team: String,
  entry: String,
  found: #(List(String), List(String), List(#(String, String))),
) -> Result(#(List(String), List(String), List(#(String, String))), String) {
  let #(threads, links, skipped) = found
  let skip = fn(why) { Ok(#(threads, links, [#(entry, why), ..skipped])) }
  let dir = root <> "/" <> entry
  let path = dir <> "/crushling.json"
  case dir_exists(dir), file_exists(path), string.ends_with(entry, "-code") {
    // The store's own files and the key, not directories.
    False, _, _ -> Ok(found)
    True, False, _ -> skip("no crushling.json")
    True, True, True ->
      case meta.read_link(path) {
        Error(Nil) -> skip("crushling.json isn't a code channel link")
        Ok(link) -> {
          let channel = string.drop_end(entry, 5)
          use known <- result.try(threads.link_row(connection, team, channel))
          case known {
            True -> skip("already in the store")
            False -> {
              use _ <- result.map(threads.write_link(
                connection,
                team,
                channel,
                link,
                "INSERT",
              ))
              #(threads, [channel, ..links], skipped)
            }
          }
        }
      }
    True, True, False ->
      case meta.read(path) {
        Error(Nil) -> skip("crushling.json isn't thread meta")
        Ok(saved) -> {
          use known <- result.try(threads.read_thread(connection, entry))
          case known, string.split_once(entry, "-") {
            Some(_), _ -> skip("already in the store")
            None, Error(Nil) -> skip("not a channel-ts key")
            None, Ok(#(channel, thread_ts)) -> {
              use _ <- result.map(threads.write_thread(
                connection,
                Thread(key: entry, team:, channel:, thread_ts:, meta: saved),
                "INSERT",
              ))
              #([entry, ..threads], links, skipped)
            }
          }
        }
      }
  }
}

@external(erlang, "crushling_store_ffi", "dir_exists")
fn dir_exists(path: String) -> Bool

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool
