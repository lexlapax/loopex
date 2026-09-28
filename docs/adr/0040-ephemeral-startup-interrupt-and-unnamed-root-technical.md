<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral startup interrupt and unnamed root](0040-ephemeral-startup-interrupt-and-unnamed-root.md#concept).

<a id="technical-adr-0040-decision"></a>
### Exact sequence and result

Concept: [Decision](0040-ephemeral-startup-interrupt-and-unnamed-root.md#concept-adr-0040-decision).

`ask` first suppresses its own primary logger output, installs one correlated handler under the 1,000 ms installation bound, and confirms the returned `:erl_signal_server` PID and reference. Only then does it call `LoopexComposition.Ephemeral.start_session/1`. A failed or malformed installation returns `interrupt_handler_unavailable` with no session start. After an acknowledged installation, startup completion or a failed liveness probe attempts to finish the exact handler; manager loss can prevent that acknowledgement, and the handler also monitors the main process. If a first signal arrived during startup and a handle is returned before the escape, the command calls `stop_session/1` before it starts any prompt worker. A failed cleanup retains the ordinary unproved result and root rules. The launcher still latches signals before the child PID is assigned; it does not promise an ephemeral status before the child owns a handle.

The only `nil` root case is an unproved cleanup while `SessionRoot` is in `:candidate_prepare`, before the owner receives a candidate or grants `:root_claim`. The owner's `candidate`, `owned_root`, and `possible_root` remain `nil`. `TempRoot.candidate/0` reads the temporary directory and entropy and constructs a possible path; it does not call `mkdir`. `TempRoot.claim/1` is the only path to that `mkdir`, and `SessionRoot` cannot call it before the owner grants `:root_claim`. The owner returns `{:error, {:cleanup_unproved, %{root: nil, root_ownership: :unknown, pending: [:session_subtree], ending: :none, cause: startup_cause}}}`, sets the session cell to sealed, and never treats that result as root removal proof. A candidate that arrives after the cleanup deadline does not grant a claim or revise the public result.

`LoopexCli.AskResult` accepts a `nil` root only with unknown ownership, exactly `[:session_subtree]` pending, and no ending. It emits the fixed `root=null` diagnostic with zero standard output. Any other `nil`-root shape is a malformed result and becomes `command_failed` with no standard output. A known path still passes the existing bounded-string and NUL checks.

<a id="technical-adr-0040-consequences"></a>
### Proofs, alternatives and rollback

Concept: [Consequences and compatibility](0040-ephemeral-startup-interrupt-and-unnamed-root.md#concept-adr-0040-consequences).

The ask interruption tests hold startup after handler installation, inject a first signal, then return a real handle. They require one stop, no prompt worker, status 130 after proved cleanup, and restoration of the handler. An installation-refusal test requires no `start_session/1` call. A manager-loss test after handle return still requires bounded stop; loss before a handle exists cannot supply one.

`ephemeral_unknown_root_test.exs` blocks entropy before any candidate exists, waits for the startup failure, and requires `root: nil`, unknown ownership, only `session_subtree` pending, no ending, and a sealed cell. It then releases entropy and verifies that no `mkdir` is invoked without an owner grant. `ask_result_test.exs` requires the fixed `root=null` line and rejects `nil` with owned status or a different pending set. Positive known-root tests keep the earlier exact-path behavior.

The rejected alternatives are post-handle installation, which leaves a live-handle gap, and a second pre-handle signal latch, which adds another actor and handoff. Root-path preallocation could remove the `nil` exception but would add a different ownership protocol before the existing side-effect-free candidate step. Neither alternative is part of M6 after this decision. Reverting to ADR 0039 requires both replacements before removing this pair's behavior; reverting only one leaves its original gap.
