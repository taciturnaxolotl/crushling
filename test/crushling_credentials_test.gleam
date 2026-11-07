import crushling/credentials
import crushling/provider
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import test_fs as fs

@external(erlang, "os", "system_time")
fn system_time(unit: SecondUnit) -> Int

type SecondUnit {
  Second
}

fn login_file(
  name: String,
  provider: String,
  expires_at: Int,
  expires_in: Int,
) -> String {
  let path = "/tmp/crushling-cred-" <> name <> ".json"
  fs.write(
    path,
    "{\"options\":{\"keep\":true},\"providers\":{\""
      <> provider
      <> "\":{\"api_key\":\"a1\",\"oauth\":{\"access_token\":\"a1\",\"refresh_token\":\"r1\",\"expires_at\":"
      <> string.inspect(expires_at)
      <> ",\"expires_in\":"
      <> string.inspect(expires_in)
      <> "}}}}",
  )
  path
}

/// A container's crush.json before its token is added.
fn container_file(name: String) -> String {
  let path = "/tmp/crushling-cred-container-" <> name <> ".json"
  fs.write(
    path,
    provider.config(provider.Claude("/unused", "2.1.300", "big", "small")),
  )
  path
}

fn refresher(calls: process.Subject(String), next: String, expires_in: Int) {
  fn(refresh_token) {
    process.send(calls, refresh_token)
    Ok(credentials.Grant("a" <> next, "r" <> next, expires_in))
  }
}

fn calls_made(calls: process.Subject(String)) -> List(String) {
  case process.receive(calls, 0) {
    Ok(call) -> [call, ..calls_made(calls)]
    Error(Nil) -> []
  }
}

fn field(path: String, at: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(fs.read(path), decode.at(at, decoder))
  value
}

fn oauth(path: String, provider: String, name: String) -> String {
  field(path, ["providers", provider, "oauth", name], decode.string)
}

pub fn fresh_login_is_published_without_refresh_test() {
  let now = system_time(Second)
  let login = login_file("fresh", "anthropic", now + 3600, 3600)
  let calls = process.new_subject()
  let assert Ok(c) =
    credentials.start(credentials.Login(
      "anthropic",
      login,
      refresher(calls, "2", 3600),
    ))
  let container = container_file("fresh")
  let assert Ok(Nil) = credentials.watch(c, container)
  let assert [] = calls_made(calls)

  let assert "a1" = oauth(container, "anthropic", "access_token")
  let assert "" = oauth(container, "anthropic", "refresh_token")
  let assert "a1" =
    field(container, ["providers", "anthropic", "api_key"], decode.string)
  // The container's own settings survive.
  let assert "big" =
    field(container, ["models", "large", "model"], decode.string)
}

pub fn half_expired_login_is_refreshed_saved_and_published_test() {
  let now = system_time(Second)
  let login = login_file("stale", "hyper", now + 1000, 3600)
  let calls = process.new_subject()
  let assert Ok(c) =
    credentials.start(credentials.Login(
      "hyper",
      login,
      refresher(calls, "2", 3600),
    ))
  let container = container_file("stale")
  let assert Ok(Nil) = credentials.watch(c, container)
  let assert ["r1"] = calls_made(calls)

  let assert "a2" = oauth(login, "hyper", "access_token")
  let assert "r2" = oauth(login, "hyper", "refresh_token")
  let assert Ok(True) =
    json.parse(fs.read(login), decode.at(["options", "keep"], decode.bool))

  let assert "a2" = oauth(container, "hyper", "access_token")
  let assert "" = oauth(container, "hyper", "refresh_token")
}

pub fn renewals_reach_every_watched_file_test() {
  let now = system_time(Second)
  // Lives 4s, so renewal is due after 2s.
  let login = login_file("renew", "anthropic", now + 4, 4)
  let calls = process.new_subject()
  let assert Ok(c) =
    credentials.start(credentials.Login(
      "anthropic",
      login,
      refresher(calls, "2", 3600),
    ))
  let one = container_file("renew-one")
  let two = container_file("renew-two")
  let assert Ok(Nil) = credentials.watch(c, one)
  let assert Ok(Nil) = credentials.watch(c, two)
  let assert "a1" = oauth(one, "anthropic", "access_token")
  let assert Ok("r1") = process.receive(calls, 5000)
  process.sleep(100)
  let assert "a2" = oauth(one, "anthropic", "access_token")
  let assert "a2" = oauth(two, "anthropic", "access_token")
}

pub fn unwatched_files_are_left_alone_test() {
  let now = system_time(Second)
  let login = login_file("unwatch", "anthropic", now + 4, 4)
  let calls = process.new_subject()
  let assert Ok(c) =
    credentials.start(credentials.Login(
      "anthropic",
      login,
      refresher(calls, "2", 3600),
    ))
  let container = container_file("unwatch")
  let assert Ok(Nil) = credentials.watch(c, container)
  credentials.unwatch(c, container)
  let assert Ok("r1") = process.receive(calls, 5000)
  process.sleep(100)
  let assert "a1" = oauth(container, "anthropic", "access_token")
}

pub fn failed_refresh_is_an_error_and_names_the_fix_test() {
  let now = system_time(Second)
  let login = login_file("revoked", "anthropic", now - 10, 3600)
  let calls = process.new_subject()
  let failing = fn(token) {
    process.send(calls, token)
    Error("invalid_grant")
  }
  let assert Ok(c) =
    credentials.start(credentials.Login("anthropic", login, failing))
  let assert Error(message) = credentials.watch(c, container_file("revoked"))
  let assert True = string.contains(message, "crush login")
  let assert True = string.contains(message, "invalid_grant")
}

pub fn missing_login_is_an_error_test() {
  let calls = process.new_subject()
  let assert Ok(c) =
    credentials.start(credentials.Login(
      "anthropic",
      "/tmp/crushling-no-such-login.json",
      refresher(calls, "2", 3600),
    ))
  let assert Error(_) = credentials.watch(c, container_file("missing"))
  let assert [] = calls_made(calls)
}

pub fn container_configs_test() {
  let claude = provider.Claude("/x", "2.1.300", "opus", "haiku")
  let config = provider.config(claude)
  let assert False = string.contains(config, "/x")
  let assert Ok("haiku") =
    json.parse(config, decode.at(["models", "small", "model"], decode.string))
  let assert Ok("anthropic") =
    json.parse(
      config,
      decode.at(["models", "large", "provider"], decode.string),
    )
  let assert ["CRUSH_CLAUDE_VERSION=2.1.300"] = provider.env(claude)
  let assert Some(credentials.Login(provider: "anthropic", path: "/x", ..)) =
    provider.login(claude)

  let assert Some(credentials.Login(provider: "hyper", ..)) =
    provider.login(provider.Hyper("/h", "d", "p"))

  let key = provider.HyperKey("sk-k", "d", "p")
  let assert None = provider.login(key)
  let assert Ok("sk-k") =
    json.parse(
      provider.config(key),
      decode.at(["providers", "hyper", "api_key"], decode.string),
    )
  let assert [] = provider.env(key)
}

pub fn extra_backends_add_providers_test() {
  let main = provider.HyperKey("k", "big", "small")
  let claude = provider.Claude("/claude.json", "2.1.300", "x", "y")
  let config = provider.config_for(main, [claude, claude], "")
  // Both providers are there for subagents; the agent's own models stay
  // on the main one.
  let assert True =
    string.contains(
      config,
      "\"providers\":{\"hyper\":{\"api_key\":\"k\"},\"anthropic\":{}}",
    )
  let assert True =
    string.contains(
      config,
      "\"large\":{\"provider\":\"hyper\",\"model\":\"big\"}",
    )
  let assert ["CRUSH_CLAUDE_VERSION=2.1.300"] = provider.env_for(main, [claude])
  let assert [_] = provider.logins(main, [claude])
  // An extra that repeats the main provider adds nothing.
  let assert [] = provider.logins(main, [provider.HyperKey("k2", "a", "b")])
}
