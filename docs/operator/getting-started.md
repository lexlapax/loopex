# Getting Started

This runbook takes you from a fresh source checkout to a one-shot local answer,
then to a durable coding session you can find again, watch, and stop cleanly.
The `loopex ask` command needs no state root or provider companion at run time
when it uses local Ollama. The later `run`, `resume`, and daemon steps use the
durable profile. Each step names the page that owns the topic when you need
more than the step.

What you end up with:

- a `loopex` command built from source, with the companion available for durable calls;
- one local answer from `loopex ask` without a state root;
- one state root holding durable sessions, receipts and artifacts;
- a first session run against a repository of yours, and its record;
- a daemon on the same state root that keeps sessions alive between commands,
  with one terminal driving a session and another watching it.

Constraints to know before you start:

- Loopex is built from source. There is no package, installer or service unit.
- It runs on Darwin (macOS) and Linux.
- Without `--state-root`, `loopex ask` uses `LOOPEX_MODEL` when `--model` is
  omitted and that variable is set; otherwise it defaults to local
  `ollama:llama3.2`. Run Ollama and make that model available before the
  one-shot example. `--model` also selects a supported hosted model. OpenAI
  needs `OPENAI_API_KEY`, Anthropic needs
  `ANTHROPIC_API_KEY`, and OpenRouter needs `OPENROUTER_API_KEY`. The older
  durable `loopex run` path and `ask --state-root` default to
  `anthropic:claude-haiku-4-5` when no model is selected, and need
  `LOOPEX_PROVIDER_API_KEY`.
- Tools run as your own operating-system user. The host policy you choose is
  the only thing between the model and your files and commands; it is not a
  sandbox. Read [what local execution can reach](tools-and-policy.md#operator-tools-reach)
  before pointing a session at a repository that matters.
- Durable session records are written unencrypted under the state root,
  including the contents of files a session reads. The one-shot ephemeral
  profile does not retain session truth there, but tools still change real
  files. See
  [what is kept on disk](tools-and-policy.md#operator-tools-disclosure).

Back to the [operator documentation index](README.md).

<a id="operator-start-prerequisites"></a>
## 1. Check the Prerequisites

You need:

- Git and a POSIX shell with `awk`, `grep`, `sed` and `tr`. Run the interactive
  credential examples below in Bash; they use Bash's silent `read -s` option.
- Elixir and Erlang/OTP as one of the two supported pairs recorded in
  `.tool-versions`: Elixir 1.18.5 with OTP 27.3.4, or Elixir 1.20.3 with
  OTP 29.0.5. [DEVELOPMENT.md](../../DEVELOPMENT.md) shows how to install either
  pair with `mise`.
- An executable `/bin/bash`. The local executor uses it for its own process
  supervision; see the
  [local supervision prerequisite](tools-and-policy.md#operator-local-supervision-shell).
  Every `loopex` command also writes its terminal output through a fixed Bash
  writer that copies bytes with the standard `dd` command; see
  [command output](coding-sessions.md#operator-sessions-output).
- An executable `/bin/ps`. Loopex runs it to confirm that a stopped tool's
  processes are gone and that a lock's owner is still alive.
- Network access for fetching dependencies and for the selected model endpoint.

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
mkdir -p ~/src
git clone https://github.com/lexlapax/loopex.git ~/src/loopex
cd ~/src/loopex
mix local.hex --force
mix local.rebar --force
mix deps.get
MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
```

The build writes three things you use later. It builds the companion even when
you intend to use only local `ask`; that companion is not launched for an
ephemeral call:

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

<a id="operator-start-ask"></a>
## 3. Ask Once Without a State Root

Run Ollama with `llama3.2` available, then move into the repository you want
Loopex to inspect. The working directory is the workspace. The command needs
an explicit policy even for a one-shot run, because model-requested tools act
as your operating-system user.

```bash
cd ~/code/my-project
loopex ask --policy shell-allowlist --model ollama:llama3.2 \
  --tools read-only "summarise this repository"
```

This form prints only the final answer to standard output. It needs neither
`LOOPEX_HOME` nor `LOOPEX_PROVIDER_API_KEY`. When cleanup is proved, Loopex has
confirmed its owned session, caller and provider-pool subtree are gone. A run
can complete and exit `0` while cleanup is unproved; check the JSON cleanup
field or the standard-error warning before starting another `ask`. A checked-out
socket and its TLS controller may drain after proved cleanup. For another agent
or a shell script, use:

```bash
loopex -p "summarise this repository" --policy shell-allowlist \
  --model ollama:llama3.2 --tools read-only --output json
```

The built command selects byte encoding before the VM reads standard input,
including on OTP 27. Legacy commands retain Unicode output; answer their
confirmation prompts with plain ASCII `y` or `yes`. Piped confirmations padded
with Unicode whitespace may be rejected.

With no prompt words, `ask` reads standard input byte-for-byte as the prompt;
one or more prompt words are joined with spaces and suppress standard-input
reading. `--` ends flag parsing, so later words that start with `--` are prompt
text. This sends the trailing newline too:

```bash
printf 'Explain this file\n' | loopex ask --policy shell-allowlist \
  --model ollama:llama3.2 --tools read-only
```

With `--output json`, a public run outcome is one JSON object on standard output, with schema
`loopex.ask/1`, session and run IDs, profile, outcome, text, tool summaries,
shadowed skills, cleanup and outcome details. Ephemeral `ask` reports its
cleanup proof; durable `ask` has `"cleanup": null`. Status `0` means the run
completed, not that ephemeral cleanup was proved. Inspect `cleanup.proved` in
JSON or the standard-error warning in text mode. Status `1` means command
refusal or lifecycle failure; `2` failed; `3` bound reached;
`4` outcome unknown; `5` cancelled; `6` no ending observed; and `130`
interrupted. These read-only examples name their tool preset explicitly;
omitting `--tools` selects the coding preset, which includes writes and shell
commands. `--model`, `--tools`,
`--skill-dir`, `--max-steps`, and `--deadline-ms` select this call's model,
tool preset, named skill directories and bounds. The command does not silently
discover a home or project skill.

Add `--trace` to inspect this command's runtime on standard error while keeping
JSON standard output separate. The same option works with durable
`ask --state-root`. Scope, levels, lowered limits and cleanup behavior are
described in [trace sessions](observability.md#operator-observability-procedure).

When `ask` receives an unproved cleanup report and no public run observation
exists, it emits no JSON result and names the pending obligation on standard
error. A retained terminal ending or partial no-ending snapshot may still
produce one result marked `cleanup.proved: false`; the no-ending result exits
with status `6`. A pre-claim startup failure can report `root=null`: no
temporary-root path was known, and that value is not permission to remove a
guessed directory. When the report names a retained root, `ask`
prints it as a JSON-encoded path with its ownership label. `unknown` ownership
is diagnostic, not deletion authority. An unmarked owner loss can instead
print only `loopex: session_unavailable` and exit `1` with no JSON result or
root path, even if a temporary root remains. Before another `ask`, make sure
the previous ask process has exited. Use independent host records to
investigate an unnamed root; do not guess a path or remove a directory based
on the diagnostic.

For `interrupt_handler_unavailable` or `cleanup_unproved`, read the plain-English
line after the fixed error code or cleanup detail. Before another `ask`, make
sure the previous ask process has exited. A repeated handler error means the
host must restore signal handling so Loopex can safely handle Ctrl-C and
termination signals; starting another prompt in that process is not a
fix. For `root=null`, do not remove a guessed directory. If `pending` includes
`run_ending`, `effect_cleanup`, `process_groups` or `session_subtree`, preserve
any named root while those obligations remain unproved. Ownership alone is not
permission to remove it. When `pending` is only `root_removal`, first make sure
the previous ask process has exited, then inspect the exact path and use
independent host records to verify that this session created it before removing
anything. The ownership label in the diagnostic alone is not that proof. If
you cannot verify ownership, leave the path untouched and investigate.

You may name up to four existing directories with `--skill-dir`. A directory
at `<workspace>/.agents/skills/<name>` contributes a project skill; a directory
outside the workspace contributes a user skill. Other directories inside the
workspace are refused. If both sources use the same name, the project skill
wins and the result reports the shadowed user skill.

`--state-root DIR` changes `ask` to the durable profile. It then needs the
built provider companion and `LOOPEX_PROVIDER_API_KEY`, and the resulting
session can be resumed. That profile refuses an `ollama:` model; use a supported
hosted model for durable `ask`. The rest of this guide shows that profile
through the existing session commands. See
[tools and policy](tools-and-policy.md#concept)
before allowing writes or shell commands.

Durable `ask` captures the reference instructions and workspace facts before
opening credential custody. It retains the canonical model and selected tools
with those instructions. Its context capacity derives from the captured model
window minus the 4,096-token reply reserve, or uses 8,192 when the window is
unknown. A rejected instruction capture creates no session.

An Elixir host can make the same local call without the command. From the
Loopex source checkout, save this as `ephemeral.exs`, then run
`mix run ephemeral.exs` while Ollama serves `llama3.2`:

```elixir
defmodule ReadOnlyPolicy do
	@behaviour Loopex.Policy
	@impl Loopex.Policy
	def decide(%{effect_class: "read_only"}), do: {:allow, nil}
	def decide(_request), do: {:deny, :effect_class_not_permitted}
end

{:ok, result} =
	LoopexComposition.Ephemeral.run("List this workspace.",
		policy: ReadOnlyPolicy,
		model: "ollama:llama3.2",
		tools: :read_only,
		cwd: File.cwd!()
	)

IO.puts(result.text)
```

The policy is host code, even for read-only tools. This example uses the source
checkout as its workspace; set `cwd` to another directory to inspect it.

<a id="operator-start-credential"></a>
## 4. Name a State Root and the Credential

The durable state root is the directory Loopex writes to: the session journal,
tool receipts and retained artifacts. It is not your repository. Durable
commands take it from `--state-root`, or from `LOOPEX_HOME` when the flag is
absent; there is no built-in default. The ephemeral `ask` form above does not
need either one.

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
## 5. Run a First Durable Session

Move into the repository you want the session to work on. That directory becomes
the workspace the tools act on.

```bash
cd ~/code/my-project
loopex run --policy shell-allowlist "list the files in this repository and summarise what it does"
```

`--policy` is required; there is no default. `shell-allowlist` lets the session
read and change files. For `bash`, it permits only raw `command` strings whose
first word is `cat`, `ls`, `pwd`, `echo`, `git`, `grep`, `head`, `tail`, or `wc`;
every `argv` form is denied. It is scope, not
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
## 6. Find and Inspect the Session

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
step 8. To trace or measure the runtime itself, see
[observability](observability.md#concept).

<a id="operator-start-stop"></a>
## 7. Stop a Session Cleanly

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
## 8. Keep Sessions Alive With the Daemon

`loopex daemon` holds a state root for as long as it runs, so sessions keep
running while no command is attached, and several terminals can reach the same
session. The daemon, not the client, owns the workspace, policy and credential.

A state root that offline commands have already written, as steps 5 to 7 did,
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

To stop the daemon, press Ctrl-C in its terminal or send it `SIGTERM`. On a
successful orderly stop, it drains every session through the runtime, tells
connected clients it is stopping, releases the state root and exits `0`. Give
it time to finish. If a component fails during stop, the exit status may be
nonzero; follow the
[signals and recovery guidance](daemon.md#operator-daemon-signals) before using
offline commands against the root.

<a id="operator-start-troubleshooting"></a>
## When Something Is Refused

| What you see | What it means | What to do |
| --- | --- | --- |
| `loopex: no built command at …` (exit 127) | The launcher found no escript beside it | Rebuild from a clean checkout, or set `LOOPEX_ESCRIPT` to the escript's path |
| `loopex: :loopex_home_required` | A durable command has neither `--state-root` nor `LOOPEX_HOME` | Export `LOOPEX_HOME` or pass `--state-root`; ephemeral `ask` needs neither |
| `loopex: set LOOPEX_PROVIDER_API_KEY to the provider credential; it is read once and removed` | Durable `run` or `resume` has no usable provider credential | Export the key in this shell before the command |
| `loopex: provider_credential_required` | Durable `ask` has no usable provider credential | Export the key before durable `ask`; local Ollama ephemeral `ask` needs no key |
| `loopex: --policy is required; there is no default host authority` | `run` or `resume` was given no policy | Name `shell-allowlist` or `allow-all` |
| `loopex: another loopex process (pid N) is using this state root; …` | Another command or a daemon holds the state root | Use the daemon's live forms, stop the other process, or pass another `--state-root` |
| `loopex daemon` exits 85 (`session_index_upgrade_required`) | The root has offline sessions and no daemon index | Run `loopex daemon prepare-index` with nothing else holding the root |
| `loopex daemon` exits 76 (`placement_active`) | Another daemon or command holds this root | Stop it, or use another state root |
| `ending failed` (exit `2`) for `ask` text mode; JSON `details.reason: "model_call_failed"`; `loopex: failed model_call_failed` for durable `run` or `resume` | The provider call failed; private provider details are withheld | For local Ollama, check that Ollama is running and the selected model is available. For a hosted provider, check its key, the network and the provider's status, then run again |

Every `loopex daemon` exit status is listed in the
[daemon reference](daemon.md#technical-depth).

<a id="operator-start-next"></a>
## Where to Go Next

- [How a run works](how-a-run-works.md#concept) — the picture of one run, what
  is durable at each step, and what a crash leaves behind.
- [Coding sessions](coding-sessions.md#concept) — steering, follow-ups,
  resuming, project skills, and every flag of the offline command; and
  [`loopex chat`](coding-sessions.md#operator-sessions-chat), a conversation
  from an explicit configuration file with settled settings, compaction,
  model questions and helper roles.
- [Tools and policy](tools-and-policy.md#concept) — the coding and read-only presets, host
  authority, artifacts, and the limits of local execution.
- [The daemon](daemon.md#concept) — several clients, takeover, reconnection,
  limits and exit statuses.
- [App server operations](app-server.md#concept) — driving a session from
  another language over standard input and output.
- [Runtime operations](runtime.md#concept) — embedding the runtime in your own
  host program and recovering it after a crash.
- [Observability](observability.md#concept) — tracing and telemetry for a
  runtime you host.
