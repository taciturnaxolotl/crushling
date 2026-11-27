import crushling/attachments
import crushling/crush/client
import crushling/files
import crushling/files/route
import crushling/mcp
import crushling/mime
import crushling/sandbox_http
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

/// Unique across runs too, so no test finds an earlier run's files.
@external(erlang, "crushling_ffi", "uuid_v4")
fn uuid() -> String

@external(erlang, "real_server_ffi", "sh")
fn sh(dir: String, command: String) -> String

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)

fn png() -> BitArray {
  let assert Ok(png) =
    bit_array.base64_decode(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==",
    )
  png
}

pub fn small_image_goes_inline_test() {
  let #(line, attached) =
    attachments.place("F1", "shot.png", "image/png", png())
  let assert [client.Attachment(name: "shot.png", mime_type: "image/png", ..)] =
    attached
  let assert True = string.contains(line, "shown to you")
  let assert True = string.contains(line, "crushling-fetch F1")
}

pub fn large_image_is_only_named_test() {
  let big = <<0:size({ attachments.max_inline_image_bytes + 1 } * 8)>>
  let #(line, attached) = attachments.place("F2", "huge.png", "image/png", big)
  let assert [] = attached
  let assert True = string.contains(line, "too large to show you")
  let assert True = string.contains(line, "crushling-fetch F2")
}

pub fn small_text_goes_inline_test() {
  // Slack calls YAML and source files by vague types; crush only pastes in
  // text/*, so they go as text/plain.
  let #(_, attached) =
    attachments.place("F3", "config.yaml", "application/octet-stream", <<
      "a: 1",
    >>)
  let assert [
    client.Attachment(mime_type: "text/plain", content: <<"a: 1">>, ..),
  ] = attached
  let #(_, attached) =
    attachments.place("F4", "main.rs", "text/x-rust", <<"fn">>)
  let assert [client.Attachment(mime_type: "text/x-rust", ..)] = attached
  let #(_, attached) =
    attachments.place("F5", "data.json", "application/json", <<"{}">>)
  let assert [client.Attachment(mime_type: "text/plain", ..)] = attached
}

pub fn specific_binary_types_are_not_text_test() {
  // A .txt name doesn't make a file Slack calls a zip text.
  let #(line, attached) =
    attachments.place("F9", "notes.txt", "application/zip", <<"PK", 3, 4>>)
  let assert [] = attached
  let assert True = string.contains(line, "fetch it with: crushling-fetch F9")
  let #(_, attached) =
    attachments.place("F9", "main.c", "application/x-mach-binary", <<"int">>)
  let assert [] = attached
  // Text with a NUL byte isn't pasted in.
  let #(_, attached) =
    attachments.place("F9", "a.txt", "text/plain", <<"a", 0, "b">>)
  let assert [] = attached
}

pub fn generically_labelled_images_are_sniffed_test() {
  let #(line, attached) =
    attachments.place("F10", "upload", "application/octet-stream", png())
  let assert [client.Attachment(mime_type: "image/png", ..)] = attached
  let assert True = string.contains(line, "shown to you")
  let assert Ok("image/jpeg") = mime.sniff_image(<<0xFF, 0xD8, 0xFF, 0xE0>>)
  let assert Ok("image/gif") = mime.sniff_image(<<"GIF89a">>)
  let assert Ok("image/webp") = mime.sniff_image(<<"RIFF", 0:32, "WEBP">>)
  // A specific non-image type isn't sniffed.
  let #(_, attached) =
    attachments.place("F10", "x.pdf", "application/pdf", png())
  let assert [] = attached
}

pub fn large_text_is_stored_test() {
  let big =
    bit_array.from_string(string.repeat(
      "x",
      attachments.max_inline_text_bytes + 1,
    ))
  let #(line, attached) = attachments.place("F6", "big.log", "text/plain", big)
  let assert [] = attached
  let assert True = string.contains(line, "fetch it with: crushling-fetch F6")
}

pub fn binary_is_stored_test() {
  let #(line, attached) =
    attachments.place("F07ABC", "build.zip", "application/zip", <<
      0:size(
        { 12 * 1_048_576 }
        * 8
      ),
    >>)
  let assert [] = attached
  let assert "- build.zip (application/zip, 12 MB) - fetch it with: crushling-fetch F07ABC" =
    line
  // A text extension with bytes that aren't UTF-8 isn't text.
  let #(_, attached) =
    attachments.place("F8", "x.txt", "text/plain", <<255, 254>>)
  let assert [] = attached
}

pub fn prompt_names_stored_files_test() {
  let #(text, attached) =
    attachments.describe("Attached to this message:\n", [
      attachments.place("F07ABC", "build.zip", "application/zip", <<1, 2, 3>>),
      attachments.place("F1", "shot.png", "image/png", png()),
    ])
  let assert True = string.starts_with(text, "Attached to this message:\n")
  let assert True =
    string.contains(
      text,
      "- build.zip (application/zip, 3 B) - fetch it with: crushling-fetch F07ABC",
    )
  let assert True = string.contains(text, "shot.png")
  let assert [_] = attached
  let assert #("", []) = attachments.describe("Attached:\n", [])
}

pub fn attachments_reach_crush_as_base64_test() {
  let #(_, attached) =
    attachments.place("F3", "notes.md", "text/markdown", <<"hi">>)
  let call =
    client.send_prompt_with(
      workspace_id: "w",
      session_id: "s",
      run_id: "r",
      prompt: "look",
      attachments: attached,
    )
  let assert Some(body) = call.body
  let assert "{\"session_id\":\"s\",\"run_id\":\"r\",\"prompt\":\"look\",\"attachments\":[{\"file_path\":\"notes.md\",\"file_name\":\"notes.md\",\"mime_type\":\"text/markdown\",\"content\":\"aGk=\"}]}" =
    json.to_string(body)
}

pub fn ids_and_names_are_confined_test() {
  let root = "/tmp/crushling-files-test-" <> uuid()
  let assert Ok(Nil) = files.store(root, "C1-1.0", "F1", "../../etc/x", <<1>>)
  let assert Ok(#(path, ".._.._etc_x")) = files.find(root, "C1-1.0", "F1")
  let assert True = string.starts_with(path, root <> "/C1-1.0/files/")
  let assert Error(_) = files.store(root, "C1-1.0", "../F1", "x", <<1>>)
  let assert Error(_) = files.store(root, "..", "F1", "x", <<1>>)
  let assert Error(Nil) = files.find(root, "C1-1.0", "..")
  let assert Error(Nil) = files.find(root, "C2-1.0", "F1")
  let _ = sh("/tmp", "rm -rf '" <> root <> "'")
  Nil
}

type Server {
  Server(
    url: String,
    port: Int,
    root: String,
    shared: process.Subject(#(String, String, BitArray, String)),
    limits: route.Limits,
  )
}

const secret = "files-secret"

fn start() -> Server {
  let port = 20_000 + int.absolute_value(unique()) % 2000
  let root = "/tmp/crushling-files-test-" <> uuid()
  let shared = process.new_subject()
  let limits = route.new_limits(2, 8)
  let assert Ok(Nil) =
    sandbox_http.start("127.0.0.1", port, [
      route.route_with(
        secret,
        root,
        fn(key, name, contents, comment) {
          process.send(shared, #(key, name, contents, comment))
          case comment {
            "fail" -> Error("slack said no")
            _ -> Ok("shared " <> name)
          }
        },
        limits,
      ),
    ])
  Server("http://127.0.0.1:" <> int.to_string(port), port, root, shared, limits)
}

fn get(server: Server, path: String, key: String) {
  let assert Ok(req) = request.to(server.url <> path)
  req
  |> request.set_header("authorization", "Bearer " <> mcp.token(secret, key))
  |> request.set_body(<<>>)
  |> httpc.send_bits
}

fn post(server: Server, path: String, key: String, body: BitArray) {
  let assert Ok(req) = request.to(server.url <> path)
  req
  |> request.set_method(http.Post)
  |> request.set_header("authorization", "Bearer " <> mcp.token(secret, key))
  |> request.set_body(body)
  |> httpc.send_bits
}

pub fn route_serves_and_takes_files_test() {
  let server = start()
  let key = "C1-1.0"
  let assert Ok(Nil) =
    files.store(server.root, key, "F07ABC", "a.txt", <<"hi">>)
  // A download, with the thread's token.
  let assert Ok(response) = get(server, "/files/" <> key <> "/F07ABC", key)
  let assert 200 = response.status
  let assert <<"hi">> = response.body
  let assert Ok("a.txt") = list.key_find(response.headers, "x-file-name")
  // No token, or another thread's token.
  let assert Ok(req) = request.to(server.url <> "/files/" <> key <> "/F07ABC")
  let assert Ok(response) = req |> request.set_body(<<>>) |> httpc.send_bits
  let assert 401 = response.status
  let assert Ok(response) = get(server, "/files/" <> key <> "/F07ABC", "C2-1.0")
  let assert 401 = response.status
  // Another thread, with its own token, can't reach this thread's file.
  let assert Ok(response) = get(server, "/files/C2-1.0/F07ABC", "C2-1.0")
  let assert 404 = response.status
  // Paths don't climb out.
  let assert Ok(response) =
    get(server, "/files/" <> key <> "/..%2F..%2Fmcp-secret", key)
  let assert 404 = response.status
  let assert Ok(response) =
    get(server, "/files/" <> key <> "/../C2-1.0/F07ABC", key)
  let assert 401 = response.status
  // An upload is kept, shared and named by id; a path in the name is cut.
  let assert Ok(response) =
    post(
      server,
      "/files/" <> key <> "?name=..%2F..%2Fout.txt&comment=look",
      key,
      <<"made">>,
    )
  let assert 200 = response.status
  let assert Ok(#(_, "out.txt", <<"made">>, "look")) =
    process.receive(server.shared, 1000)
  let assert Ok(body) = bit_array.to_string(response.body)
  let assert True = string.contains(body, "\"id\":\"S")
  let assert Ok(response) = post(server, "/files/" <> key, key, <<"x">>)
  let assert 400 = response.status
  let _ = sh("/tmp", "rm -rf '" <> server.root <> "'")
  Nil
}

@external(erlang, "lying_server_ffi", "raw")
fn raw(port: Int, request: String) -> String

@external(erlang, "crushling_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), Nil)

fn stored(server: Server, key: String) -> List(String) {
  list_dir(files.dir(server.root, key)) |> result.unwrap([])
}

fn raw_post(server: Server, key: String, headers: String, body: String) {
  raw(
    server.port,
    "POST /files/"
      <> key
      <> "?name=big.bin HTTP/1.1\r\nhost: x\r\nauthorization: Bearer "
      <> mcp.token(secret, key)
      <> "\r\n"
      <> headers
      <> "\r\n"
      <> body,
  )
}

pub fn route_caps_uploads_test() {
  let server = start()
  let key = "C1-1.0"
  // Too long: turned away on its Content-Length, before any of it is read.
  let assert "HTTP/1.1 413 " <> _ =
    raw_post(
      server,
      key,
      "content-length: " <> int.to_string(files.max_upload_bytes + 1) <> "\r\n",
      "xx",
    )
  // Chunked, or with no length at all, isn't taken.
  let assert "HTTP/1.1 411 " <> _ =
    raw_post(
      server,
      key,
      "transfer-encoding: chunked\r\n",
      "2\r\nxx\r\n0\r\n\r\n",
    )
  let assert "HTTP/1.1 411 " <> _ = raw_post(server, key, "", "xx")
  let assert [] = stored(server, key)
  let assert Error(Nil) = process.receive(server.shared, 100)
  // Exactly the cap is fine as far as the length goes.
  let assert Ok(_) =
    route.upload_length([
      #("content-length", int.to_string(files.max_upload_bytes)),
    ])
  let _ = sh("/tmp", "rm -rf '" <> server.root <> "'")
  Nil
}

pub fn uploads_in_flight_are_limited_test() {
  let limits = route.new_limits(2, 8)
  let assert Ok(a1) = route.acquire(limits, "A")
  let assert Ok(_) = route.acquire(limits, "A")
  let assert Error(Nil) = route.acquire(limits, "A")
  route.release(a1)
  let assert Ok(_) = route.acquire(limits, "A")
  // Eight in all.
  list.each(["B", "B", "C", "C", "D", "D"], fn(key) {
    let assert Ok(_) = route.acquire(limits, key)
  })
  let assert Error(Nil) = route.acquire(limits, "E")
  // A slot is freed when its holder exits.
  let limits = route.new_limits(1, 8)
  let holder =
    process.spawn(fn() {
      let assert Ok(_) = route.acquire(limits, "A")
      process.sleep(50)
    })
  process.sleep(20)
  let assert True = process.is_alive(holder)
  let assert Error(Nil) = route.acquire(limits, "A")
  process.sleep(100)
  let assert Ok(_) = route.acquire(limits, "A")
  Nil
}

pub fn route_answers_429_over_the_limit_test() {
  let server = start()
  let key = "C1-1.0"
  let assert Ok(_) = route.acquire(server.limits, key)
  let assert Ok(_) = route.acquire(server.limits, key)
  let assert Ok(response) =
    post(server, "/files/" <> key <> "?name=a.txt", key, <<"x">>)
  let assert 429 = response.status
  let assert [] = stored(server, key)
  // Another thread still can.
  let assert Ok(response) =
    post(server, "/files/C2-1.0?name=a.txt", "C2-1.0", <<"x">>)
  let assert 200 = response.status
  let _ = sh("/tmp", "rm -rf '" <> server.root <> "'")
  Nil
}

pub fn failed_shares_are_not_kept_test() {
  let server = start()
  let key = "C1-1.0"
  let assert Ok(response) =
    post(server, "/files/" <> key <> "?name=a.txt&comment=fail", key, <<"x">>)
  let assert 502 = response.status
  let assert Ok(_) = process.receive(server.shared, 1000)
  let assert [] = stored(server, key)
  let _ = sh("/tmp", "rm -rf '" <> server.root <> "'")
  Nil
}

type Declared {
  Chunked
  Length(Int)
}

@external(erlang, "lying_server_ffi", "start")
fn lying_server(declared: Declared, total: Int) -> Int

fn lying_url(declared: Declared, total: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(lying_server(declared, total)) <> "/f"
}

pub fn slack_downloads_are_capped_test() {
  let assert Ok(<<"xxxx">>) =
    attachments.fetch_file("t", lying_url(Length(4), 4), 10, 0)
  let assert Ok(_) = attachments.fetch_file("t", lying_url(Chunked, 10), 10, 0)
  // Declared too long, or sent too long without saying.
  let assert Error(attachments.TooLarge) =
    attachments.fetch_file("t", lying_url(Length(11), 11), 10, 0)
  let assert Error(attachments.TooLarge) =
    attachments.fetch_file("t", lying_url(Chunked, 3_000_000), 10, 0)
}

@external(erlang, "lying_server_ffi", "start_echo")
fn echo_server() -> Int

@external(erlang, "lying_server_ffi", "start_redirect")
fn redirect_server(location: String) -> Int

pub fn slack_downloads_need_https_test() {
  // Plain http only reaches loopback addresses; nothing is connected to.
  let assert Error(attachments.FetchFailed("only https is fetched")) =
    attachments.fetch_file("t", "http://files.slack.com/x", 10, 0)
  let assert Error(attachments.FetchFailed("only https is fetched")) =
    attachments.fetch_file("t", "http://10.0.0.1/x", 10, 0)
  let assert Error(attachments.FetchFailed("only https is fetched")) =
    attachments.fetch_file("t", "ftp://127.0.0.1/x", 10, 0)
  let assert True = attachments.is_slack_file_host("files.slack.com")
  let assert True = attachments.is_slack_file_host("a.slack-edge.com")
  let assert False = attachments.is_slack_file_host("slack.com.evil.example")
  let assert False = attachments.is_slack_file_host("evilslack.com")
}

pub fn slack_tokens_stay_with_slack_test() {
  let echo_url = "http://127.0.0.1:" <> int.to_string(echo_server()) <> "/f"
  // Straight there, the token goes along.
  let assert Ok(head) =
    attachments.fetch_file("xoxb-secret", echo_url, 10_000, 0)
  let assert Ok(head) = bit_array.to_string(head)
  let assert True = string.contains(head, "Bearer xoxb-secret")
  // Redirected to another origin, it doesn't.
  let hop = "http://127.0.0.1:" <> int.to_string(redirect_server(echo_url))
  let assert Ok(head) =
    attachments.fetch_file("xoxb-secret", hop <> "/f", 10_000, 2)
  let assert Ok(head) = bit_array.to_string(head)
  let assert False = string.contains(string.lowercase(head), "authorization")
  // A redirect to plain http elsewhere isn't followed.
  let hop =
    "http://127.0.0.1:"
    <> int.to_string(redirect_server("http://files.slack.com/x"))
  let assert Error(attachments.FetchFailed("only https is fetched")) =
    attachments.fetch_file("xoxb-secret", hop <> "/f", 10_000, 2)
}

/// Slack says the file is small, the server sends more than the cap.
pub fn lying_slack_files_are_not_kept_test() {
  let root = "/tmp/crushling-files-test-" <> uuid()
  let url = lying_url(Chunked, files.max_upload_bytes + 2_000_000)
  let #(text, attached) =
    attachments.keep(
      "t",
      [
        attachments.Attachment(
          "F1",
          "small.bin",
          "application/zip",
          Some(10),
          url,
        ),
        attachments.Attachment(
          "F2",
          "unknown.bin",
          "application/zip",
          None,
          url,
        ),
      ],
      attachments.Keep(root, "C1-1.0"),
    )
  let assert [] = attached
  let assert True =
    string.contains(
      text,
      "- small.bin (application/zip, 10 B): too large to fetch",
    )
  let assert True =
    string.contains(
      text,
      "- unknown.bin (application/zip, size unknown): too large to fetch",
    )
  let assert Error(Nil) = list_dir(files.dir(root, "C1-1.0"))
  // A size Slack gives over the cap isn't fetched at all.
  let #(text, _) =
    attachments.keep(
      "t",
      [
        attachments.Attachment(
          "F3",
          "huge.bin",
          "application/zip",
          Some(files.max_upload_bytes + 1),
          "http://127.0.0.1:1/never",
        ),
      ],
      attachments.Keep(root, "C1-1.0"),
    )
  let assert True = string.contains(text, "too large to fetch")
  let _ = sh("/tmp", "rm -rf '" <> root <> "'")
  Nil
}

/// The sandbox's helper scripts against the route.
pub fn helper_scripts_test() {
  let server = start()
  let key = "C1-1.0"
  let assert Ok(Nil) =
    files.store(server.root, key, "F07ABC", "build log.txt", <<"log">>)
  let work = server.root <> "/work"
  let cwd = string.trim(sh(".", "pwd"))
  let bin = cwd <> "/sandbox/bin"
  let env =
    "mkdir -p '"
    <> work
    <> "' && cd '"
    <> work
    <> "' && CRUSHLING_BRIDGE_URL="
    <> server.url
    <> " CRUSHLING_THREAD="
    <> key
    <> " CRUSHLING_MCP_TOKEN="
    <> mcp.token(secret, key)
    <> " sh "
    <> bin
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC")
  let assert True = string.contains(out, ".slack/build_log.txt")
  let assert Ok(<<"log">>) = read_file(work <> "/.slack/build_log.txt")
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC got.txt")
  let assert True = string.contains(out, "got.txt")
  let assert Ok(<<"log">>) = read_file(work <> "/got.txt")
  let out = sh("/tmp", env <> "/crushling-fetch F404; echo status=$?")
  let assert True = string.contains(out, "HTTP 404")
  let assert True = string.contains(out, "status=1")
  let out = sh("/tmp", env <> "/crushling-share got.txt 'a comment & more'")
  let assert True = string.contains(out, "\"id\":\"S")
  let assert Ok(#(_, "got.txt", <<"log">>, "a comment & more")) =
    process.receive(server.shared, 1000)
  // A dest ending in / is a directory; operands starting with - are files.
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC out/")
  let assert True = string.contains(out, "out/build_log.txt")
  let assert Ok(<<"log">>) = read_file(work <> "/out/build_log.txt")
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC -dash.txt")
  let assert True = string.contains(out, "./-dash.txt")
  let assert Ok(<<"log">>) = read_file(work <> "/-dash.txt")
  let out = sh("/tmp", env <> "/crushling-share -dash.txt")
  let assert True = string.contains(out, "\"id\":\"S")
  let assert Ok(#(_, "-dash.txt", <<"log">>, "")) =
    process.receive(server.shared, 1000)
  // Brackets and braces in a name are literal, not curl globs.
  let _ = sh(work, "printf one > 'a[1].txt' && printf two > 'b{x,y}.txt'")
  let out = sh("/tmp", env <> "/crushling-share 'a[1].txt'")
  let assert True = string.contains(out, "\"id\":\"S")
  let assert Ok(#(_, "a[1].txt", <<"one">>, "")) =
    process.receive(server.shared, 1000)
  let out = sh("/tmp", env <> "/crushling-share 'b{x,y}.txt'")
  let assert True = string.contains(out, "\"id\":\"S")
  let assert Ok(#(_, "b{x,y}.txt", <<"two">>, "")) =
    process.receive(server.shared, 1000)
  // An existing directory is never the destination, unless asked with /.
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC out; echo status=$?")
  let assert True = string.contains(out, "is a directory")
  let assert True = string.contains(out, "status=1")
  let _ = sh(work, "rm .slack/build_log.txt && mkdir .slack/build_log.txt")
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC; echo status=$?")
  let assert True = string.contains(out, "is a directory")
  let assert True = string.contains(out, "status=1")
  // Nor is a symlink, at .slack/<name> or at .slack itself.
  let _ =
    sh(
      work,
      "rmdir .slack/build_log.txt && echo keep > victim && ln -s ../victim .slack/build_log.txt",
    )
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC; echo status=$?")
  let assert True = string.contains(out, "is a symlink")
  let assert True = string.contains(out, "status=1")
  let assert Ok(<<"keep\n">>) = read_file(work <> "/victim")
  let _ = sh(work, "rm -rf .slack && mkdir elsewhere && ln -s elsewhere .slack")
  let out = sh("/tmp", env <> "/crushling-fetch F07ABC; echo status=$?")
  let assert True = string.contains(out, ".slack is a symlink")
  let assert True = string.contains(out, "status=1")
  let assert Ok([]) = list_dir(work <> "/elsewhere")
  // No temp files are left behind.
  let assert False = string.contains(sh(work, "ls -a out"), ".crushling-fetch")
  let _ = sh("/tmp", "rm -rf '" <> server.root <> "'")
  Nil
}
