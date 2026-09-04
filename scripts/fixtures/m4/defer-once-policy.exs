defmodule LoopexM4GatePolicy do
  @moduledoc false

  def decide(request) when is_map(request) do
    case Map.get(request, :interaction_response) do
      nil ->
        {:defer,
         %{
           kind: "choice",
           prompt: "Allow the bounded M4 gate write?",
           choices: [
             %{id: "continue", label: "Continue"},
             %{id: "deny", label: "Deny"}
           ],
           expires_in_ms: 10_000
         }}

      response ->
        case get_in(response, [:answer, :choice_id]) do
          "continue" -> {:allow, nil}
          _ -> {:deny, :policy_denied}
        end
    end
  end

  def decide(_request), do: {:deny, :policy_unavailable}
end
