# Getting Started

This runbook takes you from a fresh source checkout to a finished coding
session you can find again, watch, and stop cleanly. It uses the `loopex`
command first on its own and then through a daemon, so you see both ways the
command reaches a session. Each step names the page that owns the topic when you
need more than the step.

What you end up with:

- a `loopex` command built from source, with its private provider companion;
- one state root holding durable sessions, receipts and artifacts;
- a first session run against a repository of yours, and its record;
- a daemon on the same state root that keeps sessions alive between commands,
  with one terminal driving a session and another watching it.

Constraints to know before you start:

- Loopex is built from source. There is no package, installer or service unit.
- It runs on Darwin (macOS) and Linux.
- The shipped command calls the Anthropic model `anthropic:claude-haiku-4-5`,
  so you need an Anthropic API key. Choosing another model is a host decision,
  not a command flag.
- Tools run as your own operating-system user. The host policy you choose is
  the only thing between the model and your files and commands; it is not a
  sandbox. Read [what local execution can reach](tools-and-policy.md#operator-tools-reach)
  before pointing a session at a repository that matters.
- Session records are written unencrypted under the state root, including the
  contents of files a session reads. See
  [what is kept on disk](tools-and-policy.md#operator-tools-disclosure).

Back to the [operator documentation index](README.md).

<a id="operator-start-prerequisites"></a>
## 1. Check the Prerequisites

You need:

- Git and a POSIX shell with `awk`, `grep`, `sed` and `tr`.
- Elixir and Erlang/OTP as one of the two supported pairs recorded in
  `.tool-versions`: Elixir 1.18.5 with OTP 27.3.4, or Elixir 1.20.3 with
  OTP 29.0.5. [DEVELOPMENT.md](../../DEVELOPMENT.md) shows how to install either
  pair with `mise`.
- An executable `/bin/bash`. The local executor uses it for its own process
  supervision; see the
  [local supervision prerequisite](tools-and-policy.md#operator-local-supervision-shell).
- An executable `/bin/ps`. Loopex runs it to confirm that a stopped tool's
  processes are gone and that a lock's owner is still alive.
- Network access for fetching dependencies and for the model provider.

Confirm the toolchain:

```bash
elixir --version
```

<a id="operator-start-build"></a>
## 2. Build the Command

Clone the repository and build from its root. The build refuses a checkout with
uncommitted or untracked changes, because it records the exact source revision
it was made from.

```bash
git clone https://github.com/lexlapax/loopex.git ~/src/loopex
cd ~/src/loopex
mix local.hex --force
mix local.rebar --force
mix deps.get
MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
```

The build writes three things you use later:

| Path under the checkout | What it is |
| --- | --- |
| `apps/loopex_cli/bin/loopex` | The launcher. This is the command you run. |
| `apps/loopex_cli/loopex` | The built escript the launcher starts. Do not run it directly. |
| `_build/prod/loopex_provider` and `_build/prod/loopex_provider.launch` | The private provider companion and its non-secret launch file. The command records their absolute paths; keep them where they are. |

Always run the launcher. It is what turns Ctrl-C into a clean stop; the escript
run on its own cannot see that interrupt. The reason is explained under
[stopping a task](coding-sessions.md#operator-sessions-stopping).

Put the launcher on your `PATH` for the rest of this guide:

```bash
export PATH="$HOME/src/loopex/apps/loopex_cli/bin:$PATH"
loopex
```

With no arguments the command prints its usage and exits with status `1`. If
the launcher reports `no built command at …`, the build did not finish; run the
`escript.build` step again from a clean checkout.

To prove the whole loop on this machine without a credential, you can also run
the credential-free demonstration from
[runtime operations](runtime.md#operator-runtime-first-run).

<a id="operator-start-credential"></a>
## 3. Name a State Root and the Credential

The state root is the directory Loopex writes to: the session journal, tool
receipts and retained artifacts. It is not your repository. Every command takes
it from `--state-root`, or from `LOOPEX_HOME` when the flag is absent; there is
no built-in default, and a command that finds neither refuses with
`:loopex_home_required`.

```bash
export LOOPEX_HOME="$HOME/.loopex"
```

The command reads the provider credential from `LOOPEX_PROVIDER_API_KEY` once,
when it composes the runtime, and removes it from its own environment. Read it without echoing
it and without writing it to your shell history:

```bash
read -rs LOOPEX_PROVIDER_API_KEY
export LOOPEX_PROVIDER_API_KEY
```

Never put the key in a command argument, a file in the repository, or the state
root. A missing, empty or oversized value (above 65,536 bytes) refuses with
`:provider_credential_required`. The
[credential boundary](tools-and-policy.md#operator-tools-credential) says where
the key goes and who can still read it.

<a id="operator-start-first-run"></a>
## 4. Run a First Session

Move into the repository you want the session to work on. That directory becomes
the workspace the tools act on.

```bash
cd ~/code/my-project
loopex run --policy shell-allowlist "list the files in this repository and summarise what it does"
```

`--policy` is required; there is no default. `shell-allowlist` lets the session
read and change files and run only `cat`, `ls`, `pwd`, `echo`, `git`, `grep`,
`head`, `tail` and `wc`, which is a reasonable first scope. It is scope, not
containment; see [host policy](tools-and-policy.md#operator-tools-policy) and
the permissive [`allow-all`](tools-and-policy.md#operator-tools-allow-all)
stance before choosing another.

What you see, in order:

1. If the repository has an `AGENTS.md` at its root, its path, size and digest,
   then `loopex: admit these project resources for this run? [y/N]`. Only `y` or
   `yes` admits it; anything else runs without it. See
   [project resources are your decision](coding-sessions.md#operator-sessions-project-trust).
   Selected skills are offered the same way.
2. Your prompt echoed back as `> …`, from the journal rather than from what you
   typed.
3. The answer streaming to standard output as the model writes it.
4. At the first tool call, a notice on standard error naming the active policy;
   then each tool call on standard error, such as `  · loopex.read (call_…)` and
   then `  · loopex.read: ok`, or `denied` when the policy refuses it.
5. One ending line, such as `loopex: done`.

Standard output carries your echoed prompt and the answer; tool lines and the
ending go to standard error, so `loopex run … > answer.txt` keeps the
conversation and leaves the commentary on your terminal. The endings and what each one means are listed in
[stopping a task](coding-sessions.md#operator-sessions-stopping) and
[one run, from prompt to answer](how-a-run-works.md#concept-run-flow).

<a id="operator-start-observe"></a>
## 5. Find and Inspect the Session

Sessions outlive the process that started them. List the ones in the state root:

```bash
loopex sessions
```

Each line is a session identifier, the same string `resume` and `cancel` take.
`loopex resume <session> --policy shell-allowlist` replays that session's durable
record from the beginning and continues any work that was still in flight;
[finding and continuing work](coding-sessions.md#operator-sessions-finding) has
the details.

When a tool produced more output than it may show the model, the tool line is
followed by a ready-made retrieval command:

```text
    output beyond the tool's bound was retained: 240113 bytes, read it with `loopex artifact -- '3f9c1a…d80b'`
```

Run that command to get the full bytes back; see
[artifacts](tools-and-policy.md#operator-tools-artifacts).

To watch a session from a second terminal while it runs, use the daemon in
step 7. To trace or measure the runtime itself, see
[observability](observability.md#concept).

<a id="operator-start-stop"></a>
## 6. Stop a Session Cleanly

Press Ctrl-C while a run is going. The launcher turns it into the same public
abort any host would submit, and the run reports what actually happened before
the command exits:

- `loopex: cancelled` means every operation reached a validated ending and
  every tool process group was confirmed gone.
- `loopex: stopped, but the effect's outcome is unknown` followed by
  `loopex: reconcile with …` means Loopex could not prove what a tool did. The
  work may have taken effect. It is never retried blindly. Inspect the workspace
  yourself.

If the process was killed instead, for example because the terminal closed, the
session is still in the state root. Reconcile it from any terminal once no other
`loopex` process holds the state root:

```bash
loopex cancel <session>
```

`cancel` needs the credential in the environment, because it opens the session
to settle it, but no `--policy`: it runs no tool.
[`loopex cancel` is narrow](coding-sessions.md#operator-sessions-cancel) lists
its refusals.

<a id="operator-start-daemon"></a>
## 7. Keep Sessions Alive With the Daemon

`loopex daemon` holds a state root for as long as it runs, so sessions keep
running while no command is attached, and several terminals can reach the same
session. The daemon, not the client, owns the workspace, policy and credential.

A state root that offline commands have already written, as steps 4 to 6 did,
must be imported once, while nothing else holds it. Otherwise the daemon refuses
to start with status `85` (`session_index_upgrade_required`).

```bash
loopex daemon prepare-index
```

Start the daemon in its own terminal. It needs the credential and the provider
launch file the build wrote:

```bash
read -rs LOOPEX_PROVIDER_API_KEY
export LOOPEX_PROVIDER_API_KEY
export LOOPEX_HOME="$HOME/.loopex"
loopex daemon --workspace ~/code/my-project \
              --provider-launch ~/src/loopex/_build/prod/loopex_provider.launch \
              --policy shell-allowlist
```

If the workspace has an `AGENTS.md` at its root, the daemon asks the same
admission question at start-up, once, for every session it will run. When it is
ready it prints one JSON line naming its socket, normally
`$LOOPEX_HOME/daemon/daemon.sock`, and keeps running in the foreground.

In a second terminal, drive a session through it. The live forms take only the
socket; the daemon refuses host flags such as `--policy` from a client.

```bash
SOCK="$HOME/.loopex/daemon/daemon.sock"
loopex run --daemon "$SOCK" "add a short CONTRIBUTING note to the README"
```

The command prints `loopex: session <id>` on standard error and then streams the
run like the offline command. In a third terminal, list and watch:

```bash
loopex sessions --daemon "$SOCK"
loopex sessions --daemon "$SOCK" --status
loopex attach <session> --daemon "$SOCK"
```

The observer follows the session's durable events and sends nothing. Ctrl-C on
a client only detaches it (`loopex: detached; the session continues in the
daemon`); the run carries on in the daemon. The
[daemon runbook](daemon.md#concept) covers taking over control, reconnection
and limits.

To stop the daemon, press Ctrl-C in its terminal or send it `SIGTERM`. It drains
every session through the runtime, tells connected clients it is stopping,
releases the state root and exits `0`. Give it time to finish; the
[signals section](daemon.md#operator-daemon-signals) explains the stop and its
bound. After it exits, the offline commands work against the root again.

<a id="operator-start-troubleshooting"></a>
## When Something Is Refused

| What you see | What it means | What to do |
| --- | --- | --- |
| `loopex: no built command at …` (exit 127) | The launcher found no escript beside it | Rebuild from a clean checkout, or set `LOOPEX_ESCRIPT` to the escript's path |
| `loopex: :loopex_home_required` | Neither `--state-root` nor `LOOPEX_HOME` names a state root | Export `LOOPEX_HOME` or pass `--state-root` |
| `loopex: :provider_credential_required` | `LOOPEX_PROVIDER_API_KEY` is missing, empty or too large | Export the key in this shell before the command |
| `loopex: --policy is required; there is no default host authority` | `run` or `resume` was given no policy | Name `shell-allowlist` or `allow-all` |
| `loopex: another loopex process (pid N) is using this state root; …` | Another command or a daemon holds the state root | Use the daemon's live forms, stop the other process, or pass another `--state-root` |
| `loopex daemon` exits 85 (`session_index_upgrade_required`) | The root has offline sessions and no daemon index | Run `loopex daemon prepare-index` with nothing else holding the root |
| `loopex daemon` exits 76 (`placement_active`) | Another daemon or command holds this root | Stop it, or use another state root |
| `loopex: failed model_call_failed (retryable …)` | The provider call failed; its details are withheld on purpose | Check the key, the network and the provider's status, then run again |

Every `loopex daemon` exit status is listed in the
[daemon reference](daemon.md#technical-depth).

<a id="operator-start-next"></a>
## Where to Go Next

- [How a run works](how-a-run-works.md#concept) — the picture of one run, what
  is durable at each step, and what a crash leaves behind.
- [Coding sessions](coding-sessions.md#concept) — steering, follow-ups,
  resuming, project skills, and every flag of the offline command.
- [Tools and policy](tools-and-policy.md#concept) — the four tools, host
  authority, artifacts, and the limits of local execution.
- [The daemon](daemon.md#concept) — several clients, takeover, reconnection,
  limits and exit statuses.
- [App server operations](app-server.md#concept) — driving a session from
  another language over standard input and output.
- [Runtime operations](runtime.md#concept) — embedding the runtime in your own
  host program and recovering it after a crash.
- [Observability](observability.md#concept) — tracing and telemetry for a
  runtime you host.
