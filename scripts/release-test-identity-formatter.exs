defmodule LoopexReleaseTestIdentityFormatter do
  @moduledoc """
  ## Concept

  Retain the identity of the ExUnit test that actually ran in a release lane.

  ## Technical depth

  The release runner creates a private, empty sidecar before starting Mix.
  ExUnit sends completion events for excluded and skipped cases too. At suite
  completion this formatter records only cases that actually ran, including
  failures, with their case, name, source location, release tag, and success
  state. The runner requires one exact record matching its source definition.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    path = System.fetch_env!("LOOPEX_RELEASE_TEST_IDENTITY_PATH")
    {:ok, %{path: path, tests: []}}
  end

  @impl true
  def handle_cast({:test_finished, test}, state) do
    case test.state do
      {kind, _reason} when kind in [:excluded, :skipped] -> {:noreply, state}
      _ -> {:noreply, %{state | tests: [test | state.tests]}}
    end
  end

  def handle_cast({:suite_finished, _times}, state) do
    records = state.tests |> Enum.reverse() |> Enum.map(&record/1)
    File.write!(state.path, records)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp record(test) do
    [
      Atom.to_string(test.case),
      Atom.to_string(test.name),
      Path.expand(test.tags[:file]),
      Integer.to_string(test.tags[:line]),
      to_string(test.tags[:real_provider] == true),
      to_string(is_nil(test.state))
    ]
    |> Enum.join("\t")
    |> Kernel.<>("\n")
  end
end
