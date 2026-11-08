//// The Tailscale API and the scripts that put a sandbox on the tailnet.
//// A sandbox joins as an ephemeral node with in-memory state, so logging
//// out or stopping its container takes the node off the tailnet for good.
//// `tailscaled` runs in userspace mode, which needs no TUN device.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

pub type Credential {
  /// An API access token (`tskey-api-…`). It expires after 90 days.
  ApiKey(String)
  /// An OAuth client with the `auth_keys` scope that owns the tag.
  OAuthClient(id: String, secret: String)
}

pub type Config {
  Config(
    credential: Credential,
    /// The tag every sandbox node gets, such as `tag:crushling`.
    tag: String,
    /// The tailnet's name, or "-" for the credential's own.
    tailnet: String,
  )
}

const api = "https://api.tailscale.com/api/v2"

/// The SOCKS5 proxy into the tailnet, inside the container.
pub const socks_port = 1055

/// The HTTP proxy into the tailnet, inside the container.
pub const http_port = 1056

fn send(req: request.Request(String)) -> Result(String, String) {
  case httpc.send(req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    Ok(response) ->
      Error(
        "Tailscale answered "
        <> int.to_string(response.status)
        <> ": "
        <> string.slice(response.body, 0, 300),
      )
    Error(error) -> Error("Tailscale: " <> string.inspect(error))
  }
}

fn post(
  path: String,
  content_type: String,
  body: String,
) -> request.Request(String) {
  let assert Ok(req) = request.to(api <> path)
  req
  |> request.set_method(http.Post)
  |> request.set_header("content-type", content_type)
  |> request.set_body(body)
}

fn token(config: Config) -> Result(String, String) {
  case config.credential {
    ApiKey(key) -> Ok(key)
    OAuthClient(id:, secret:) -> {
      let form =
        uri.query_to_string([#("client_id", id), #("client_secret", secret)])
      use body <- result.try(
        post("/oauth/token", "application/x-www-form-urlencoded", form) |> send,
      )
      json.parse(body, decode.at(["access_token"], decode.string))
      |> result.replace_error("Tailscale sent no access token")
    }
  }
}

/// The request body for an auth key: single use, preauthorized, for an
/// ephemeral node with the sandbox tag, valid for ten minutes.
pub fn auth_key_request(config: Config) -> String {
  let create =
    json.object([
      #("reusable", json.bool(False)),
      #("ephemeral", json.bool(True)),
      #("preauthorized", json.bool(True)),
      #("tags", json.array([config.tag], json.string)),
    ])
  json.object([
    #(
      "capabilities",
      json.object([#("devices", json.object([#("create", create)]))]),
    ),
    #("expirySeconds", json.int(600)),
    #("description", json.string("crushling sandbox")),
  ])
  |> json.to_string
}

/// Make an auth key for one sandbox to join with.
pub fn new_auth_key(config: Config) -> Result(String, String) {
  use token <- result.try(token(config))
  use body <- result.try(
    post(
      "/tailnet/" <> config.tailnet <> "/keys",
      "application/json",
      auth_key_request(config),
    )
    |> request.set_header("authorization", "Bearer " <> token)
    |> send,
  )
  json.parse(body, decode.at(["key"], decode.string))
  |> result.replace_error("Tailscale sent no auth key")
}

/// A thread's node name: `crushling-` and its key, as a hostname allows.
pub fn hostname(key: String) -> String {
  let name =
    string.lowercase(key)
    |> string.to_graphemes
    |> list.map(fn(char) {
      case string.contains("abcdefghijklmnopqrstuvwxyz0123456789", char) {
        True -> char
        False -> "-"
      }
    })
    |> string.concat
  string.slice("crushling-" <> name, 0, 63)
}

const paths = "dir=\"$HOME/.tailscale\"\nsock=\"$dir/tailscaled.sock\"\n"

/// Start `tailscaled`, join with `$TS_AUTHKEY` as `$TS_HOSTNAME`, and send
/// ssh to tailnet hosts through it. `tailscale up` gives up well inside the
/// bridge's 60 second limit on `docker exec`.
pub fn join_script() -> String {
  paths <> "set -e
mkdir -p \"$dir\" \"$HOME/.ssh\"
if ! { [ -f \"$dir/tailscaled.pid\" ] && kill -0 \"$(cat \"$dir/tailscaled.pid\")\" 2>/dev/null; }; then
  nohup tailscaled --tun=userspace-networking --state=mem: \\
    --statedir=\"$dir\" --socket=\"$sock\" \\
    --socks5-server=127.0.0.1:" <> int.to_string(socks_port) <> " \\
    --outbound-http-proxy-listen=127.0.0.1:" <> int.to_string(http_port) <> " \\
    --no-logs-no-support \\
    >\"$dir/tailscaled.log\" 2>&1 &
  echo $! >\"$dir/tailscaled.pid\"
  i=0
  until [ -S \"$sock\" ]; do
    i=$((i + 1))
    [ $i -gt 100 ] && { echo 'tailscaled did not start'; tail -5 \"$dir/tailscaled.log\"; exit 1; }
    sleep 0.1
  done
fi
tailscale --socket=\"$sock\" up --auth-key=\"$TS_AUTHKEY\" \\
  --hostname=\"$TS_HOSTNAME\" --accept-dns=false --timeout=40s
cat >\"$HOME/.ssh/tailnet\" <<EOF
Match exec \"tailscale --socket=$sock ip -4 %h >/dev/null 2>&1\"
  ProxyCommand tailscale --socket=$sock nc %h %p
EOF
touch \"$HOME/.ssh/config\"
grep -q 'Include ~/.ssh/tailnet' \"$HOME/.ssh/config\" || {
  printf 'Include ~/.ssh/tailnet\\n\\n' | cat - \"$HOME/.ssh/config\" >\"$HOME/.ssh/config.new\"
  mv \"$HOME/.ssh/config.new\" \"$HOME/.ssh/config\"
}
chmod 600 \"$HOME/.ssh/config\" \"$HOME/.ssh/tailnet\"
"
}

/// Log out, which removes the ephemeral node, then stop `tailscaled`.
pub fn leave_script() -> String {
  paths <> "tailscale --socket=\"$sock\" logout >/dev/null 2>&1
[ -f \"$dir/tailscaled.pid\" ] && kill \"$(cat \"$dir/tailscaled.pid\")\" 2>/dev/null
rm -f \"$dir/tailscaled.pid\" \"$HOME/.ssh/tailnet\"
true
"
}
