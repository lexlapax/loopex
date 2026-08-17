# M0 Provider Identity

Retained by the `M0` real-provider lane. Non-secret identity only: a credential
never appears here, and this file is not evidence that a call succeeded — it
records what was called so a reviewer can judge the claim.

Populated when outcome 7 first runs.

- provider: anthropic
- model: claude-haiku-4-5-20251001
- endpoint: https://api.anthropic.com
- recorded: 2026-08-17 on Elixir 1.20.3 / OTP 29.0.5, req_llm 1.20.0, usage input=16 output=6

The lane was verified to depend on `LOOPEX_PROVIDER_API_KEY` itself rather than on
a provider library's own credential lookup. That check mattered here: the
operator's environment file also carries `ANTHROPIC_API_KEY`, and ReqLLM's
dependency closure includes a dotenv reader, so a passing run could have proved
nothing about the variable the gate names. Running the lane with a deliberately
invalid `LOOPEX_PROVIDER_API_KEY` produced a real provider `401
authentication_error` rather than a silent success, which is what establishes that
the credential under test is the one that reached the provider. Running it with no
`LOOPEX_PROVIDER_API_KEY` failed as evidence unavailable rather than skipping.
