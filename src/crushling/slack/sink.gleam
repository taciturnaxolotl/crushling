//// The Slack side of a thread: a `Sink` that shows a run as an agent
//// session (Slack's "Working…" and Stop), a plan card and markdown
//// replies, in the place the thread's venue says.

import crushling/conversation.{type Conversation, Conversation}
import crushling/render
import crushling/sink.{type Sink} as thread_sink
import crushling/slack/workspace.{type Workspace, Message}
import crushling/sys
import crushling/venue.{type Venue}
import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline/api/agents
import slackline/api/agents/conversations_create
import slackline/api/agents/conversations_set_properties
import slackline/api/agents/conversations_set_view
import slackline/api/agents/sessions_rename
import slackline/api/chat
import slackline/block
import slackline/httpc
import slackline/stream
import slackline/stream/httpc as reply

/// Where a sink posts.
pub type Place {
  /// A thread, with its own agent session.
  InThread(thread_ts: String)
  /// A code channel: top-level posts, and the channel is the session.
  InCodeChannel
  /// A thread inside a code channel, which can't have a session of its
  /// own; for subagents working there.
  InCodeThread(thread_ts: String)
}

/// Where a thread whose Slack thread is `home` (channel and ts) posts in
/// `venue`: its code channel, or else its thread.
pub fn place_of(venue: Venue, home: #(String, String)) -> #(String, Place) {
  case venue {
    venue.CodeChannel(channel:, ..) -> #(channel, InCodeChannel)
    venue.Thread | venue.ThreadOnly(..) | venue.Archived(..) -> #(
      home.0,
      InThread(home.1),
    )
  }
}

/// The sinks for a thread whose Slack thread is `home`, one per venue.
pub fn surface(
  workspace: Workspace,
  home: #(String, String),
) -> thread_sink.Surface {
  fn(at) {
    let #(channel, place) = place_of(at, home)
    place_sink(workspace, channel, place)
  }
}

fn markdown_blocks(markdown: String) -> List(block.Block) {
  [block.markdown(markdown, [])]
}

fn rich(text: String) -> Option(block.RichText) {
  case text {
    "" -> None
    text ->
      Some(block.RichText(
        elements: [block.rich_text_section([block.rich_text_run(text)])],
        block_id: None,
      ))
  }
}

fn plan_blocks(plan: render.Plan) -> List(block.Block) {
  let tasks =
    list.map(plan.tasks, fn(task) {
      block.PlanTask(
        task_id: task.id,
        title: task.title,
        status: task_status(task.status),
        details: rich(task.details),
        output: rich(task.output),
        sources: None,
        icon: None,
        hide_title: None,
      )
    })
  [block.plan(plan.title, tasks, [])]
}

fn stream_task(task: render.Task) -> stream.Task {
  stream.Task(
    id: task.id,
    title: task.title,
    status: case task.status {
      render.InProgress -> stream.Running
      render.Complete -> stream.Done
      render.Failed -> stream.Failed
    },
    details: task.details,
    output: task.output,
  )
}

fn task_status(status: render.TaskStatus) -> block.TaskStatus {
  case status {
    render.InProgress -> block.TaskInProgress
    render.Complete -> block.TaskComplete
    render.Failed -> block.TaskError
  }
}

/// Everything a thread actor needs to reply in one place in Slack.
fn place_sink(workspace: Workspace, channel: String, place: Place) -> Sink {
  let thread_ts = case place {
    InThread(ts) | InCodeThread(ts) -> Some(ts)
    InCodeChannel -> None
  }
  let here = Conversation(channel, thread_ts)
  let post = fn(text, blocks) {
    workspace.post(workspace, here, Message(text, blocks))
  }
  let branch = fn(intro, blocks, title) {
    // In a code channel a subagent gets a thread there; elsewhere a new
    // top-level message with its own session.
    let child = case place {
      InThread(_) -> InThread
      InCodeChannel | InCodeThread(_) -> InCodeThread
    }
    use root <- result.try(workspace.post(
      workspace,
      Conversation(channel, None),
      Message(intro, blocks),
    ))
    let link =
      chat.get_permalink(channel:, message_ts: root)
      |> httpc.send(workspace.client(workspace))
      |> result.map(fn(found) { found.permalink })
      |> result.unwrap("")
    let branch = place_sink(workspace, channel, child(root))
    thread_sink.title(branch, title)
    Ok(
      thread_sink.Branch(
        sink: branch,
        link:,
        root_ts: root,
        post_plan: post_plan(branch, _),
        update_plan: fn(ts, plan) { update_plan(branch, ts, plan) },
      ),
    )
  }
  thread_sink.Sink(
    conversation: here,
    reply: open_reply(workspace, here, _),
    post: fn(markdown) { post(markdown, markdown_blocks(markdown)) },
    post_blocks: post,
    update_blocks: fn(ts, text, blocks) {
      workspace.update(workspace, channel, ts, Message(text, blocks))
    },
    delete: fn(ts) {
      httpc.retrying(attempts: 3, run: fn() {
        chat.delete(channel:, ts:)
        |> httpc.send(workspace.client(workspace))
      })
      |> result.replace(Nil)
      |> result.map_error(workspace.describe)
    },
    upload: fn(name, content) {
      workspace.upload(
        workspace,
        here,
        name,
        bit_array.from_string(content),
        "",
      )
    },
    branch:,
    session: case place {
      InThread(_) | InCodeChannel -> Some(session(workspace, here))
      InCodeThread(_) -> None
    },
    code_view: case place {
      InCodeChannel -> Some(code_view(workspace, channel))
      InThread(_) | InCodeThread(_) -> None
    },
    open_code_channel: case place {
      InThread(root) -> Some(open_code_channel(workspace, channel, root, _))
      InCodeChannel | InCodeThread(_) -> None
    },
  )
}

/// A plan card, as markdown in a workspace that rejects plan blocks.
fn post_plan(sink: Sink, plan: render.Plan) -> Result(String, String) {
  case sink.post_blocks(plan.title, plan_blocks(plan)) {
    Ok(ts) -> Ok(ts)
    Error(_) -> {
      let markdown = render.plan_markdown(plan)
      sink.post_blocks(markdown, markdown_blocks(markdown))
    }
  }
}

fn update_plan(
  sink: Sink,
  ts: String,
  plan: render.Plan,
) -> Result(Nil, String) {
  case sink.update_blocks(ts, plan.title, plan_blocks(plan)) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> {
      let markdown = render.plan_markdown(plan)
      sink.update_blocks(ts, markdown, markdown_blocks(markdown))
    }
  }
}

/// A run's reply streams where Slack can, and falls back to a plan card and
/// messages where it can't; slackline's stream handles both. Slack streams
/// a reply in a channel to one person, named by user and team.
fn open_reply(
  workspace: Workspace,
  here: Conversation,
  from: String,
) -> thread_sink.Reply {
  let builder =
    stream.new(workspace.client(workspace), channel: here.channel)
    |> stream.to(user: from, team: workspace.team(workspace))
  let builder = case here.thread {
    Some(ts) -> stream.in_thread(builder, ts)
    None -> builder
  }
  case reply.open(builder) {
    Error(error) -> {
      sys.warn("crushling: couldn't open a reply: " <> string.inspect(error))
      thread_sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] })
    }
    Ok(opened) ->
      thread_sink.Reply(
        show: fn(text, tasks, title) {
          reply.text(opened, text)
          list.each(tasks, fn(task) { reply.task(opened, stream_task(task)) })
          reply.title(opened, title)
        },
        finish: fn(closing) {
          case reply.finish(opened, closing:) {
            Ok(finished) -> {
              case finished.problem {
                Some(problem) ->
                  sys.warn("crushling: the reply didn't stream: " <> problem)
                None -> Nil
              }
              finished.messages
            }
            Error(Nil) -> {
              sys.warn("crushling: the reply's writer stopped answering")
              []
            }
          }
        },
      )
  }
}

fn session(workspace: Workspace, here: Conversation) -> thread_sink.Session {
  thread_sink.Session(
    // Slack shows "Working…" with its Stop control until the session is
    // set back to active; posting doesn't clear it.
    working: fn(working) {
      case working {
        True -> workspace.mark_working(workspace, here)
        False -> workspace.session_done(workspace, here)
      }
    },
    title: fn(title) {
      agents.sessions_rename(title:)
      |> sessions_rename.channel_id(here.channel)
      |> conversation.in_thread(here, sessions_rename.thread_ts)
      |> httpc.send(workspace.client(workspace))
      |> result.map_error(workspace.describe)
      |> workspace.best_effort("naming the session in " <> here.channel, _)
    },
  )
}

/// Open a code channel called `name` from the thread at `root` in
/// `channel`. Slack's answer has no ts, so the time it came back stands in
/// for when the channel opened.
fn open_code_channel(
  workspace: Workspace,
  channel: String,
  root: String,
  name: String,
) -> Result(thread_sink.Opened, String) {
  use opened <- result.try(
    agents.conversations_create()
    |> conversations_create.name(string.slice(name, 0, 80))
    |> conversations_create.origin_channel_id(channel)
    |> conversations_create.origin_message_ts(root)
    // A session that was archived and picked up again gets a new
    // channel, so the id can't be the thread alone; kept short.
    |> conversations_create.session_id(sys.uuid())
    |> httpc.send(workspace.client(workspace))
    |> result.map_error(fn(error) {
      workspace.describe(error) <> " creating a code channel named " <> name
    }),
  )
  let ts = float.to_string(int.to_float(sys.system_ms()) /. 1000.0)
  workspace.set_commands(workspace, opened.channel_id)
  Ok(thread_sink.Opened(channel: opened.channel_id, ts:))
}

fn code_view(workspace: Workspace, channel: String) -> thread_sink.CodeView {
  let client = workspace.client(workspace)
  thread_sink.CodeView(
    context: fn(items) {
      let items =
        list.take(items, 5)
        |> list.map(fn(item) {
          agents.ContextBarItem(
            key: item.key,
            label: item.label,
            icon: Some(item.icon),
            url: case item.url {
              "" -> None
              url -> Some(url)
            },
            item_type: None,
          )
        })
      agents.conversations_set_properties(channel_id: channel)
      |> conversations_set_properties.code_channel(agents.CodeChannelProperties(
        context_bar_items: Some(items),
        summary_message: None,
      ))
      |> httpc.send(client)
      |> result.map_error(workspace.describe)
      |> workspace.best_effort("setting the context bar in " <> channel, _)
    },
    code: fn(diff, base, head) {
      case string.trim(diff) {
        "" ->
          agents.conversations_remove_view(channel_id: channel)
          |> httpc.send(client)
          |> result.map_error(workspace.describe)
          |> workspace.best_effort("clearing the Code tab in " <> channel, _)
        _ -> set_code_view(workspace, channel, diff, base, head)
      }
    },
  )
}

fn set_code_view(
  workspace: Workspace,
  channel: String,
  diff: String,
  base: String,
  head: String,
) -> Nil {
  let call =
    agents.conversations_set_view(channel_id: channel)
    |> conversations_set_view.type_("diff")
    |> conversations_set_view.content(diff)
  let call = case base {
    "" -> call
    base -> conversations_set_view.base_branch(call, base)
  }
  let call = case head {
    "" | "HEAD" -> call
    head -> conversations_set_view.head_branch(call, head)
  }
  let attempt = fn() {
    httpc.send(call, workspace.client(workspace))
    |> result.map_error(workspace.describe)
  }
  // A brand-new channel can refuse its first view for a moment.
  case attempt() {
    Error(reason) ->
      case string.contains(reason, "view_creation_failed") {
        True -> {
          process.sleep(2000)
          attempt()
        }
        False -> Error(reason)
      }
    ok -> ok
  }
  |> workspace.best_effort("Code tab update failed", _)
}
