defmodule Loopex.AppServer.Policy.Ask do
  @moduledoc """
  ## Concept

  The host policy this server ships for an operator who wants to be asked,
  selected with `LOOPEX_POLICY=ask`.

  The first time a tool call reaches it there is no answer to read, so it defers
  with one bounded question offering two choices. Once an answer has committed,
  the same policy is asked again and decides on what that answer says.

  The wording and the two choice identifiers are product behaviour: a client
  renders the question it was given and sends back one of the identities the
  question offered, so changing either changes what every consumer sees. They
  are deliberately short and deliberately about the call rather than about any
  particular tool, because the decision request names the effect class and the
  arguments but not a tool name, and a question that guessed one would be wrong
  in the case that matters.

  ## Technical depth

  This is the shape accepted ADR 0024 exists for. An answer is an input to this
  decision and never the decision itself: the allow is minted here, by the host,
  after the answer committed, which is what makes the chain a client observes a
  real authorization rather than a relayed one.

  `expires_in_ms` is five minutes, because the answering party here is a person
  at a client rather than a program. It is a request, not the lifetime: the
  runtime fixes an absolute instant once, at the committed creation, as the
  earlier of five minutes from that instant and the run's own deadline, and
  every later owner reuses it.

  That instant survives a restart and is not extended by one. A recovered owner
  re-arms a still-pending question against the time remaining, so a server
  killed four minutes into a question and restarted three minutes later
  recovers a question whose instant has already passed: it expires at once, and
  the tool call it suspended is denied. A question that was already answered is
  not re-armed at all — it is owed a resumed evaluation instead, which is why an
  answer that committed before the loss is never overtaken by an expiry.

  A deferral reaching a caller that cannot hold a question open resolves to
  `interaction_unsupported` at the port, so selecting this policy for such a
  caller denies rather than silently allowing.
  """

  @behaviour Loopex.Policy

  @prompt "Allow this tool call?"
  @allow "allow"
  @deny "deny"
  @expires_in_ms 300_000

  @impl Loopex.Policy
  @spec decide(Loopex.Policy.request()) ::
          {:allow, nil} | {:deny, :policy_denied} | {:defer, map()}
  def decide(request) do
    case Map.get(request, :interaction_response) do
      nil ->
        {:defer,
         %{
           kind: :choice,
           prompt: @prompt,
           choices: [
             %{id: @allow, label: "Allow"},
             %{id: @deny, label: "Deny"}
           ],
           expires_in_ms: @expires_in_ms
         }}

      %{answer: %{choice_id: @allow}} ->
        {:allow, nil}

      # Concept: anything that is not the allow identity is a refusal.
      #
      # Technical depth: failing closed here is what keeps a malformed or
      # unexpected answer from reading as permission. The port would deny an
      # unrecognised return shape anyway; denying explicitly says why.
      _refused ->
        {:deny, :policy_denied}
    end
  end
end
