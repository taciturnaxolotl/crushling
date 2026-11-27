import crushling/people
import crushling/registry/gate
import gleam/erlang/process
import slackline

fn client() -> slackline.Client {
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  client
}

pub fn listed_users_pass_and_others_dont_test() {
  let g = gate.new(people.only(["U1"]), client(), "T1", fn(_, _) { Nil })
  let assert gate.Allowed = gate.check(g, "U1", "hi")
  let assert gate.Denied = gate.check(g, "U2", "hi")
}

pub fn messages_wait_for_a_lookup_and_come_back_in_order_test() {
  let answers = process.new_subject()
  let g =
    gate.new(people.parse("*"), client(), "T1", fn(answer, ms) {
      process.send(answers, #(answer, ms))
    })
  let assert gate.Waiting(g) = gate.check(g, "U9", "first")
  let assert gate.Waiting(g) = gate.check(g, "U9", "second")
  let answer = lookup_answer(answers)
  let #(g, waiting) = gate.answered(g, answer)
  let assert ["first", "second"] = waiting
  // The lookup failed: refused for what waited, then asked again.
  let assert gate.Denied = gate.check(g, "U9", "third")
  let g = gate.forget_failed(g, answer)
  let assert gate.Waiting(_) = gate.check(g, "U9", "third")
}

/// The lookup's own answer, not its timeout's.
fn lookup_answer(answers) {
  let assert Ok(#(answer, ms)) = process.receive(answers, 5000)
  case ms {
    0 -> answer
    _ -> lookup_answer(answers)
  }
}
