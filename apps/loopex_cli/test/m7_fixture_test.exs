defmodule LoopexCli.M7FixtureTest do
  use ExUnit.Case, async: false

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "loopex-m7-oracle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "repair oracle rejects the seeded empty-ledger bug and accepts the bounded repair", %{
    root: root
  } do
    workspace = copy_fixture(root, "repair")
    assert {output, 2} = oracle("repair", workspace)
    assert output =~ "empty ledger totals zero"

    File.write!(
      Path.join(workspace, "lib/ledger.ex"),
      "defmodule Ledger do\n  def total(entries), do: Enum.sum(entries)\nend\n"
    )

    assert {_, 0} = oracle("repair", workspace)
  end

  test "feature oracle independently checks each chosen default and both explicit modes", %{
    root: root
  } do
    workspace = copy_fixture(root, "feature")
    assert {output, 2} = oracle("feature", workspace, [{"M7_NIL_DEFAULT", "empty"}])
    assert output =~ "selected nil default"

    for {mode, default} <- [{"empty", ":empty"}, {"literal_null", ":literal_null"}] do
      source = """
      defmodule RowEncoder do
        def encode(values, options \\\\ []) do
          mode = Keyword.get(options, :nil_mode, #{default})
          Enum.map_join(values, ",", fn
            nil -> if mode == :empty, do: "", else: "null"
            value -> to_string(value)
          end)
        end
      end
      """

      File.write!(Path.join(workspace, "lib/row_encoder.ex"), source)
      assert {_, 0} = oracle("feature", workspace, [{"M7_NIL_DEFAULT", mode}])
      other = if mode == "empty", do: "literal_null", else: "empty"
      assert {_, 2} = oracle("feature", workspace, [{"M7_NIL_DEFAULT", other}])
    end
  end

  test "review oracle requires the exact finding and leaves the seeded workspace unchanged", %{
    root: root
  } do
    workspace = copy_fixture(root, "review")
    before = workspace_bytes(workspace)
    finding = Path.join(root, "finding.tsv")

    File.write!(
      finding,
      "file\tfunction\tdefect_code\tcall_chain\nlib/fees.ex\ttotal/2\tduplicate_fee\tCheckout.quote/2>Invoice.total/2>Fees.total/2\n"
    )

    assert {_, 0} = oracle("review", workspace, [{"M7_FINDING", finding}])
    assert workspace_bytes(workspace) == before

    File.write!(
      finding,
      "file\tfunction\tdefect_code\tcall_chain\nlib/fees.ex\ttotal/2\tduplicate_fee\tFees.total/2\n"
    )

    assert {_, 2} = oracle("review", workspace, [{"M7_FINDING", finding}])
    assert workspace_bytes(workspace) == before
  end

  test "long-conversation oracle checks actual files against the early facts", %{root: root} do
    workspace = copy_fixture(root, "long")
    assert {_, 2} = oracle("long", workspace)
    File.write!(Path.join(workspace, "release.txt"), "amber\n")
    File.write!(Path.join(workspace, "batches.txt"), "amber-001\namber-002\namber-003\n")
    assert {_, 0} = oracle("long", workspace)
    File.write!(Path.join(workspace, "release.txt"), "blue\n")
    assert {_, 2} = oracle("long", workspace)
  end

  defp copy_fixture(root, name) do
    workspace = Path.join(root, name)
    File.cp_r!(Path.join([@fixtures, name, "workspace"]), workspace)
    workspace
  end

  defp oracle(name, workspace, env \\ []) do
    System.cmd("elixir", [Path.join([@fixtures, name, "oracle.exs"])],
      env: [{"M7_WORKSPACE", workspace} | env],
      stderr_to_stdout: true
    )
  end

  defp workspace_bytes(workspace) do
    workspace
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, workspace), File.read!(&1)})
  end
end
