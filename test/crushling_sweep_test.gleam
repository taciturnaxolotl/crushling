//// Tidying up after quiet threads: which threads are archived or cleared
//// out, the store's view of quiet, and a forget that removes only the
//// thread's own directory.

import crushling/meta
import crushling/registry/sweep
import crushling/store
import crushling/sys
import crushling/venue

const day = 86_400

const now = 100_000_000

fn thread(key: String, venue: venue.Venue) -> store.Thread {
  store.Thread(key:, team: "T1", channel: "C1", thread_ts: "1.0", meta: {
    meta.Meta(..meta.new(False), venue:)
  })
}

fn plan(threads: List(#(store.Thread, Int))) -> List(sweep.Action) {
  sweep.plan(threads, now, fn(key) { key == "busy" }, fn(key) { key != "gone" })
}

pub fn a_quiet_code_channel_is_archived_test() {
  let code = venue.CodeChannel(channel: "CCODE", repo: "./hyper")
  let assert [sweep.Archive("k", "CCODE", "./hyper")] =
    plan([#(thread("k", code), now - 8 * day)])
  // Not after only six days, and not a plain thread.
  let assert [] = plan([#(thread("k", code), now - 6 * day)])
  let assert [] = plan([#(thread("k", venue.Thread), now - 8 * day)])
  // Never with an agent up.
  let assert [] = plan([#(thread("busy", code), now - 8 * day)])
}

pub fn a_month_quiet_thread_is_cleared_out_test() {
  let assert [sweep.Forget("k")] =
    plan([#(thread("k", venue.Archived("./hyper")), now - 31 * day)])
  let assert [sweep.Forget("k")] =
    plan([#(thread("k", venue.Thread), now - 31 * day)])
  // A code channel quiet that long is archived first.
  let assert [sweep.Archive(..), sweep.Forget("k")] =
    plan([
      #(thread("k", venue.CodeChannel("C", "./r")), now - 31 * day),
    ])
  // Not when its workspace is already gone, or it's busy.
  let assert [] = plan([#(thread("gone", venue.Thread), now - 31 * day)])
  let assert [] = plan([#(thread("busy", venue.Thread), now - 31 * day)])
  let assert [] = plan([#(thread("k", venue.Thread), now - 29 * day)])
}

pub fn quiet_threads_test() {
  let assert Ok(key) =
    store.parse_key("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
  let assert Ok(s) = store.start(":memory:", key)
  let assert Ok(Nil) = store.put_thread(s, thread("a", venue.Thread))
  let assert Ok(Nil) =
    store.put_thread(s, store.Thread(..thread("b", venue.Thread), team: "T2"))
  let later = sys.system_ms() / 1000 + 10
  let assert Ok([#(store.Thread(key: "a", ..), at)]) =
    store.quiet_threads(s, "T1", later)
  let assert True = at <= later
  let assert Ok([]) = store.quiet_threads(s, "T1", later - 3600)
  store.close(s)
}
