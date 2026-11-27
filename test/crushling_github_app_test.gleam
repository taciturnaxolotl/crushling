//// The GitHub App's own token: the JWT, and that it is only handed out for
//// public repos.

import crushling/github
import crushling/github/app
import crushling/github/repo
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "test_fs_ffi", "rsa_pem")
fn rsa_pem() -> String

@external(erlang, "test_fs_ffi", "rs256_ok")
fn rs256_ok(pem: String, data: BitArray, sig: BitArray) -> Bool

pub fn keys_parse_test() {
  let pem = rsa_pem()
  let assert Ok(_) = app.parse_key(pem)
  // An env file holds one line: base64 of it, or `\n` for newlines.
  let assert Ok(_) =
    app.parse_key(bit_array.base64_encode(bit_array.from_string(pem), True))
  let assert Ok(_) = app.parse_key(string.replace(pem, "\n", "\\n"))
  let assert Error(Nil) = app.parse_key("nope")
  let assert Error(Nil) = app.parse_key("")
}

pub fn jwt_test() {
  let pem = rsa_pem()
  let assert Ok(key) = app.parse_key(pem)
  let jwt = app.jwt("Iv23.test", key, 1000)
  let assert [head, claims, sig] = string.split(jwt, ".")
  let decode_part = fn(part) {
    let assert Ok(bits) = bit_array.base64_url_decode(part)
    let assert Ok(text) = bit_array.to_string(bits)
    text
  }
  let assert Ok("RS256") =
    json.parse(decode_part(head), decode.at(["alg"], decode.string))
  let claims = decode_part(claims)
  let assert Ok("Iv23.test") =
    json.parse(claims, decode.at(["iss"], decode.string))
  let assert Ok(940) = json.parse(claims, decode.at(["iat"], decode.int))
  let assert Ok(1540) = json.parse(claims, decode.at(["exp"], decode.int))
  let assert Ok(sig) = bit_array.base64_url_decode(sig)
  let assert [_, raw_claims, _] = string.split(jwt, ".")
  let signed = bit_array.from_string(head <> "." <> raw_claims)
  let assert True = rs256_ok(pem, signed, sig)
}

/// A GitHub with one installation, where `octo/public` is public and
/// `octo/private` isn't.
fn fake(seen: Subject(Request(String))) -> github.Config {
  github.Config(client_id: "Iv23.test", client_secret: None, send: fn(req) {
    process.send(seen, req)
    let #(status, body) = case req.path {
      "/app/installations" -> #(200, "[{\"id\":7}]")
      "/app/installations/7/access_tokens" -> #(201, "{\"token\":\"ghs_x\"}")
      "/repos/octo/public" -> #(200, "{\"private\":false}")
      "/repos/octo/private" -> #(200, "{\"private\":true}")
      "/repos/octo/flaky" -> #(502, "")
      "/repos/octo/hyper/installation" -> #(200, "{}")
      "/users/octo/installation" -> #(200, "{\"repository_selection\":\"all\"}")
      "/users/picky/installation" -> #(
        200,
        "{\"repository_selection\":\"selected\"}",
      )
      _ -> #(404, "{}")
    }
    Ok(response.new(status) |> response.set_body(body))
  })
}

pub fn only_public_repos_get_the_token_test() {
  let seen = process.new_subject()
  let assert Ok(key) = app.parse_key(rsa_pem())
  let assert Ok(a) = app.start(fake(seen), key)
  let assert Some("ghs_x") = app.token(a, r("octo", "public"))
  let assert None = app.token(a, r("octo", "private"))
  let assert None = app.token(a, r("octo", "missing"))
  // The JWT was used for the app's own calls, the token for the rest.
  let assert Ok(first) = process.receive(seen, 100)
  let assert "/app/installations" = first.path
  let assert Ok("Bearer " <> jwt) = request.get_header(first, "authorization")
  let assert 3 = list.length(string.split(jwt, "."))
  let assert Ok(_) = process.receive(seen, 100)
  let assert Ok(asked) = process.receive(seen, 100)
  let assert Ok("Bearer ghs_x") = request.get_header(asked, "authorization")
  drain(seen)
  // Answers and the token are remembered.
  let assert Some("ghs_x") = app.token(a, r("octo", "public"))
  let assert None = app.token(a, r("OCTO", "Private"))
  let assert Error(Nil) = process.receive(seen, 50)
}

fn drain(seen: Subject(a)) -> Nil {
  case process.receive(seen, 50) {
    Ok(_) -> drain(seen)
    Error(Nil) -> Nil
  }
}

/// GitHub says 404 for a repo the app can't see and for one that doesn't
/// exist: on an account it's installed on whole, it's the latter.
pub fn installed_test() {
  let assert Ok(key) = app.parse_key(rsa_pem())
  let assert Ok(a) = app.start(fake(process.new_subject()), key)
  let assert Ok(True) = app.installed(a, r("octo", "hyper"))
  // No such repo, on an account with every repo: nothing to install.
  let assert Ok(True) = app.installed(a, r("octo", "nope"))
  // On an account with some repos: it may need adding.
  let assert Ok(False) = app.installed(a, r("picky", "nope"))
  // On an account without the app.
  let assert Ok(False) = app.installed(a, r("stranger", "repo"))
}

fn r(owner: String, name: String) -> repo.Repo {
  let assert Ok(found) = repo.parse_path(owner, name)
  found
}

/// GitHub not answering is neither public nor private, and isn't
/// remembered as either.
pub fn unknown_is_not_no_test() {
  let seen = process.new_subject()
  let assert Ok(key) = app.parse_key(rsa_pem())
  let assert Ok(a) = app.start(fake(seen), key)
  let assert Error(app.Unknown(_)) = app.public(a, r("octo", "flaky"))
  let assert Ok(True) = app.public(a, r("octo", "public"))
  drain(seen)
  let assert Error(app.Unknown(_)) = app.public(a, r("octo", "flaky"))
  let assert Ok(flaky) = process.receive(seen, 100)
  let assert "/repos/octo/flaky" = flaky.path
}

/// Everyone asking the same thing at once shares one request.
pub fn questions_are_shared_test() {
  let seen = process.new_subject()
  let assert Ok(key) = app.parse_key(rsa_pem())
  let assert Ok(a) = app.start(fake(seen), key)
  let answers = process.new_subject()
  list.each([1, 2, 3, 4], fn(_) {
    process.spawn(fn() {
      process.send(answers, app.installed(a, r("octo", "hyper")))
    })
  })
  list.each([1, 2, 3, 4], fn(_) {
    let assert Ok(Ok(True)) = process.receive(answers, 5000)
  })
  let assert Ok(asked) = process.receive(seen, 100)
  let assert "/repos/octo/hyper/installation" = asked.path
  let assert Error(Nil) = process.receive(seen, 100)
}
