defmodule LoopexCli.Policy.AllowAll do
  @moduledoc """
  ## Concept

  The permissive host policy this command ships, selected with
  `--policy allow-all`.

  It exists because the kernel refuses to run tools for a host that has named no
  authority, and an operator running `loopex` on their own machine has a real
  answer to that question. It says so out loud once rather than quietly behaving
  as though a decision had been made.

  ## Technical depth

  A second permissive policy alongside the reference client's is the honest
  consequence of the rule that a client may not depend on another client. Both
  are permission-granting modules an operator selects explicitly, both print the
  same single notice, and neither is ever an implicit fallback.

  The composition cannot supply one for either of them: it owns wiring and never
  authority, and a permissive default shipped there would be inherited by every
  embedder that depends on it.
  """

  @behaviour Loopex.Policy

  alias LoopexCli.Policy.Notice

  @notice "loopex: the allow-all host policy is active. " <>
            "This is permissive local authority, not a permission model: " <>
            "every tool call this session makes will be allowed."

  @doc """
  ## Concept

  The single notice this policy prints.

  ## Technical depth

  Exposed so the command can render it in its own transcript and its locked case
  can assert the exact text rather than a paraphrase.
  """
  @spec notice() :: binary()
  def notice, do: @notice

  @impl Loopex.Policy
  @spec decide(Loopex.Policy.request()) :: {:allow, nil}
  def decide(_request) do
    announce()
    {:allow, nil}
  end

  # Concept: once per VM, not once per call.
  #
  # Technical depth: a line per tool call would train an operator to skip it,
  # which is the opposite of what a notice is for. The shared notice helper
  # serializes the otherwise-racy persistent-term check and write.
  defp announce do
    Notice.once({__MODULE__, :announced}, fn -> IO.puts(:stderr, @notice) end)
  end
end
