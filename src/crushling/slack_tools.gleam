//// The Slack tools a thread's agent gets through `mcp`: read the
//// conversation it is in and channels the bot belongs to, look people up,
//// post an update, and move its work into a code channel. Files are shared
//// with the sandbox's `crushling-share` helper through `files`, which posts
//// them with `share`.
////
//// Reading reaches any channel the bot is a member of. Posting and sharing
//// only reach the conversation the agent is working in, so an agent can't
//// speak anywhere its people didn't put it.

import crushling/conversation.{type Conversation}
import crushling/mcp
import crushling/slack
import crushling/thread
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
import slackline/api/files/complete_upload_external
import slackline/api/users
import slackline/api/users/conversations as users_conversations
import slackline/api/users/info as users_info
import slackline/conversation as slack_conversation
import slackline/httpc
import slackline/message

pub type Context {
  Context(
    /// The workspace a thread's key belongs to, for its Slack client.
    workspace: fn(String) -> Result(Workspace, String),
    /// The thread actor for a key, if its agent is up.
    lookup: fn(String) -> Option(Subject(thread.Message)),
    /// Ask the people in a thread to put its sandbox on the tailnet, with
    /// the agent's reason.
    ask_tailnet: fn(String, String) -> Result(String, String),
  )
}

/// One Slack workspace, as the tools reach it: the client with its bot
/// token, and the bot's own user id.
pub type Workspace {
  Workspace(client: slackline.Client, bot_user: String)
}

const timeout_ms = 60_000

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

/// The tools an agent gets. `tailnet` says whether it may ask to be put on
/// the tailnet.
pub fn tools(tailnet tailnet: Bool) -> List(mcp.Tool) {
  case tailnet {
    True -> [tailnet_tool(), ..common_tools()]
    False -> common_tools()
  }
}

fn tailnet_tool() -> mcp.Tool {
  mcp.Tool(
    "request_tailnet",
    "Ask the people in this conversation to put your sandbox on their tailnet for a while, so you can reach their machines over ssh or HTTP. They get Allow and Deny buttons in Slack. Ask only when the task needs one of their machines, and say which and why. The call returns at once. If someone allows it, a later message tells you how to connect, so don't wait for it.",
    schema(
      [
        #(
          "reason",
          "string",
          "Which machines you need and why, in a sentence or two.",
        ),
      ],
      ["reason"],
    ),
  )
}

fn common_tools() -> List(mcp.Tool) {
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
      "Post a progress update in the conversation you are working in while you keep working, such as what you found so far in a long task. Don't use it for your answer: your reply at the end of the turn is posted for you, so posting it here too shows it twice. Slack markdown.",
      schema([#("text", "string", "The message.")], ["text"]),
    ),
    mcp.Tool(
      "propose_pr",
      "Propose a pull request for the branch you pushed (a `crushling/…` branch): posts a card in the conversation, and a person opens the PR from it, as themselves. You can't open one yourself. Push first. The base is the branch you started from.",
      schema(
        [
          #(
            "title",
            "string",
            "The PR's title, like \"Fix the flaky checkout test\".",
          ),
          #(
            "body",
            "string",
            "The PR's description, in GitHub markdown: what changed and why, and how it was checked.",
          ),
        ],
        ["title", "body"],
      ),
    ),
    mcp.Tool(
      "open_code_channel",
      "Move this work into a Slack code channel: its own channel for a task that changes a repository, where people can follow along and see the diff in a Code tab. Only for changing code: reviewing, reading or answering questions about a repository stays in the thread. Changing a repository's files moves the work there anyway; call this first to give the channel a good name. Your replies go to the channel from then on.",
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
  use workspace <- result.try(context.workspace(key))
  use thread <- result.try(
    context.lookup(key)
    |> option.to_result("this thread's agent isn't running"),
  )
  use location <- result.try(ask(thread, thread.Where))
  let thread.Location(conversation: place, ..) = location
  case name {
    "read_conversation" -> read(workspace, place, limit_arg(arguments))
    "read_channel" ->
      case string_arg(arguments, "channel") {
        "" -> Error("give the channel's id")
        channel ->
          read(
            workspace,
            conversation.from_slack(channel, string_arg(arguments, "thread_ts")),
            limit_arg(arguments),
          )
      }
    "list_channels" -> list_channels(workspace)
    "user_info" -> user_info(workspace, string_arg(arguments, "user"))
    "post_message" ->
      case string_arg(arguments, "text") {
        "" -> Error("there's nothing to post")
        text -> {
          use posted <- result.try(ask(thread, thread.Say(text, _)))
          posted
          |> result.map(fn(ts) {
            "posted (ts "
            <> ts
            <> "). People have read it, so don't repeat it in your reply; end the turn with only what is new, or nothing."
          })
        }
      }
    "request_tailnet" ->
      case string_arg(arguments, "reason") {
        "" -> Error("say which machines you need and why")
        reason -> context.ask_tailnet(key, reason)
      }
    "propose_pr" -> {
      let answered = process.new_subject()
      process.send(
        thread,
        thread.Propose(
          string_arg(arguments, "title"),
          string_arg(arguments, "body"),
          fn(result) { process.send(answered, result) },
        ),
      )
      process.receive(answered, timeout_ms)
      |> result.replace_error("the thread didn't answer in time")
      |> result.flatten
    }
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
  context: Workspace,
  place: Conversation,
  limit: Int,
) -> Result(String, String) {
  use messages <- result.try(slack.read_conversation(
    context.client,
    place,
    "",
    "",
  ))
  let messages = list.drop(messages, int.max(list.length(messages) - limit, 0))
  case list.filter_map(messages, fn(m) { line(context, m) }) {
    [] -> Ok("(no messages)")
    lines -> Ok(string.join(lines, "\n"))
  }
}

fn line(context: Workspace, message: message.Message) -> Result(String, Nil) {
  use ts <- result.try(option.to_result(message.ts, Nil))
  let who = case message.user, message.bot_id {
    Some(user), _ if user == context.bot_user -> "you"
    Some(user), _ -> "<@" <> user <> ">"
    None, Some(_) -> option.unwrap(message.username, "a bot")
    None, None -> "someone"
  }
  let text =
    slack.prompt_text(option.unwrap(message.text, ""), context.bot_user)
  let files = slack.files_note(slack.attachments(message.files))
  let thread = case message.reply_count {
    Some(count) if count > 0 ->
      " [thread: " <> int.to_string(count) <> " replies]"
    _ -> ""
  }
  Ok("[" <> ts <> "] " <> who <> ": " <> text <> files <> thread)
}

fn list_channels(context: Workspace) -> Result(String, String) {
  // users.conversations lists only what the bot is in, unlike
  // conversations.list, whose `is_member` Slack doesn't always fill in.
  let first =
    users.conversations()
    |> users_conversations.types(["public_channel", "private_channel"])
    |> users_conversations.exclude_archived(True)
    |> users_conversations.limit(200)
  use channels <- result.try(all_channels(context, first, [], 10))
  let lines =
    list.map(channels, fn(channel) {
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

fn all_channels(
  context: Workspace,
  call: slackline.Call(users.Conversations, users.ConversationsResponse),
  found: List(slack_conversation.Conversation),
  pages_left: Int,
) -> Result(List(slack_conversation.Conversation), String) {
  use page <- result.try(
    httpc.send(call, context.client) |> result.map_error(slack.describe),
  )
  let found = list.append(found, option.unwrap(page.channels, []))
  case pages_left > 1, slackline.next_page(call, page.response_metadata) {
    True, Some(next) -> all_channels(context, next, found, pages_left - 1)
    _, _ -> Ok(found)
  }
}

fn user_info(context: Workspace, user: String) -> Result(String, String) {
  let id = case user {
    "<@" <> rest -> string.replace(rest, ">", "")
    id -> id
  }
  use found <- result.try(
    users.info()
    |> users_info.user(id)
    |> httpc.send(context.client)
    |> result.map_error(slack.describe),
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

/// Upload a file the thread's agent sent through the bridge into the
/// conversation it is working in, as the bot, with `comment` ("" for none).
/// This is `files.Share`.
pub fn share(
  context: Context,
  key: String,
  name: String,
  contents: BitArray,
  comment: String,
) -> Result(String, String) {
  use workspace <- result.try(context.workspace(key))
  use thread <- result.try(
    context.lookup(key)
    |> option.to_result("this thread's agent isn't running"),
  )
  use location <- result.try(ask(thread, thread.Where))
  let thread.Location(conversation: place, ..) = location
  let file =
    slackline.FileUpload(
      filename: name,
      content_type: content_type(name),
      contents:,
    )
  httpc.upload_files(workspace.client, [file], share: fn(call) {
    let call =
      complete_upload_external.channel_id(call, place.channel)
      |> conversation.in_thread(place, complete_upload_external.thread_ts)
    case comment {
      "" -> call
      comment -> complete_upload_external.initial_comment(call, comment)
    }
  })
  |> result.map(fn(_) { "shared " <> name })
  |> result.map_error(slack.describe)
}
