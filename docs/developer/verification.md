# Verification

<a id="concept"></a>
## Concept

Technical depth: [Verification mechanics](verification-technical.md#technical-depth).

This is the rule book for checking work after M4. It replaces the milestone
gates: there is no per-milestone runner, no locked digest table, and no
amendment transaction. What remains is one current test suite, two commands,
an independent review, and the maintainer's decisions, arranged so that the
cost of proving a change is proportional to what the change could break.

The design goal set by the maintainer is that verification takes a small share
of development time, on the order of one fifth, while every real product
guarantee still has a check that would fail if it were broken. The measured
baseline at M4 closure is in the technical companion; the short version is
that the credential-free suite took fourteen minutes, two minutes of which
were two tests waiting out a sixty-second ceiling and about three more were
forty tests waiting on shorter real-time ceilings, and that the whole suite
could run in about five minutes of wall-clock time with no test changed at
all.

<a id="concept-verification-stages"></a>
### Three stages, one question each

Every piece of work passes through the same three stages. Each stage answers
one question, runs one set of checks, and has one person or command that can
stop it. Nothing runs twice for the same bytes.
Technical depth: [What each stage runs](verification-technical.md#technical-verification-stages).

| Stage | Question | What runs | Who or what can stop it |
| --- | --- | --- | --- |
| Change | Is this change whole, and is it what it claims to be? | While editing: the focused tests for the changed boundary, `mix format`, a warning-free compile. Before merge to `main`: `bash scripts/check.sh` green in hosted CI on the branch, plus an independent review of the diff against its stated purpose. Every merge, not only milestone closures. | A red check or a blocking review finding; the integrator merges only a green, reviewed candidate |
| Close | Did the milestone deliver its outcomes? | An indexed evidence-page scaffold in the candidate; `check.sh` once under the floor toolchain pair (the current pair is already proved by CI on every change); `bash scripts/check-release.sh` once, whose M5-delivered fresh-source lane retains the exact NUL-delimited output from the M5-delivered `scripts/source-archive-manifest.sh` on the tested archive extraction; the outcome-to-evidence map in the plan; an independent review of the candidate. All checks and review use the **tested implementation SHA** once. The **administrative closure SHA** fills the scaffold and records the decision without re-running the matrix | The maintainer, who closes it or does not |
| Release | Is the source about to be tagged the closed source? | Reuse the closure evidence when the source is unchanged. On the **administrative closure SHA**, verify the five paths and each path's exact allowed region from the complete retained patch, including byte-for-byte reconstruction of `docs/plans/README.md` from the administrative register row and Current Status block and of the root `README.md` from its administrative marked block; run `check.sh --docs`; run the final semantic gate over the relevant operator and developer documentation; stage a fresh `git archive` extraction and run the M5-delivered repository-owned `scripts/source-archive-manifest.sh`; and compare that exact manifest with the retained tested manifest outside `docs/`, except for the supplied root `README.md` and separately validated M5-delivered `SOURCE_IDENTITY`. Retain these proofs outside the repository and put their results, retained-output references, and SHA-256 digests in the annotated tag at creation. No suite and no release check run twice | The maintainer's separate release decision |

The two-commit closure and release rows govern M5 and later milestones.
Earlier closures and tags retain their recorded procedure; `v0.1.0` remains
the separately authorized tag of M4's integrated source commit.

The tested commit itself moves the register and both marked status blocks from
`In progress` to `In review`; the administrative direct child later makes only
`In review` to `Closed`. At the tested SHA, a `Proved` progress row records completed implementation
and its named proof obligation. A scaffold value marked `Pending` is the later
result or identity of a closure run or review taken of that SHA; the
administrative commit records it without implying that the tested commit knew
its own future result.

The fast check is the everyday gate. It is credential-free, needs no network,
and is the same command locally and in CI, where it runs as
`check.sh --select` on every push to `main` and every pull request. The release check is the expensive one: it spends a provider
credential, needs the pinned Node, and runs the attended operator workflow, so
it runs once at milestone closure and whenever a change touches what it proves
during development. An unchanged-source release reuses that closure evidence
and runs only the pre-tag administrative-SHA proofs in the table.

<a id="concept-verification-selection"></a>
### A changed guarantee selects its checks

The old structure ran every historical gate on every contract moment because
it could not tell what a change affected. The replacement asks the developer
to say what boundary a change touches, and routes from there. The fast check
already runs every ordinary suite — conformance, recovery, CLI, composition,
observability — so those are counted once and never asked for again; the
table names only the proof a boundary needs *in addition*, which is a real
provider, a real Node client, a second toolchain, or a document. Two
boundaries select the union of their rows, not the whole release check. An
unknown impact falls through to the release check, not to nothing.
Technical depth: [The selection table](verification-technical.md#technical-verification-selection).

| The change touches | In addition to the fast check, before merge |
| --- | --- |
| Code or tests behind an unchanged boundary | Nothing; the suite is the proof |
| A port behaviour (Store, model, executor, extension, transport) or an adapter of one | Nothing more to run; the review confirms the port's conformance suite still runs against every adapter |
| Durable records, the Store, recovery | Nothing more to run; the review confirms the fault-injection and old-reader cases still cover the change |
| The wire protocol, its schema or vectors | The Node consumer workflows (`--only node_client`, part of the release check), and the compatibility surfaces page updated in the same change |
| The CLI or operator-facing commands | The operator page that describes the behavior updated in the same change; a changed operator command also selects its workflow in the release check |
| Provider or credential handling | `bash scripts/check-release.sh`, the real-provider cases |
| The executor's OS boundary (launch, signals, cleanup) | `bash scripts/fixtures/pinned-load.sh` over the touched cases on a Linux host: thirty runs under four pinned cores and load, no failure and no hang |
| The toolchain floor or `.tool-versions` | The fast check under the floor pair once |
| Documentation only | `bash scripts/check.sh --docs`, which `check.sh --select` chooses on its own for a prose-only diff |
| Unknown | The release check, and the review names the boundaries it found |

Hosted CI's green run on the candidate is the fast-check evidence for that
merge; a local full run of the same bytes is not required as well.

<a id="concept-verification-rules"></a>
### Rules that make the checks trustworthy

Checks are only as good as the rules around them. These are the ones the
repository enforces or the contract binds, and each exists because its
absence was exploited or nearly exploited during M0–M4.

- A required check is never skipped, filtered, softened, retried into green,
  or satisfied with a fake where the real path is what is claimed. A failure
  that disappears on retry is a flake to fix.
- The real-provider tests assert facts only a real provider can produce: its
  own response identifiers and the observed model identity. A scripted model
  cannot pass them.
- Tests fail before touching real user state; a leaked credential or a shared
  environment variable is a defect, and the release check runs each
  application in its own VM so one test cannot reach the next.
- Compile before validating: a project-defined Mix task runs whatever beams
  the build directory holds, so every check compiles first.
- The dependency direction, the documentation chain and the ban on
  content-origin attribution are enforced mechanically, not by review.
- Historical milestones keep their plans, evidence logs and dispositions as
  records of what was proved at the revisions they name; current tests belong
  to the current product. A refactor changes code and tests together and needs
  no historical bookkeeping.
- An architecture decision is made once, as an ADR, with the compatibility
  evidence its class requires; it is not re-approved through every place it
  touches.

<a id="concept-verification-speed"></a>
### Making it fast

Three steps, in order of value per effort, each measured in the technical
companion. The maintainer approved all three and all three are done; the fast
check went from fourteen minutes to under four on the Mac. The critical path
is now the provider suite, which cannot be split from the test side, so more
test changes elsewhere no longer shorten the check.
Technical depth: [Measurements and plan](verification-technical.md#technical-verification-speed).

1. **Run applications in parallel VMs.** The suite is ten independent
   applications. Run concurrently on the Mac, the four heavy ones finished in
   312 s wall against 795 s in sequence, all green, with no contention. This
   takes the push check from about 14 minutes to about 5 and changes no test.
2. **Inject the time bounds the slow tests wait for.** Forty tests wait on
   real-time ceilings: two wait a full minute for the cancellation bound, ten
   wait ten to sixteen seconds for provider deadlines, two sleep ten and
   fifteen seconds for admission. Making each bound an option the test sets
   keeps the proof (the bound is applied) and removes the wait. Three tests
   whose claim is the real duration keep it and moved to the release check.
   Measured: the fast check on the Mac went from 346 s to 256 s.
3. **Let independent modules run concurrently.** Two thirds of the test
   modules are serial, most for a reason (VM-global tracing, environment
   variables, registered names). The ones with no shared state can become
   asynchronous one at a time, each proved by the suite staying green over
   several seeds. Twenty-one modules were; the provider suite cannot be,
   because its cases share the one credential variable the child inherits.

What is deliberately not on the list: cutting durability, security or
recovery tests to meet a number, or shortening a fault window in production
code to make a test faster.
