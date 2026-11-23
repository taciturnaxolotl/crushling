//// The store: its schema, what it keeps, the bot tokens it seals, and the
//// one-time import of the files the bridge kept before it.

import crushling/meta
import crushling/store
import crushling/sys
import crushling/venue
import gleam/bit_array
import gleam/dict
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "crushling_test_ffi", "file_mode")
fn file_mode(path: String) -> Int

fn tmp(name: String) -> String {
  let dir = "/tmp/crushling-store-" <> name <> "-" <> sys.uuid()
  let assert Ok(Nil) = mkdir_p(dir)
  dir
}

const key_a = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

const key_b = "HxwdHhscGRoYFRYXFBESExAODw0MCQoLCAUGBwQBAgM="

fn open(dir: String, key: String) -> store.Store {
  let assert Ok(key) = store.parse_key(key)
  let assert Ok(s) = store.start(dir <> "/crushling.db", key)
  s
}

fn team(id: String, token: String) -> store.Team {
  store.Team(
    id:,
    bot_token: token,
    bot_user: "UBOT" <> id,
    enterprise_id: None,
    installed_by: "U1",
    installed_at: 1_731_888_000,
    active: True,
  )
}

pub fn migrations_run_once_test() {
  let dir = tmp("migrate")
  let s = open(dir, key_a)
  let assert Ok(version) = store.version(s)
  let assert True = version == store.schema_version()
  let assert True = version >= 1
  let assert Ok(Nil) = store.put_team(s, team("T1", "xoxb-1"))
  // WAL mode keeps its log beside the file while it is open.
  let assert True = file_exists(dir <> "/crushling.db-wal")
  store.close(s)
  // Opening it again migrates nothing and keeps what was there.
  let s = open(dir, key_a)
  let assert Ok(again) = store.version(s)
  let assert True = again == version
  let assert Ok(Some(_)) = store.team(s, "T1")
  store.close(s)
}

pub fn teams_and_settings_test() {
  let s = open(tmp("teams"), key_a)
  let assert Ok(None) = store.team(s, "T1")
  let assert Ok(Nil) = store.put_team(s, team("T1", "xoxb-1"))
  let assert Ok(Nil) =
    store.put_team(
      s,
      store.Team(..team("T2", "xoxb-2"), enterprise_id: Some("E1")),
    )
  let assert Ok(Some(found)) = store.team(s, "T1")
  let assert "xoxb-1" = found.bot_token
  let assert "UBOTT1" = found.bot_user
  // A reinstall replaces the token and keeps who installed it, and when.
  let assert Ok(Nil) =
    store.put_team(
      s,
      store.Team(
        ..team("T1", "xoxb-1b"),
        installed_by: "USOMEONE",
        installed_at: 99,
        bot_user: "UNEW",
      ),
    )
  let assert Ok(Some(store.Team(
    bot_token: "xoxb-1b",
    bot_user: "UNEW",
    installed_by: "U1",
    installed_at: 1_731_888_000,
    ..,
  ))) = store.team(s, "T1")
  let assert Ok([_, _]) = store.active_teams(s)
  let assert Ok(Nil) = store.set_active(s, "T2", False)
  let assert Ok([store.Team(id: "T1", ..)]) = store.active_teams(s)

  let assert Ok(None) = store.setting(s, "T1", store.allowed_users)
  let assert Ok(Nil) = store.set_setting(s, "T1", store.allowed_users, "U1,U2")
  let assert Ok(Nil) = store.set_setting(s, "T1", store.allowed_users, "U3")
  let assert Ok(Nil) = store.set_setting(s, "T1", store.admins, "U3")
  let assert Ok(Some("U3")) = store.setting(s, "T1", store.allowed_users)
  let assert Ok(all) = store.settings(s, "T1")
  let assert 2 = dict.size(all)
  // Settings belong to a team that exists.
  let assert Error(_) = store.set_setting(s, "TNONE", store.admins, "U1")
  store.close(s)
}

pub fn threads_and_links_test() {
  let s = open(tmp("threads"), key_a)
  let saved =
    meta.Meta(
      follow: True,
      paused: True,
      cursor: "5.0",
      venue: venue.CodeChannel("CCODE", "./demo"),
      tailnet: Some(meta.Grant(
        until_ms: 1_800_000_000_000,
        card: meta.Card("C9", "2.0", "1.0"),
      )),
      model: Some(meta.ModelChoice(
        model: "kimi-k3",
        reasoning: meta.Effort("high"),
      )),
    )
  let assert Ok(None) = store.thread(s, "T1-C9-1.0")
  let assert Ok(Nil) =
    store.put_thread(s, store.Thread("T1-C9-1.0", "T1", "C9", "1.0", saved))
  let assert Ok(Some(found)) = store.thread(s, "T1-C9-1.0")
  let assert True = found.meta == saved
  let assert "T1" = found.team
  let updated =
    meta.Meta(..saved, venue: venue.Archived("./demo"), tailnet: None)
  let assert Ok(Nil) =
    store.put_thread(s, store.Thread("T1-C9-1.0", "T1", "C9", "1.0", updated))
  let assert Ok(Some(store.Thread(meta: again, ..))) =
    store.thread(s, "T1-C9-1.0")
  let assert True = again == updated

  // Renaming moves a row once, and never over another.
  let assert Ok(Nil) =
    store.put_thread(s, store.Thread("C8-1.0", "", "C8", "1.0", saved))
  let assert Ok(True) =
    store.rename_thread(s, old: "C8-1.0", new: "T1-C8-1.0", team: "T1")
  let assert Ok(None) = store.thread(s, "C8-1.0")
  let assert Ok(Some(store.Thread(team: "T1", ..))) =
    store.thread(s, "T1-C8-1.0")
  let assert Ok(False) =
    store.rename_thread(s, old: "C8-1.0", new: "T1-C8-1.0", team: "T1")

  let link = meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: "9.0")
  let assert Ok(None) = store.link(s, "T1", "CCODE")
  let assert Ok(Nil) = store.put_link(s, "T1", "CCODE", link)
  let assert Ok(Some(found)) = store.link(s, "T1", "CCODE")
  let assert True = found == link
  // Links are per workspace.
  let assert Ok(None) = store.link(s, "T2", "CCODE")
  store.close(s)
}

pub fn tokens_are_sealed_test() {
  let dir = tmp("seal")
  let s = open(dir, key_a)
  let assert Ok(Nil) = store.put_team(s, team("T1", "xoxb-secret-token"))
  store.close(s)
  // The token isn't in the file in the clear.
  let assert Ok(raw) = read_file(dir <> "/crushling.db")
  let assert False = string.contains(raw, "xoxb-secret-token")
  let assert Ok(wal) = case read_file(dir <> "/crushling.db-wal") {
    Ok(wal) -> Ok(wal)
    Error(Nil) -> Ok("")
  }
  let assert False = string.contains(wal, "xoxb-secret-token")
  // With the wrong key it can't be read.
  let s = open(dir, key_b)
  let assert Error(reason) = store.team(s, "T1")
  let assert True = string.contains(reason, "decrypt")
  let assert Error(_) = store.active_teams(s)
  store.close(s)
  // With the right one it can.
  let s = open(dir, key_a)
  let assert Ok(Some(store.Team(bot_token: "xoxb-secret-token", ..))) =
    store.team(s, "T1")
  store.close(s)
}

pub fn seal_round_trip_test() {
  let assert Ok(a) = store.parse_key(key_a)
  let assert Ok(b) = store.parse_key(key_b)
  let plain = bit_array.from_string("xoxb-123")
  let aad = bit_array.from_string("T1")
  let one = store.seal(a, aad, plain)
  let two = store.seal(a, aad, plain)
  // A fresh nonce each time.
  let assert False = one == two
  let assert Ok(back) = store.unseal(a, aad, one)
  let assert True = back == plain
  let assert Error(Nil) = store.unseal(b, aad, one)
  // Bound to its team: copied onto another row it doesn't open.
  let assert Error(Nil) = store.unseal(a, bit_array.from_string("T2"), one)
  let assert Error(Nil) = store.unseal(a, aad, <<1, 2, 3>>)
}

pub fn the_key_is_made_once_test() {
  let dir = tmp("key")
  let assert Ok(#(made, True)) = store.load_key(Error(Nil), dir)
  let assert 32 = bit_array.byte_size(made)
  let assert 0o600 = file_mode(dir <> "/store-key")
  let assert Ok(#(again, False)) = store.load_key(Error(Nil), dir)
  let assert True = again == made
  // The environment wins.
  let assert Ok(a) = store.parse_key(key_a)
  let assert Ok(#(from_env, False)) = store.load_key(Ok(key_a), dir)
  let assert True = from_env == a
  let assert Error(_) = store.load_key(Ok("c2hvcnQ="), dir)
  let assert Error(_) = store.load_key(Ok("not base64!"), dir)
}

pub fn the_old_files_are_imported_once_test() {
  let root = tmp("import")
  let s = open(root, key_a)
  // A thread, a code channel's link, a workspace with no meta, and junk.
  let thread_meta =
    meta.Meta(..meta.new(False), cursor: "3.0", venue: venue.ThreadOnly("./x"))
  let assert Ok(Nil) = meta.write(root <> "/C9-1.0/crushling.json", thread_meta)
  let assert Ok(Nil) =
    meta.write_link(
      root <> "/CCODE-code/crushling.json",
      meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: "7.0"),
    )
  let assert Ok(Nil) = mkdir_p(root <> "/C7-2.0/work")
  let assert Ok(Nil) = mkdir_p(root <> "/s")
  // One already in the store, and one that isn't meta.
  let assert Ok(Nil) =
    meta.write(root <> "/C5-1.0/crushling.json", meta.new(True))
  let assert Ok(Nil) =
    store.put_thread(
      s,
      store.Thread("C5-1.0", "T1", "C5", "1.0", meta.new(False)),
    )
  let assert Ok(Nil) = mkdir_p(root <> "/C4-1.0")
  let assert Ok(Nil) = write_file(root <> "/C4-1.0/crushling.json", "nope")
  let assert Ok(store.Imported(
    threads: ["C9-1.0"],
    links: ["CCODE"],
    skipped: skipped,
  )) = store.import_files(s, root, "T1")
  // Each skipped directory says why; plain files aren't mentioned.
  let assert [
    #("C4-1.0", "crushling.json isn't thread meta"),
    #("C5-1.0", "already in the store"),
    #("C7-2.0", "no crushling.json"),
    #("s", "no crushling.json"),
  ] = skipped
  // The row already there won.
  let assert Ok(Some(store.Thread(meta: meta.Meta(follow: False, ..), ..))) =
    store.thread(s, "C5-1.0")
  let assert Ok(Some(store.Thread(
    team: "T1",
    channel: "C9",
    thread_ts: "1.0",
    meta: m,
    ..,
  ))) = store.thread(s, "C9-1.0")
  let assert True = m == thread_meta
  let assert Ok(Some(meta.Link(opened_ts: "7.0", ..))) =
    store.link(s, "T1", "CCODE")
  // The files stay, and are never read again.
  let assert True = file_exists(root <> "/C9-1.0/crushling.json")
  let assert Ok(Nil) =
    meta.write(root <> "/C6-1.0/crushling.json", meta.new(True))
  let assert Ok(store.AlreadyImported) = store.import_files(s, root, "T1")
  let assert Ok(None) = store.thread(s, "C6-1.0")
  store.close(s)
}
