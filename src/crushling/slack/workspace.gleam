//// One Slack workspace as the bridge reaches it: its id, the bot's user id,
//// and a client with its bot token. Built once per workspace by `instance`;
//// everything the bridge says in Slack goes through the functions here.
////
//// The `*_later` functions are fire-and-forget: they go through the
//// workspace's outbox, one actor that sends them in order, retries what
//// Slack throttles or drops, and logs what still fails, so nothing that
//// posts waits on Slack.

import crushling/attachments.{type Attachment, type Earlier, type Keep}
import crushling/commands
import crushling/conversation.{type Conversation, Conversation}
import crushling/crush/client
import crushling/mime
import crushling/slack/text.{type CatchUp}
import crushling/sys
import crushling/text as clip
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import slackline
import slackline/api/agents
import slackline/api/agents/conversations_archive
import slackline/api/agents/sessions_set_status
import slackline/api/chat
import slackline/api/chat/post_ephemeral
import slackline/api/chat/post_message
import slackline/api/chat/update
import slackline/api/conversations
import slackline/api/conversations/history
import slackline/api/conversations/replies
import slackline/api/files/complete_upload_external
import slackline/block
import slackline/httpc
import slackline/interaction
import slackline/message

pub opaque type Workspace {
  Workspace(
    team: String,
    bot_user: String,
    client: slackline.Client,
    token: String,
    outbox: Outbox,
  )
}

/// Sends a workspace's fire-and-forget calls, one at a time.
pub opaque type Outbox {
  Outbox(subject: Subject(Job))
}

type Job {
  Job(label: String, run: fn() -> Result(Nil, slackline.Error))
}

/// A workspace with an outbox of its own, linked to the caller.
pub fn new(
  team team: String,
  bot_user bot_user: String,
  client client: slackline.Client,
  token token: String,
) -> Workspace {
  using(start_outbox(), team:, bot_user:, client:, token:)
}

/// A workspace sending through `outbox`, which outlives the handle: a
/// registry started again with a new token keeps its workspace's order.
pub fn using(
  outbox: Outbox,
  team team: String,
  bot_user bot_user: String,
  client client: slackline.Client,
  token token: String,
) -> Workspace {
  Workspace(team:, bot_user:, client:, token:, outbox:)
}

/// An outbox, linked to the caller.
pub fn start_outbox() -> Outbox {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, job: Job) {
      // On a process of its own, so a call that crashes takes only itself.
      let worker =
        process.spawn_unlinked(fn() {
          httpc.retrying(attempts: 3, run: job.run)
          |> result.map_error(describe)
          |> best_effort(job.label, _)
        })
      let monitor = process.monitor(worker)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive_forever
      actor.continue(state)
    })
    |> actor.start
  Outbox(started.data)
}

/// The workspace's id.
pub fn team(workspace: Workspace) -> String {
  workspace.team
}

/// The bot's own user id, so mentions of it can be stripped.
pub fn bot_user(workspace: Workspace) -> String {
  workspace.bot_user
}

pub fn client(workspace: Workspace) -> slackline.Client {
  workspace.client
}

/// The bot token, for downloading attachments.
pub fn token(workspace: Workspace) -> String {
  workspace.token
}

/// A Slack error for logs and the agent; slackline includes the detail
/// Slack gives for vague codes like `invalid_arguments`.
pub fn describe(error: slackline.Error) -> String {
  slackline.describe_error(error)
}

/// Log a call that is only decoration when it fails, under `label`.
pub fn best_effort(label: String, result: Result(a, String)) -> Nil {
  case result {
    Ok(_) -> Nil
    Error(reason) -> sys.warn("crushling: " <> label <> ": " <> reason)
  }
}

fn send(run: fn() -> Result(a, slackline.Error)) -> Result(a, String) {
  httpc.retrying(attempts: 3, run:)
  |> result.map_error(describe)
}

fn later(
  workspace: Workspace,
  label: String,
  run: fn() -> Result(a, slackline.Error),
) -> Nil {
  process.send(
    workspace.outbox.subject,
    Job(label, fn() { run() |> result.replace(Nil) }),
  )
}

// Messages ---------------------------------------------------------------------

/// A message: `text` is the whole of it with no blocks, else the
/// notification fallback.
pub type Message {
  Message(text: String, blocks: List(block.Block))
}

/// Notifications and old clients show the fallback; keep it short.
const fallback_length = 200

/// A markdown message.
pub fn markdown(markdown: String) -> Message {
  Message(markdown, [block.markdown(markdown, [])])
}

fn fallback(message: Message) -> String {
  case message.blocks {
    [] -> message.text
    _ -> clip.clip(message.text, fallback_length)
  }
}

fn post_call(workspace: Workspace, place: Conversation, message: Message) {
  let call =
    chat.post_message(channel: place.channel, text: fallback(message))
    |> conversation.in_thread(place, post_message.thread_ts)
    |> post_message.unfurl_links(False)
    |> post_message.unfurl_media(False)
  case message.blocks {
    [] -> call
    blocks -> post_message.blocks(call, blocks)
  }
  |> httpc.send(workspace.client)
}

/// Post `message` in `place`, retrying what Slack throttles, and return its
/// ts. Links and media never unfurl.
pub fn post(
  workspace: Workspace,
  place: Conversation,
  message: Message,
) -> Result(String, String) {
  use <- send
  post_call(workspace, place, message)
  |> result.map(fn(posted) { posted.ts })
}

/// Replace the message at `ts` in `channel`.
pub fn update(
  workspace: Workspace,
  channel: String,
  ts: String,
  message: Message,
) -> Result(Nil, String) {
  use <- send
  update_call(workspace, channel, ts, message)
}

fn update_call(
  workspace: Workspace,
  channel: String,
  ts: String,
  message: Message,
) -> Result(Nil, slackline.Error) {
  chat.update(channel:, ts:)
  |> update.text(fallback(message))
  |> update.blocks(message.blocks)
  |> httpc.send(workspace.client)
  |> result.replace(Nil)
}

fn ephemeral_call(
  workspace: Workspace,
  place: Conversation,
  user: String,
  message: Message,
) -> Result(Nil, slackline.Error) {
  let call =
    chat.post_ephemeral(channel: place.channel, user:, text: message.text)
    |> conversation.in_thread(place, post_ephemeral.thread_ts)
  case message.blocks {
    [] -> call
    blocks -> post_ephemeral.blocks(call, blocks)
  }
  |> httpc.send(workspace.client)
  |> result.replace(Nil)
}

/// Say something only `user` sees, in `place`.
pub fn ephemeral(
  workspace: Workspace,
  place: Conversation,
  user: String,
  message: Message,
) -> Result(Nil, String) {
  ephemeral_call(workspace, place, user, message)
  |> result.map_error(describe)
}

fn respond_call(
  url: String,
  text: String,
  replace: Bool,
) -> Result(Nil, slackline.Error) {
  let message =
    interaction.ResponseMessage(
      ..interaction.ephemeral(text),
      replace_original: Some(replace),
    )
  httpc.webhook(url, interaction.response_message_to_json(message))
}

/// Answer whoever pressed a button, privately, through its `response_url`:
/// in place of the message they pressed when `replace`, else beside it.
pub fn respond(
  url: String,
  text: String,
  replace: Bool,
) -> Result(Nil, String) {
  respond_call(url, text, replace) |> result.map_error(describe)
}

/// Share a file named `name` in `place`, with `comment` ("" for none).
pub fn upload(
  workspace: Workspace,
  place: Conversation,
  name: String,
  contents: BitArray,
  comment: String,
) -> Result(Nil, String) {
  let file =
    slackline.FileUpload(
      filename: name,
      content_type: mime.of_name(name),
      contents:,
    )
  use <- send
  httpc.upload_files(workspace.client, [file], share: fn(call) {
    let call =
      complete_upload_external.channel_id(call, place.channel)
      |> conversation.in_thread(place, complete_upload_external.thread_ts)
    case comment {
      "" -> call
      comment -> complete_upload_external.initial_comment(call, comment)
    }
  })
  |> result.replace(Nil)
}

// Agent sessions and code channels ---------------------------------------------

fn session_call(
  workspace: Workspace,
  place: Conversation,
  status: agents.AgentStatus,
) -> Result(Nil, slackline.Error) {
  agents.sessions_set_status(status:)
  |> sessions_set_status.channel_id(place.channel)
  |> conversation.in_thread(place, sessions_set_status.thread_ts)
  |> httpc.send(workspace.client)
  |> result.replace(Nil)
}

fn session_label(place: Conversation, status: agents.AgentStatus) -> String {
  "setting the session in "
  <> place.channel
  <> " to "
  <> agents.agent_status_to_string(status)
}

/// Set an agent session's status: a thread's, or a whole code channel's
/// when there is no thread. Best effort: it is decoration, and Slack times
/// a working session out after an hour regardless.
fn session_status(
  workspace: Workspace,
  place: Conversation,
  status: agents.AgentStatus,
) -> Nil {
  session_call(workspace, place, status)
  |> result.map_error(describe)
  |> best_effort(session_label(place, status), _)
}

/// Show the agent session in a conversation as working, with Slack's
/// "Working…" and Stop.
pub fn mark_working(workspace: Workspace, place: Conversation) -> Nil {
  session_status(workspace, place, agents.Processing)
}

/// Mark the agent session as ready for the next prompt.
pub fn session_done(workspace: Workspace, place: Conversation) -> Nil {
  session_status(workspace, place, agents.Active)
}

fn archive_call(
  workspace: Workspace,
  channel: String,
  summary_ts: String,
) -> Result(Nil, slackline.Error) {
  let call = agents.conversations_archive(channel_id: channel)
  case summary_ts {
    "" -> call
    ts -> conversations_archive.summary_message_ts(call, ts)
  }
  |> httpc.send(workspace.client)
  |> result.replace(Nil)
}

/// Archive a code channel once its work is done, keeping `summary_ts` (a
/// message in it, or "") as its summary.
pub fn archive(
  workspace: Workspace,
  channel: String,
  summary_ts: String,
) -> Result(Nil, String) {
  archive_call(workspace, channel, summary_ts) |> result.map_error(describe)
}

/// Offer the slash commands in code channel `channel`. Best effort: the
/// `!` commands work regardless.
pub fn set_commands(workspace: Workspace, channel: String) -> Nil {
  let commands =
    list.map(commands.slash_commands(), fn(slash) {
      let commands.Slash(name:, description:, hint:) = slash
      agents.AgentCommand(name:, description:, argument_hint: case hint {
        "" -> None
        hint -> Some(hint)
      })
    })
  agents.conversations_set_commands(channel_id: channel, commands:)
  |> httpc.send(workspace.client)
  |> result.map_error(describe)
  |> best_effort("offering commands in " <> channel, _)
}

// Reading ----------------------------------------------------------------------

/// Read a conversation, oldest first: a thread's replies, or with no
/// thread a channel's top level. `after_ts` and `before_ts` ("" for no
/// bound) narrow a channel's history; a thread's replies come whole. At
/// most 200 messages.
pub fn read(
  workspace: Workspace,
  place: Conversation,
  after_ts: String,
  before_ts: String,
) -> Result(List(message.Message), String) {
  let channel = place.channel
  case place.thread {
    None -> {
      let call = conversations.history(channel:) |> history.limit(200)
      let call = case before_ts {
        "" -> call
        ts -> history.latest(call, ts)
      }
      case after_ts {
        "" -> call
        ts -> history.oldest(call, ts)
      }
      |> httpc.send(workspace.client)
      // History is newest first.
      |> result.map(fn(response) {
        option.unwrap(response.messages, []) |> list.reverse
      })
    }
    Some(ts) ->
      conversations.replies(channel:, ts:)
      |> replies.limit(200)
      |> httpc.send(workspace.client)
      |> result.map(fn(response) { option.unwrap(response.messages, []) })
  }
  |> result.map_error(describe)
}

/// What people said in `place` between `after_ts` (exclusive; "" for the
/// start) and `before_ts` (exclusive), as context for the next prompt; the
/// last `limit` messages. A code channel is caught up on as a whole.
pub fn catch_up(
  workspace: Workspace,
  place: Conversation,
  after_ts: String,
  before_ts: String,
  limit: Int,
) -> Result(CatchUp, String) {
  use found <- result.map(read(workspace, place, after_ts, before_ts))
  text.catch_up(
    found,
    option.is_some(place.thread),
    after_ts,
    before_ts,
    workspace.bot_user,
    limit,
  )
}

/// Keep a message's attachments with the bot token; see
/// `attachments.keep`.
pub fn keep_attachments(
  workspace: Workspace,
  files: List(Attachment),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  attachments.keep(workspace.token, files, keep)
}

/// Keep the files of messages a prompt caught up on.
pub fn keep_earlier(
  workspace: Workspace,
  earlier: List(Earlier),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  attachments.keep_earlier(workspace.token, earlier, keep)
}

// Later ------------------------------------------------------------------------

/// `post`, through the outbox.
pub fn post_later(
  workspace: Workspace,
  place: Conversation,
  message: Message,
) -> Nil {
  later(workspace, "posting in " <> place.channel, fn() {
    post_call(workspace, place, message)
  })
}

/// Post markdown, through the outbox.
pub fn say_later(
  workspace: Workspace,
  place: Conversation,
  markdown_text: String,
) -> Nil {
  post_later(workspace, place, markdown(markdown_text))
}

/// `update`, through the outbox.
pub fn update_later(
  workspace: Workspace,
  channel: String,
  ts: String,
  message: Message,
) -> Nil {
  later(workspace, "updating a message in " <> channel, fn() {
    update_call(workspace, channel, ts, message)
  })
}

/// `ephemeral`, through the outbox.
pub fn whisper_later(
  workspace: Workspace,
  place: Conversation,
  user: String,
  message: Message,
) -> Nil {
  later(workspace, "telling " <> user <> " in " <> place.channel, fn() {
    ephemeral_call(workspace, place, user, message)
  })
}

/// `respond`, through the outbox.
pub fn respond_later(
  workspace: Workspace,
  url: String,
  text: String,
  replace: Bool,
) -> Nil {
  later(workspace, "answering an interaction", fn() {
    respond_call(url, text, replace)
  })
}

/// `session_done`, through the outbox.
pub fn session_done_later(workspace: Workspace, place: Conversation) -> Nil {
  later(workspace, session_label(place, agents.Active), fn() {
    session_call(workspace, place, agents.Active)
  })
}

/// Say `note` (if any) at the top of code channel `channel`, then archive
/// it, through the outbox.
pub fn archive_later(
  workspace: Workspace,
  channel: String,
  note: option.Option(String),
  summary_ts: String,
) -> Nil {
  case note {
    Some(note) -> say_later(workspace, Conversation(channel, None), note)
    None -> Nil
  }
  later(workspace, "archiving " <> channel, fn() {
    archive_call(workspace, channel, summary_ts)
  })
}
