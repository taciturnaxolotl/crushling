import crushling/agent/post_mortem
import crushling/thread/say
import gleam/option.{None, Some}

// Lines as crush's own log has them.
const log =
  "{\"time\":\"t\",\"level\":\"INFO\",\"msg\":\"Tunnel control socket lost, redialing\"}
{\"time\":\"t\",\"level\":\"ERROR\",\"msg\":\"Session failed\",\"error\":\"context canceled\"}
not json at all
{\"time\":\"t\",\"level\":\"WARN\",\"msg\":\"Failed to dial tunnel control socket\",\"status\":0}
{\"time\":\"t\",\"level\":\"INFO\",\"msg\":\"still here\"}
"

pub fn last_words_prefer_the_last_error_test() {
  let assert "Session failed: context canceled" = post_mortem.last_words(log)
}

pub fn last_words_fall_back_to_a_warning_test() {
  let assert "Failed to dial tunnel control socket" =
    post_mortem.last_words(
      "{\"level\":\"WARN\",\"msg\":\"Failed to dial tunnel control socket\"}\n{\"level\":\"INFO\",\"msg\":\"x\"}",
    )
  let assert "" = post_mortem.last_words("{\"level\":\"INFO\",\"msg\":\"x\"}")
  let assert "" = post_mortem.last_words("")
}

const tail =
  ", so this run is over. Send a message to start it again; the workspace is kept._"

pub fn lost_says_why_test() {
  let assert True =
    say.lost(post_mortem.OutOfMemory("4g"))
    == "_The agent's sandbox ran out of memory (its limit is 4 GB) and was killed"
    <> tail
  let assert True =
    say.lost(post_mortem.Exited(Some(137), ""))
    == "_The agent's sandbox was killed (exit code 137)" <> tail
  let assert True =
    say.lost(post_mortem.Exited(Some(2), "panic: boom"))
    == "_The agent crashed (exit code 2)" <> tail <> "\n> `panic: boom`"
  let assert True =
    say.lost(post_mortem.Exited(None, "")) == "_The agent crashed" <> tail
  let assert True =
    say.lost(post_mortem.StillRunning("Failed to dial"))
    == "_The connection to the agent's sandbox dropped and couldn't be restored"
    <> tail
    <> "\n> `Failed to dial`"
  let assert True =
    say.lost(post_mortem.Vanished) == "_The agent's sandbox was deleted" <> tail
  let assert True =
    say.lost(post_mortem.Unknown("docker is unreachable: nope"))
    == "_The agent stopped for an unknown reason"
    <> tail
    <> "\n> `docker is unreachable: nope`"
}
