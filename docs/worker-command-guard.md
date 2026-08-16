# Worker command guard

A crewmate or scout runs unattended, in a disposable worktree, with its harness's approval prompts disabled.
Nothing stands between the model and the host, so a command that reaches past the task - host privileges, a remote host, the captain's global git config, a rewritten history, a push onto `master`/`main`, or a live `.env` - executes with no one in front of it.
This guard refuses that class of tool call before it runs, identically on every worker harness firstmate launches.

It is a seatbelt against an agent that wanders, not a sandbox against an adversary: a worker that genuinely needs one of these actions asks firstmate instead of routing around the refusal.

## One perimeter, two application points

[`bin/fm-worker-command-policy.mjs`](../bin/fm-worker-command-policy.mjs) is the single owner of the perimeter and of every deny/allow decision.
[`bin/fm-worker-pretool-check.sh`](../bin/fm-worker-pretool-check.sh) is the only way to reach it: a stable transport that acquires the harness's tool-call payload, calls the policy, and renders each harness's own deny response.

Both application points are written per task by [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), and neither restates a rule:

| Harness | Application point | Mechanism |
| --- | --- | --- |
| Pi, pi-signed | the per-task extension at `state/<id>.pi-ext.ts`, already loaded with `-e` | `pi.on("tool_call", ...)` returning `{block: true, reason}` |
| Claude | the per-task `.claude/settings.local.json` in the task worktree | a `PreToolUse` hook running the transport with `--claude` |

That is what keeps the two from drifting: extending the perimeter means editing the rule tables in the policy owner and nothing else, and removing the policy owner changes both verdicts at once.
`tests/fm-worker-command-guard.test.sh` pins that property as behavior rather than as a comment - it drives both live application points and asserts they follow the same owner.

The transport also speaks the Codex, Grok, and Cursor payload and response shapes, so a future worker harness needs a wiring line in `fm-spawn.sh`, not a second copy of the rules.

## The perimeter

Stated here for readers; the policy owner's rule tables are authoritative.

- `sudo` - privilege escalation.
- `ssh`, `scp`, `rsync` - reaching or moving data to another host.
- `chmod` - host file modes.
- `git config --global` - the captain's host-wide git configuration.
- `git rebase` - history the delivery path depends on.
- `git push` whose destination ref resolves to `master` or `main`. Pushing the task branch, including `git push origin HEAD`, is deliberately untouched: work lands through a PR, so the ordinary push must keep working.
- Reading or copying a file whose basename is exactly `.env`, through a shell command or through a harness file tool.

`.env` is matched on the exact basename rather than on "contains env", because firstmate itself tracks ordinary files such as `config/x-mode.env` that a worker legitimately reads.

## Deliberate boundaries

**The submitted command, not the scripts it runs.**
The policy classifies the command a worker submits.
It does not open and re-classify the body of a script that command would run: doing so blocks this repo's own test suite, which legitimately changes fixture modes, and every project's build scripts.

**Fail closed, unlike its siblings.**
[`bin/fm-arm-pretool-check.sh`](../bin/fm-arm-pretool-check.sh) and [`bin/fm-cd-pretool-check.sh`](../bin/fm-cd-pretool-check.sh) guard a supervised primary against agent mistakes and fail open, because a false block there costs more than a missed one.
This guard is a perimeter around an unattended worker, so the trade runs the other way:

- An unusable classifier - missing `node`, missing `jq`, an absent policy owner, an unreadable payload, an invalid policy response - denies with a `worker-guard-unavailable` or `worker-guard-unreadable` reason.
- Unparseable shell syntax that mentions a perimeter command denies as `unclassifiable-perimeter-command`. Unparseable syntax that mentions none of them still allows, so the guard never blocks work it has no opinion about.
- `bin/fm-spawn.sh` refuses to launch a Pi or Claude worker whose guard runtime is missing, so an unguarded worker is never started in the first place.
- A Pi extension whose transport has disappeared since launch blocks every tool call carrying a command or a path, naming itself in the reason.

**Workers, not secondmates.**
A secondmate is a firstmate instance with its own supervised posture, not an unattended worker, so `fm-spawn.sh` does not wire the guard for a `--secondmate` spawn.

**Not the primary's own session.**
The guard is wired per task. Firstmate's own primary session is the captain's supervised session and keeps whatever perimeter the captain configures for it.

## Verification

`tests/fm-worker-command-guard.test.sh` is the regression owner:

- the full deny/allow matrix across the Claude, Codex, Grok, Pi, and OpenCode entry forms, including the `git push origin HEAD` case the delivery path needs;
- the file-tool path perimeter in both payload shapes;
- every fail-closed path;
- a real `fm-spawn.sh` run driving the generated Pi extension in a plain Node host, and the recorded Claude hook command fed a real payload;
- the spawn refusal when the guard runtime is missing.

Run it with `bin/fm-test-run.sh tests/fm-worker-command-guard.test.sh`.
No harness is spawned; the Pi blocking mechanism itself (`tool_call` returning `{block: true}`) is the one recorded in [`docs/cd-guard.md`](cd-guard.md), verified live against Pi.

## Maintaining this file

Keep this file to the guard's contract, its boundaries, and where its verification lives.
Exact rules, flags, and reason codes belong in the policy owner and the transport's own header, not restated here.
