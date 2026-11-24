//// GitHub reads through the bridge: the route against a fake GitHub, the
//// thread tokens, the sandbox's git settings, and the read-only check on
//// GraphQL.

import crushling/github/route
import crushling/gun
import crushling/relay
import crushling/sandbox_http
import crushling/token
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mist

const secret = "test-secret"

/// Connected as ghu_a.
const connected = "T1-C1-1.0"

/// Not connected.
const anonymous = "T1-C2-1.0"

/// The token lookup fails.
const broken = "T1-C3-1.0"

/// Not connected, but connects (as ghu_late) when asked.
const late = "T1-C4-1.0"

// Tokens --------------------------------------------------------------------

pub fn bound_tokens_name_their_thread_test() {
  let bound = token.bound(secret, token.GitHub, "T1-C1-1795.000100")
  let assert Ok("T1-C1-1795.000100") = token.opened(secret, token.GitHub, bound)
  // Not for another purpose, another secret, or with the key swapped.
  let assert Error(Nil) = token.opened(secret, token.Proxy, bound)
  let assert Error(Nil) = token.opened("other", token.GitHub, bound)
  let mac = token.mint(secret, token.GitHub, "T1-C1-1795.000100")
  let assert Error(Nil) =
    token.opened(secret, token.GitHub, "T1-C9-1795.000100." <> mac)
  let assert Error(Nil) = token.opened(secret, token.GitHub, mac)
  let assert Error(Nil) = token.opened(secret, token.GitHub, "")
}

pub fn sandbox_env_test() {
  let env = route.env("http://172.30.0.1:7469", secret, connected)
  let bound = token.bound(secret, token.GitHub, connected)
  let assert True = list.contains(env, "GH_TOKEN=" <> bound)
  let assert True = list.contains(env, "GIT_CONFIG_COUNT=4")
  let base = "url.http://172.30.0.1:7469/git/.insteadOf"
  let assert True = list.contains(env, "GIT_CONFIG_KEY_0=" <> base)
  let assert True = list.contains(env, "GIT_CONFIG_VALUE_0=https://github.com/")
  let assert True = list.contains(env, "GIT_CONFIG_VALUE_1=git@github.com:")
  let assert True =
    list.contains(env, "GIT_CONFIG_VALUE_3=Authorization: Bearer " <> bound)
}

pub fn only_reads_test() {
  let q = fn(query) {
    route.only_reads(bit_array.from_string(
      "{\"query\":" <> string.inspect(query) <> "}",
    ))
  }
  let assert True = q("query { viewer { login } }")
  let assert True = q("{ repository(owner: \"a\", name: \"b\") { id } }")
  let assert False = q("mutation { addStar(input: {}) { clientMutationId } }")
  let assert False = q("  # a comment\n mutation M { x }")
  let assert False = q("subscription { x }")
  let assert False = q("query A { a } mutation B { b }")
  // Only outside strings and comments.
  let assert True = q("{ search(query: \"mutation testing\") { issueCount } }")
  let assert True = q("# mutation\n{ viewer { login } }")
  let assert True = q("{ a(b: \"\"\"say \\\"\"\" mutation\"\"\") }")
  // Not GraphQL at all.
  let assert False = route.only_reads(<<"mutation { x }">>)
  let assert False = route.only_reads(<<"{\"variables\":{}}">>)
}

// The route against a fake GitHub ---------------------------------------------

type Arrival {
  Arrival(
    method: http.Method,
    path: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

const big = 5_000_000

/// What's true at the fake GitHub, changed as the test goes.
type Flags =
  Subject(#(String, Subject(Bool)))

fn flags() -> #(Flags, fn(String) -> Nil) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let asks = process.new_subject()
    let sets = process.new_subject()
    process.send(ready, #(asks, sets))
    flags_loop(asks, sets, [])
  })
  let assert Ok(#(asks, sets)) = process.receive(ready, 1000)
  #(asks, fn(flag) { process.send(sets, flag) })
}

fn flags_loop(
  asks: Subject(#(String, Subject(Bool))),
  sets: Subject(String),
  set: List(String),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(asks, fn(ask) { Ok(ask) })
    |> process.select_map(sets, Error)
  case process.selector_receive_forever(selector) {
    Ok(#(flag, reply)) -> {
      process.send(reply, list.contains(set, flag))
      flags_loop(asks, sets, set)
    }
    Error(flag) -> flags_loop(asks, sets, [flag, ..set])
  }
}

fn has(flags: Flags, flag: String) -> Bool {
  process.call(flags, 1000, fn(reply) { #(flag, reply) })
}

/// A GitHub that answers by path and says what it was asked.
/// `octo/elsewhere` reads only once the app is installed there.
fn fake_github(arrivals: Subject(Arrival), flags: Flags) -> Int {
  serve(fn(req: Request(mist.Connection)) {
    let body = case mist.read_body(req, 10_000_000) {
      Ok(req) -> req.body
      Error(_) -> <<>>
    }
    let path =
      req.path <> option.map(req.query, fn(q) { "?" <> q }) |> option.unwrap("")
    process.send(arrivals, Arrival(req.method, path, req.headers, body))
    let authed = request.get_header(req, "authorization") |> result.is_ok
    let #(status, headers, text) = case req.path, authed {
      "/octo/public/info/refs", _ -> #(200, [], "refs")
      "/octo/private/info/refs", True -> #(200, [], "refs")
      "/octo/private/info/refs", False -> #(401, [], "no")
      "/octo/gone/info/refs", _ -> #(404, [], "no")
      "/octo/private/git-receive-pack", True -> #(200, [], "pushed")
      "/octo/private/git-receive-pack", False -> #(401, [], "no")
      "/octo/elsewhere/info/refs", True ->
        case has(flags, "installed") {
          True -> #(200, [], "refs")
          False -> #(404, [], "no")
        }
      "/octo/moved/info/refs", _ -> #(
        301,
        [#("location", "https://github.com/octo/new/info/refs")],
        "",
      )
      "/octo/public/git-upload-pack", _ -> #(200, [], string.repeat("p", big))
      "/repos/octo/public", _ -> #(200, [], "{\"name\":\"public\"}")
      "/repos/octo/private", True -> #(200, [], "{\"name\":\"private\"}")
      "/repos/octo/private", False -> #(404, [], "{\"message\":\"Not Found\"}")
      "/graphql", True -> #(200, [], "{\"data\":{}}")
      "/graphql", False -> #(401, [], "{\"message\":\"no\"}")
      _, _ -> #(404, [], "")
    }
    list.fold(headers, response.new(status), fn(resp, header) {
      response.set_header(resp, header.0, header.1)
    })
    |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
  })
}

fn serve(
  handler: fn(Request(mist.Connection)) -> response.Response(mist.ResponseData),
) -> Int {
  let port = process.new_subject()
  let assert Ok(_) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port, p) })
    |> mist.start
  let assert Ok(port) = process.receive(port, 5000)
  port
}

type Setup {
  Setup(bridge: Int, arrivals: Subject(Arrival), nudged: Subject(route.Want))
}

/// The person of thread `late` connects when asked, and `octo/elsewhere`
/// gets the app once someone is asked to add it there.
fn setup() -> Setup {
  let arrivals = process.new_subject()
  let nudged = process.new_subject()
  let #(flags, set) = flags()
  let github = relay.Upstream("127.0.0.1", fake_github(arrivals, flags), False)
  let handler =
    route.route(route.Setup(
      secret:,
      access: fn(key) {
        case key {
          "T1-C1-1.0" -> Ok(Some("ghu_a"))
          "T1-C3-1.0" -> Error("store down")
          "T1-C4-1.0" ->
            case has(flags, "connected") {
              True -> Ok(Some("ghu_late"))
              False -> Ok(None)
            }
          _ -> Ok(None)
        }
      },
      web: github,
      api: github,
      bridge_url: "http://172.30.0.1:7469",
      // The app's token is only for the public repo.
      app_token: fn(owner, repo) {
        case owner, repo {
          "octo", "public" -> Some("ghs_app")
          _, _ -> None
        }
      },
      installed: fn(owner, repo) {
        case owner, repo {
          "octo", "elsewhere" -> Some(has(flags, "installed"))
          "octo", "never" -> Some(False)
          _, _ -> Some(True)
        }
      },
      ask: fn(key, want) {
        process.send(nudged, want)
        case key, want {
          "T1-C4-1.0", route.Connection(..) -> set("connected")
          _, route.Install("octo", "elsewhere") -> set("installed")
          _, _ -> Nil
        }
      },
      wait_ms: 1000,
      poll_ms: 20,
    ))
  let bridge =
    serve(fn(req) {
      handler(req) |> option.unwrap(sandbox_http.reply(404, "not mine"))
    })
  Setup(bridge:, arrivals:, nudged:)
}

/// Each request from a process of its own, so gun's messages about the
/// connection don't outlive it in the test's mailbox.
fn ask(
  setup: Setup,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> gun.Response {
  let done = process.new_subject()
  process.spawn(fn() {
    let assert Ok(conn) =
      gun.connect_tcp("127.0.0.1", setup.bridge, False, 2000)
    let assert Ok(resp) = gun.request(conn, method, path, headers, body, 10_000)
    gun.close(conn)
    process.send(done, resp)
  })
  let assert Ok(resp) = process.receive(done, 15_000)
  resp
}

fn as_thread(key: String) -> #(String, String) {
  #("authorization", "Bearer " <> token.bound(secret, token.GitHub, key))
}

fn git_get(setup: Setup, key: String, path: String) -> gun.Response {
  ask(setup, http.Get, path, [as_thread(key)], <<>>)
}

fn api_get(setup: Setup, key: String, path: String) -> gun.Response {
  // gh sends its token as `token`, to api.github.com.
  ask(
    setup,
    http.Get,
    path,
    [
      #("host", "api.github.com"),
      #("authorization", "token " <> token.bound(secret, token.GitHub, key)),
    ],
    <<>>,
  )
}

fn arrived(setup: Setup) -> Arrival {
  let assert Ok(arrival) = process.receive(setup.arrivals, 2000)
  arrival
}

fn nothing_arrived(setup: Setup) -> Bool {
  process.receive(setup.arrivals, 200) == Error(Nil)
}

fn header(arrival: Arrival, name: String) -> Result(String, Nil) {
  list.key_find(arrival.headers, name)
}

fn text(resp: gun.Response) -> String {
  bit_array.to_string(resp.body) |> result.unwrap("")
}

pub fn git_fetches_as_the_person_test() {
  let s = setup()
  let resp =
    git_get(s, connected, "/git/octo/private/info/refs?service=git-upload-pack")
  let assert 200 = resp.status
  let assert "refs" = text(resp)
  let arrival = arrived(s)
  let assert "/octo/private/info/refs?service=git-upload-pack" = arrival.path
  // The person's token, as git sends one; never the thread's.
  let basic = bit_array.base64_encode(<<"x-access-token:ghu_a":utf8>>, True)
  let assert Ok(auth) = header(arrival, "authorization")
  let assert True = auth == "Basic " <> basic
}

pub fn git_without_a_connection_reads_public_repos_test() {
  let s = setup()
  let resp =
    git_get(s, anonymous, "/git/octo/public/info/refs?service=git-upload-pack")
  let assert 200 = resp.status
  // With the app's token, not the person's.
  let basic = bit_array.base64_encode(<<"x-access-token:ghs_app":utf8>>, True)
  let assert Ok(auth) = header(arrived(s), "authorization")
  let assert True = auth == "Basic " <> basic
  let assert Error(Nil) = process.receive(s.nudged, 50)
  // A private one is answered in words git shows, saying what to do.
  let resp =
    git_get(s, anonymous, "/git/octo/private/info/refs?service=git-upload-pack")
  let assert 403 = resp.status
  let assert Ok("text/plain" <> _) = list.key_find(resp.headers, "content-type")
  let assert True = string.contains(text(resp), "octo/private isn't public")
  let assert True = string.contains(text(resp), "asked them in this thread")
  // They were asked, for that repo, before the answer.
  let assert Ok(route.Connection(Some("octo/private"))) =
    process.receive(s.nudged, 0)
  let assert Error(Nil) = header(arrived(s), "authorization")
  // Connected but not found: it may be the app's installation.
  let resp =
    git_get(
      s,
      connected,
      "/git/octo/gone.git/info/refs?service=git-upload-pack",
    )
  let assert 403 = resp.status
  let assert True = string.contains(text(resp), "octo/gone can't be read")
  let assert True = string.contains(text(resp), "don't have access")
  // Someone connected isn't asked to connect.
  let assert Error(Nil) = process.receive(s.nudged, 100)
}

/// A read that needs the person's connection waits for it, then goes
/// through as them: the agent sees one command that succeeded.
pub fn a_read_waits_for_the_connection_test() {
  let s = setup()
  let resp =
    git_get(s, late, "/git/octo/private/info/refs?service=git-upload-pack")
  let assert 200 = resp.status
  let assert "refs" = text(resp)
  let assert Error(Nil) = header(arrived(s), "authorization")
  let basic = bit_array.base64_encode(<<"x-access-token:ghu_late":utf8>>, True)
  let assert Ok(auth) = header(arrived(s), "authorization")
  let assert True = auth == "Basic " <> basic
  let assert Ok(route.Connection(Some("octo/private"))) =
    process.receive(s.nudged, 0)
  // Connected now, the next read goes straight through as them.
  let resp =
    ask(
      s,
      http.Post,
      "/graphql",
      [
        #("host", "api.github.com"),
        #("authorization", "token " <> token.bound(secret, token.GitHub, late)),
      ],
      <<"{\"query\":\"{ viewer { login } }\"}">>,
    )
  let assert 200 = resp.status
  let again = arrived(s)
  let assert Ok("Bearer ghu_late") = header(again, "authorization")
  let assert True = again.body == <<"{\"query\":\"{ viewer { login } }\"}">>
  let assert Error(Nil) = process.receive(s.nudged, 0)
}

/// A GraphQL read that waits for the connection is sent again, body and
/// all.
pub fn a_resent_read_keeps_its_body_test() {
  let s = setup()
  let body = <<"{\"query\":\"{ viewer { login } }\"}">>
  let resp =
    ask(
      s,
      http.Post,
      "/graphql",
      [
        #("host", "api.github.com"),
        #("authorization", "token " <> token.bound(secret, token.GitHub, late)),
      ],
      body,
    )
  let assert 200 = resp.status
  let assert Error(Nil) = header(arrived(s), "authorization")
  let again = arrived(s)
  let assert Ok("Bearer ghu_late") = header(again, "authorization")
  let assert True = again.body == body
  let assert Ok(route.Connection(None)) = process.receive(s.nudged, 0)
}

/// Connected, but the app isn't on the repo's account: they're asked to
/// add it, and the read waits, then goes through.
pub fn a_read_waits_for_the_app_test() {
  let s = setup()
  let resp =
    git_get(
      s,
      connected,
      "/git/octo/elsewhere/info/refs?service=git-upload-pack",
    )
  let assert 200 = resp.status
  let assert Ok(route.Install("octo", "elsewhere")) =
    process.receive(s.nudged, 0)
  // Where it never comes, the agent is told why.
  let resp =
    git_get(s, connected, "/git/octo/never/info/refs?service=git-upload-pack")
  let assert 403 = resp.status
  let assert True =
    string.contains(text(resp), "GitHub App isn't installed on octo")
  let assert Ok(route.Install("octo", "never")) = process.receive(s.nudged, 0)
}

pub fn git_streams_a_fetch_test() {
  let s = setup()
  let body = <<"0032want 0123456789012345678901234567890123456789\n":utf8>>
  let resp =
    ask(
      s,
      http.Post,
      "/git/octo/public/git-upload-pack",
      [
        as_thread(connected),
        #("content-type", "application/x-git-upload-pack-request"),
        #("git-protocol", "version=2"),
        #("cookie", "nope"),
      ],
      body,
    )
  let assert 200 = resp.status
  let assert True = bit_array.byte_size(resp.body) == big
  let arrival = arrived(s)
  let assert True = arrival.body == body
  let assert Ok("version=2") = header(arrival, "git-protocol")
  let assert Error(Nil) = header(arrival, "cookie")
}

/// A receive-pack request: its commands, a flush, then the pack.
fn push_body(commands: List(String)) -> BitArray {
  let lines =
    list.index_map(commands, fn(command, i) {
      let line = case i {
        0 -> command <> "\u{0} report-status side-band-64k\n"
        _ -> command <> "\n"
      }
      let length = string.byte_size(line) + 4
      string.pad_start(int.to_base16(length), 4, "0")
      |> string.lowercase
      <> line
    })
  bit_array.from_string(string.concat(lines) <> "0000PACK....")
}

const old = "1111111111111111111111111111111111111111"

const new = "2222222222222222222222222222222222222222"

const none = "0000000000000000000000000000000000000000"

pub fn pushable_test() {
  let assert Ok(Nil) =
    route.pushable(
      push_body([old <> " " <> new <> " refs/heads/crushling/fix"]),
    )
  // A new branch, and a force push, are both fine.
  let assert Ok(Nil) =
    route.pushable(
      push_body([
        none <> " " <> new <> " refs/heads/crushling/a",
        old <> " " <> new <> " refs/heads/crushling/b/c",
      ]),
    )
  let assert Error(why) =
    route.pushable(push_body([old <> " " <> new <> " refs/heads/main"]))
  let assert True = string.contains(why, "refs/heads/main")
  let assert True = string.contains(why, "HEAD:crushling/")
  // One bad ref refuses the whole push.
  let assert Error(_) =
    route.pushable(
      push_body([
        old <> " " <> new <> " refs/heads/crushling/ok",
        old <> " " <> new <> " refs/tags/v1",
      ]),
    )
  let assert Error(why) =
    route.pushable(push_body([old <> " " <> none <> " refs/heads/crushling/x"]))
  let assert True = string.contains(why, "deleting")
  let assert Error(_) =
    route.pushable(push_body([old <> " " <> new <> " refs/heads/crushling/"]))
  let assert Error(_) =
    route.pushable(push_body([old <> " " <> new <> " refs/heads/crushlingx"]))
  let assert Error(_) = route.pushable(<<"garbage">>)
  let assert Error(_) = route.pushable(<<"0000">>)
}

pub fn pushes_go_as_the_person_test() {
  let s = setup()
  // The ref advertisement, then the push.
  let resp =
    git_get(
      s,
      connected,
      "/git/octo/private/info/refs?service=git-receive-pack",
    )
  let assert 200 = resp.status
  let _ = arrived(s)
  let body = push_body([old <> " " <> new <> " refs/heads/crushling/fix"])
  let resp =
    ask(
      s,
      http.Post,
      "/git/octo/private/git-receive-pack",
      [
        as_thread(connected),
        #("content-type", "application/x-git-receive-pack-request"),
      ],
      body,
    )
  let assert 200 = resp.status
  let assert "pushed" = text(resp)
  let arrival = arrived(s)
  let assert True = arrival.body == body
  let basic = bit_array.base64_encode(<<"x-access-token:ghu_a":utf8>>, True)
  let assert Ok(auth) = header(arrival, "authorization")
  let assert True = auth == "Basic " <> basic
}

pub fn pushes_elsewhere_never_reach_github_test() {
  let s = setup()
  let resp =
    ask(
      s,
      http.Post,
      "/git/octo/private/git-receive-pack",
      [as_thread(connected)],
      push_body([old <> " " <> new <> " refs/heads/main"]),
    )
  let assert 403 = resp.status
  let assert True = string.contains(text(resp), "crushling/")
  let assert True = nothing_arrived(s)
}

/// Without a connection, a push waits for one rather than going to GitHub
/// with the app's token or none.
pub fn pushes_wait_for_the_connection_test() {
  let s = setup()
  let body = push_body([old <> " " <> new <> " refs/heads/crushling/fix"])
  let resp =
    ask(
      s,
      http.Post,
      "/git/octo/private/git-receive-pack",
      [as_thread(late)],
      body,
    )
  let assert 200 = resp.status
  let assert Error(Nil) = header(arrived(s), "authorization")
  let again = arrived(s)
  let basic = bit_array.base64_encode(<<"x-access-token:ghu_late":utf8>>, True)
  let assert Ok(auth) = header(again, "authorization")
  let assert True = auth == "Basic " <> basic
  let assert Ok(route.Connection(Some("octo/private"))) =
    process.receive(s.nudged, 0)
}

pub fn lfs_and_odd_paths_are_refused_test() {
  let s = setup()
  let resp = git_get(s, connected, "/git/octo/public/info/lfs/objects/batch")
  let assert 404 = resp.status
  let resp =
    git_get(s, connected, "/git/../etc/info/refs?service=git-upload-pack")
  let assert True = resp.status >= 400
  let assert True = nothing_arrived(s)
}

pub fn git_redirects_stay_on_the_bridge_test() {
  let s = setup()
  let resp =
    git_get(s, connected, "/git/octo/moved/info/refs?service=git-upload-pack")
  let assert 301 = resp.status
  let assert Ok("http://172.30.0.1:7469/git/octo/new/info/refs") =
    list.key_find(resp.headers, "location")
}

pub fn only_thread_tokens_get_through_test() {
  let s = setup()
  let path = "/git/octo/public/info/refs?service=git-upload-pack"
  let assert 401 = ask(s, http.Get, path, [], <<>>).status
  let assert 401 =
    ask(s, http.Get, path, [#("authorization", "Bearer ghu_real")], <<>>).status
  let proxy_token = token.mint(secret, token.Proxy, connected)
  let assert 401 =
    ask(
      s,
      http.Get,
      path,
      [#("authorization", "Bearer " <> connected <> "." <> proxy_token)],
      <<>>,
    ).status
  // git with the token as a password works too.
  let basic =
    bit_array.base64_encode(
      bit_array.from_string(
        "x:" <> token.bound(secret, token.GitHub, connected),
      ),
      True,
    )
  let assert 200 =
    ask(s, http.Get, path, [#("authorization", "Basic " <> basic)], <<>>).status
  let _ = arrived(s)
  // A lookup that fails says so, without reaching GitHub.
  let assert 503 = git_get(s, broken, path).status
  let assert True = nothing_arrived(s)
  // Other hosts and paths are someone else's.
  let assert 404 = ask(s, http.Get, "/repos/octo/public", [], <<>>).status
}

pub fn the_api_reads_as_the_person_test() {
  let s = setup()
  let resp = api_get(s, connected, "/repos/octo/private?per_page=1")
  let assert 200 = resp.status
  let arrival = arrived(s)
  let assert "/repos/octo/private?per_page=1" = arrival.path
  let assert Ok("Bearer ghu_a") = header(arrival, "authorization")
  // Without a connection, public repos read with the app's token, other
  // paths with none, and the rest says what to do.
  let assert 200 = api_get(s, anonymous, "/repos/octo/public").status
  let assert Ok("Bearer ghs_app") = header(arrived(s), "authorization")
  let _ = api_get(s, anonymous, "/search/code?q=secret")
  let assert Error(Nil) = header(arrived(s), "authorization")
  let assert Ok(route.Connection(None)) = process.receive(s.nudged, 0)
  let resp = api_get(s, anonymous, "/repos/octo/private")
  let assert Error(Nil) = header(arrived(s), "authorization")
  let assert 404 = resp.status
  let assert True = string.contains(text(resp), "hasn't connected")
  let assert Ok(route.Connection(Some("octo/private"))) =
    process.receive(s.nudged, 1000)
}

pub fn the_api_only_reads_test() {
  let s = setup()
  let gh = fn(method, path, body) {
    ask(
      s,
      method,
      path,
      [
        #("host", "api.github.com"),
        #(
          "authorization",
          "token " <> token.bound(secret, token.GitHub, connected),
        ),
        #("content-type", "application/json"),
      ],
      body,
    )
  }
  let assert 200 =
    gh(http.Post, "/graphql", <<"{\"query\":\"{ viewer { login } }\"}">>).status
  let arrival = arrived(s)
  let assert True = arrival.body == <<"{\"query\":\"{ viewer { login } }\"}">>
  let refused = gh(http.Post, "/graphql", <<"{\"query\":\"mutation { x }\"}">>)
  let assert 403 = refused.status
  let assert True = string.contains(text(refused), "only lets reads through")
  let assert 403 = gh(http.Post, "/repos/octo/public/issues", <<"{}">>).status
  let assert 403 = gh(http.Delete, "/repos/octo/public", <<>>).status
  let assert 403 = gh(http.Patch, "/repos/octo/public", <<"{}">>).status
  let assert True = nothing_arrived(s)
}

// Real GitHub, with CRUSHLING_REAL=1 --------------------------------------------

@external(erlang, "real_server_ffi", "enabled")
fn enabled() -> Bool

@external(erlang, "real_server_ffi", "timeout")
fn with_timeout(seconds: Int, body: fn() -> Nil) -> Dynamic

@external(erlang, "proxy_test_ffi", "run")
fn run(
  program: String,
  args: List(String),
  env: List(String),
  cwd: String,
  timeout_ms: Int,
) -> #(Int, String)

@external(erlang, "proxy_test_ffi", "tmp_dir")
fn tmp_dir() -> String

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(a: a) -> Dynamic

pub fn real_github_test_() -> Dynamic {
  case enabled() {
    True -> to_dynamic([with_timeout(120, real_clone)])
    False -> to_dynamic([])
  }
}

/// git clones a public repo through the bridge with only the settings a
/// sandbox gets, and the API answers as api.github.com.
fn real_clone() -> Nil {
  let handler =
    route.route(route.Setup(
      secret:,
      access: fn(_) { Ok(None) },
      web: route.github(),
      api: route.github_api(),
      bridge_url: "http://127.0.0.1:1",
      app_token: fn(_, _) { None },
      installed: fn(_, _) { None },
      ask: fn(_, _) { Nil },
      wait_ms: 0,
      poll_ms: 10,
    ))
  let port =
    serve(fn(req) {
      handler(req) |> option.unwrap(sandbox_http.reply(404, "not mine"))
    })
  let bridge = "http://127.0.0.1:" <> int.to_string(port)
  let dir = tmp_dir()
  let env = [
    "PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME=" <> dir,
    "GIT_TERMINAL_PROMPT=0",
    ..route.env(bridge, secret, anonymous)
  ]
  let #(status, out) =
    run(
      "git",
      [
        "clone", "--depth", "1", "https://github.com/charmbracelet/vhs-action",
        "repo",
      ],
      env,
      dir,
      90_000,
    )
  let assert 0 = status as out
  let #(_, log) =
    run("git", ["-C", "repo", "config", "remote.origin.url"], env, dir, 5000)
  let assert True = string.contains(log, "https://github.com/") as log
  // A private one says what to do.
  let #(status, out) =
    run(
      "git",
      ["ls-remote", "https://github.com/charmbracelet/no-such-repo-crushling"],
      env,
      dir,
      30_000,
    )
  let assert True = status != 0
  let assert True = string.contains(out, "remote: crushling:") as out
  let resp =
    ask(
      Setup(
        bridge: port,
        arrivals: process.new_subject(),
        nudged: process.new_subject(),
      ),
      http.Get,
      "/repos/charmbracelet/crush",
      [
        #("host", "api.github.com"),
        #("user-agent", "crushling-test"),
        #(
          "authorization",
          "token " <> token.bound(secret, token.GitHub, anonymous),
        ),
      ],
      <<>>,
    )
  let assert 200 = resp.status
  let assert True = string.contains(text(resp), "\"full_name\"")
  Nil
}
