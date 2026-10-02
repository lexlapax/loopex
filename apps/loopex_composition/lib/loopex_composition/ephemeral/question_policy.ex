defmodule LoopexComposition.Ephemeral.QuestionPolicy do
  @moduledoc """
  ## Concept

  Refuses model questions for a one-shot host that cannot answer them while
  preserving that host's ordinary tool decisions.

  ## Technical depth

  The one-shot wrapper supplies the original policy through Core's private
  contextual port. Only the exact reviewed question generation is denied as
  interaction_unsupported. Every other request, including a resumed policy
  interaction, uses the unchanged callback and decision validator. No runtime
  gate or journaled callback context is introduced.
  """

  @behaviour Loopex.Policy

  @question_generation LoopexProtocol.ToolDefinition.generation(
                         LoopexProtocol.ToolDefinition.question_definition()
                       )

  @impl true
  def decide(_request), do: {:deny, :policy_unavailable}

  @impl true
  def decide(%{generation: @question_generation}, _policy),
    do: {:deny, :interaction_unsupported}

  def decide(request, policy),
    do: Loopex.Policy.evaluate_callback(policy, request, :admit_defer)
end
