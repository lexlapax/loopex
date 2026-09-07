defmodule Loopex.LLM.ReqLLM.ProviderBuildTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Loopex.Provider.Build
  alias Loopex.LLM.ReqLLM.ProviderConfiguration

  @identity "Elixir.Loopex.LLM.ReqLLM.ProviderBuildIdentity.beam"

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-provider-build-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "archive identity covers actual paths and bytes in both supported layouts", %{root: root} do
    for identity <- [@identity, "loopex_llm_reqllm/ebin/" <> @identity] do
      entries = [
        {identity, "generated identity"},
        {"nil_escript.beam", "compiled bootstrap and configuration"},
        {"a/priv/data", "first payload"},
        {"b/priv/data", "second payload"}
      ]

      worker = archive!(root, entries)
      baseline = Build.packaged_input_digest(worker)

      assert baseline == expected_digest(tl(entries))
      assert baseline == Build.packaged_input_digest(archive!(root, Enum.reverse(entries)))

      assert baseline ==
               Build.packaged_input_digest(
                 archive!(root, List.keyreplace(entries, identity, 0, {identity, "new identity"}))
               )

      for change <- [
            {"nil_escript.beam", "different embedded configuration"},
            {"a/priv/data", "changed first payload"},
            {"b/priv/data", "changed second payload"}
          ] do
        changed = archive!(root, List.keyreplace(entries, elem(change, 0), 0, change))
        refute Build.packaged_input_digest(changed) == baseline

        assert_raise Mix.Error, ~r/packaged inputs changed/, fn ->
          Build.verify_packaged_input!(changed, baseline)
        end
      end

      moved = List.keyreplace(entries, "b/priv/data", 0, {"c/priv/data", "second payload"})
      refute Build.packaged_input_digest(archive!(root, moved)) == baseline

      shadow = entries ++ [{"other/priv/" <> @identity, "ordinary archived input"}]
      refute Build.packaged_input_digest(archive!(root, shadow)) == baseline
    end
  end

  test "missing or ambiguous build identity refuses", %{root: root} do
    for entries <- [
          [{"other.beam", "not an identity"}],
          [{@identity, "one"}, {"loopex_llm_reqllm/ebin/" <> @identity, "two"}],
          [{@identity, "one"}, {"duplicate", "first"}, {"duplicate", "second"}]
        ] do
      worker = archive!(root, entries)

      assert_raise Mix.Error, ~r/ambiguous paths or build identity/, fn ->
        Build.packaged_input_digest(worker)
      end
    end

    invalid = Path.join(root, "invalid")
    File.write!(invalid, "not an escript")

    assert_raise Mix.Error, ~r/readable archive/, fn -> Build.packaged_input_digest(invalid) end
  end

  test "dirty source and compilation bypasses refuse before building", %{root: root} do
    adapter = Path.join(root, "apps/loopex_llm_reqllm")
    File.mkdir_p!(adapter)

    File.write!(Path.join(adapter, "mix.exs"), """
    defmodule Loopex.ProviderBuildRefusalFixture do
      use Mix.Project
      def project, do: [app: :loopex_llm_reqllm, version: "0.0.0"]
    end
    """)

    {_, 0} = System.cmd("git", ["init", "--quiet", root])

    Mix.Project.in_project(:provider_build_refusal_fixture, adapter, fn _project ->
      assert_raise Mix.Error, ~r/clean source checkout/, fn -> Build.run([]) end

      for args <- [["--no-compile"], ["--no-deps-check"], ["--no-warnings-as-errors"]] do
        assert_raise Mix.Error, ~r/accepts only/, fn -> Build.run(args) end
      end
    end)

    refute File.exists?(Path.join(root, "_build"))
  end

  test "external artifact digest refuses a changed executable even if inputs match", %{root: root} do
    worker = archive!(root, [{@identity, "first identity"}, {"code.beam", "unchanged"}])
    inputs = Build.packaged_input_digest(worker)
    {:ok, digest} = ProviderConfiguration.file_digest(worker)
    interpreter = Path.join(List.to_string(:code.root_dir()), "bin/escript")

    configuration = %{worker_path: worker, interpreter_path: interpreter, worker_sha256: digest}
    assert :ok = ProviderConfiguration.verify_artifact(configuration)

    archive!(root, [{@identity, "different identity"}, {"code.beam", "unchanged"}])
    assert :ok = Build.verify_packaged_input!(worker, inputs)

    assert {:error, :provider_artifact_unavailable} =
             ProviderConfiguration.verify_artifact(configuration)
  end

  defp archive!(root, entries) do
    worker = Path.join(root, "loopex_provider")
    entries = Enum.map(entries, fn {path, bytes} -> {String.to_charlist(path), bytes} end)

    :ok =
      :escript.create(String.to_charlist(worker), [
        :shebang,
        {:archive, entries, []}
      ])

    worker
  end

  defp expected_digest(entries) do
    entries
    |> Enum.map(fn {path, bytes} -> {path, sha256(bytes)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
