//// Posts every card and inline message crushling sends, built by the same
//// functions the bridge uses, into one channel, and writes each one's
//// Block Kit JSON to a directory. For tweaking the look:
////
////   SHOWCASE_CHANNEL=C0B1WDCJWRH SHOWCASE_OUT=~/Downloads/crushling-blocks \
////     gleam run -m showcase

import crushling/agent/post_mortem
import crushling/commands
import crushling/crush/catalog
import crushling/git
import crushling/github
import crushling/github/nudge
import crushling/github/repo
import crushling/home
import crushling/meta
import crushling/pr
import crushling/registry/sweep
import crushling/registry/tailnet/card as tailnet
import crushling/registry/text
import crushling/render
import crushling/slack/blocks
import crushling/slack/model_card
import crushling/snapshot
import crushling/sys
import crushling/thread/say
import crushling/usage
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import slackline
import slackline/api/chat
import slackline/api/chat/post_message
import slackline/block
import slackline/httpc

type Sample {
  Sample(id: String, label: String, text: String, blocks: List(block.Block))
}

fn md(id: String, label: String, markdown: String) -> Sample {
  Sample(id, label, markdown, [block.markdown(markdown, [])])
}

fn bk(id: String, label: String, card: #(String, List(block.Block))) -> Sample {
  Sample(id, label, card.0, card.1)
}

pub fn main() -> Nil {
  let assert Ok(channel) = getenv("SHOWCASE_CHANNEL") as "SHOWCASE_CHANNEL"
  let assert Ok(out) = getenv("SHOWCASE_OUT") as "SHOWCASE_OUT"
  let assert Ok(token) = getenv("SLACK_BOT_TOKEN") as "SLACK_BOT_TOKEN"
  let client = slackline.new(token)
  let assert Ok(_) = sys.mkdir_p(out)
  let samples = samples(channel)
  list.each(samples, fn(sample) {
    let json =
      json.object([
        #("text", json.string(sample.text)),
        #("blocks", json.array(sample.blocks, block.block_to_json)),
      ])
      |> json.to_string
    let assert Ok(_) =
      sys.write_private(out <> "/" <> sample.id <> ".json", json)
    let label = blocks.context("*" <> sample.id <> "* · " <> sample.label)
    let posted =
      chat.post_message(channel:, text: sample.text)
      |> post_message.blocks([label, block.divider(with: []), ..sample.blocks])
      |> post_message.unfurl_links(False)
      |> httpc.send(client)
    case posted {
      Ok(_) -> io.println("posted " <> sample.id)
      Error(error) -> {
        io.println("FAILED " <> sample.id <> ": " <> string.inspect(error))
        // Plan blocks only render in agent conversations; show the fallback.
        let _ =
          chat.post_message(
            channel:,
            text: sample.id
              <> " · "
              <> sample.label
              <> " (Slack refused the blocks here; JSON is in the file)",
          )
          |> httpc.send(client)
        Nil
      }
    }
    process_sleep(1100)
  })
  io.println(
    "wrote " <> int.to_string(list.length(samples)) <> " files to " <> out,
  )
}

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "timer", "sleep")
fn process_sleep(ms: Int) -> Nil

fn samples(channel: String) -> List(Sample) {
  let thread = #(channel, "1795800000.000100")
  let assert Ok(target) = repo.parse_path("charmbracelet", "crush")
  let proposal =
    pr.Proposal(
      repo: target,
      head: "crushling/fix-flaky-test",
      base: "main",
      title: "Fix the flaky checkout test",
      body: "",
      commits: 3,
      files: 4,
      added: 52,
      removed: 17,
    )
  let sonnet =
    catalog.Model(
      id: "claude-sonnet-5-5",
      name: "Claude Sonnet 5.5",
      kind: catalog.Levels(
        [#("low", "Low"), #("medium", "Medium"), #("high", "High")],
        "medium",
      ),
    )
  let opus =
    catalog.Model(
      id: "claude-opus-5-5",
      name: "Claude Opus 5.5",
      kind: catalog.Toggle,
    )
  let mini =
    catalog.Model(id: "gpt-mini", name: "GPT Mini", kind: catalog.NoReasoning)
  let current = catalog.Current(sonnet, meta.Effort("high"))
  let plan =
    render.Plan(title: "Fixing the checkout test", tasks: [
      render.Task("1", "Searching the code", render.Complete, "rg checkout", ""),
      render.Task(
        "2",
        "Running a command",
        render.Complete,
        "go test ./...",
        "FAIL checkout_test.go:42",
      ),
      render.Task(
        "3",
        "Editing a file",
        render.InProgress,
        "checkout_test.go",
        "",
      ),
    ])
  let spent = usage.Usage(1200, 340, 0.42, 12)
  let base_home = fn(gh) {
    home.Home(
      github: gh,
      threads: [
        home.Thread(
          channel,
          Some("https://slack.com/archives/" <> channel),
          "claude-sonnet-5-5",
          spent,
        ),
        home.Thread(channel, None, "claude-opus-5-5", usage.zero),
      ],
      thread_count: 3,
      today: spent,
      month: usage.Usage(90_000, 21_000, 18.75, 640),
      default_model: "claude-sonnet-5-5",
    )
  }
  let home_sample = fn(id, label, h) {
    Sample(id, label, "App Home", home.view(h).blocks)
  }
  let accounts =
    Some(github.Accounts(
      ["taciturnaxolotl", "charmbracelet"],
      "https://github.com/apps/crushling/installations/new",
    ))
  [
    // A: run lifecycle
    Sample("A4", "plan card", plan.title, [
      block.plan(plan.title, list.map(plan.tasks, plan_task), []),
    ]),
    md(
      "A4-fallback",
      "plan card as markdown (workspaces without plan blocks)",
      render.plan_markdown(plan),
    ),
    md(
      "A6-retry",
      "run error, retryable",
      "_The model provider rate-limited the request. The reply above may be partial. Wait a minute. Send a follow-up to try again._",
    ),
    md(
      "A6-quoted",
      "run error, quoted",
      "_The run failed with an unrecognized error. Send a follow-up to try again._\n> `boom: something odd happened`",
    ),
    md("A7", "empty run", "_The agent finished without replying._"),
    md("A8", "stalled", say.stalled),
    md(
      "A9-oom",
      "agent lost: out of memory",
      say.lost(post_mortem.OutOfMemory("4g")),
    ),
    md(
      "A9-crash",
      "agent lost: crashed with log line",
      say.lost(post_mortem.Exited(
        Some(2),
        "panic: runtime error: index out of range",
      )),
    ),
    md(
      "A9-conn",
      "agent lost: still running",
      say.lost(post_mortem.StillRunning("Failed to dial tunnel control socket")),
    ),
    md("A10", "bridge restarted", text.restart_note),
    md(
      "A11-start",
      "failed to start",
      text.could_not_start("docker: no space left on device (500)"),
    ),
    md("A11-stop", "failed to stop", text.could_not_stop),
    md("A11-crash", "thread handler crashed", text.stopped_unexpectedly),
    md("A11-migrate", "workspace migration failed", text.broken_thread),
    md("A12", "failed to send", say.not_sent("the agent is busy")),
    md("A13", "agent disconnected", say.not_connected),
    // B: code channels and subagents
    md(
      "B1",
      "moved to a code channel",
      say.moved("charmbracelet/crush", channel),
    ),
    md("B6", "!done", text.wrapping_up),
    md("B7-busy", "!done while working", text.still_working),
    md("B7-none", "!done with no channel", text.no_code_channel),
    md("B8", "weekly sweep", sweep.archive_note),
    bk(
      "B9",
      "subagent root card",
      say.subagent_card(
        "Explorer",
        "map the checkout flow",
        say.subagent_working,
      ),
    ),
    bk(
      "B9-done",
      "subagent root card, finished",
      say.subagent_card(
        "Explorer",
        "map the checkout flow",
        say.subagent_outcome(render.Complete, False, 7, 72_000),
      ),
    ),
    bk(
      "B11",
      "subagent report in parent",
      say.subagent_report(
        "Jan",
        "Gemini subscription sign-in research",
        False,
        say.subagent_outcome(render.Complete, False, 29, 240_000),
        sample_report,
        "https://slack.com/archives/" <> channel,
      ),
    ),
    bk(
      "B11-failed",
      "subagent stopped, in parent",
      say.subagent_report(
        "Explorer",
        "map the checkout flow",
        True,
        say.subagent_outcome(render.Failed, False, 3, 9000),
        "The connection to the model provider dropped.",
        "https://slack.com/archives/" <> channel,
      ),
    ),
    // C: ! commands
    md("C1", "!help", commands.help()),
    md(
      "C2-pause",
      "!pause",
      "_Paused. The agent only replies when mentioned._",
    ),
    md(
      "C2-resume",
      "!resume",
      "_Following along again. Every message here reaches the agent._",
    ),
    md("C3", "!stop, nothing running", "_Nothing is running in this thread._"),
    md(
      "C4",
      "!info",
      say.status(
        git.RepoInfo(
          "https://github.com/charmbracelet/crush",
          "crushling/fix-flaky-test",
          "main",
        ),
        [
          snapshot.Change("a.go", Ok(40), Ok(10)),
          snapshot.Change("b.go", Ok(12), Ok(7)),
        ],
        git.PushState(
          uncommitted: 1,
          upstream: "origin/crushling/fix-flaky-test",
          ahead: Ok(2),
        ),
      ),
    ),
    md("C5-norepo", "!info, no repo", say.no_repo),
    md("C5-asleep", "!info, asleep", say.asleep),
    md("C5-timeout", "!info, timed out", "_The agent timed out._"),
    md(
      "C6",
      "!pr failure",
      "_Failed to propose a PR: some commits aren't pushed yet, so push first._",
    ),
    md(
      "C7",
      "!model usage",
      "_`!model` shows the model; `!model <id> [level]` switches, and `!model default` goes back to the default._",
    ),
    md("C8", "not working here", "_crushling isn't running in this thread._"),
    md("C9-use", "can't use", text.cant_use),
    md("C9-stop", "can't stop", text.cant_stop),
    md("C9-model", "can't change model", text.cant_change_model),
    // D: model card
    Sample(
      "D1",
      "model card",
      say.model_card_text(current),
      model_card.card(current, current, [sonnet, opus, mini], thread, ""),
    ),
    Sample(
      "D1-note",
      "model card with a note",
      say.model_card_text(current),
      model_card.card(
        current,
        current,
        [sonnet, opus, mini],
        thread,
        say.refused_note("the model isn't offered"),
      ),
    ),
    Sample(
      "D2",
      "model card once confirmed",
      say.switched("U0B1XDG6AGZ", current),
      say.switched_card("U0B1XDG6AGZ", current),
    ),
    bk("D3-gone", "model gone", say.model_gone("claude-old")),
    bk("D3-reasoning", "reasoning dropped", say.reasoning_dropped("gpt-mini")),
    bk(
      "D3-refused",
      "model refused",
      say.model_refused("broken", "unknown provider"),
    ),
    md(
      "D4-show",
      "failed to load models",
      say.no_model_card("crush offered no models"),
    ),
    md("D4-switch", "failed to switch", say.not_switched("crush refused")),
    // E: PR card
    md(
      "E1",
      "agent-facing ack (tool result)",
      say.proposed("crushling/fix-flaky-test", "main"),
    ),
    bk("E2", "PR card", pr.card(proposal)),
    bk(
      "E3-opened",
      "PR card, opened",
      pr.opened(
        proposal,
        "U0B1XDG6AGZ",
        "https://github.com/charmbracelet/crush/pull/4451",
        4451,
        False,
      ),
    ),
    bk(
      "E3-draft",
      "PR card, opened as draft",
      pr.opened(
        proposal,
        "U0B1XDG6AGZ",
        "https://github.com/charmbracelet/crush/pull/4452",
        4452,
        True,
      ),
    ),
    md("E4-expired", "press: card expired", text.card_expired),
    md("E4-setup", "press: GitHub not set up", text.github_not_set_up),
    md("E4-connect", "press: connect first", text.connect_first),
    md("E4-conn", "press: connection failed", text.no_connection),
    md(
      "E4-open",
      "press: open failed",
      text.could_not_open_pr(
        "your GitHub account can't open pull requests there",
      ),
    ),
    // F: GitHub
    bk("F1", "connect ask", nudge.ask_connect(channel, thread.1, Some(target))),
    bk(
      "F1-private",
      "connect ask, no repo",
      nudge.ask_connect(channel, thread.1, None),
    ),
    bk(
      "F2",
      "install ask",
      nudge.ask_install(
        target,
        "https://github.com/apps/crushling/installations/new",
      ),
    ),
    md("F3", "after pressing install", nudge.installing("charmbracelet")),
    md(
      "F4",
      "device code",
      "Enter *`ABCD-1234`* at https://github.com/login/device to connect your GitHub account.",
    ),
    md("F5-ok", "connected", "_GitHub connected as @taciturnaxolotl._"),
    md(
      "F5-fail",
      "connect failed",
      "_Failed to connect GitHub: the code expired._",
    ),
    md(
      "F5-crash",
      "connect flow crashed",
      "_The GitHub connection flow crashed. Try again._",
    ),
    md("F6-done", "disconnected", "_GitHub disconnected._"),
    md(
      "F6-listed",
      "disconnected, still authorized",
      "_GitHub disconnected here. GitHub still lists crushling under your authorized apps until you revoke it there._",
    ),
    // G: tailnet
    Sample(
      "G1",
      "tailnet ask (agent)",
      tailnet.title,
      tailnet.ask_blocks(
        "",
        "I need to reach your NAS at nas.lan to read the build cache.",
        "T0620036Q4U-C0B1WDCJWRH-1795800000.000100",
        "tag:crushling",
        thread,
      ),
    ),
    Sample(
      "G1-person",
      "tailnet ask (person)",
      tailnet.title,
      tailnet.ask_blocks(
        "U0B1XDG6AGZ",
        "",
        "T0620036Q4U-C0B1WDCJWRH-1795800000.000100",
        "tag:crushling",
        thread,
      ),
    ),
    Sample(
      "G2",
      "tailnet on",
      tailnet.title,
      tailnet.on_blocks(
        sys.system_ms() + 3_600_000,
        "U0B1XDG6AGZ",
        "T0620036Q4U-C0B1WDCJWRH-1795800000.000100",
        "tag:crushling",
        thread,
      ),
    ),
    md(
      "G4",
      "tailnet failed",
      "_Failed to put the sandbox on the tailnet: tailscale up timed out._",
    ),
    // H: App Home (sent as messages here; the real thing is a Home view)
    home_sample("H1", "Home: not allowed", home.NotAllowed),
    home_sample(
      "H2-unavailable",
      "Home: GitHub not set up",
      base_home(home.Unavailable),
    ),
    home_sample(
      "H2-connect",
      "Home: not connected",
      base_home(home.NotConnected(None)),
    ),
    home_sample("H2-asking", "Home: asking for a code", base_home(home.Asking)),
    home_sample(
      "H2-code",
      "Home: enter the code",
      base_home(home.Connecting(
        "ABCD-1234",
        "https://github.com/login/device",
        14,
      )),
    ),
    home_sample(
      "H2-connected",
      "Home: connected",
      base_home(home.Connected("taciturnaxolotl", None, accounts)),
    ),
    home_sample(
      "H3-empty",
      "Home: no agents running",
      home.Home(
        ..base_home(home.Connected(
          "taciturnaxolotl",
          None,
          Some(github.Accounts(
            [],
            "https://github.com/apps/crushling/installations/new",
          )),
        )),
        threads: [],
        thread_count: 0,
      ),
    ),
  ]
}

fn plan_task(task: render.Task) -> block.PlanTask {
  let rich = fn(text) {
    case text {
      "" -> None
      text ->
        Some(block.RichText(
          elements: [block.rich_text_section([block.rich_text_run(text)])],
          block_id: None,
        ))
    }
  }
  block.PlanTask(
    task_id: task.id,
    title: task.title,
    status: case task.status {
      render.InProgress -> block.TaskInProgress
      render.Complete -> block.TaskComplete
      render.Failed -> block.TaskError
    },
    details: rich(task.details),
    output: rich(task.output),
    sources: None,
    icon: None,
    hide_title: None,
  )
}

const sample_report =
  "# Sign in with Google for Gemini subscriptions

## 1. gemini-cli \"Login with Google\" OAuth

Source: [oauth2.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts)

* **Client ID**: a public installed-app client, embedded in the CLI.
* **Scopes**: `cloud-platform`, `userinfo.email`, `userinfo.profile`.
* **Browser flow**: authorization code with PKCE over a loopback redirect.

## 2. After sign-in

The CLI calls `v1internal:loadCodeAssist` to find the user's project, and `onboardUser` for a fresh account, then sends every request to `cloudcode-pa.googleapis.com/v1internal:generateContent` with that project.

```
POST /v1internal:generateContent
{ \"model\": \"...\", \"project\": \"...\", \"request\": { ... } }
```
"
