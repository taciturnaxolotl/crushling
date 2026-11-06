//// The Slack tools a thread's agent gets through `mcp`: read the
//// conversation it is in and channels the bot belongs to, look people up,
//// post an update, share a file from its workspace, and move its work into
//// a code channel.
////
//// Reading reaches any channel the bot is a member of. Posting and sharing
//// only reach the conversation the agent is working in, so an agent can't
//// speak anywhere its people didn't put it.

import crushling/launcher.{type Launcher}
import crushling/mcp
import crushling/slack
import crushling/thread
import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline
import slackline/api/conversations
import slackline/api/conversations/history
import slackline/api/conversations/list as conversations_list
import slackline/api/conversations/replies
import slackline/api/files/complete_upload_external
import slackline/api/users
import slackline/api/users/info as users_info
import slackline/httpc
import slackline/message

pub type Context {
  Context(
    client: slackline.Client,
    bot_user: String,
    launcher: Launcher,
    /// The thread actor for a key, if its agent is up.
    lookup: fn(String) -> Option(Subject(thread.Message)),
  )
}

const timeout_ms = 60_000

/// Files larger than this aren't shared.
const max_file_bytes = 20_000_000

fn schema(
  properties: List(#(String, String, String)),
  required: List(String),
) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #(
      "properties",
      json.object(
        list.map(properties, fn(property) {
          let #(name, kind, description) = property
          #(
            name,
            json.object([
              #("type", json.string(kind)),
              #("description", json.string(description)),
            ]),
          )
        }),
      ),
    ),
    #("required", json.array(required, json.string)),
  ])
}

pub fn tools() -> List(mcp.Tool) {
  [
    mcp.Tool(
      "read_conversation",
      "Read the Slack conversation you are working in (the thread, or the code channel once the work moved there), oldest first, including your own replies.",
      schema(
        [
          #(
            "limit",
            "integer",
            "How many recent messages; default 30, at most 200.",
          ),
        ],
        [],
      ),
    ),
    mcp.Tool(
      "read_channel",
      "Read recent messages in a Slack channel you are a member of, or one thread in it. Find channels with list_channels.",
      schema(
        [
          #("channel", "string", "The channel id, like C0123456789."),
          #(
            "thread_ts",
            "string",
            "A thread's root ts, to read that thread instead of the channel.",
          ),
          #(
            "limit",
            "integer",
            "How many recent messages; default 30, at most 200.",
          ),
        ],
        ["channel"],
      ),
    ),
    mcp.Tool(
      "list_channels",
      "List the Slack channels you are a member of, with their ids.",
      schema([], []),
    ),
    mcp.Tool(
      "user_info",
      "Look up a Slack user by id (as in <@U0123>): their names, title and time zone.",
      schema([#("user", "string", "The user id, like U0123456789.")], ["user"]),
    ),
    mcp.Tool(
      "post_message",
      "Post a message in the conversation you are working in, right away, without waiting for your turn to end. Use it for progress updates or a question; your final reply is posted for you. Slack markdown.",
      schema([#("text", "string", "The message.")], ["text"]),
    ),
    mcp.Tool(
      "share_file",
      "Upload a file from your workspace into the conversation you are working in, such as a screenshot, a log, or a build artifact.",
      schema(
        [
          #("path", "string", "The file's path in your workspace."),
          #("comment", "string", "A message to post with it."),
        ],
        ["path"],
      ),
    ),
    mcp.Tool(
      "open_code_channel",
      "Move this work into a Slack code channel: its own channel for a task that changes a repository, where people can follow along and see the diff in a Code tab. Use it once the repository is cloned and the work will take more than one message. Your replies go to the channel from then on.",
      schema(
        [
          #(
            "name",
            "string",
            "The channel's title, naming the task, like \"Fix the flaky checkout test\".",
          ),
          #(
            "repo",
            "string",
            "The repository's directory in your workspace; default the first one found.",
          ),
        ],
        ["name"],
      ),
    ),
  ]
}

fn string_arg(arguments: Dynamic, name: String) -> String {
  decode.run(arguments, decode.at([name], decode.string))
  |> result.unwrap("")
  |> string.trim
}

fn limit_arg(arguments: Dynamic) -> Int {
  decode.run(arguments, decode.at(["limit"], decode.int))
  |> result.unwrap(30)
  |> int.clamp(1, 200)
}

fn ask(subject: Subject(a), make: fn(Subject(b)) -> a) -> Result(b, String) {
  let reply = process.new_subject()
  process.send(subject, make(reply))
  process.receive(reply, timeout_ms)
  |> result.replace_error("the agent's thread didn't answer in time")
}

/// Run one tool for the thread `key`.
pub fn call(
  context: Context,
  key: String,
  name: String,
  arguments: Dynamic,
) -> Result(String, String) {
  use thread <- result.try(
    context.lookup(key)
    |> option.to_result("this thread's agent isn't running"),
  )
  use #(channel, thread_ts, root) <- result.try(ask(thread, thread.Where))
  case name {
    "read_conversation" ->
      read(context, channel, thread_ts, limit_arg(arguments))
    "read_channel" ->
      case string_arg(arguments, "channel") {
        "" -> Error("give the channel's id")
        channel ->
          read(
            context,
            channel,
            string_arg(arguments, "thread_ts"),
            limit_arg(arguments),
          )
      }
    "list_channels" -> list_channels(context)
    "user_info" -> user_info(context, string_arg(arguments, "user"))
    "post_message" ->
      case string_arg(arguments, "text") {
        "" -> Error("there's nothing to post")
        text -> {
          use posted <- result.try(ask(thread, thread.Say(text, _)))
          posted |> result.map(fn(ts) { "posted (ts " <> ts <> ")" })
        }
      }
    "share_file" ->
      share_file(
        context,
        key,
        root,
        channel,
        thread_ts,
        string_arg(arguments, "path"),
        string_arg(arguments, "comment"),
      )
    "open_code_channel" -> {
      use opened <- result.try(
        ask(thread, thread.OpenCodeChannel(
          string_arg(arguments, "name"),
          string_arg(arguments, "repo"),
          _,
        )),
      )
      opened
      |> result.map(fn(code) {
        "moved to code channel " <> code <> "; your replies go there now"
      })
    }
    name -> Error("no tool named " <> name)
  }
}

fn read(
  context: Context,
  channel: String,
  thread_ts: String,
  limit: Int,
) -> Result(String, String) {
  let messages = case thread_ts {
    "" ->
      conversations.history(channel:)
      |> history.limit(limit)
      |> httpc.send(context.client)
      // History is newest first.
      |> result.map(fn(found) {
        option.unwrap(found.messages, []) |> list.reverse
      })
    ts ->
      conversations.replies(channel:, ts:)
      |> replies.limit(200)
      |> httpc.send(context.client)
      |> result.map(fn(found) {
        let all = option.unwrap(found.messages, [])
        list.drop(all, int.max(list.length(all) - limit, 0))
      })
  }
  use messages <- result.try(
    messages |> result.map_error(slackline.describe_error),
  )
  case list.filter_map(messages, fn(m) { line(context, m) }) {
    [] -> Ok("(no messages)")
    lines -> Ok(string.join(lines, "\n"))
  }
}

fn line(context: Context, message: message.Message) -> Result(String, Nil) {
  use ts <- result.try(option.to_result(message.ts, Nil))
  let who = case message.user, message.bot_id {
    Some(user), _ if user == context.bot_user -> "you"
    Some(user), _ -> "<@" <> user <> ">"
    None, Some(_) -> option.unwrap(message.username, "a bot")
    None, None -> "someone"
  }
  let text =
    slack.prompt_text(option.unwrap(message.text, ""), context.bot_user)
  let files = case slack.attachments(message.files) {
    [] -> ""
    files ->
      " [attached: "
      <> string.join(list.map(files, fn(file) { file.name }), ", ")
      <> "]"
  }
  let thread = case message.reply_count {
    Some(count) if count > 0 ->
      " [thread: " <> int.to_string(count) <> " replies]"
    _ -> ""
  }
  Ok("[" <> ts <> "] " <> who <> ": " <> text <> files <> thread)
}

fn list_channels(context: Context) -> Result(String, String) {
  use found <- result.try(
    conversations.list()
    |> conversations_list.types(["public_channel", "private_channel"])
    |> conversations_list.exclude_archived(True)
    |> conversations_list.limit(1000)
    |> httpc.send(context.client)
    |> result.map_error(slackline.describe_error),
  )
  let lines =
    option.unwrap(found.channels, [])
    |> list.filter(fn(channel) { channel.is_member == Some(True) })
    |> list.map(fn(channel) {
      "#"
      <> option.unwrap(channel.name, "?")
      <> " ("
      <> channel.id
      <> ")"
      <> case channel.is_private {
        Some(True) -> ", private"
        _ -> ""
      }
    })
  case lines {
    [] -> Ok("(you aren't in any channels)")
    lines -> Ok(string.join(lines, "\n"))
  }
}

fn user_info(context: Context, user: String) -> Result(String, String) {
  let id = case user {
    "<@" <> rest -> string.replace(rest, ">", "")
    id -> id
  }
  use found <- result.try(
    users.info()
    |> users_info.user(id)
    |> httpc.send(context.client)
    |> result.map_error(slackline.describe_error),
  )
  case found.user {
    None -> Error("no such user")
    Some(person) -> {
      let profile = person.profile
      let field = fn(get) { option.then(profile, get) |> option.unwrap("") }
      [
        #("id", person.id),
        #("handle", option.unwrap(person.name, "")),
        #("name", option.unwrap(person.real_name, "")),
        #("display name", field(fn(p) { p.display_name })),
        #("title", field(fn(p) { p.title })),
        #("time zone", option.unwrap(person.tz, "")),
      ]
      |> list.filter(fn(pair) { pair.1 != "" })
      |> list.map(fn(pair) { pair.0 <> ": " <> pair.1 })
      |> string.join("\n")
      |> Ok
    }
  }
}

@external(erlang, "crushling_ffi", "read_file")
fn read_bytes(path: String) -> Result(BitArray, Nil)

/// A path the agent gave, relative to its workspace, if it stays inside.
pub fn workspace_path(root: String, path: String) -> Result(String, Nil) {
  let relative = case string.starts_with(path, root <> "/") {
    True -> string.drop_start(path, string.length(root) + 1)
    False -> path
  }
  let parts =
    string.split(relative, "/") |> list.filter(fn(p) { p != "" && p != "." })
  case
    string.starts_with(relative, "/")
    || list.contains(parts, "..")
    || parts == []
  {
    True -> Error(Nil)
    False -> Ok(string.join(parts, "/"))
  }
}

fn content_type(name: String) -> String {
  let extension =
    string.split(name, ".")
    |> list.last
    |> result.unwrap("")
    |> string.lowercase
  case extension {
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "svg" -> "image/svg+xml"
    "pdf" -> "application/pdf"
    "json" -> "application/json"
    "html" -> "text/html"
    "csv" -> "text/csv"
    "diff" | "patch" -> "text/x-diff"
    "txt" | "log" | "md" -> "text/plain"
    _ -> "application/octet-stream"
  }
}

fn share_file(
  context: Context,
  key: String,
  root: String,
  channel: String,
  thread_ts: String,
  path: String,
  comment: String,
) -> Result(String, String) {
  use relative <- result.try(
    workspace_path(root, path)
    |> result.replace_error("give a path inside your workspace"),
  )
  let host = context.launcher.workspace(key) <> "/" <> relative
  use contents <- result.try(
    read_bytes(host) |> result.replace_error("couldn't read " <> relative),
  )
  let size = bit_array.byte_size(contents)
  use <- bool.guard(
    size > max_file_bytes,
    Error(relative <> " is too large to share"),
  )
  let name = list.last(string.split(relative, "/")) |> result.unwrap(relative)
  let file =
    slackline.FileUpload(
      filename: name,
      content_type: content_type(name),
      contents:,
    )
  httpc.upload_files(context.client, [file], share: fn(call) {
    let call = complete_upload_external.channel_id(call, channel)
    let call = case thread_ts {
      "" -> call
      ts -> complete_upload_external.thread_ts(call, ts)
    }
    case comment {
      "" -> call
      comment -> complete_upload_external.initial_comment(call, comment)
    }
  })
  |> result.map(fn(_) { "shared " <> relative })
  |> result.map_error(slackline.describe_error)
}
