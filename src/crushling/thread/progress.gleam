//// Showing a turn in Slack as it goes, and ending its reply.

import crushling/render
import crushling/sink.{type Sink}
import crushling/sys
import crushling/thread/subagents.{type Subagents}
import crushling/thread/turn.{type Turn}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Where and for whom a turn is shown: the sink for where the work is, the
/// workspace path the agent sees, its subagents, and who the reply is for.
pub type Place {
  Place(sink: Sink, root: String, subs: Subagents, reader: String)
}

/// A patch bigger than this is not attached; Slack won't preview it, and a
/// change that size is better read in the workspace.
const max_patch_bytes = 400_000

/// Show the turn as it goes: what the agent has said, and its steps.
pub fn show(place: Place, current: Turn) -> Turn {
  let text = turn.said(current)
  let steps =
    render.all_tasks(current.run, place.root) |> subagents.rows(place.subs, _)
  case turn.reply(current), text, steps {
    None, "", [] -> current
    shown, _, _ -> {
      let reply = case shown {
        Some(reply) -> reply
        None -> place.sink.reply(place.reader)
      }
      let title = case steps {
        [] -> ""
        _ -> render.progress_title(current.run)
      }
      reply.show(text, steps, title)
      turn.streaming(current, reply)
    }
  }
}

/// End an open reply with what it has, and `note`.
pub fn close(place: Place, current: Turn, note: String) -> Nil {
  case turn.reply(current) {
    Some(_) ->
      case turn.reply(show(place, current)) {
        Some(reply) -> {
          let _ = reply.finish(note)
          Nil
        }
        None -> Nil
      }
    None -> Nil
  }
}

/// End the turn's reply with its closing line, posted on its own when there
/// was no reply. Returns the last message's ts, or "".
pub fn end(place: Place, current: Turn) -> String {
  let closing = turn.closing(current)
  case turn.reply(show(place, current)), closing {
    Some(reply), _ -> reply.finish(closing) |> list.last |> result.unwrap("")
    None, "" -> ""
    None, closing -> place.sink.post(closing) |> result.unwrap("")
  }
}

/// Attach the run's patch, unless it is empty or too big to be any use.
pub fn attach(sink: Sink, run_id: String, patch: String) -> Nil {
  case patch, string.byte_size(patch) > max_patch_bytes {
    "", _ -> Nil
    _, True -> sys.warn("crushling: patch too large to attach: " <> run_id)
    _, False ->
      case sink.upload(string.slice(run_id, 0, 8) <> ".diff", patch) {
        Ok(Nil) -> Nil
        Error(reason) -> sys.warn("crushling: upload failed: " <> reason)
      }
  }
}
