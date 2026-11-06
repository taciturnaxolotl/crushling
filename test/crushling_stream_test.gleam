import crushling/crush/event
import crushling/render
import crushling/run
import gleam/dict
import gleam/list
import gleeunit/should

fn assistant(id: String, text: String) -> event.Event {
  event.MessageEvent(
    "updated",
    event.Message(id, "s1", event.Assistant, text, [], [], []),
  )
}

fn tool(call_id: String) -> event.Event {
  event.MessageEvent(
    "created",
    event.Message(
      "t" <> call_id,
      "s1",
      event.Tool,
      "",
      [],
      [event.ToolResult(call_id, "bash", "out", False)],
      [],
    ),
  )
}

fn feed(events: List(event.Event)) -> run.Run {
  list.fold(events, run.new("s1", "r1"), fn(r, e) {
    run.apply(r, dict.new(), e)
  })
}

fn texts(chunks: List(render.Chunk)) -> List(String) {
  list.filter_map(chunks, fn(chunk) {
    case chunk {
      render.ChunkText(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

pub fn text_streams_in_deltas_test() {
  let first = feed([assistant("m1", "Look")])
  let start = render.pending(first, "/w", render.empty_shown())
  should.equal(["Look"], texts(start.chunks))

  // The same message comes back longer as it streams.
  let second = feed([assistant("m1", "Looking at it.")])
  let next = render.pending(second, "/w", start.shown)
  should.equal(["ing at it."], texts(next.chunks))
  should.equal("", render.remainder(render.reply(second), next.shown.text))

  // Nothing new, nothing to send.
  let again = render.pending(second, "/w", next.shown)
  should.equal([], again.chunks)
}

pub fn a_new_message_follows_the_last_test() {
  let r = feed([assistant("m1", "One."), assistant("m2", "Two.")])
  let next = render.pending(r, "/w", render.empty_shown())
  should.equal(["One.", "\n\nTwo."], texts(next.chunks))
  should.equal("", render.remainder(render.reply(r), next.shown.text))
}

pub fn what_did_not_fit_is_posted_after_test() {
  let r = feed([assistant("m1", "Done.")])
  let next = render.pending(r, "/w", render.empty_shown())
  // A run whose text was cut short by the stream limit says the rest.
  should.equal("and more", render.remainder("Done.and more", "Done."))
  should.equal("", render.remainder("Done.", next.shown.text))
}

pub fn tasks_are_sent_once_each_test() {
  let call = event.ToolCall("c1", "bash", "{\"command\":\"ls\"}", True)
  let r =
    feed([
      event.MessageEvent(
        "created",
        event.Message("m1", "s1", event.Assistant, "On it.", [call], [], []),
      ),
      tool("c1"),
    ])
  let first = render.pending(r, "/w", render.empty_shown())
  let tasks =
    list.filter_map(first.chunks, fn(chunk) {
      case chunk {
        render.ChunkTask(task) -> Ok(task)
        _ -> Error(Nil)
      }
    })
  should.equal(1, list.length(tasks))
  // Unchanged tasks aren't sent again; the title change is.
  let again = render.pending(r, "/w", first.shown)
  should.equal([], texts(again.chunks))
}

pub fn no_plan_title_without_tools_test() {
  // A run that only talks gets no plan block, so no title either.
  let r = feed([assistant("m1", "Just an answer.")])
  let next = render.pending(r, "/w", render.empty_shown())
  should.equal(
    [],
    list.filter(next.chunks, fn(chunk) {
      case chunk {
        render.ChunkTitle(_) -> True
        _ -> False
      }
    }),
  )
  // A tool call brings the plan, and its title.
  let call = event.ToolCall("c1", "bash", "{\"command\":\"ls\"}", False)
  let with_tool =
    feed([
      event.MessageEvent(
        "created",
        event.Message("m1", "s1", event.Assistant, "On it.", [call], [], []),
      ),
    ])
  let after = render.pending(with_tool, "/w", next.shown)
  should.equal(
    ["Working"],
    list.filter_map(after.chunks, fn(chunk) {
      case chunk {
        render.ChunkTitle(title) -> Ok(title)
        _ -> Error(Nil)
      }
    }),
  )
}

pub fn a_rewritten_message_is_not_doubled_test() {
  // Crush may revise earlier words rather than append; what was shown is
  // what the thread has, so nothing is posted twice.
  should.equal("", render.remainder("A different answer.", "The first answer."))
}
