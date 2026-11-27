//// The Slack tools a thread's agent gets through `mcp`: read the
//// conversation it is in and channels the bot belongs to, look people up,
//// post an update, and move its work into a code channel. Files are shared
//// with the sandbox's `crushling-share` helper through `files/route`, which
//// posts them with `share`.
////
//// Reading reaches any channel the bot is a member of. Posting and sharing
//// only reach the conversation the agent is working in, so an agent can't
//// speak anywhere its people didn't put it.

import crushling/attachments
import crushling/conversation.{type Conversation}
import crushling/mcp
import crushling/slack/text
import crushling/slack/workspace.{type Workspace}
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
import slackline/api/users
import slackline/api/users/conversations as users_conversations
import slackline/api/users/info as users_info
import slackline/conversation as slack_conversation
import slackline/httpc
import slackline/message

pub type Context {
  Context(
    /// The workspace a thread's key belongs to.
    workspace: fn(String) -> Result(Workspace, String),
    /// The thread actor for a key, if its agent is up.
    lookup: fn(String) -> Option(Subject(thread.Message)),
    /// Ask the people in a thread to put its sandbox on the tailnet, with
    /// the agent's reason.
    ask_tailnet: fn(String, String) -> Result(String, String),
    /// What this bridge offers, which decides the tools.
    features: Features,
  )
}

/// What a bridge offers its agents beyond the common tools.
pub type Features {
  Features(
    /// Whether an agent may ask to be put on the tailnet.
    tailnet: Bool,
  )
}

/// What a tool runs with, resolved once per call: the thread's key, its
/// workspace and actor, and the conversation it is working in.
pub type ToolCtx {
  ToolCtx(
    context: Context,
    key: String,
    workspace: Workspace,
    thread: Subject(thread.Message),
    here: Conversation,
  )
}

pub type Tool {
  Tool(
    name: String,
    description: String,
    schema: json.Json,
    enabled: fn(Features) -> Bool,
    run: fn(ToolCtx, Dynamic) -> Result(String, String),
  )
}

const timeout_ms = 60_000

/// The tools an agent is offered.
pub fn tools(features: Features) -> List(mcp.Tool) {
  enabled(features)
  |> list.map(fn(tool) { mcp.Tool(tool.name, tool.description, tool.schema) })
}

fn enabled(features: Features) -> List(Tool) {
  list.filter(all(), fn(tool) { tool.enabled(features) })
}

/// Run one tool for the thread `key`; only an offered tool runs.
pub fn call(
  context: Context,
  key: String,
  name: String,
  arguments: Dynamic,
) -> Result(String, String) {
  use tool <- result.try(
    list.find(enabled(context.features), fn(tool) { tool.name == name })
    |> result.replace_error("no tool named " <> name),
  )
  use ctx <- result.try(resolve(context, key))
  tool.run(ctx, arguments)
}

fn resolve(context: Context, key: String) -> Result(ToolCtx, String) {
  use workspace <- result.try(context.workspace(key))
  use thread <- result.try(
    context.lookup(key)
    |> option.to_result("this thread's agent isn't running"),
  )
  use location <- result.map(ask(thread, thread.Where))
  ToolCtx(context:, key:, workspace:, thread:, here: location.conversation)
}

/// Upload a file the thread's agent sent through the bridge into the
/// conversation it is working in, as the bot, with `comment` ("" for none).
/// This is `route.Share`.
pub fn share(
  context: Context,
  key: String,
  name: String,
  contents: BitArray,
  comment: String,
) -> Result(String, String) {
  use ctx <- result.try(resolve(context, key))
  workspace.upload(ctx.workspace, ctx.here, name, contents, comment)
  |> result.replace("shared " <> name)
}

fn always(_: Features) -> Bool {
  True
}

fn all() -> List(Tool) {
  [
    Tool(
      name: "request_tailnet",
      description: "Ask the people in this conversation to put your sandbox on their tailnet for a while, so you can reach their machines over ssh or HTTP. They get Allow and Deny buttons in Slack. Ask only when the task needs one of their machines, and say which and why. The call returns at once. If someone allows it, a later message tells you how to connect, so don't wait for it.",
      schema: schema(
        [
          #(
            "reason",
            "string",
            "Which machines you need and why, in a sentence or two.",
          ),
        ],
        ["reason"],
      ),
      enabled: fn(features) { features.tailnet },
      run: fn(ctx, arguments) {
        case string_arg(arguments, "reason") {
          "" -> Error("say which machines you need and why")
          reason -> ctx.context.ask_tailnet(ctx.key, reason)
        }
      },
    ),
    Tool(
      name: "read_conversation",
      description: "Read the Slack conversation you are working in (the thread, or the code channel once the work moved there), oldest first, including your own replies.",
      schema: schema(
        [
          #(
            "limit",
            "integer",
            "How many recent messages; default 30, at most 200.",
          ),
        ],
        [],
      ),
      enabled: always,
      run: fn(ctx, arguments) {
        read(ctx.workspace, ctx.here, limit_arg(arguments))
      },
    ),
    Tool(
      name: "read_channel",
      description: "Read recent messages in a Slack channel you are a member of, or one thread in it. Find channels with list_channels.",
      schema: schema(
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
      enabled: always,
      run: fn(ctx, arguments) {
        case string_arg(arguments, "channel") {
          "" -> Error("give the channel's id")
          channel ->
            read(
              ctx.workspace,
              conversation.from_slack(
                channel,
                string_arg(arguments, "thread_ts"),
              ),
              limit_arg(arguments),
            )
        }
      },
    ),
    Tool(
      name: "list_channels",
      description: "List the Slack channels you are a member of, with their ids.",
      schema: schema([], []),
      enabled: always,
      run: fn(ctx, _) { list_channels(ctx.workspace) },
    ),
    Tool(
      name: "user_info",
      description: "Look up a Slack user by id (as in <@U0123>): their names, title and time zone.",
      schema: schema([#("user", "string", "The user id, like U0123456789.")], [
        "user",
      ]),
      enabled: always,
      run: fn(ctx, arguments) {
        user_info(ctx.workspace, string_arg(arguments, "user"))
      },
    ),
    Tool(
      name: "post_message",
      description: "Post a progress update in the conversation you are working in while you keep working, such as what you found so far in a long task. Don't use it for your answer: your reply at the end of the turn is posted for you, so posting it here too shows it twice. Slack markdown.",
      schema: schema([#("text", "string", "The message.")], ["text"]),
      enabled: always,
      run: fn(ctx, arguments) {
        case string_arg(arguments, "text") {
          "" -> Error("there's nothing to post")
          text -> {
            use posted <- result.try(ask(ctx.thread, thread.Say(text, _)))
            posted
            |> result.map(fn(ts) {
              "posted (ts "
              <> ts
              <> "). People have read it, so don't repeat it in your reply; end the turn with only what is new, or nothing."
            })
          }
        }
      },
    ),
    Tool(
      name: "propose_pr",
      description: "Propose a pull request for the branch you pushed (a `crushling/…` branch): posts a card in the conversation, and a person opens the PR from it, as themselves. You can't open one yourself. Push first. The base is the branch you started from.",
      schema: schema(
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
      enabled: always,
      run: fn(ctx, arguments) {
        let answered = process.new_subject()
        process.send(
          ctx.thread,
          thread.Propose(
            string_arg(arguments, "title"),
            string_arg(arguments, "body"),
            fn(result) { process.send(answered, result) },
          ),
        )
        process.receive(answered, timeout_ms)
        |> result.replace_error("the thread didn't answer in time")
        |> result.flatten
      },
    ),
    Tool(
      name: "open_code_channel",
      description: "Move this work into a Slack code channel: its own channel for a task that changes a repository, where people can follow along and see the diff in a Code tab. Only for changing code: reviewing, reading or answering questions about a repository stays in the thread. Changing a repository's files moves the work there anyway; call this first to give the channel a good name. Your replies go to the channel from then on.",
      schema: schema(
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
      enabled: always,
      run: fn(ctx, arguments) {
        use opened <- result.try(
          ask(ctx.thread, thread.OpenCodeChannel(
            string_arg(arguments, "name"),
            string_arg(arguments, "repo"),
            _,
          )),
        )
        opened
        |> result.map(fn(code) {
          "moved to code channel " <> code <> "; your replies go there now"
        })
      },
    ),
  ]
}

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

fn read(
  workspace: Workspace,
  place: Conversation,
  limit: Int,
) -> Result(String, String) {
  use messages <- result.try(workspace.read(workspace, place, "", ""))
  let messages = list.drop(messages, int.max(list.length(messages) - limit, 0))
  case list.filter_map(messages, fn(m) { line(workspace, m) }) {
    [] -> Ok("(no messages)")
    lines -> Ok(string.join(lines, "\n"))
  }
}

fn line(workspace: Workspace, message: message.Message) -> Result(String, Nil) {
  use ts <- result.try(option.to_result(message.ts, Nil))
  let bot_user = workspace.bot_user(workspace)
  let who = case message.user, message.bot_id {
    Some(user), _ if user == bot_user -> "you"
    Some(user), _ -> "<@" <> user <> ">"
    None, Some(_) -> option.unwrap(message.username, "a bot")
    None, None -> "someone"
  }
  let said = text.prompt_text(option.unwrap(message.text, ""), bot_user)
  let files = text.files_note(attachments.from_slack(message.files))
  let thread = case message.reply_count {
    Some(count) if count > 0 ->
      " [thread: " <> int.to_string(count) <> " replies]"
    _ -> ""
  }
  Ok("[" <> ts <> "] " <> who <> ": " <> said <> files <> thread)
}

fn list_channels(workspace: Workspace) -> Result(String, String) {
  // users.conversations lists only what the bot is in, unlike
  // conversations.list, whose `is_member` Slack doesn't always fill in.
  let first =
    users.conversations()
    |> users_conversations.types(["public_channel", "private_channel"])
    |> users_conversations.exclude_archived(True)
    |> users_conversations.limit(200)
  use channels <- result.try(all_channels(workspace, first, [], 10))
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
  workspace: Workspace,
  call: slackline.Call(users.Conversations, users.ConversationsResponse),
  found: List(slack_conversation.Conversation),
  pages_left: Int,
) -> Result(List(slack_conversation.Conversation), String) {
  use page <- result.try(
    httpc.send(call, workspace.client(workspace))
    |> result.map_error(workspace.describe),
  )
  let found = list.append(found, option.unwrap(page.channels, []))
  case pages_left > 1, slackline.next_page(call, page.response_metadata) {
    True, Some(next) -> all_channels(workspace, next, found, pages_left - 1)
    _, _ -> Ok(found)
  }
}

fn user_info(workspace: Workspace, user: String) -> Result(String, String) {
  let id = case user {
    "<@" <> rest -> string.replace(rest, ">", "")
    id -> id
  }
  use found <- result.try(
    users.info()
    |> users_info.user(id)
    |> httpc.send(workspace.client(workspace))
    |> result.map_error(workspace.describe),
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
