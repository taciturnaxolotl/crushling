//// What the registry says in Slack, outside the `!` command replies.

pub const broken_thread =
  "_Failed to migrate this thread's workspace. An admin should check the bridge logs._"

pub fn could_not_start(reason: String) -> String {
  "_Failed to start an agent for this thread: " <> reason <> "._"
}

pub const could_not_stop =
  "_Failed to stop this thread's agent, so its sandbox may still be running. Send a follow-up to start it again._"

pub const stopped_unexpectedly =
  "_crushling's handler for this thread crashed. Send a follow-up to start it again._"

pub const restart_note =
  "crushling restarted and stopped this run. Send a follow-up to carry on."

pub const cant_use = "_You can't use crushling here._"

pub const cant_stop = "_You can't use crushling here, so you can't stop it._"

pub const cant_change_model = "_You can't change this thread's model._"

pub const not_working_there = "_crushling is no longer running in that thread._"

pub const wrapping_up =
  "_Wrapping up. This channel will be archived; mention crushling in the original thread to pick the work back up._"

pub const still_working =
  "_The agent is still working. Use `!stop` first, or wait for this turn to finish._"

pub const no_code_channel = "_There's no code channel to wrap up._"

pub const card_expired = "_This card has expired; `/pr` posts a new one._"

pub const github_not_set_up = "_GitHub isn't set up for this crushling._"

pub const connect_first =
  "_Connect your GitHub account first, from crushling's Home tab or with `!github`, then press again: the PR opens as you._"

pub const no_connection = "_Failed to load your GitHub connection. Try again._"

pub fn could_not_open_pr(why: String) -> String {
  "_Failed to open the PR: " <> why <> "._"
}
