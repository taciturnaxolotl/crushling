//// Subagents an agent dispatches. In a code channel, each gets a thread of
//// its own: a first message in the channel that says who it is and how it
//// is doing, and in its thread a plan card of its steps and what it says
//// between them; when it reports back, its first message says how it went
//// and the parent's conversation gets a short note with a link. In a Slack
//// thread, which can't hold threads of its own, a subagent is only its row
//// in the parent's plan card (`rows`), showing what it's doing.
////
//// Each runs in a child session, `<message id>$$<tool call id>`, whether
//// started with `agent` (the parent waits) or `agent_dispatch` (it reports
//// back later). Session events give it a title, a dispatch result gives it
//// a name, its own messages are its progress, and its own run_complete
//// finishes it.

import crushling/crush/event
import crushling/render
import crushling/run.{type Run}
import crushling/sink.{type Sink}
import crushling/sys
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline/block

pub opaque type Subagents {
  Subagents(by_call: Dict(String, Sub))
}

type Sub {
  Sub(
    /// The tool call that started it, its key.
    key: String,
    /// The name crush gave a dispatched one, like "madeline-crush-server-api".
    label: String,
    /// What crush titled its session.
    title: String,
    run: Run,
    /// Its thread, once opened, and the link to it.
    thread: Option(Sink),
    link: String,
    plan_ts: Option(String),
    /// Its first message in the channel, to update when it finishes.
    root_ts: Option(String),
    /// When it started, in monotonic ms.
    started_ms: Int,
    shown: Option(render.Plan),
    /// The ids of its messages already posted in its thread.
    posted: List(String),
    /// Set when its report arrives.
    done: Bool,
  )
}

/// What the subagents need to know about their parent thread.
pub type Parent {
  Parent(
    session_id: String,
    sink: Sink,
    root: String,
    /// Whether subagents get threads of their own: only in a code channel.
    threads: Bool,
  )
}

pub fn new() -> Subagents {
  Subagents(dict.new())
}

/// Whether any subagent is still working.
pub fn running(subs: Subagents) -> Bool {
  dict.values(subs.by_call) |> list.any(fn(sub) { !sub.done })
}

/// Follow an event from the server.
pub fn track(subs: Subagents, parent: Parent, event: event.Event) -> Subagents {
  case event {
    event.SessionEvent(id:, parent_session_id:, title:)
      if parent_session_id == parent.session_id && parent.session_id != ""
    ->
      case call_id(id) {
        Ok(call) ->
          upsert(subs, call, id, fn(sub) {
            case title {
              "" | "New Agent Session" -> sub
              title -> Sub(..sub, title:)
            }
          })
        Error(Nil) -> subs
      }
    event.MessageEvent(message:, ..)
      if message.session_id == parent.session_id
    ->
      list.fold(message.tool_results, subs, fn(subs, result) {
        case result.name, started_label(result.content) {
          "agent_dispatch", Ok(label) ->
            update(subs, result.tool_call_id, fn(sub) { Sub(..sub, label:) })
          _, _ -> subs
        }
      })
    event.MessageEvent(message: event.Message(session_id: child, ..), ..) ->
      update(subs, call_id(child) |> result.unwrap(""), fn(sub) {
        Sub(..sub, run: run.apply(sub.run, event))
      })
    event.RunCompleteEvent(done) ->
      update(subs, call_id(done.session_id) |> result.unwrap(""), fn(sub) {
        case sub.done {
          True -> sub
          False -> {
            let sub = Sub(..sub, run: run.apply(sub.run, event))
            case run.is_done(sub.run) {
              True -> finish(parent, Sub(..sub, done: True))
              False -> sub
            }
          }
        }
      })
    _ -> subs
  }
}

/// Bring every working subagent's thread up to date.
pub fn show(subs: Subagents, parent: Parent) -> Subagents {
  Subagents(
    dict.map_values(subs.by_call, fn(_, sub) {
      case sub.done {
        True -> sub
        False -> show_sub(parent, sub)
      }
    }),
  )
}

/// When a run is cancelled, its subagents stop too. Post `note` in each of
/// their threads, unless it is "".
pub fn close(subs: Subagents, note: String) -> Nil {
  dict.each(subs.by_call, fn(_, sub) {
    case sub.done, sub.thread {
      False, Some(thread) -> {
        case note {
          "" -> Nil
          note -> {
            let _ = thread.post(note)
            Nil
          }
        }
        thread.working(False)
      }
      _, _ -> Nil
    }
  })
}

fn update(subs: Subagents, call: String, change: fn(Sub) -> Sub) -> Subagents {
  case dict.get(subs.by_call, call) {
    Ok(sub) -> Subagents(dict.insert(subs.by_call, call, change(sub)))
    Error(Nil) -> subs
  }
}

fn upsert(
  subs: Subagents,
  call: String,
  session_id: String,
  change: fn(Sub) -> Sub,
) -> Subagents {
  let sub =
    dict.get(subs.by_call, call)
    |> result.unwrap(Sub(
      key: call,
      label: "",
      title: "",
      run: run.new(session_id, ""),
      thread: None,
      link: "",
      plan_ts: None,
      root_ts: None,
      started_ms: sys.monotonic_ms(),
      shown: None,
      posted: [],
      done: False,
    ))
  Subagents(dict.insert(subs.by_call, call, change(sub)))
}

fn call_id(session_id: String) -> Result(String, Nil) {
  string.split_once(session_id, "$$") |> result.map(fn(pair) { pair.1 })
}

/// The label crush gave a dispatched subagent, from the tool's result:
/// `Started subagent "madeline-crush-server-api". …`
fn started_label(content: String) -> Result(String, Nil) {
  use #(_, rest) <- result.try(string.split_once(content, "Started subagent \""))
  string.split_once(rest, "\"") |> result.map(fn(pair) { pair.0 })
}

const names = [
  "Ada", "Grace", "Alan", "Edsger", "Barbara", "Margaret", "Linus", "Radia",
  "Ken", "Dennis", "Frances", "Donald", "Leslie", "Hedy", "Niklaus", "Katherine",
]

/// What to call a subagent: the first name crush gave a dispatched one
/// ("madeline-crush-server-api" is Madeline), otherwise one picked from its
/// call id so it stays the same. And what it is working on.
fn name(sub: Sub) -> #(String, String) {
  let scope = case sub.title {
    "" -> "a task"
    title -> title
  }
  case string.split_once(sub.label, "-") {
    Ok(#(first, rest)) -> #(string.capitalise(first), case sub.title {
      "" -> rest
      title -> title
    })
    Error(Nil) -> {
      let hash =
        string.to_utf_codepoints(sub.key)
        |> list.fold(0, fn(acc, cp) {
          acc * 31 + string.utf_codepoint_to_int(cp)
        })
      let index = int.absolute_value(hash) % list.length(names)
      #(list.drop(names, index) |> list.first |> result.unwrap("Ada"), scope)
    }
  }
}

/// Open the subagent's thread once it has a step to show, keep its plan
/// card current, and post what it says.
fn show_sub(parent: Parent, sub: Sub) -> Sub {
  case parent.threads {
    True -> show_thread(parent, sub)
    False -> sub
  }
}

fn show_thread(parent: Parent, sub: Sub) -> Sub {
  let plan = render.plan(sub.run, parent.root)
  let sub = case sub.thread, plan {
    None, Some(_) -> {
      let #(who, scope) = name(sub)
      let #(text, blocks) = card(who, scope, "Subagent · working")
      case parent.sink.branch(text, blocks, who <> ": " <> scope) {
        Ok(#(thread, link, ts)) -> {
          thread.working(True)
          Sub(..sub, thread: Some(thread), link:, root_ts: Some(ts))
        }
        Error(reason) -> {
          sys.warn("crushling: couldn't open a subagent thread: " <> reason)
          sub
        }
      }
    }
    _, _ -> sub
  }
  let sub = case sub.thread, plan, sub.plan_ts {
    Some(thread), Some(plan), Some(ts) if Some(plan) != sub.shown ->
      case thread.update_plan(ts, plan) {
        Ok(Nil) -> Sub(..sub, shown: Some(plan))
        Error(_) -> sub
      }
    Some(thread), Some(plan), None ->
      case thread.post_plan(plan) {
        Ok(ts) -> Sub(..sub, plan_ts: Some(ts), shown: Some(plan))
        Error(_) -> sub
      }
    _, _, _ -> sub
  }
  post_messages(sub)
}

/// Post what the subagent said between its tool calls, each message once
/// it is complete, so its thread reads as its working notes.
fn post_messages(sub: Sub) -> Sub {
  case sub.thread {
    None -> sub
    Some(thread) ->
      run.messages(sub.run, sub.done)
      |> list.filter(fn(message) { !list.contains(sub.posted, message.0) })
      |> list.fold(sub, fn(sub, message) {
        list.each(render.chunk(message.1, render.message_limit), fn(chunk) {
          let _ = thread.post(chunk)
          Nil
        })
        Sub(..sub, posted: [message.0, ..sub.posted])
      })
  }
}

/// A subagent's first message in the channel: who, what, and how it's
/// going.
fn card(
  who: String,
  scope: String,
  status: String,
) -> #(String, List(block.Block)) {
  let text = "*" <> who <> "* · " <> scope
  #(text, [
    block.section(text: block.mrkdwn(text), with: []),
    block.context(elements: [block.context_mrkdwn(status)], with: []),
  ])
}

/// How a finished subagent went, in a few words: "Done · 5 steps · 1m 12s".
fn outcome(sub: Sub, failed: Bool) -> String {
  let steps = case list.length(sub.run.tools) {
    1 -> "1 step"
    n -> int.to_string(n) <> " steps"
  }
  let how = case failed, sub.run.outcome {
    True, Some(run.Cancelled) -> "Stopped"
    True, _ -> "Ran into trouble"
    False, _ -> "Done"
  }
  how <> " · " <> steps <> " · " <> took(sys.monotonic_ms() - sub.started_ms)
}

fn took(ms: Int) -> String {
  let s = ms / 1000
  case s < 60 {
    True -> int.to_string(int.max(s, 1)) <> "s"
    False ->
      int.to_string(s / 60)
      <> "m"
      <> case s % 60 {
        0 -> ""
        rest -> " " <> int.to_string(rest) <> "s"
      }
  }
}

/// A finished subagent: the rest of its work in its thread, its first
/// message updated with how it went, and a note in the parent's
/// conversation linking to it. The parent's own reply says what it found,
/// so the note doesn't repeat it. In a Slack thread, its row in the plan
/// card is all.
fn finish(parent: Parent, sub: Sub) -> Sub {
  case parent.threads {
    False -> sub
    True -> finish_thread(parent, sub)
  }
}

fn finish_thread(parent: Parent, sub: Sub) -> Sub {
  let streamed = run.messages(sub.run, True)
  let sub = show_thread(parent, sub)
  // Its messages are already in its thread. Only an error, or a final answer
  // that never streamed, is left to post.
  let #(failed, rest) = case sub.run.outcome, list.last(streamed) {
    Some(run.Errored(error)), _ -> #(True, error)
    Some(run.Cancelled), _ -> #(True, "")
    _, Ok(_) -> #(False, "")
    _, Error(Nil) -> #(False, render.answer(sub.run) |> string.join("\n\n"))
  }
  case sub.thread {
    Some(thread) -> {
      render.chunk(rest, render.message_limit)
      |> list.filter(fn(chunk) { string.trim(chunk) != "" })
      |> list.each(fn(chunk) {
        let _ = thread.post(chunk)
        Nil
      })
      thread.working(False)
    }
    None -> Nil
  }
  let #(who, scope) = name(sub)
  let status = outcome(sub, failed)
  case sub.root_ts {
    Some(ts) -> {
      let #(text, blocks) = card(who, scope, status)
      let _ = parent.sink.update_blocks(ts, text, blocks)
      Nil
    }
    None -> Nil
  }
  case sub.link {
    "" -> Nil
    link -> {
      let verb = case failed {
        True -> "stopped on"
        False -> "finished"
      }
      let text = "*" <> who <> "* " <> verb <> " " <> scope
      let _ =
        parent.sink.post_blocks(text, [
          block.section(
            text: block.mrkdwn(text <> " · <" <> link <> "|open its thread>"),
            with: [],
          ),
          block.context(elements: [block.context_mrkdwn(status)], with: []),
        ])
      Nil
    }
  }
  sub
}

/// The parent's plan card rows, with each subagent's row saying who it is,
/// what it's on, and, while it works, its latest step.
pub fn rows(subs: Subagents, tasks: List(render.Task)) -> List(render.Task) {
  list.map(tasks, fn(task) {
    case dict.get(subs.by_call, task.id) {
      Error(Nil) -> task
      Ok(sub) -> {
        let #(who, scope) = name(sub)
        let latest =
          list.last(sub.run.tools)
          |> result.map(fn(tool) {
            case tool.description {
              "" -> render.title(tool.name)
              description -> string.capitalise(description)
            }
          })
          |> result.unwrap("Starting")
        render.Task(
          ..task,
          title: who <> ": " <> scope,
          status: case sub.done, sub.run.outcome {
            False, _ -> render.InProgress
            True, Some(run.Completed(_)) -> render.Complete
            True, _ -> render.Failed
          },
          details: case sub.done {
            False -> latest
            True -> outcome(sub, sub.run.outcome != None && !is_completed(sub))
          },
        )
      }
    }
  })
}

fn is_completed(sub: Sub) -> Bool {
  case sub.run.outcome {
    Some(run.Completed(_)) -> True
    _ -> False
  }
}
