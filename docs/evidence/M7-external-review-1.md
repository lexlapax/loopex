# M7 external review, round 1

Received: 2026-09-30. Reviewed candidate: `20ff082a23b7f0bbba09f123a3db0dc262a866bc`.

This is the received assessment, retained verbatim below. It is review evidence,
not an accepted decision. Its implementation-readiness objections reopen the
internal checkpoint disposition. Findings are being checked against source;
material choices require maintainer disposition before dependent revisions.

Source SHA-256: `545b28c7b7c9ea9c081b16e30ec2cc98a11a5f9d3518fff540352178245f5769`.

## Received assessment

Concept

Verdict. The M7 packet is a faithful record of the maintainer's scope decisions, and its structure is sound: nine outcomes, nine prerequisite ADRs, an evidence matrix, and twelve operator scenarios. It is not implementation-ready, and it is not yet holistic against the vision. Six blocker families stand between it and acceptance. None requires a redesign of the product idea, but three require a maintainer decision rather than an edit.

What holds up. Serial barriers are respected and M7 sits correctly before the M8–M10 drafts. Between-run model and provider switching is squarely permitted by the vision. Roles, allowances, and credentials sit in the host as the vision says. The tracing API the plan assumes already exists in core. The register, roadmap row, and Progress rows agree, and all twenty contract hashes in the review record match the committed bytes.

Blocker families.

1. The headline promise is arithmetically unreachable at the chosen limits. The plan promises "keep going when the context fills," yet the retained request record ceiling holds roughly four maximum-size tool outputs, and ADR 0043's compaction source envelope is the same size as one tool output. A turn containing one full read or bash result can never be summarised. The vision's remedy is artifact references, and its open question on inline versus artifact bytes is triggered by exactly this kind of ADR. The plan excludes artifacts without naming a successor. Separately, the default context budget in composition is small enough that the phase 1 "two prompts plus restart" proof likely refuses before compaction exists.
2. The two "vision readings" are misstated. The plan asks the maintainer to confirm that questions and helpers are opt-in host tools outside the tool budget. ADR 0045 actually makes the ask tool a core-handled interaction-class tool in the reserved namespace, which is an eighth built-in tool. The vision's budget text is unqualified: seven built-in tool implementations, no built-in sub-agent. Either is a deliberate vision revision with principle, evidence, compatibility, and migration named, or the ask tool is redesigned as a host-side tool raising a policy defer. The task tool also sits in the core-reserved namespace.
3. Proposed ADRs amend accepted clauses they do not declare. ADR 0046's absolute deadline contradicts accepted ADR 0013's "neither admission path commits an absolute deadline." ADRs 0041 and 0044 move the context token budget into session configuration against ADR 0017's placement. ADR 0045 ignores the accepted ephemeral session API, whose answer path is choice-only in code today. ADR 0046 leaves a child's policy defer unhandled, so a child would hang to its deadline, and does not bind the frozen role catalog to a session record or to tool re-registration after restart.
4. Closure is not yet possible under the repository's own rules. Outcome 9 names no fixed attended step set, no pass rule, and no mapping from "unavailable" to the allowed Progress states. Several release rows are judged from model prose or depend on the model choosing to call the ask or task tool, which clashes with the single-run, no-retry closure rule. The compatibility section's M6-root upgrade fixtures, exact-M6-binary downgrade, and pre-upgrade backup are attached to no outcome or scenario, and the backup procedure is gated behind ADR 0036 in M8. No evidence-page scaffold is named.
5. Hidden implementation work is unnamed. Single-provider wiring is structural across the coordinator, credential plane, executor, and receipt validation. The coordinator holds one executor slot and the composition opens the executor before the runtime exists, so the child adapter has a construction-order problem. Interactions exist only inside a policy defer and resume by re-running policy. The protocol has two generations on different servers and its schema digest does not cover payload shapes. The release runner is hard-wired to eleven rows and one credential. No pseudo-terminal test helper exists. The agent context map has no M7 routing.
6. The coding fixtures cannot run as described. The bash tool runs under a scrubbed environment with a declared PATH, and the reference shell-allowlist policy permits nine commands, none a test runner. The repair and feature fixtures ask the model to run tests. The system-class ceiling also counts every tool descriptor, so base text, environment facts, appendix, and two new tool schemas share about three kilobytes.

Recommendation. Do not accept the packet as is. Resolve the three maintainer-level decisions first: the artifact or effective-context stance, the tool-budget and sub-agent vision revisions, and whether piped chat input is supported. Then repair the ADR supersession lines and joins, add the missing evidence rows and hidden work items, and re-hash. The ADR readiness grades and the full finding list follow.

Technical depth

ADR readiness.

┌─────────────────┬────────────────────┬───────────────────────────────────────────────────────────────────────────┐
│       ADR       │       Grade        │                                 Main gap                                  │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0041 lineage    │ ready with edits   │ Reply reserve and model window have no source; changes ADR 0017's default │
│                 │                    │  while claiming "Supersedes: nothing"                                     │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0042            │ ready with edits   │ Required version has no source in the 0049 file schema; environment-facts │
│ instructions    │                    │  rendering unspecified so digests diverge                                 │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│                 │ ready with edits,  │ Summary prompt ownership unclear against the "no prompt engineering in    │
│ 0043 compaction │ but see blocker 1  │ core" non-goal; supersedes only 0010's deferral while changing 0017 and   │
│                 │                    │ 0018                                                                      │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0044            │ not ready          │ Moves context budget against 0017; capability source unnamed; protocol    │
│ configuration   │                    │ clients gain quota-like authority over provider and budget                │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0045 questions  │ not ready          │ Core tool, not host tool; ignores accepted ephemeral session API; no      │
│                 │                    │ decline command in 0049 grammar                                           │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│                 │                    │ Contradicts 0013/0011/0017; child defer unhandled; catalog-to-session     │
│ 0046 child tool │ not ready          │ binding and registry re-registration undefined; ledger caps do not fit    │
│                 │                    │ 128 children                                                              │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0047 run limits │ ready              │ Measurement rule has no decision threshold                                │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0048 providers  │ ready with edits   │ Credential-free providers cannot be configured; any env name may be       │
│                 │                    │ deleted, including PATH                                                   │
├─────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────┤
│ 0049 config and │ ready with edits   │ Contradicts plan on piped input; trace selectors undefined; grammar       │
│  chat           │                    │ hedged as "proposed until implemented"                                    │
└─────────────────┴────────────────────┴───────────────────────────────────────────────────────────────────────────┘

Blocker evidence.

#: 1
Claim: Tool outputs are 16,384 bytes
Where: apps/loopex_executor_local/lib/coding_tools.ex:60-61
────────────────────────────────────────
#: 1
Claim: Compaction source envelope is 16,384 bytes including prior summary; first group not fitting stops with
compaction_input_too_large
Where: docs/adr/0043-context-compaction-checkpoint-technical.md:36-46
────────────────────────────────────────
#: 1
Claim: Request record ceiling preserved, no artifact-backed storage
Where: docs/plans/M7.md:133-138
────────────────────────────────────────
#: 1
Claim: Vision: overflow becomes an artifact; open question triggered "during the context/store ADR"
Where: docs/vision-technical.md:1465-1467, :3103
────────────────────────────────────────
#: 2
Claim: Vision budget text is unqualified
Where: docs/vision-technical.md:2866-2870
────────────────────────────────────────
#: 2
Claim: Ask tool created by the session owner with no executor; interaction class only for loopex.ask
Where: docs/adr/0045-model-originated-questions.md:18-19, -technical.md:11-13
────────────────────────────────────────
#: 2
Claim: Task tool routed as loopex.task in the reserved namespace
Where: docs/adr/0046-child-session-tool-technical.md:11
────────────────────────────────────────
#: 3
Claim: 0013: no absolute deadline at admission; follow-up inherits all three bounds
Where: docs/adr/0013-...md:66,75,84
────────────────────────────────────────
#: 3
Claim: 0046 commits bounds.deadline_at_ms at admission with "Supersedes: no existing guarantee"
Where: docs/adr/0046-child-session-tool-technical.md:102-113, concept :9
────────────────────────────────────────
#: 3
Claim: 0017: context budget is a top-level option, not command input
Where: docs/adr/0017-durable-context-admission-budget.md:146-149
────────────────────────────────────────
#: 3
Claim: 0044 puts it in configuration and the configure command
Where: docs/adr/0044-...-technical.md:11-20
────────────────────────────────────────
#: 3
Claim: Ephemeral start_session, ask, answer exist; answer is choice-only
Where: apps/loopex_composition/lib/loopex_composition/ephemeral.ex:41,85,104
────────────────────────────────────────
#: 4
Claim: Objective-check rule versus prose-judged rows
Where: docs/plans/M7-technical.md:181-182 versus :171,174,206
────────────────────────────────────────
#: 4
Claim: Compatibility obligations with no evidence row
Where: docs/plans/M7-technical.md:464-478 versus :169-179
────────────────────────────────────────
#: 4
Claim: Backup and restore are M8 commands gated on 0036 acceptance
Where: docs/adr/0036-...md:63-67
────────────────────────────────────────
#: 4
Claim: Rollback lane still pinned to v0.2.0
Where: scripts/rollback-lane.sh:2,17
────────────────────────────────────────
#: 5
Claim: Release runner exports one credential name and fixes eleven rows
Where: scripts/check-release.sh:25,117-131,282-326
────────────────────────────────────────
#: 5
Claim: Interaction created only from policy defer; answer re-runs policy
Where: apps/loopex/lib/loopex/runtime/session_coordinator.ex:6414,6596-6620
────────────────────────────────────────
#: 6
Claim: Allowlist permits only cat ls pwd echo git grep head tail wc
Where: apps/loopex_cli/lib/policy/shell_allowlist.ex:42
────────────────────────────────────────
#: 6
Claim: System class counts every tool descriptor; ceiling 1,000 tokens
Where: session_coordinator.ex:3244,3322-3331, context_admission.ex:47,121

Should-fix findings.

- Outcome 1 is a conformance defect, not new scope. Accepted ADR 0010 states that M2 implements lineage projection, yet each run's conversation starts as its prompt alone. The plan should record the defect against the closed milestone.
- Missing "why not an edge" rows. The vision requires one per new core concept. M7 adds the interaction tool class, a five-level reasoning enum, maintenance episodes, configure, and a generic absolute deadline without that argument.
- Silently missing vision capabilities. Branch and fork, active-tool changes between runs, visible tool and artifact rendering in chat, and the default tool-profile decision have no scope row and no successor. Foreground-only chat regresses disconnect survival and should be a stated non-goal.
- Prompt-budget escape hatch. The vision target of under 1,000 tokens applies to the reference CLI. The plan exempts opt-in sets, but chat with questions and helpers enabled is the reference CLI.
- Piped-input contradiction. The plan requires steer, follow-up, question, and interrupt tests over a pseudo-terminal or piped input. ADR 0049 refuses non-TTY chat. Decide, then name the PTY harness and its toolchain pin.
- Anthropic reasoning in tool loops. ADR 0044 forbids replaying reasoning signatures. Extended thinking with tool use may require them. Run a real-provider canary before accepting 0044.
- Two-provider proof has no named providers. The A→B→A row and V8 need a second credential variable, redaction entries, and a release-lane design. Whether B may be credential-free is undecided and ADR 0048 cannot express a credential-free provider.
- Undefined joins. Instruction version source, environment-facts rendering, child context and system-class budgets, checkpoint summary rendering, the compact protocol method name, and one owner for the request-revision inventory including ADR 0046.
- Maintainer decisions have no durable record. About ten "maintainer selected option" statements exist only in plan prose with no context-map disposition, and the external task pin has no named destination.
- Successor claims overreach. ADR 0038 has no record-capability text despite the plan's claim; M8's attachment wording differs; the placement table omits M8's backup and restore, which M7's downgrade story depends on.
- Stale labels. The comparison basis cites "branch m6," which does not exist; the source is release commit 1fe09520. The roadmap still says "accepted M6." The evidence index is out of order.

Order of repair.

1. Maintainer decisions: artifact or effective-context stance for blocker 1; vision revision or redesign for blocker 2; piped-input support; whether the fixture harness, not the model, runs acceptance commands.
2. ADR edits: supersession lines for 0043, 0044, 0046 against 0013, 0017, 0018, 0011; child defer handling; catalog binding; ephemeral answer path; one revision inventory.
3. Plan edits: hidden-work items per outcome, compatibility evidence row, named evidence scaffold, attended step list with pass rule, named provider pair and release rows, fixture feasibility under the allowlist, context-map routing.
4. Re-hash the packet and rerun the two documentation checks before external audit.

This review is assessment only; nothing was edited. If you want it retained alongside the existing planning-review record in docs/evidence/, say so and I will write and index it.
