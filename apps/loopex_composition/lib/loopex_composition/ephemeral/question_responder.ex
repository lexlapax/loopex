defmodule LoopexComposition.Ephemeral.QuestionResponder do
  @moduledoc """
  ## Concept

  A host answers one model question in a separate temporary worker. Its input
  contains only the bounded question, and its answer grants no tool authority.

  ## Technical depth

  The session owner supervises and monitors this worker before granting its
  exact reference permission to invoke the callback. Results bind that reference
  and the private runtime generation. Callback failures become responder_failed
  without exception detail. A result is evidence only: the owner must join the
  exact worker and validate the current interaction before submitting an answer.
  Caller expiry, abort and cleanup remain the session owner's responsibility.
  """

  @uint64_max 18_446_744_073_709_551_615
  @keys ~w(interaction_id prompt kind choices expires_at)

  @doc false
  def question(%{"producer" => "model_tool", "status" => "pending"} = question) do
    dto = Map.take(question, @keys)

    with id when is_binary(id) <- dto["interaction_id"],
         true <- byte_size(id) in 1..256 and String.valid?(id),
         expiry when is_integer(expiry) <- dto["expires_at"],
         true <- expiry >= 0 and expiry <= @uint64_max,
         {:ok, _request} <- request(dto) do
      {:ok, dto}
    else
      _ -> {:error, :responder_failed}
    end
  end

  def question(_question), do: {:error, :responder_failed}

  @doc false
  def start_link(owner, generation, reference, callback, dto)
      when is_pid(owner) and is_reference(generation) and is_reference(reference) and
             is_function(callback, 1) do
    with true <- is_map(dto) and map_size(dto) == 5,
         {:ok, ^dto} <-
           question(Map.merge(dto, %{"producer" => "model_tool", "status" => "pending"})) do
      Task.start_link(fn ->
        receive do
          {^owner, ^generation, ^reference, :execute} ->
            result = invoke(callback, dto)
            send(owner, {self(), generation, reference, :question_response, result})
        end
      end)
    else
      _ -> {:error, :responder_failed}
    end
  end

  defp invoke(callback, dto) do
    with {:ok, request} <- request(dto) do
      try do
        response = callback.(dto)

        with {:ok, answer} <- response(response),
             {:ok, _validated} <- Loopex.Interaction.model_answer(request, answer) do
          {:ok, response}
        else
          _ -> {:error, :responder_failed}
        end
      rescue
        _ -> {:error, :responder_failed}
      catch
        _, _ -> {:error, :responder_failed}
      end
    end
  end

  defp response({:text, text}), do: {:ok, %{"text" => text}}
  defp response({:choice, id}), do: {:ok, %{"choice_id" => id}}
  defp response(:decline), do: {:ok, %{"disposition" => "declined"}}
  defp response(_), do: {:error, :responder_failed}

  # Concept: the callback sees the same exact choices the model question offered.
  # Technical depth: reconstruct the canonical question through the existing
  # port validator, including generated choice IDs. Extra choice members or a
  # substituted kind cannot turn a policy interaction into a model answer.
  defp request(%{"kind" => kind, "choices" => choices, "prompt" => prompt} = dto)
       when kind in ["text", "choice"] and is_list(choices) and map_size(dto) == 5 do
    with true <- Enum.all?(choices, &(is_map(&1) and Enum.sort(Map.keys(&1)) == ~w(id label))),
         labels = Enum.map(choices, & &1["label"]),
         arguments =
           if(kind == "text",
             do: %{"question" => prompt},
             else: %{"question" => prompt, "choices" => labels}
           ),
         {:ok, request} <- Loopex.Interaction.model_request(arguments),
         true <- Atom.to_string(request.kind) == kind,
         true <- Enum.map(request.choices, &%{"id" => &1.id, "label" => &1.label}) == choices do
      {:ok, request}
    else
      _ -> {:error, :responder_failed}
    end
  end

  defp request(_dto), do: {:error, :responder_failed}
end
