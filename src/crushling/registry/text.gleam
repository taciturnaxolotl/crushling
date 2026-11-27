//// What the registry says in Slack, outside the `!` command replies.

import gleam/int

pub const broken_thread =
  "_couldn't move this thread's old workspace; an admin should check the logs._"

pub fn could_not_start(reason: String) -> String {
  "_couldn't start an agent for this thread: " <> reason <> "_"
}

pub const could_not_stop =
  "_couldn't stop this thread's agent, so its sandbox may still be running. Send a follow-up to start it again._"

pub const stopped_unexpectedly =
  "_the agent for this thread stopped unexpectedly. Send a follow-up to start it again._"

pub const restart_note =
  "crushling restarted, so this run was stopped. Send a follow-up to carry on."

pub const cant_use = "_You can't use crushling here._"

pub const cant_stop = "_You can't use crushling here, so you can't stop it._"

pub const cant_change_model = "_you can't change this thread's model._"

pub const not_working_there = "_I'm not working in that thread anymore._"

pub const wrapping_up =
  "_wrapping up; this channel will be archived. Mention me in the original thread to pick the work up again._"

pub const still_working =
  "_still working; `!stop` first, or wait for this turn to finish._"

pub const no_code_channel = "_there's no code channel to wrap up._"

pub const tailnet_ended_with_channel =
  "_The tailnet access ended with the channel._"

pub const card_expired = "_This card has expired; `/pr` posts a new one._"

pub const github_not_set_up = "_GitHub isn't set up for this crushling._"

pub const connect_first =
  "_Connect your GitHub account first, from crushling's Home tab or with `!github`, then press again: the PR opens as you._"

pub const no_connection = "_Couldn't get your GitHub connection; try again._"

pub fn could_not_open_pr(why: String) -> String {
  "_Couldn't open the PR: " <> why <> "._"
}

pub fn pr_dismissed(user: String) -> String {
  "Dismissed by <@" <> user <> ">"
}

pub fn pr_opened(
  user: String,
  url: String,
  number: Int,
  draft: Bool,
) -> String {
  "<@"
  <> user
  <> "> opened <"
  <> url
  <> "|#"
  <> int.to_string(number)
  <> ">"
  <> case draft {
    True -> " as a draft"
    False -> ""
  }
}
