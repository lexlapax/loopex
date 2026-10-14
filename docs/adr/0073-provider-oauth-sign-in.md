<a id="concept"></a>
## Concept

Technical depth: [Provider sign-in contract, token store, refresh and evidence](0073-provider-oauth-sign-in-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-13; the maintainer's decisions on the `chatgpt:` reply
  ceiling, the public failure reason, daemon exit statuses and outcome
  numbering recorded the same day; the host-to-store sign-in context and the
  lifetime-scaled custody deadline specified the same day; the ADC directory's
  protection and the custody deadline under a slow exchange specified the
  same day; the maintainer's ADC client exception, the amended Core
  settlement clauses and the in-process reply bound recorded the same day;
  the maintainer's decisions on startup readiness of a sign-in route and on
  the generation floor that survives sign-out recorded the same day, with
  `chatgpt:` model admission, the store-failure and lock-contention rules
  and the explicit Secret Service bus specified the same day; the
  maintainer's decision that the model list is part of a `chatgpt:` sign-in
  (D25) recorded on 2026-10-14, and the lock-failure and fail-stop decision
  (D32), the lane deferral (D36), the widened host-VM credential audience
  (D37) and route loss in foreground chat and `ask` (D38) recorded the same
  day
- **Decision owner:** Maintainer
- **Supersedes:** nothing on its own. On acceptance it amends named clauses of
  [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept),
  [ADR 0019](0019-host-owned-provider-protection.md#concept),
  [ADR 0021](0021-compacted-provider-accounting-provenance.md#concept),
  [ADR 0029](0029-bounded-provider-failure-diagnostics.md#concept),
  [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept),
  [ADR 0039](0039-ephemeral-embedded-profile.md#concept),
  [ADR 0043](0043-context-compaction-checkpoint.md#concept),
  [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept) and
  [ADR 0049](0049-explicit-host-configuration.md#concept),
  listed under [amendments](#concept-adr-0073-amendments). It changes one
  sentence of the Proposed [ADR 0037](0037-host-configuration-and-path-discovery.md#concept)
  and one non-goal of the M8 plan.
- **Depends on:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
  and [ADR 0049](0049-explicit-host-configuration.md#concept), delivered by M7;
  [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the
  installed home; [ADR 0071](0071-daemon-attached-conversation.md#concept) for
  the service as the host that holds credentials;
  [ADR 0038](0038-installed-distribution-and-release-artifact.md#concept) for
  the two supported hosts
- **Prerequisite for:** M8 outcome 8, provider sign-in, and its workstream,
  added by the maintainer on 2026-10-13

<a id="concept-adr-0073-decision"></a>
### Context and Decision

Technical depth: [Contract](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-decision).

Technical depth: [ID-token verification](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-id-token).

Technical depth: [Refresh-response rules](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-refresh-merge).

Technical depth: [The ADC source](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-adc).

Today every hosted provider route needs an API key in a named environment
variable. Many operators instead have a paid plan or a cloud project, and
expect to sign in once in a browser, as other coding agents let them. On
2026-10-13 the maintainer added provider sign-in to M8 as a new outcome
alongside API keys. API keys remain fully supported. Sign-in is another way
for the host to hold a credential. It is not a new authority and it is not a
new provider protocol.

**The decision.**

1. **Sign-in is a credential form.** A provider binding may name `oauth` as its
   credential, beside the existing `env` and `none` forms. The binding still
   names one route per provider. Model output, roles, saved defaults and
   remote clients still cannot select or create a credential.
2. **A plan-billed or cloud-billed route is its own provider route.** A
   request billed to a ChatGPT plan accepts different models and request
   members than an API-key request. A Gemini request billed to a Google Cloud
   project uses a different endpoint. So each gets its own route prefix:
   `chatgpt:` for OpenAI sign-in, `vertex:` for Gemini on Google Cloud, and
   `claude:` reserved for Anthropic. The committed `provider:model` then says
   how a run was billed. Switching between `openai:` and `chatgpt:` is an
   ordinary ADR 0048 provider switch.
3. **Loopex uses only its own client identity.** Each provider sees Loopex as
   a distinct OAuth client, registered or issued for Loopex. Loopex never
   presents another product's client ID, user agent or application header. It
   never lets the provider library refresh tokens or turn on its
   subscription-impersonation modes. The maintainer decided on 2026-10-13 one
   exception: the `adc` source presents the client ID and secret written in
   gcloud's Application Default Credentials file, because Application
   Default Credentials are Google's documented way for any application to use
   the credentials the user gave gcloud. The exception covers that source
   only. It never applies to `chatgpt:` or `claude:`.
4. **The order is OpenAI, then Gemini, then Anthropic.**
   - **OpenAI** uses Sign in with ChatGPT. A Plus or Pro user authorizes Loopex
     to use their plan, up to a weekly cap they set for Loopex. Requests go to
     OpenAI's public Responses API.
   - **Gemini** uses Google Cloud OAuth for Vertex AI, billed to the
     operator's Google Cloud project. The token comes from Loopex's own Google
     OAuth client, or from Google's Application Default Credentials that
     `gcloud auth application-default login` writes. The consumer Gemini CLI
     and Code Assist sign-in is out of scope, because Google's terms forbid
     third-party software from using it.
   - **Anthropic** sign-in is designed in full behind the same interface. It is
     disabled until Anthropic sanctions an OAuth client registration for
     Loopex. Anthropic's current terms forbid third-party apps from offering
     Claude.ai login or using Free, Pro or Max credentials. Until such a
     registration exists, Anthropic is API-key only.
5. **The host keeps tokens in the operating system's keyring.** macOS uses the
   login Keychain. Linux uses the Secret Service through libsecret when it is
   available. Without a keyring, as on a headless Linux host, tokens go to a
   private file in the Loopex home, readable only by its owner. The token
   directory, gcloud's Application Default Credentials directory that the
   `adc` source reads, and every state root, backup, restore destination
   and available restore source must lie apart by path, under ADR 0037's
   separation invariant, which refuses an overlapping selection, after
   symbolic links are resolved, before any token or root write. The
   installed host checks the paths once and hands the token store the
   checked paths; the store and its refreshers repeat that check before
   every token write and never look for a root themselves. So backups never
   contain tokens, within the operator limit ADR 0037 states under the
   maintainer's D27: separation is a path rule only, and the operator must
   not mount credential storage into or over a Loopex state root, backup or
   restore destination. Tokens never enter
   journals, public events, progress, diagnostics, traces, fixtures, executor
   jobs or project resources.
6. **An access token travels exactly like an API key.** For each provider call
   the host resolves the current access token for the selected route. It
   passes the token over the existing private credential channel. The
   selected-credential echo guard, trace exclusion and cleanup proofs then
   apply unchanged, with the access token as the selected credential.
7. **The host refreshes, and refuses rather than guesses.** The process that
   holds the route refreshes the token before it expires, and stops using it
   a margin before its expiry that scales with the token's lifetime, at most
   one minute. A provider reply granting a token that lives under ten seconds
   is refused as a failed sign-in. A lock serializes
   refreshes across every Loopex process that shares the home, and no
   process exchanges a Loopex-stored refresh token without holding it. A
   result obtained without that lock, such as a model list, a token save
   that is being retried, a re-login a running service is taking up, or a
   token from gcloud's file, passes one recheck under the lock: it is used
   only if the stored sign-in is still the one it was obtained for. A
   newer sign-in of the same account and client is taken up in its place,
   and anything else leaves the route without a token and stores nothing
   it obtained. A provider
   that rejects the refresh token leaves the route unusable. Its calls are
   then refused before dispatch, by name: sign-in required. Nothing falls back
   to another route or to an API key. The maintainer decided on 2026-10-13
   how this meets service startup: a sign-in route that is not ready when
   the service starts, because it was never signed in, its sign-in is
   incomplete or it needs sign-in again, refuses the service start with exit
   status 120. A revocation or sign-out while the service runs makes only
   that route refuse its calls; the service and its other routes keep
   running. When the provider has issued a new token but the store cannot
   save it, the service keeps using the new token from memory and retries
   only the save; if the service stops before the save succeeds, the new
   token is lost and the route needs sign-in again.
8. **Three commands manage sign-in.** `loopex auth login <provider>` opens a
   browser and receives the answer on a local loopback address. A headless
   host uses the provider's device flow where one exists; the companion
   explains why each provider has none today. `loopex auth status` reports
   which routes are signed in without reading a token. `loopex auth logout
   <provider>` revokes the token with the provider and removes it locally.
   A refresh holds the lock for up to one provider exchange, so a login or
   logout that meets one for more than ten seconds fails as busy, changes
   nothing and can be run again. The maintainer decided on 2026-10-14 (D32)
   that a lock that cannot be verified or taken, as opposed to one another
   process holds, fails as `sign_in_lock_failed` with the same exit status
   73 and the same no-change behaviour, printing the lock primitive's cause
   so the operator can repair it; and that an unexpected exit of the
   process holding a route's sign-in stops the daemon (exit status 123).
   The maintainer decided the same day (D38) that such an exit stops
   foreground chat and `ask` with `loopex: sign_in_route_lost` and exit
   status 1, their lifecycle-failure status; a foreground run is interrupted
   and resumes later as any interrupted run does.
9. **Loopex enforces the `chatgpt:` reply ceiling itself.** A plan-billed
   request cannot carry a maximum output length. Loopex ends the reply stream
   once the configured ceiling is reached and records the reply as cut at its
   limit, as any provider's truncated reply is recorded. So `chatgpt:` works
   in every role, the summarizer included. See
   [The `chatgpt:` reply ceiling](#concept-adr-0073-reply-ceiling).
10. **"Sign-in required" is a public failure reason.** A call refused because
    its route needs sign-in ends the run as failed with the reason
    `provider_sign_in_required`, which every client can show. This amends
    accepted ADR 0029's bounded failure vocabulary. See
    [The public failure reason](#concept-adr-0073-failure-reason).
11. **A stored token belongs to one account and one client.** Each stored
    token names the account it was issued for, the Loopex client that
    obtained it, and a write generation. The non-secret metadata that
    `auth status` reads names the same three. The route uses the token only
    when both agree. Any disagreement, such as a crash between the two
    writes, leaves the route signed out until the same account's write is
    completed or the operator signs in again. A token is never shown or used
    under another account's name. See
    [Account binding and recovery](#concept-adr-0073-account-binding).
12. **Loopex checks the provider's signature before trusting an account.**
    The account a sign-in names comes from the provider's signed identity
    token. Loopex verifies that signature against the provider's published
    keys, with OTP's built-in cryptography and no new library,
    before it records or compares the account.
13. **Google's Application Default Credentials stay gcloud's file.** With the
    `adc` source Loopex stores no token of its own. It reads gcloud's file at
    each refresh, notices when gcloud replaced it, and confirms the account
    before using a replaced file's token.
14. **A `chatgpt:` model must be one the account lists.** OpenAI admits on
    each plan only the models it lists for that account. After each sign-in
    and each successful refresh, Loopex fetches that list through the same
    process that exchanges tokens, which in a durable host is the isolated
    provider companion and never the durable host VM itself. It bounds the
    list and records it beside the sign-in. The maintainer decided on
    2026-10-14 (D25) that the list is part of signing in: when the list
    cannot be fetched or is malformed, empty or too large, `loopex auth
    login openai` fails by name and keeps nothing, so a signed-in
    `chatgpt:` route always has a list. Refusing an empty list is this
    record's reading of D25's required list. A refresh whose listing fails
    keeps the previous list and says so in a diagnostic. A list belongs to
    the sign-in that fetched it: a login records its list together with its
    own token, and a refresh's list passes the recheck of decision 7. A
    login cut short after its token write and completed later keeps the
    previous list until the next refresh lists again. A
    `chatgpt:` model is
    admitted, when the configuration is composed and when a session switches
    model, only if the recorded list names it. An unlisted model is refused
    before any call with the refusal an unconfigured provider route already
    gets, and a refused switch keeps the prior model.
    It is a configuration refusal, not a failed model call, so nothing is
    retried.
15. **Signing out keeps a floor, not a secret.** The maintainer decided on
    2026-10-13 that `auth logout` leaves, beside the home's host identity, a
    small non-secret file per route naming the highest write generation the
    route has used and the client of the sign-in it removed. The next
    sign-in writes a generation above every earlier one, and the next OpenAI
    sign-in reuses the client OpenAI issued. A service that is still running,
    and that the sign-out left without a token, therefore recognizes a later
    sign-in by the same account and client as newer than anything it held,
    takes it up without a restart and resumes refreshing.

The maintainer decided items 9 and 10, the daemon exit statuses and the
outcome numbering on 2026-10-13, and the startup rule of item 7 and the
generation floor of item 15 the same day. They are recorded as decided, not
proposed.

Alternatives are in the companion. The main one rejected is reusing a widely
deployed client identity, such as Codex CLI's or Claude Code's, which the
provider library ships with. That impersonates another product, can break
without notice, and for Anthropic contradicts the published terms.

<a id="concept-adr-0073-reply-ceiling"></a>
### The `chatgpt:` Reply Ceiling

Technical depth: [Ceiling enforcement in the stream drain](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-reply-ceiling).

Every model call carries a reply ceiling, a maximum number of output tokens.
On other routes the provider enforces it. OpenAI rejects that member on a
plan-billed request, so for `chatgpt:` Loopex never sends it and counts
instead. While the reply streams, the adapter keeps Loopex's existing
conservative token estimate of what has arrived. When the estimate reaches
the ceiling, it stops reading, closes the stream and builds the reply from
what it kept. The reply is recorded with the same `limit` completion a
provider-truncated reply has, so the run, accounting and compaction treat it
as they already treat a reply cut at its limit. The estimate counts about one
token per three bytes. For English text and code that is usually more tokens
than the provider counts, so a cut reply is usually shorter than a
provider-enforced ceiling would have allowed. For text in multi-byte scripts
it can count fewer, so such a reply can run past the provider's own count of
the ceiling. Either way the kept reply never exceeds the ceiling by the
estimate. The summarizer and every other
role may therefore use `chatgpt:`.

One ceiling rule serves both ways a call is made: the provider companion of
the durable hosts, and the in-process caller of the ephemeral profile. The
in-process caller streams the `chatgpt:` reply through the profile's existing
single-use connection, so the ephemeral cleanup proof is unchanged, and it
shows no reply progress while the reply arrives, as it shows none for any
route today. That connection also keeps its existing bound on the raw bytes
of one response. The stream carries far more bytes than the reply text, so a
large ceiling can meet that bound first. The call then fails as a dispatched
model-call failure, as any oversized in-process response does, and is not
recorded as a reply cut at its limit. The companion has no such bound, so
there the ceiling always decides.

<a id="concept-adr-0073-failure-reason"></a>
### The Public Failure Reason

Technical depth: [Reason, schemas, vectors and Core handling](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-failure-reason).

When a call is refused before dispatch because its sign-in route has no
usable sign-in, the run ends as failed with the reason
`provider_sign_in_required`, not the generic `model_call_failed`. Nothing was
sent and nothing is owed. Loopex does not retry the call, because a retry
would meet the same refusal. The refusal can also arrive on the one retry a
generic unsent failure earns, when the sign-in was lost between the two
attempts; it ends the run the same way. A maintenance or compaction run reports the same
category. An abort or a run deadline that has already won takes precedence,
as it does over any other model-call failure: the run ends cancelled or at
its bound, and the attempt record still names the sign-in category.

Clients see the reason in the run's terminal outcome on both
`loopex.experimental/3` and `/4`. The reference chat and `ask` print that the
route needs sign-in and the exact `loopex auth login <provider>` command, then
leave the session resumable. After the operator signs in, the next turn or
resume uses the route without a restart. Other clients show the reason as
they show any failed outcome. A token that merely expired while the provider
was unreachable is not this reason: it stays `model_call_failed`, because
signing in again would not help.

<a id="concept-adr-0073-account-binding"></a>
### Account Binding and Recovery

Technical depth: [Token record, pairing rule and recovery](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-pairing).

A sign-in is stored in two places: the secret, in the keyring or the private
file, and the non-secret metadata beside it. They cannot be written in one
step. Loopex writes the secret first and the metadata second, and both name
the account, the client and the generation. A reader that finds them
disagreeing uses neither as they stand:

- When the secret is exactly one write ahead for the same account and
  client, the next process that takes the refresh lock completes the
  metadata write from the secret. A refresh that crashed after the secret
  write therefore loses nothing; one that crashed after the provider rotated
  the token and before the secret write loses the rotated token, so the
  route needs sign-in again.
- In every other disagreement, including a secret for a different account,
  the route is signed out. `auth status` shows that sign-in is incomplete
  and `auth login` repairs it. A running service keeps the account it
  started with and never writes over the other account's secret.

Signing out deletes both the secret and the metadata but keeps the route's
generation floor (decision 15). So a sign-in after a sign-out never reuses a
generation a running service has already seen, and an OpenAI sign-in
presents the same issued client that service holds. A sign-in that moves a
route to another store or source signs the route out first, so no secret is
left in a store the metadata no longer names.

<a id="concept-adr-0073-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-evidence).

Technical depth: [Threat model](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-threats).

An operator with a ChatGPT Plus or Pro plan runs `loopex auth login openai`,
approves Loopex in the browser and sets its cap. They then select a
`chatgpt:` model in configuration. Calls count against the plan, never an API
balance, unless the operator separately allowed credit overflow for Loopex in
ChatGPT's settings. A Google Cloud operator signs in for `vertex:` and names
the project to bill.

`auth status` lists each configured sign-in route: whether it is signed in,
which account by its displayed label, where the token is stored, and when the
current token expires. It never prints a token and never contacts a provider.
Configuration inspection still shows only the reference form, never whether a
credential is available.

A service holding a sign-in route keeps the token fresh while it runs. A
sign-in route that is not ready when the service starts refuses the start
(decision 7). If the operator signs out, or the provider revokes access,
while the service runs, only that route's new calls fail before dispatch with
the public reason `provider_sign_in_required`. The service notices a sign-out
within about 30 seconds and a revocation at its next refresh. Until then it
may still send the access token it holds, and a revoked sign-in's last access
token can stay valid at the provider until it expires, up to an hour for
OpenAI. The service also records the reason in its own diagnostic output, and
`auth status` shows it. After the operator signs in again with
the same account, the service picks up the new token without a restart, after
a sign-out too. A
different account needs a service restart, as replacing an API key does
today. A running call is never cut off or repeated because a token changed.

On Linux the Secret Service is reached through the desktop session's message
bus. The service uses the bus address it was started with and never looks
for another. A keyring that is locked or absent when the service starts makes
a route stored there refuse the start as an unavailable credential store
(exit status 121). `auth login` falls back to the private file only for a
route with no stored sign-in yet.

When no keyring is available, `auth login` says the token is stored in a file
and names the file. Anything running as the same operating-system user can
read a keyring or that file, including tools the operator lets the agent run.
That is the same exposure an environment-held key already has. The plan's
weekly cap and the cloud project's budget limit the damage from a stolen
token.

<a id="concept-adr-0073-amendments"></a>
### Amendments to Accepted Decisions

Technical depth: [Amendment text](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-amendments).

Acceptance would amend only these clauses. Each accepted file stays
byte-for-byte as accepted, and the ADR index records the amendment.

| ADR | Clause amended | Change |
| --- | --- | --- |
| 0048 | Credentialed routes store only named environment references; no keychain or file sources; no live rotation; one fixed binding shape | Adds the `oauth` form and the `vertex` project and location members. A host refresher may rotate the same route's custody to a fresh token for the same account. A different account still needs a restart |
| 0019 | The sender passes a credential read from the environment; the private protocol's closed frames serve one Model request | The credential may be a host-held access token. Two new invocation kinds of the same companion, a token exchange and a `chatgpt:` model listing, carry a refresh or access token, and for `adc` the file's client secret, over the same private channel in closed frames of their own |
| 0034 | Custody holds one value bound at composition; custody's `:missing` and `:expired` become ADR 0019's generic credential-send failure, and no ADR 0029 terminal gains them | Custody's existing rotation and expiry are used by a host refresher. On a sign-in route `:missing` becomes the public `provider_sign_in_required`; `:expired`, and both answers on other routes, are unchanged. The token, registry and sender rules are unchanged |
| 0039 | In the ephemeral profile, each hosted provider's key is read from its variable at the model boundary for each call; a proved pre-call refusal is fixed `model_call_failed`; the host-VM audience covers the selected provider credential | A sign-in route resolves from custody owned by the composition, and a proved pre-call refusal for missing sign-in is `provider_sign_in_required`. Refresh tokens, ID tokens and the authorization-code exchange may also live in the host VM (D37) |
| 0049 | The schema-version-1 configuration file's closed `providers` member; durable chat requires an `env` credential; a failed terminal's `reason` is `model_call_failed` or `unreadable_model_answer` | Adds, inside schema version 1, the `chatgpt`, `vertex` and `claude` provider names, the `oauth` credential form, and the `vertex` `project` and `location` members. Durable chat also accepts an `oauth` binding. A failed terminal's `reason` may also be `provider_sign_in_required`. The schema version does not change |
| 0029 | A failed model call's public result is the fixed `model_call_failed`; the diagnostic pair stays private | A host refusal before dispatch because a sign-in route needs sign-in is public as `not_dispatched` with `provider_sign_in_required`. Dispatched failures and the private diagnostic pair are unchanged |
| 0018 | The Model callback returns only `model_call_failed` as an error reason; settlement results carry only `model_call_failed` or `unreadable_model_answer`; its closed valid-combination table; an exact not-dispatched result retries once | The callback also admits `not_dispatched` with `provider_sign_in_required`. Its settlement records no conversation and no charge and always ends the run, on either attempt, without a retry |
| 0021 | The settled-attempt record's model-failure result is exactly `model_call_failed` | The result also admits `provider_sign_in_required` |
| 0043 | A failed compaction episode's failure is one of a closed set of categories | The set also admits `provider_sign_in_required`, not retryable |

The Proposed ADR 0037 leaves only file, keychain and command sources for API
keys to a separate future decision, and the M8 plan's credential non-goal
excludes sign-in tokens and their same-account refresh.

The vision already gives the host credential custody, including access
tokens, rotation and encryption. The maintainer decided on 2026-10-14 (D37)
that refresh tokens, ID tokens and the authorization-code exchange may live
in the ephemeral `ask` host VM and in the `auth` command's VM. That widens
the host-VM credential audience ADR 0039 accepted for the selected provider
credential, and it is accepted explicitly; AGENTS.md's ADR 0039 statement
points to it at acceptance. The launcher disables crash dumps for `auth` as
it does for `ask`.

<a id="concept-adr-0073-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-compatibility).

Existing configuration files, `env` and `none` bindings, and the
`openai:`, `anthropic:`, `openrouter:` and `ollama:` routes are unchanged. The
configuration schema stays at version 1. The new forms are additive members
that a build without this decision refuses by name: a new provider name as an
unsupported provider, and an `oauth` credential on an existing route as an
invalid credential binding. No Core callback is
added; the Model callback admits one more closed reason before dispatch. The committed model already names its route. The one durable and wire
change is the new failure reason: the settled-attempt record admits its
category, the `loopex.experimental/3` and `/4` schemas and vectors list it,
and `loopex ask`'s `loopex.ask/1` result reports it as a failed outcome.
Before 1.0 only the current contract is kept, so no older reader is
supported.

Removing sign-in removes the `auth` command, the sign-in routes, the token
store code and the failure reason. Sessions whose committed model names a removed route refuse to
resume until the operator configures a supported route and switches model.
Tokens the store holds are revoked with `auth logout` before downgrade. They
can also be revoked from the provider's account settings.

<a id="concept-adr-0073-open"></a>
### Open for the Maintainer

Technical depth: [Verification items](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-verification).

1. **OpenAI client.** Sign in with ChatGPT issues each install its own client
   by dynamic registration. OpenAI's documentation offers this to open-source,
   locally run apps, and sends paid or hosted apps to an interest form. Confirm
   that Loopex registers this way, and approve the `agent_name_hint` it
   presents. If OpenAI requires a partner client, submit the interest form.
2. **Google client.** Create Loopex's Google OAuth desktop client in a Google
   Cloud project the maintainer owns, and decide when to pass verification for
   the `cloud-platform` scope. Until the app is verified, users see an
   unverified-app screen, it is capped at 100 users, and in Testing status its
   refresh tokens expire after 7 days. The `adc` source works without this
   client.
3. **Anthropic sanction.** Ask Anthropic whether it will sanction an OAuth
   client registration for Loopex, and on what terms. Until it does, `claude:`
   stays disabled.

Decided on 2026-10-13, and no longer open: the `chatgpt:` reply ceiling
(decision 9), the public failure reason (decision 10), and the numbering.
The sign-in outcome is M8 outcome 8, and its release lanes are
`real-sign-in-openai`, `real-sign-in-gemini` and `real-sign-in-anthropic`.
Items 1 to 3 remain maintainer actions with the providers. Closure needs
positive real sign-in proofs for OpenAI and Google only. A lane whose
provider client is missing is deferred only by the maintainer before the
closure candidate, and is then left out of that candidate's pinned case
list (D36). The disabled `claude:` route is proved by its tested refusal and
needs no deferral.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
