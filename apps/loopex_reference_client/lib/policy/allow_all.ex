defmodule Loopex.ReferenceClient.Policy.AllowAll do
  @moduledoc """
  ## Concept

  A host policy that allows everything, shipped so the reference client has
  something to name.

  This is permissive local authority, not a permission model. It exists because
  the kernel refuses to run tools for a host that has named no authority at all,
  and a reference client running on a developer's own machine has a real answer
  to that question: yes, on my machine, to my own files. It says so out loud once
  per VM rather than quietly behaving as though a decision had been made.

  It ships here, in a client, and deliberately not in core and not in an edge. A
  permissive default inside the kernel would be inherited by every host that
  forgot to think about authority; inside an edge it would be inherited by the
  first isolated or remote hand that reused that edge. Here it is inherited by
  nobody: a host that wants it must name it.

  ## Technical depth

  Implements `Loopex.Policy.decide/1` and returns `{:allow, nil}` for every
  request. `nil` is a complete decision context — this policy has nothing to say
  about a call beyond permitting it, and inventing a `decision_ref` would imply a
  decision record that does not exist.

  The notice is emitted once per VM rather than once per call, because a
  line per tool call would train an operator to ignore it, which is the opposite
  of what a notice is for. It is emitted at first decision rather than at load,
  so a module that is compiled but never selected stays silent.
  """

  @behaviour Loopex.Policy

  @notice "loopex: the allow-all host policy is active. " <>
            "This is permissive local authority, not a permission model: " <>
            "every tool call this session makes will be allowed."
  @notice_key {__MODULE__, :announced}

  @doc """
  ## Concept

  The single notice this policy prints.

  ## Technical depth

  Exposed so a client can render it in its own transcript and so its locked case
  can assert the exact text rather than a paraphrase of it.
  """
  @spec notice() :: binary()
  def notice, do: @notice

  @impl Loopex.Policy
  @spec decide(Loopex.Policy.request()) :: {:allow, nil}
  def decide(_request) do
    announce()
    {:allow, nil}
  end

  # Concept: say it once, to whoever is listening.
  #
  # Technical depth: persistent_term retains the VM-wide fact independently of
  # caller lifetime. A local global transaction serializes its check and write;
  # each calling process is a distinct requester for the same notice resource.
  # No ETS ownership is transferred to init when the first caller exits.
  defp announce do
    if :persistent_term.get(@notice_key, false) do
      :ok
    else
      case :global.trans({{__MODULE__, :notice}, self()}, &announce_under_lock/0, [node()]) do
        :ok -> :ok
        aborted -> raise "policy notice lock failed: #{inspect(aborted)}"
      end
    end
  end

  defp announce_under_lock do
    unless :persistent_term.get(@notice_key, false) do
      IO.puts(:stderr, @notice)
      :persistent_term.put(@notice_key, true)
    end

    :ok
  end

  @doc false
  @spec reset_notice_for_test() :: :ok
  def reset_notice_for_test do
    :persistent_term.erase(@notice_key)
    :ok
  end
end
