//// The Slack workspaces the bridge serves (bot tokens sealed) and their
//// settings.

import crushling/store.{type Migration, type Store, Migration}
import crushling/store/github as accounts
import crushling/store/sealed
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

/// A Slack workspace the bridge serves.
pub type Team {
  Team(
    id: String,
    /// The `xoxb-` token, decrypted.
    bot_token: String,
    bot_user: String,
    enterprise_id: Option(String),
    /// Who installed the app, "" when seeded from the environment.
    installed_by: String,
    /// Unix seconds.
    installed_at: Int,
    active: Bool,
  )
}

pub fn migrations() -> List(Migration) {
  [
    Migration(
      id: "teams.1",
      legacy_version: 1,
      sql: "CREATE TABLE teams (
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
      );",
    ),
  ]
}

// Teams -----------------------------------------------------------------------

/// Add a team. A team already there (a reinstall, or the self-host
/// workspace on every start) gets the new token, bot user, organization and
/// active flag, and keeps who installed it and when.
pub fn put_team(store: Store, team: Team) -> Result(Nil, String) {
  use connection, key <- store.run(store)
  write_team(connection, key, team)
}

fn write_team(
  connection: sqlight.Connection,
  key: BitArray,
  team: Team,
) -> Result(Nil, String) {
  let sealed =
    sealed.seal(
      key,
      sealed.BotToken,
      [team.id],
      bit_array.from_string(team.bot_token),
    )
  store.exec(
    connection,
    "INSERT INTO teams
       (team_id, bot_token_enc, bot_user, enterprise_id, installed_by,
        installed_at, active)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (team_id) DO UPDATE SET
       bot_token_enc = excluded.bot_token_enc,
       bot_user = excluded.bot_user,
       enterprise_id = excluded.enterprise_id,
       active = excluded.active",
    [
      sqlight.text(team.id),
      sqlight.blob(sealed),
      sqlight.text(team.bot_user),
      sqlight.nullable(sqlight.text, team.enterprise_id),
      sqlight.text(team.installed_by),
      sqlight.int(team.installed_at),
      sqlight.bool(team.active),
    ],
  )
}

/// Save an installed team, and for a workspace new to the store give
/// `seed` (its installer) its allowlist and admins, in one transaction so
/// a new workspace never starts with nobody allowed. True when it was new.
pub fn install(
  store: Store,
  team: Team,
  seed: fn(Bool) -> Option(String),
) -> Result(Bool, String) {
  use connection, key <- store.run(store)
  use <- store.transaction(connection)
  use known <- result.try(read_team(connection, team.id))
  let new = known == []
  use _ <- result.try(write_team(connection, key, team))
  use _ <- result.map(case seed(new) {
    None -> Ok(Nil)
    Some(user) -> {
      use _ <- result.try(write_setting(
        connection,
        team.id,
        allowed_users,
        user,
      ))
      write_setting(connection, team.id, admins, user)
    }
  })
  new
}

const team_columns =
  "team_id, bot_token_enc, bot_user, enterprise_id, installed_by, installed_at, active"

type SealedTeam {
  SealedTeam(team: Team, sealed: BitArray)
}

fn team_decoder() -> decode.Decoder(SealedTeam) {
  use id <- decode.field(0, decode.string)
  use sealed <- decode.field(1, decode.bit_array)
  use bot_user <- decode.field(2, decode.string)
  use enterprise_id <- decode.field(3, decode.optional(decode.string))
  use installed_by <- decode.field(4, decode.string)
  use installed_at <- decode.field(5, decode.int)
  use active <- decode.field(6, sqlight.decode_bool())
  decode.success(SealedTeam(
    Team(
      id:,
      bot_token: "",
      bot_user:,
      enterprise_id:,
      installed_by:,
      installed_at:,
      active:,
    ),
    sealed,
  ))
}

fn unseal_team(key: BitArray, row: SealedTeam) -> Result(Team, String) {
  sealed.unseal(key, sealed.BotToken, [row.team.id], row.sealed)
  |> result.try(bit_array.to_string)
  |> result.map(fn(token) { Team(..row.team, bot_token: token) })
  |> result.replace_error(
    "can't decrypt the bot token of "
    <> row.team.id
    <> "; is CRUSHLING_STORE_KEY the key it was stored with?",
  )
}

fn read_team(
  connection: sqlight.Connection,
  id: String,
) -> Result(List(SealedTeam), String) {
  store.query(
    connection,
    "SELECT " <> team_columns <> " FROM teams WHERE team_id = ?",
    [sqlight.text(id)],
    team_decoder(),
  )
}

pub fn team(store: Store, id: String) -> Result(Option(Team), String) {
  use connection, key <- store.run(store)
  use rows <- result.try(read_team(connection, id))
  case rows {
    [row, ..] -> unseal_team(key, row) |> result.map(Some)
    [] -> Ok(None)
  }
}

/// Every active team.
pub fn active_teams(store: Store) -> Result(List(Team), String) {
  use connection, key <- store.run(store)
  use rows <- result.try(store.query(
    connection,
    "SELECT "
      <> team_columns
      <> " FROM teams WHERE active = 1 ORDER BY installed_at",
    [],
    team_decoder(),
  ))
  list.try_map(rows, unseal_team(key, _))
}

/// Mark a team inactive (or active again), keeping its row.
pub fn set_active(
  store: Store,
  id: String,
  active: Bool,
) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  store.exec(connection, "UPDATE teams SET active = ? WHERE team_id = ?", [
    sqlight.bool(active),
    sqlight.text(id),
  ])
}

/// The app was removed from a workspace: turn it off and forget its
/// people's GitHub tokens, which nothing there can use any more. Its
/// threads and settings stay for a reinstall.
pub fn uninstall(store: Store, id: String) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  use <- store.transaction(connection)
  use _ <- result.try(
    store.exec(connection, "UPDATE teams SET active = 0 WHERE team_id = ?", [
      sqlight.text(id),
    ]),
  )
  accounts.delete_team(connection, id)
}

// Settings --------------------------------------------------------------------

/// The names settings are kept under.
pub const allowed_users = "allowed_users"

pub const admins = "admins"

pub fn set_setting(
  store: Store,
  team: String,
  name: String,
  value: String,
) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  write_setting(connection, team, name, value)
}

fn write_setting(
  connection: sqlight.Connection,
  team: String,
  name: String,
  value: String,
) -> Result(Nil, String) {
  store.exec(
    connection,
    "INSERT INTO team_settings (team_id, name, value) VALUES (?, ?, ?)
     ON CONFLICT (team_id, name) DO UPDATE SET value = excluded.value",
    [sqlight.text(team), sqlight.text(name), sqlight.text(value)],
  )
}

pub fn settings(
  store: Store,
  team: String,
) -> Result(Dict(String, String), String) {
  use connection, _ <- store.run(store)
  store.query(
    connection,
    "SELECT name, value FROM team_settings WHERE team_id = ?",
    [sqlight.text(team)],
    {
      use name <- decode.field(0, decode.string)
      use value <- decode.field(1, decode.string)
      decode.success(#(name, value))
    },
  )
  |> result.map(dict.from_list)
}

pub fn setting(
  store: Store,
  team: String,
  name: String,
) -> Result(Option(String), String) {
  settings(store, team)
  |> result.map(fn(all) { dict.get(all, name) |> option.from_result })
}
