//// Links from code channels to the threads they belong to. A message in a code
//// channel uses its link to find its thread. Links are saved on disk, so they
//// last through a restart.

import crushling/meta.{type Link, Link}
import crushling/sandbox
import crushling/slack
import crushling/sys
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

pub opaque type Links {
  Links(meta_path: fn(String) -> String, by_channel: Dict(String, Link))
}

/// An empty set of links. Each link is saved at `meta_path` of its channel's
/// key.
pub fn new(meta_path: fn(String) -> String) -> Links {
  Links(meta_path:, by_channel: dict.new())
}

/// A code channel's link is saved under the key its thread would have, with
/// "code" as the ts.
fn path(links: Links, channel: String) -> String {
  links.meta_path(sandbox.key(channel, "code"))
}

/// Find the link for `channel`, if it is a code channel. This looks in memory
/// first and then on disk.
pub fn find(links: Links, channel: String) -> #(Links, Option(Link)) {
  case dict.get(links.by_channel, channel) {
    Ok(link) -> #(links, Some(link))
    Error(Nil) ->
      case meta.read_link(path(links, channel)) {
        Ok(link) -> #(add_known(links, channel, link), Some(link))
        Error(Nil) -> #(links, None)
      }
  }
}

/// Link a new code channel to its thread.
pub fn add(links: Links, channel: String, link: Link) -> Links {
  case meta.write_link(path(links, channel), link) {
    Ok(Nil) -> Nil
    Error(reason) ->
      sys.warn("crushling: saving " <> channel <> " failed: " <> reason)
  }
  add_known(links, channel, link)
}

fn add_known(links: Links, channel: String, link: Link) -> Links {
  Links(..links, by_channel: dict.insert(links.by_channel, channel, link))
}

/// The channel and ts of the thread that a code channel belongs to.
pub fn origin(link: Link) -> #(String, String) {
  #(link.origin_channel, link.origin_ts)
}

/// Slack starts a new code channel with a copy of the request that opened it. A
/// message older than the channel is that copy.
pub fn is_seed(code: Option(Link), ts: String) -> Bool {
  case code {
    Some(Link(opened_ts:, ..)) if opened_ts != "" ->
      slack.ts_value(ts) <=. slack.ts_value(opened_ts) +. 1.0
    _ -> False
  }
}
