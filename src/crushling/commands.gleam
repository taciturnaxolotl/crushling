//// The `!` commands people say in a thread, in one table: the parser, the
//// help text, the slash commands offered in code channels and their
//// rewrite to `!` commands all come from `specs`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Command {
  StopCommand
  HelpCommand
  /// Stop following: only mentions reach the agent until `!resume`.
  PauseCommand
  ResumeCommand
  /// Archive the code channel: the work is done.
  DoneCommand
  /// Where the work stands: branch, changes, pushed or not.
  InfoCommand
  /// Post a card proposing a PR for the pushed branch, titled `title` if
  /// given.
  PrCommand(title: String)
  /// `!tailnet` asks to put the sandbox on the tailnet; `!tailnet off`
  /// takes it off.
  TailnetCommand(on: Bool)
  /// `!model` shows the model card; `!model <id> [level]` switches.
  ModelCommand(argument: String)
  /// `!github connect` or `!github disconnect`; `!github` alone connects.
  GitHubCommand(connect: Bool)
  /// A `##` aside meant for the people in the thread, not the agent.
  SideComment
  NotACommand
}

/// What may follow a command's name.
pub type Argument {
  /// Nothing: the name alone.
  NoArgument
  /// Free text, kept in its own case, or nothing; `hint` shows its shape.
  Text(hint: String)
  /// One of `options`, or nothing.
  Choice(options: List(String))
  /// Anything at all, glued to the name or not.
  Anything
}

pub type Spec {
  Spec(
    /// Lowercase, as said; the first is the one help and slash commands use.
    names: List(String),
    argument: Argument,
    /// What it does, for the help text, after its usage.
    help: String,
    /// The slash command's description, if code channels offer one.
    slash: Option(String),
    /// The command, from its argument ("" when none was given).
    build: fn(String) -> Command,
  )
}

pub const specs = [
  Spec(
    names: ["!stop", "stop", "cancel", "stop!"],
    argument: NoArgument,
    help: "stops the current run.",
    slash: Some("Stop the current run"),
    build: stop,
  ),
  Spec(
    names: ["!pause"],
    argument: NoArgument,
    help: "makes it answer only when mentioned.",
    slash: None,
    build: pause,
  ),
  Spec(
    names: ["!resume", "!unpause"],
    argument: NoArgument,
    help: "has it follow along again.",
    slash: None,
    build: resume,
  ),
  Spec(
    names: ["!pr"],
    argument: Text("[title]"),
    help: "posts a card proposing a pull request for the agent's pushed branch; whoever presses Open PR opens it, as themselves.",
    slash: Some("Propose a pull request for the pushed branch"),
    build: PrCommand,
  ),
  Spec(
    names: ["!info"],
    argument: NoArgument,
    help: "shows the branch, what changed, and whether it's pushed.",
    slash: Some("Show the branch, what changed, and whether it's pushed"),
    build: info,
  ),
  Spec(
    names: ["!done", "!archive"],
    argument: NoArgument,
    help: "in a code channel archives it.",
    slash: Some("Wrap up: archive this channel"),
    build: done,
  ),
  Spec(
    names: ["!tailnet", "!tailscale"],
    argument: Choice(["off"]),
    help: "asks to put the agent's sandbox on your tailnet for a while; `!tailnet off` ends it.",
    slash: None,
    build: tailnet,
  ),
  Spec(
    names: ["!model"],
    argument: Text("[model] [reasoning]"),
    help: "shows the model and lets you pick another and its reasoning; `!model <id> [level]` switches directly, and `!model default` goes back.",
    slash: Some("Show or switch the agent's model"),
    build: ModelCommand,
  ),
  Spec(
    names: ["!github"],
    argument: Choice(["connect", "disconnect"]),
    help: "connects your GitHub account so agents can work in your repos as you; `!github disconnect` forgets it. The App Home has both too.",
    slash: None,
    build: github,
  ),
  Spec(
    names: ["##"],
    argument: Anything,
    help: "at the start of a line talks without the agent seeing it.",
    slash: None,
    build: side_comment,
  ),
  Spec(
    names: ["!help"],
    argument: NoArgument,
    help: "shows this.",
    slash: None,
    build: help_command,
  ),
]

fn stop(_: String) -> Command {
  StopCommand
}

fn pause(_: String) -> Command {
  PauseCommand
}

fn resume(_: String) -> Command {
  ResumeCommand
}

fn info(_: String) -> Command {
  InfoCommand
}

fn done(_: String) -> Command {
  DoneCommand
}

fn tailnet(option: String) -> Command {
  TailnetCommand(on: option != "off")
}

fn github(option: String) -> Command {
  GitHubCommand(connect: option != "disconnect")
}

fn side_comment(_: String) -> Command {
  SideComment
}

fn help_command(_: String) -> Command {
  HelpCommand
}

/// What a message says, if it's a command.
pub fn parse(prompt: String) -> Command {
  let said = string.trim(prompt)
  let lower = string.lowercase(said)
  list.find_map(specs, fn(spec) {
    list.find_map(spec.names, fn(name) { said_as(spec, name, said, lower) })
  })
  |> result.unwrap(NotACommand)
}

fn said_as(
  spec: Spec,
  name: String,
  said: String,
  lower: String,
) -> Result(Command, Nil) {
  case spec.argument {
    _ if lower == name -> Ok(spec.build(""))
    NoArgument -> Error(Nil)
    Anything ->
      case string.starts_with(lower, name) {
        True -> Ok(spec.build(""))
        False -> Error(Nil)
      }
    Choice(options) ->
      list.find(options, fn(option) { lower == name <> " " <> option })
      |> result.map(spec.build)
    // Model ids keep their case: the argument comes from what was said.
    Text(_) ->
      case string.starts_with(lower, name <> " ") {
        True ->
          Ok(
            spec.build(
              string.trim(string.drop_start(said, string.length(name))),
            ),
          )
        False -> Error(Nil)
      }
  }
}

/// A slash command offered in code channels, by name without the slash.
pub type Slash {
  Slash(name: String, description: String, hint: String)
}

/// The slash commands crushling offers in its code channels, each standing
/// for its `!` command. None may be one of Slack's own (`/status`,
/// `/archive`…): a clash fails the whole set.
pub fn slash_commands() -> List(Slash) {
  list.filter_map(specs, fn(spec) {
    case spec.slash, spec.names {
      Some(description), ["!" <> name, ..] ->
        Ok(Slash(name:, description:, hint: hint(spec.argument)))
      _, _ -> Error(Nil)
    }
  })
}

/// The `!` command that slash command `name`, typed with `text`, stands
/// for.
pub fn from_slash(name: String, text: String) -> String {
  string.trim("!" <> name <> " " <> text)
}

fn hint(argument: Argument) -> String {
  case argument {
    NoArgument | Anything -> ""
    Text(hint) -> hint
    Choice(options) -> "[" <> string.join(options, "|") <> "]"
  }
}

/// Every command and what it does, for `!help`.
pub fn help() -> String {
  let lines =
    list.map(specs, fn(spec) {
      let name = case spec.names {
        [name, ..] -> name
        [] -> ""
      }
      let usage = case hint(spec.argument) {
        "" -> "`" <> name <> "`"
        hint -> "`" <> name <> "` " <> hint
      }
      "• " <> usage <> " " <> spec.help
    })
  let slashes =
    list.map(slash_commands(), fn(slash) { "`/" <> slash.name <> "`" })
  [
    "*crushling* runs a coding agent for this thread.",
    "• Reply in the thread to keep going; messages sent while it works run next.",
    ..lines
  ]
  |> list.append([
    "• In a code channel these are slash commands too: "
    <> string.join(slashes, ", ")
    <> ".",
  ])
  |> string.join("\n")
}
