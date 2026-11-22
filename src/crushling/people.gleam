//// Who may use crushling in a workspace: listed Slack user ids, and maybe
//// everyone (`*`).
////
//// "Everyone" means the workspace's full members only, since agents run
//// with no permission prompts: not guests, not people from other
//// workspaces in Slack Connect channels, not bots or apps, not deactivated
//// accounts. Message events don't say which workspace their author is from,
//// so membership is looked up with users.info, and the answer kept for a
//// while (`Cache`). A listed id never needs a lookup.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline
import slackline/api/users
import slackline/api/users/info as users_info
import slackline/httpc
import slackline/user.{type User}

pub type People {
  People(everyone: Bool, ids: Set(String))
}

/// Nobody at all.
pub fn nobody() -> People {
  People(everyone: False, ids: set.new())
}

/// Just these ids.
pub fn only(ids: List(String)) -> People {
  People(everyone: False, ids: set.from_list(ids))
}

/// A comma-separated list of user ids, where `*` means everyone in the
/// workspace, listed ids or not.
pub fn parse(text: String) -> People {
  let items =
    string.split(text, ",")
    |> list.map(string.trim)
    |> list.filter(fn(item) { item != "" })
  People(
    everyone: list.contains(items, "*"),
    ids: list.filter(items, fn(item) { item != "*" }) |> set.from_list,
  )
}

pub fn is_empty(people: People) -> Bool {
  !people.everyone && set.is_empty(people.ids)
}

/// Whether `user` is allowed. `check` says whether someone is a member of
/// the workspace; it is asked only for everyone, and never for a listed id.
pub fn allows(people: People, user: String, check: fn(String) -> Bool) -> Bool {
  set.contains(people.ids, user) || people.everyone && check(user)
}

/// Whether allowing `user` depends on their membership.
pub fn needs_lookup(people: People, user: String) -> Bool {
  people.everyone && !set.contains(people.ids, user)
}

/// For logs: "everyone" or how many ids.
pub fn describe(people: People) -> String {
  case people.everyone {
    True -> "everyone in the workspace (members only)"
    False -> string.inspect(set.size(people.ids)) <> " allowed users"
  }
}

/// Whether a Slack user, as users.info describes them, is a full member of
/// workspace `team`. Org-wide (Enterprise Grid) installs aren't supported,
/// so the user's own workspace must be `team`.
pub fn is_member(person: User, team: String) -> Bool {
  let yes = fn(flag: Option(Bool)) { option.unwrap(flag, False) }
  person.team_id == Some(team)
  && person.id != "USLACKBOT"
  && !yes(person.deleted)
  && !yes(person.is_restricted)
  && !yes(person.is_ultra_restricted)
  && !yes(person.is_bot)
  && !yes(person.is_workflow_bot)
  && !yes(person.is_agentforce_bot)
}

/// Ask Slack whether `user` is a full member of workspace `team`.
pub fn lookup(
  client: slackline.Client,
  team: String,
  user: String,
) -> Result(Bool, String) {
  use found <- result.try(
    users.info()
    |> users_info.user(user)
    |> httpc.send(client)
    |> result.map_error(fn(error) {
      "users.info: " <> slackline.describe_error(error)
    }),
  )
  case found.user {
    Some(person) -> Ok(is_member(person, team))
    None -> Error("users.info: no user in the answer")
  }
}

// CACHE -----------------------------------------------------------------------

/// How long a lookup's answer is kept, yes or no.
pub const cache_ms = 600_000

/// Membership answers for one workspace, each until it expires.
pub opaque type Cache {
  Cache(entries: Dict(String, #(Bool, Int)), ttl_ms: Int)
}

pub fn new_cache(ttl_ms: Int) -> Cache {
  Cache(entries: dict.new(), ttl_ms:)
}

/// What is known about `user` at `now_ms`, if it hasn't expired.
pub fn cached(cache: Cache, user: String, now_ms: Int) -> Option(Bool) {
  case dict.get(cache.entries, user) {
    Ok(#(member, until)) if until > now_ms -> Some(member)
    _ -> None
  }
}

/// Keep an answer for `ttl_ms` from `now_ms`. Expired answers go.
pub fn remember(
  cache: Cache,
  user: String,
  member: Bool,
  now_ms: Int,
) -> Cache {
  let entries =
    dict.filter(cache.entries, fn(_, entry) { entry.1 > now_ms })
    |> dict.insert(user, #(member, now_ms + cache.ttl_ms))
  Cache(..cache, entries:)
}

pub fn forget(cache: Cache, user: String) -> Cache {
  Cache(..cache, entries: dict.delete(cache.entries, user))
}
