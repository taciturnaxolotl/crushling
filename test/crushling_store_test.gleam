//// The store: its schema, what it keeps, the bot tokens it seals, and the
//// one-time import of the files the bridge kept before it.

import crushling/github
import crushling/meta
import crushling/store
import crushling/store/github as accounts
import crushling/store/legacy_import
import crushling/store/schema
import crushling/store/sealed
import crushling/store/teams
import crushling/store/threads
import crushling/sys
import crushling/venue
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sqlight

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
  let assert Ok(s) = schema.open(dir <> "/crushling.db", key)
  s
}

fn team(id: String, token: String) -> teams.Team {
  teams.Team(
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
  let assert Ok(applied) = store.applied(s)
  let assert True =
    applied == list.map(schema.migrations(), fn(migration) { migration.id })
  let assert Ok(Nil) = teams.put_team(s, team("T1", "xoxb-1"))
  // WAL mode keeps its log beside the file while it is open.
  let assert True = file_exists(dir <> "/crushling.db-wal")
  store.close(s)
  // Opening it again migrates nothing and keeps what was there.
  let s = open(dir, key_a)
  let assert Ok(again) = store.applied(s)
  let assert True = again == applied
  let assert Ok(Some(_)) = teams.team(s, "T1")
  store.close(s)
}

/// The schema before each module kept its own migrations, as its three
/// steps made it, `user_version` counting them.
const old_schema =
  "CREATE TABLE teams (
    team_id TEXT PRIMARY KEY,
    bot_token_enc BLOB NOT NULL,
    bot_user TEXT NOT NULL,
    enterprise_id TEXT,
    installed_by TEXT NOT NULL DEFAULT '',
    installed_at INTEGER NOT NULL,
    active INTEGER NOT NULL DEFAULT 1
  );
  CREATE TABLE team_settings (
    team_id TEXT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    PRIMARY KEY (team_id, name)
  );
  CREATE TABLE threads (
    key TEXT PRIMARY KEY,
    team_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    thread_ts TEXT NOT NULL,
    follow INTEGER NOT NULL,
    paused INTEGER NOT NULL,
    cursor TEXT NOT NULL,
    venue TEXT NOT NULL,
    tailnet TEXT,
    updated_at INTEGER NOT NULL
  );
  CREATE INDEX threads_team ON threads (team_id);
  CREATE TABLE links (
    team_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    origin_channel TEXT NOT NULL,
    origin_ts TEXT NOT NULL,
    opened_ts TEXT NOT NULL,
    PRIMARY KEY (team_id, channel)
  );
  CREATE TABLE bridge (name TEXT PRIMARY KEY, value TEXT NOT NULL);
  ALTER TABLE threads ADD COLUMN model TEXT;
  CREATE TABLE usage (
    team_id TEXT NOT NULL,
    key TEXT NOT NULL,
    day TEXT NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cost_usd REAL NOT NULL,
    requests INTEGER NOT NULL,
    PRIMARY KEY (key, day)
  );
  CREATE INDEX usage_team_day ON usage (team_id, day);
  CREATE TABLE github_accounts (
    team_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    login TEXT NOT NULL,
    tokens_enc BLOB NOT NULL,
    connected_at INTEGER NOT NULL,
    PRIMARY KEY (team_id, user_id)
  );
  PRAGMA user_version = 3;"

/// A store the bridge made before: its rows, sealed the old way, still
/// read, nothing is made twice, and a connection no workspace has goes.
pub fn an_older_store_is_upgraded_test() {
  let dir = tmp("upgrade")
  let path = dir <> "/crushling.db"
  let assert Ok(key) = store.parse_key(key_a)
  let assert Ok(db) = sqlight.open(path)
  let assert Ok(Nil) = sqlight.exec(old_schema, db)
  let bot = sealed.seal_legacy(key, sealed.BotToken, ["T1"], <<"xoxb-old">>)
  let tokens =
    sealed.seal_legacy(key, sealed.GitHubTokens, ["T1", "U1"], <<
      "{\"access\":\"ghu_a\",\"expires_at\":0,\"refresh\":\"\",\"refresh_expires_at\":0}",
    >>)
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO teams (team_id, bot_token_enc, bot_user, installed_at)
       VALUES ('T1', ?, 'UBOT', 5)",
      db,
      [sqlight.blob(bot)],
      decode.success(Nil),
    )
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO github_accounts VALUES ('T1', 'U1', 'octo', ?, 7),
         ('TGONE', 'U1', 'octo', ?, 7)",
      db,
      [sqlight.blob(tokens), sqlight.blob(tokens)],
      decode.success(Nil),
    )
  let assert Ok(Nil) = sqlight.close(db)

  let s = open(dir, key_a)
  let assert Ok(applied) = store.applied(s)
  let assert True =
    applied == list.map(schema.migrations(), fn(migration) { migration.id })
  let assert Ok(Some(teams.Team(bot_token: "xoxb-old", ..))) =
    teams.team(s, "T1")
  let assert Ok(Some(accounts.Account(login: "octo", ..))) =
    accounts.get(s, "T1", "U1")
  let assert Ok(None) = accounts.get(s, "TGONE", "U1")
  // Saved again, it's sealed the new way, and reads the same.
  let assert Ok(Nil) = teams.put_team(s, team("T1", "xoxb-old"))
  let assert Ok(Some(teams.Team(bot_token: "xoxb-old", ..))) =
    teams.team(s, "T1")
  store.close(s)
  let assert Ok(db) = sqlight.open(path)
  let assert Ok([<<1, _:bits>>]) =
    sqlight.query(
      "SELECT bot_token_enc FROM teams WHERE team_id = 'T1'",
      db,
      [],
      decode.field(0, decode.bit_array, decode.success),
    )
  let assert Ok(Nil) = sqlight.close(db)
}

/// Uninstalling forgets a workspace's GitHub tokens, and its connections
/// go with its row.
pub fn uninstalling_forgets_github_tokens_test() {
  let s = open(tmp("uninstall"), key_a)
  let assert Ok(Nil) = teams.put_team(s, team("T1", "xoxb-1"))
  let assert Ok(Nil) = teams.put_team(s, team("T2", "xoxb-2"))
  let account = fn(team) {
    accounts.Account(team, "U1", "octo", github.Tokens("ghu", 0, "", 0), 1)
  }
  let assert Ok(Nil) = accounts.put(s, account("T1"))
  let assert Ok(Nil) = accounts.put(s, account("T2"))
  let assert Ok(Nil) = teams.uninstall(s, "T1")
  let assert Ok(None) = accounts.get(s, "T1", "U1")
  let assert Ok(Some(teams.Team(active: False, ..))) = teams.team(s, "T1")
  let assert Ok(Some(_)) = accounts.get(s, "T2", "U1")
  // A connection only exists for a workspace the store has.
  let assert Error(_) = accounts.put(s, account("TNONE"))
  store.close(s)
}

pub fn teams_and_settings_test() {
  let s = open(tmp("teams"), key_a)
  let assert Ok(None) = teams.team(s, "T1")
  let assert Ok(Nil) = teams.put_team(s, team("T1", "xoxb-1"))
  let assert Ok(Nil) =
    teams.put_team(
      s,
      teams.Team(..team("T2", "xoxb-2"), enterprise_id: Some("E1")),
    )
  let assert Ok(Some(found)) = teams.team(s, "T1")
  let assert "xoxb-1" = found.bot_token
  let assert "UBOTT1" = found.bot_user
  // A reinstall replaces the token and keeps who installed it, and when.
  let assert Ok(Nil) =
    teams.put_team(
      s,
      teams.Team(
        ..team("T1", "xoxb-1b"),
        installed_by: "USOMEONE",
        installed_at: 99,
        bot_user: "UNEW",
      ),
    )
  let assert Ok(Some(teams.Team(
    bot_token: "xoxb-1b",
    bot_user: "UNEW",
    installed_by: "U1",
    installed_at: 1_731_888_000,
    ..,
  ))) = teams.team(s, "T1")
  let assert Ok([_, _]) = teams.active_teams(s)
  let assert Ok(Nil) = teams.set_active(s, "T2", False)
  let assert Ok([teams.Team(id: "T1", ..)]) = teams.active_teams(s)

  let assert Ok(None) = teams.setting(s, "T1", teams.allowed_users)
  let assert Ok(Nil) = teams.set_setting(s, "T1", teams.allowed_users, "U1,U2")
  let assert Ok(Nil) = teams.set_setting(s, "T1", teams.allowed_users, "U3")
  let assert Ok(Nil) = teams.set_setting(s, "T1", teams.admins, "U3")
  let assert Ok(Some("U3")) = teams.setting(s, "T1", teams.allowed_users)
  let assert Ok(all) = teams.settings(s, "T1")
  let assert 2 = dict.size(all)
  // Settings belong to a team that exists.
  let assert Error(_) = teams.set_setting(s, "TNONE", teams.admins, "U1")
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
  let assert Ok(None) = threads.thread(s, "T1-C9-1.0")
  let assert Ok(Nil) =
    threads.put_thread(s, threads.Thread("T1-C9-1.0", "T1", "C9", "1.0", saved))
  let assert Ok(Some(found)) = threads.thread(s, "T1-C9-1.0")
  let assert True = found.meta == saved
  let assert "T1" = found.team
  let updated =
    meta.Meta(..saved, venue: venue.Archived("./demo"), tailnet: None)
  let assert Ok(Nil) =
    threads.put_thread(
      s,
      threads.Thread("T1-C9-1.0", "T1", "C9", "1.0", updated),
    )
  let assert Ok(Some(threads.Thread(meta: again, ..))) =
    threads.thread(s, "T1-C9-1.0")
  let assert True = again == updated

  // Renaming moves a row once, and never over another.
  let assert Ok(Nil) =
    threads.put_thread(s, threads.Thread("C8-1.0", "", "C8", "1.0", saved))
  let assert Ok(True) =
    threads.rename_thread(s, old: "C8-1.0", new: "T1-C8-1.0", team: "T1")
  let assert Ok(None) = threads.thread(s, "C8-1.0")
  let assert Ok(Some(threads.Thread(team: "T1", ..))) =
    threads.thread(s, "T1-C8-1.0")
  let assert Ok(False) =
    threads.rename_thread(s, old: "C8-1.0", new: "T1-C8-1.0", team: "T1")

  let link = meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: "9.0")
  let assert Ok(None) = threads.link(s, "T1", "CCODE")
  let assert Ok(Nil) = threads.put_link(s, "T1", "CCODE", link)
  let assert Ok(Some(found)) = threads.link(s, "T1", "CCODE")
  let assert True = found == link
  // Links are per workspace.
  let assert Ok(None) = threads.link(s, "T2", "CCODE")
  store.close(s)
}

pub fn tokens_are_sealed_test() {
  let dir = tmp("seal")
  let s = open(dir, key_a)
  let assert Ok(Nil) = teams.put_team(s, team("T1", "xoxb-secret-token"))
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
  let assert Error(reason) = teams.team(s, "T1")
  let assert True = string.contains(reason, "decrypt")
  let assert Error(_) = teams.active_teams(s)
  store.close(s)
  // With the right one it can.
  let s = open(dir, key_a)
  let assert Ok(Some(teams.Team(bot_token: "xoxb-secret-token", ..))) =
    teams.team(s, "T1")
  store.close(s)
}

pub fn seal_round_trip_test() {
  let assert Ok(a) = store.parse_key(key_a)
  let assert Ok(b) = store.parse_key(key_b)
  let plain = bit_array.from_string("xoxb-123")
  let one = sealed.seal(a, sealed.BotToken, ["T1"], plain)
  let two = sealed.seal(a, sealed.BotToken, ["T1"], plain)
  // A fresh nonce each time, after the version.
  let assert False = one == two
  let assert <<1, _:bits>> = one
  let assert Ok(back) = sealed.unseal(a, sealed.BotToken, ["T1"], one)
  let assert True = back == plain
  let assert Error(Nil) = sealed.unseal(b, sealed.BotToken, ["T1"], one)
  // Bound to its team: copied onto another row it doesn't open.
  let assert Error(Nil) = sealed.unseal(a, sealed.BotToken, ["T2"], one)
  // Nor read as another kind of secret.
  let assert Error(Nil) = sealed.unseal(a, sealed.GitHubTokens, ["T1"], one)
  let assert Error(Nil) = sealed.unseal(a, sealed.BotToken, ["T1"], <<1, 2, 3>>)
  // What was sealed before versions still opens, bound as it was.
  let old = sealed.seal_legacy(a, sealed.BotToken, ["T1"], plain)
  let assert Ok(back) = sealed.unseal(a, sealed.BotToken, ["T1"], old)
  let assert True = back == plain
  let assert Error(Nil) = sealed.unseal(a, sealed.BotToken, ["T2"], old)
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
    threads.put_thread(
      s,
      threads.Thread("C5-1.0", "T1", "C5", "1.0", meta.new(False)),
    )
  let assert Ok(Nil) = mkdir_p(root <> "/C4-1.0")
  let assert Ok(Nil) = write_file(root <> "/C4-1.0/crushling.json", "nope")
  let assert Ok(legacy_import.Imported(
    threads: ["C9-1.0"],
    links: ["CCODE"],
    skipped: skipped,
  )) = legacy_import.import_files(s, root, "T1")
  // Each skipped directory says why; plain files aren't mentioned.
  let assert [
    #("C4-1.0", "crushling.json isn't thread meta"),
    #("C5-1.0", "already in the store"),
    #("C7-2.0", "no crushling.json"),
    #("s", "no crushling.json"),
  ] = skipped
  // The row already there won.
  let assert Ok(Some(threads.Thread(meta: meta.Meta(follow: False, ..), ..))) =
    threads.thread(s, "C5-1.0")
  let assert Ok(Some(threads.Thread(
    team: "T1",
    channel: "C9",
    thread_ts: "1.0",
    meta: m,
    ..,
  ))) = threads.thread(s, "C9-1.0")
  let assert True = m == thread_meta
  let assert Ok(Some(meta.Link(opened_ts: "7.0", ..))) =
    threads.link(s, "T1", "CCODE")
  // The files stay, and are never read again.
  let assert True = file_exists(root <> "/C9-1.0/crushling.json")
  let assert Ok(Nil) =
    meta.write(root <> "/C6-1.0/crushling.json", meta.new(True))
  let assert Ok(legacy_import.AlreadyImported) =
    legacy_import.import_files(s, root, "T1")
  let assert Ok(None) = threads.thread(s, "C6-1.0")
  store.close(s)
}
