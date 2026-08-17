defmodule Mix.Tasks.Loopex.DepsBudgetTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.DepsBudget

  @fixture "scripts/fixtures/deps-budget-invalid/mix.exs"

  setup do
    dir = Path.join(System.tmp_dir!(), "deps-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the repository satisfies the dependency budget and direction" do
    assert DepsBudget.check_repository(LoopexTest.Repo.root()) == :ok
  end

  test "a forbidden core dependency is rejected" do
    # The bound adversarial fixture declares app: :loopex with a provider
    # dependency, which the runtime application may never carry.
    fixture = Path.join(LoopexTest.Repo.root(), @fixture)
    assert File.exists?(fixture), "the bound fixture #{@fixture} is missing"
    assert {:error, reasons} = DepsBudget.check_mix_exs(fixture)
    assert Enum.any?(reasons, &String.contains?(&1, "req_llm"))
  end

  test "a reverse edge from contract to runtime is rejected", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "leak.ex"), """
    defmodule LoopexProtocol.Leak do
      def call, do: Loopex.version()
    end
    """)

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "runtime module Loopex"))
  end

  test "a dynamic module reference across the boundary is rejected", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    # No alias node names the runtime here, so an AST alias walk sees nothing.
    File.write!(Path.join(lib, "dynamic.ex"), """
    defmodule LoopexProtocol.Dynamic do
      def call, do: apply(String.to_atom("Elixir.Loopex"), :version, [])
    end
    """)

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "dynamic reference"))
  end

  # The reverse-edge scan is scoped to the contract application's lib directory,
  # so a fixture tree is exercised through the same code path by pointing the
  # scan at it rather than by duplicating the logic in the test.
  defp reverse_edges(lib) do
    case DepsBudget.reverse_edge_check(lib) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end
end
