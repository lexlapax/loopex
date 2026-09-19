defmodule Loopex.AppServer.Policy.AllowAll do
  @moduledoc """
  ## Concept

  The permissive host policy this server ships, selected with
  `LOOPEX_POLICY=allow-all`.

  It exists because the kernel refuses to run tools for a host that has named no
  authority, and an operator running this server on their own machine has a real
  answer to that question. It says so out loud once rather than quietly behaving
  as though a decision had been made.

  ## Technical depth

  A third permissive policy alongside the command's and the reference client's
  is the honest consequence of the rule that a client may not depend on another
  client. All three are permission-granting modules an operator selects
  explicitly, all three print the same single notice, and none is ever an
  implicit fallback.

  The composition cannot supply one for any of them: it owns wiring and never
  authority, and a permissive default shipped there would be inherited by every
  embedder that depends on it.
  """

  @behaviour Loopex.Policy

  @notice "loopex app-server: the allow-all host policy is active. " <>
            "This is permissive local authority, not a permission model: " <>
            "every tool call this session makes will be allowed."
  @notice_table Loopex.AppServer.Policy.AllowAll.Notices

  @doc """
  ## Concept

  The single notice this policy prints.

  ## Technical depth

  Exposed so a case can assert the exact text rather than a paraphrase of it.
  """
  @spec notice() :: binary()
  def notice, do: @notice

  @impl Loopex.Policy
  @spec decide(Loopex.Policy.request()) :: {:allow, nil}
  def decide(_request) do
    announce()
    {:allow, nil}
  end

  # Concept: once per virtual machine, not once per call.
  #
  # Technical depth: a line per tool call would train an operator to skip it,
  # which is the opposite of what a notice is for. A named ETS set gives one
  # atomic first insertion rather than a racy read-then-write, and the init
  # process inherits the table so a short-lived first caller cannot take the
  # announcement state with it.
  defp announce do
    if :ets.insert_new(notice_table(), {:announced, true}), do: IO.puts(:stderr, @notice)
    :ok
  end

  defp notice_table do
    case :ets.whereis(@notice_table) do
      :undefined ->
        try do
          :ets.new(@notice_table, [
            :named_table,
            :public,
            :set,
            {:heir, Process.whereis(:init), :loopex_notice_table}
          ])
        rescue
          ArgumentError -> @notice_table
        end

      table ->
        table
    end
  end
end
