//// Links from code channels to the threads they belong to. A message in a code
//// channel uses its link to find its thread. Links are kept in the store, per
//// workspace, so they last through a restart.

import crushling/meta.{type Link, Link}
import crushling/slack/text
import crushling/store.{type Store}
import crushling/store/threads
import crushling/sys
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

pub opaque type Links {
  Links(store: Store, team: String, by_channel: Dict(String, Link))
}

/// An empty set of links for workspace `team`, backed by `store`.
pub fn new(store: Store, team: String) -> Links {
  Links(store:, team:, by_channel: dict.new())
}

/// Find the link for `channel`, if it is a code channel. This looks in memory
/// first and then in the store.
pub fn find(links: Links, channel: String) -> #(Links, Option(Link)) {
  case dict.get(links.by_channel, channel) {
    Ok(link) -> #(links, Some(link))
    Error(Nil) ->
      case threads.link(links.store, links.team, channel) {
        Ok(Some(link)) -> #(add_known(links, channel, link), Some(link))
        Ok(None) -> #(links, None)
        Error(reason) -> {
          sys.warn("crushling: reading link " <> channel <> ": " <> reason)
          #(links, None)
        }
      }
  }
}

/// Link a new code channel to its thread.
pub fn add(links: Links, channel: String, link: Link) -> Links {
  case threads.put_link(links.store, links.team, channel, link) {
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
      text.ts_value(ts) <=. text.ts_value(opened_ts) +. 1.0
    _ -> False
  }
}
