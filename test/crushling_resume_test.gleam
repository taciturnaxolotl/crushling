//// A thread's event stream resumes after a drop: against a fake `crush
//// server` (test/fake_crush_ffi.erl), the thread rejoins its workspace,
//// subscribes with `Last-Event-ID`, finishes runs from replayed events,
//// falls back to checking the session on a resync, and never handles an
//// event twice.

import crushling/crush/client
import crushling/crush/event
import crushling/gun
import crushling/render
import crushling/run
import crushling/sink
import crushling/thread
import crushling/thread/resume
import crushling/venue
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

type Server

@external(erlang, "fake_crush_ffi", "start")
fn start_server(path: String) -> Server

@external(erlang, "fake_crush_ffi", "stop")
fn stop_server(server: Server) -> Nil

@external(erlang, "fake_crush_ffi", "push")
fn push(server: Server, frame: String) -> Nil

@external(erlang, "fake_crush_ffi", "drop")
fn drop(server: Server) -> Nil

@external(erlang, "fake_crush_ffi", "set_busy")
fn set_busy(server: Server, busy: Bool) -> Nil

@external(erlang, "fake_crush_ffi", "set_exists")
fn set_exists(server: Server, exists: Bool) -> Nil

@external(erlang, "fake_crush_ffi", "expire_on_get")
fn expire_on_get(server: Server) -> Nil

@external(erlang, "fake_crush_ffi", "suspend")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "fake_crush_ffi", "resume")
fn resume_actor(pid: process.Pid) -> Nil

@external(erlang, "fake_crush_ffi", "next")
fn next_request(timeout_ms: Int) -> Result(#(String, a), Nil)

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

// The cursor on its own.

pub fn ids_parse_test() {
  let assert Ok(resume.EventId("ab12", 7)) = resume.parse("ab12-7")
  let assert Error(Nil) = resume.parse("7")
  let assert Error(Nil) = resume.parse("-7")
  let assert Error(Nil) = resume.parse("ab-x")
}

pub fn cursor_tracks_ids_test() {
  let cursor = resume.new()
  let assert None = resume.last(cursor)
  // An event without an id is handled and doesn't move the cursor.
  let assert #(True, cursor) = resume.admit(cursor, None)
  let assert None = resume.last(cursor)
  let assert #(True, cursor) = resume.admit(cursor, Some("e-1"))
  let assert #(True, cursor) = resume.admit(cursor, Some("e-2"))
  let assert Some("e-2") = resume.last(cursor)
  let assert #(True, cursor) = resume.admit(cursor, None)
  let assert Some("e-2") = resume.last(cursor)
}

pub fn empty_id_clears_the_cursor_test() {
  let assert #(True, cursor) = resume.admit(resume.new(), Some("e-1"))
  let assert #(True, cursor) = resume.admit(cursor, Some(""))
  let assert None = resume.last(cursor)
  // No id at all leaves it alone.
  let assert #(True, cursor) = resume.admit(cursor, Some("e-2"))
  let assert #(True, cursor) = resume.admit(cursor, None)
  let assert Some("e-2") = resume.last(cursor)
}

pub fn cursor_skips_duplicates_test() {
  let assert #(True, cursor) = resume.admit(resume.new(), Some("e-5"))
  // Explicit repeats are duplicates, however many in a row.
  let assert #(False, cursor) = resume.admit(cursor, Some("e-5"))
  let assert #(False, cursor) = resume.admit(cursor, Some("e-5"))
  let assert #(False, cursor) = resume.admit(cursor, Some("e-3"))
  let assert #(True, cursor) = resume.admit(cursor, Some("e-6"))
  let assert Some("e-6") = resume.last(cursor)
  // Another epoch is never a duplicate.
  let assert #(True, cursor) = resume.admit(cursor, Some("f-1"))
  let assert Some("f-1") = resume.last(cursor)
  // A resync positions the cursor at its own id.
  let cursor = resume.resynced(cursor, Some("g-9"))
  let assert Some("g-9") = resume.last(cursor)
}

pub fn resync_event_parses_test() {
  let assert Ok(event.Resync("epoch_mismatch", "a-3")) =
    event.parse(
      "{\"type\":\"resync\",\"payload\":{\"reason\":\"epoch_mismatch\",\"last_event_id\":\"a-3\"}}",
    )
}

pub fn stream_sends_last_event_id_test() {
  let assert [#("accept", "text/event-stream"), #("last-event-id", "e-4")] =
    gun.stream_headers([], Some("e-4"))
  let assert [#("accept", "text/event-stream"), #("x", "y")] =
    gun.stream_headers([#("x", "y")], None)
}

// A thread against the fake server.

type Seen {
  Posted(String)
  Ended(thread.Finished)
}

fn start(name: String) -> #(Server, Subject(thread.Message), Subject(Seen)) {
  let socket =
    "/tmp/crushling-resume-"
    <> name
    <> "-"
    <> int.to_string(int.absolute_value(unique()))
    <> ".sock"
  let server = start_server(socket)
  let seen = process.new_subject()
  let post = fn(text) {
    process.send(seen, Posted(text))
    Ok("ts")
  }
  let sink =
    sink.Sink(
      conversation: sink.Conversation("C", Some("1.0")),
      working: fn(_) { Nil },
      title: fn(_) { Nil },
      post:,
      post_blocks: fn(text, _) { post(text) },
      update_blocks: fn(_, _, _) { Ok(Nil) },
      delete: fn(_) { Ok(Nil) },
      post_plan: fn(plan) { post(render.plan_markdown(plan)) },
      update_plan: fn(_, _) { Ok(Nil) },
      reply: fn(_) {
        sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(closing) {
          let _ = post(closing)
          []
        })
      },
      upload: fn(_, _) { Ok(Nil) },
      branch: fn(_, _, _) { Error("no") },
      open_code_channel: fn(_) { Error("no") },
      context: fn(_) { Nil },
      code: fn(_, _, _) { Nil },
    )
  let assert Ok(t) =
    thread.start(
      thread.Config(
        socket:,
        root: "/work",
        title: "test",
        venue: venue.Thread,
        sink:,
        flush_ms: 60_000,
        mode: client.Yolo,
        notify: fn(notice) {
          case notice {
            thread.RunEnded(finished) -> process.send(seen, Ended(finished))
            _ -> Nil
          }
        },
        on_connect: fn(_) { Nil },
        model: None,
        home: #("C", "1.0"),
      ),
    )
  #(server, t, seen)
}

/// The next request of `kind`, skipping others.
fn expect(kind: String) -> a {
  case next_request(5000) {
    Ok(#(got, value)) if got == kind -> value
    Ok(_) -> expect(kind)
    Error(Nil) -> panic as { "no " <> kind <> " request" }
  }
}

/// The requests that matter from here until the event stream reopens, and
/// its Last-Event-ID.
fn until_events(seen: List(String)) -> #(List(String), String) {
  case next_request(5000) {
    Ok(#("events", last)) -> #(list.reverse(seen), last)
    Ok(#(kind, _)) -> until_events([kind, ..seen])
    Error(Nil) -> panic as "the event stream never reopened"
  }
}

fn finished(
  seen: Subject(Seen),
  posts: List(String),
) -> #(thread.Finished, List(String)) {
  case process.receive(seen, 5000) {
    Ok(Ended(finished)) -> #(finished, list.reverse(posts))
    Ok(Posted(text)) -> finished(seen, [text, ..posts])
    Error(Nil) -> panic as "the run never ended"
  }
}

/// Connect, send a prompt, and return its run id.
fn prompted(t: Subject(thread.Message)) -> String {
  let assert "" = expect("events")
  process.send(t, thread.Prompt("go", [], ""))
  expect("prompt")
}

fn frame(id: String, data: String) -> String {
  case id {
    "" -> "data: " <> data <> "\n\n"
    id -> "id: " <> id <> "\ndata: " <> data <> "\n\n"
  }
}

fn says(text: String) -> String {
  "{\"type\":\"message\",\"payload\":{\"type\":\"updated\",\"payload\":{\"id\":\"m1\",\"role\":\"assistant\",\"session_id\":\"s1\",\"parts\":[{\"type\":\"text\",\"data\":{\"text\":\""
  <> text
  <> "\"}}]}}}"
}

fn completes(run_id: String) -> String {
  "{\"type\":\"run_complete\",\"payload\":{\"type\":\"created\",\"payload\":{\"session_id\":\"s1\",\"run_id\":\""
  <> run_id
  <> "\",\"message_id\":\"m1\",\"text\":\"done\",\"error\":\"\",\"cancelled\":false}}}"
}

fn resync(reason: String) -> String {
  "{\"type\":\"resync\",\"payload\":{\"reason\":\""
  <> reason
  <> "\",\"last_event_id\":\"x\"}}"
}

fn lost(posts: List(String)) -> Bool {
  list.any(posts, string.contains(_, "lost the connection"))
}

pub fn run_completing_in_a_gap_finishes_from_the_replay_test() {
  let #(server, t, seen) = start("gap")
  let run_id = prompted(t)
  push(server, frame("e-1", says("working")))
  drop(server)

  // The thread rejoins its workspace without creating it again, resumes
  // after the last event it handled, and doesn't ask whether the session
  // is busy.
  let assert #(["got"], "e-1") = until_events([])
  push(server, frame("e-2", says("all done")))
  push(server, frame("e-3", completes(run_id)))

  let #(finished, posts) = finished(seen, [])
  let assert run.Completed("done") = finished.outcome
  let assert "all done" = finished.text
  let assert False = lost(posts)
  let assert Error(Nil) = next_request(50)
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn gone_workspace_is_created_again_test() {
  let #(server, t, _seen) = start("gone")
  let _ = prompted(t)
  push(server, frame("e-1", says("working")))
  set_exists(server, False)
  drop(server)
  let assert #(["got", "created"], "e-1") = until_events([])
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn resync_falls_back_to_the_session_state_test() {
  let #(server, t, seen) = start("resync")
  let run_id = prompted(t)
  push(server, frame("e-1", says("working")))
  drop(server)
  let assert #(_, "e-1") = until_events([])

  // Still busy: the run carries on, from the resync's position.
  set_busy(server, True)
  push(server, frame("f-1", resync("epoch_mismatch")))
  let assert True = expect("busy")
  drop(server)
  let assert #(_, "f-1") = until_events([])

  // Not busy any more: the run ends as lost.
  set_busy(server, False)
  push(server, frame("f-2", resync("expired")))
  let assert False = expect("busy")
  let #(finished, _) = finished(seen, [])
  let assert run.Errored("lost the connection mid-run") = finished.outcome
  let _ = run_id
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn duplicates_are_ignored_test() {
  let #(server, t, seen) = start("dup")
  let run_id = prompted(t)
  push(server, frame("e-1", says("old")))
  push(server, frame("e-2", says("new")))
  drop(server)
  let assert #(_, "e-2") = until_events([])

  // Replayed again at the boundary, two in a row with the same id, then an
  // older one: all already handled.
  push(server, frame("e-2", says("stale two")))
  push(server, frame("e-2", says("stale two again")))
  push(server, frame("e-1", says("stale one")))
  push(server, frame("e-3", completes(run_id)))
  let #(finished, _) = finished(seen, [])
  let assert run.Completed(_) = finished.outcome
  let assert "new" = finished.text
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn queued_prompt_waits_for_the_stream_to_attach_test() {
  let #(server, t, _seen) = start("expire")
  let assert "" = expect("events")
  let assert Ok(pid) = process.subject_owner(t)

  // The stream drops while nothing runs, and a prompt arrives before the
  // thread has reconnected. The workspace check then passes, but the
  // workspace is gone by the time the stream attaches.
  expire_on_get(server)
  suspend(pid)
  drop(server)
  process.sleep(200)
  process.send(t, thread.Prompt("go", [], ""))
  resume_actor(pid)

  // The 404 sets the workspace up again in the same attempt, and only then
  // is the prompt sent, to the new workspace.
  let assert #(["got", "refused", "created"], "") = until_events([])
  let _run_id: String = expect("prompt")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn drop_before_any_id_settles_after_attach_test() {
  let #(server, t, seen) = start("noids")
  let _ = prompted(t)
  set_busy(server, False)
  drop(server)

  // Nothing to resume from: no Last-Event-ID, and the session is checked
  // only once the stream is attached.
  let assert #(kinds, "") = until_events([])
  let assert False = list.contains(kinds, "busy")
  let assert False = expect("busy")
  let #(finished, _) = finished(seen, [])
  let assert run.Errored("lost the connection mid-run") = finished.outcome
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn event_without_id_is_handled_test() {
  let #(server, t, seen) = start("noid")
  let run_id = prompted(t)
  push(server, frame("e-1", says("first")))
  // gun reports this with the id before it, e-1; it must still count.
  push(server, frame("", says("second")))
  push(server, frame("e-2", completes(run_id)))
  let #(finished, _) = finished(seen, [])
  let assert "second" = finished.text
  process.send(t, thread.Stop)
  stop_server(server)
}
