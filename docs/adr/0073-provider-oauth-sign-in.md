<a id="concept"></a>
## Concept

Technical depth: [Provider sign-in contract, token store, refresh and evidence](0073-provider-oauth-sign-in-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-13
- **Decision owner:** Maintainer
- **Supersedes:** nothing on its own. On acceptance it amends named clauses of
  [ADR 0019](0019-host-owned-provider-protection.md#concept),
  [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept),
  [ADR 0039](0039-ephemeral-embedded-profile.md#concept) and
  [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept),
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
- **Prerequisite for:** the M8 provider sign-in outcome and workstream added by
  the maintainer on 2026-10-13

<a id="concept-adr-0073-decision"></a>
### Context and Decision

Technical depth: [Contract](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-decision).

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
   subscription-impersonation modes.
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
   private file in the Loopex home, readable only by its owner. Tokens live
   outside the state root, so backups never contain them. Tokens never enter
   journals, public events, progress, diagnostics, traces, fixtures, executor
   jobs or project resources.
6. **An access token travels exactly like an API key.** For each provider call
   the host resolves the current access token for the selected route. It
   passes the token over the existing private credential channel. The
   selected-credential echo guard, trace exclusion and cleanup proofs then
   apply unchanged, with the access token as the selected credential.
7. **The host refreshes, and refuses rather than guesses.** The process that
   holds the route refreshes the token before it expires. A lock serializes
   refreshes across every Loopex process that shares the home. A provider
   that rejects the refresh token leaves the route unusable. Its calls are
   then refused before dispatch, by name: sign-in required. Nothing falls back
   to another route or to an API key.
8. **Three commands manage sign-in.** `loopex auth login <provider>` opens a
   browser and receives the answer on a local loopback address. A headless
   host uses the provider's device flow where one exists; the companion
   explains why each provider has none today. `loopex auth status` reports
   which routes are signed in without reading a token. `loopex auth logout
   <provider>` revokes the token with the provider and removes it locally.

Alternatives are in the companion. The main one rejected is reusing a widely
deployed client identity, such as Codex CLI's or Claude Code's, which the
provider library ships with. That impersonates another product, can break
without notice, and for Anthropic contradicts the published terms.

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

A service holding a sign-in route keeps the token fresh while it runs. If the
operator signs out, or the provider revokes access, new calls on that route
fail before dispatch. The service records the reason in its own diagnostic
output, and `auth status` shows it. After the operator signs in again with
the same account, the service picks up the new token without a restart. A
different account needs a service restart, as replacing an API key does
today. A running call is never cut off or repeated because a token changed.

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
| 0019 | The sender passes a credential read from the environment | The credential may be a host-held access token. A new token-exchange invocation of the same companion carries a refresh token over the same private channel |
| 0034 | Custody holds one value bound at composition | Custody's existing rotation and expiry are used by a host refresher; the token, registry and sender rules are unchanged |
| 0039 | In the ephemeral profile, each hosted provider's key is read from its variable at the model boundary for each call | A sign-in route resolves from custody owned by the composition. A refresh in this profile runs in the host VM, under the same audience the profile already accepts |

The Proposed ADR 0037's sentence that file, keychain and command credentials
need a separate future decision is answered by this record, for sign-in tokens
only. Command credentials stay out. The M8 plan's non-goal "no file, keychain
or command credential source, and no live rotation" narrows to exclude sign-in
tokens and their refresh. The integrator edits both.

The vision already gives the host credential custody, including access
tokens, rotation and encryption. This record changes no vision principle.

<a id="concept-adr-0073-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-compatibility).

Existing configuration files, `env` and `none` bindings, and the
`openai:`, `anthropic:`, `openrouter:` and `ollama:` routes are unchanged. The
configuration schema stays at version 1. The new forms are additive members
that a build without this decision refuses by name. No durable record, wire
generation or Core callback changes. The committed model already names its
route.

Removing sign-in removes the `auth` command, the sign-in routes and the token
store code. Sessions whose committed model names a removed route refuse to
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
4. **OpenAI request limits.** A plan-billed request may not send
   `max_output_tokens` or system-role items. Choose whether Loopex enforces its
   reply ceiling by ending the stream once the ceiling is reached, or keeps
   `chatgpt:` out of roles that need a provider-enforced ceiling, such as the
   summarizer.
5. **Public failure reason.** Choose whether a refused sign-in call stays the
   fixed `model_call_failed` with a host diagnostic, or ADR 0029's bounded
   failure set gains a `provider_sign_in_required` reason with vectors.
6. **Outcome number.** The M8 outcome number and the release-lane names for
   each provider.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
