//// Subagents an agent dispatches, each shown in a Slack thread of its own:
//// a plan card of its steps, what it says between them, and a note in the
//// parent's conversation when it reports back.
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
    shown: Option(render.Plan),
    /// The ids of its messages already posted in its thread.
    posted: List(String),
    /// Set when its report arrives.
    done: Bool,
  )
}

/// What the subagents need to know about their parent thread.
pub type Parent {
  Parent(session_id: String, sink: Sink, root: String, known: run.Known)
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
    event.MessageEvent(message: event.Message(session_id: child, ..), ..)
    | event.FileEvent(event.FileVersion(session_id: child, ..)) ->
      update(subs, call_id(child) |> result.unwrap(""), fn(sub) {
        Sub(..sub, run: run.apply(sub.run, parent.known, event))
      })
    event.RunCompleteEvent(done) ->
      update(subs, call_id(done.session_id) |> result.unwrap(""), fn(sub) {
        case sub.done {
          True -> sub
          False -> {
            let sub = Sub(..sub, run: run.apply(sub.run, parent.known, event))
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
/// their threads.
pub fn close(subs: Subagents, note: String) -> Nil {
  dict.each(subs.by_call, fn(_, sub) {
    case sub.done, sub.thread {
      False, Some(thread) -> {
        let _ = thread.post(note)
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
  let plan = render.plan(sub.run, parent.root)
  let sub = case sub.thread, plan {
    None, Some(_) -> {
      let #(who, scope) = name(sub)
      case
        parent.sink.branch(
          "*" <> who <> "* is working on _" <> scope <> "_",
          who <> ": " <> scope,
        )
      {
        Ok(#(thread, link)) -> {
          thread.working(True)
          Sub(..sub, thread: Some(thread), link:)
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

/// Post the rest of a finished subagent's work in its thread, and a short
/// note with a link in the parent's conversation.
fn finish(parent: Parent, sub: Sub) -> Sub {
  let streamed = run.messages(sub.run, True)
  let sub = show_sub(parent, sub)
  // Its messages are already in its thread. Only an error, or a final answer
  // that never streamed, is left to post.
  let #(failed, output, rest) = case sub.run.outcome, list.last(streamed) {
    Some(run.Errored(error)), _ -> #(True, error, error)
    Some(run.Cancelled), _ -> #(True, "stopped", "stopped")
    _, Ok(#(_, last)) -> #(False, last, "")
    _, Error(Nil) -> {
      let answer = render.answer(sub.run) |> string.join("\n\n")
      #(False, answer, answer)
    }
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
  let verb = case failed {
    True -> "ran into trouble with"
    False -> "finished"
  }
  let link = case sub.link {
    "" -> ""
    link -> " · <" <> link <> "|see its thread>"
  }
  let summary =
    string.split(string.trim(output), "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
    |> list.take(3)
    |> list.map(fn(line) { "> " <> line })
    |> string.join("\n")
  let _ =
    parent.sink.post(
      "*"
      <> who
      <> "* "
      <> verb
      <> " _"
      <> scope
      <> "_"
      <> link
      <> "\n"
      <> summary,
    )
  sub
}
