defmodule LoopexCli.ProviderLaunchBuildTest do
  use ExUnit.Case, async: false

  @source Path.expand("../lib/provider_launch.ex", __DIR__)
  @fixture LoopexCli.ProviderLaunchBuildFixture
  @compile {:no_warn_undefined, @fixture}

  test "explicit build input changes invalidate compiled configuration without runtime discovery" do
    root =
      Path.join(System.tmp_dir!(), "loopex-launch-build-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    path = Path.join(root, "configuration.launch")
    previous = System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")

    on_exit(fn ->
      if previous,
        do: System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", previous),
        else: System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")

      :code.purge(@fixture)
      :code.delete(@fixture)
      File.rm_rf!(root)
    end)

    System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    compile_fixture()
    assert @fixture.options() == []
    refute @fixture.__mix_recompile__?()

    File.write!(path, "[{worker_path, <<\"/first/worker\">>}].\n")
    System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", path)
    assert @fixture.__mix_recompile__?()
    compile_fixture()
    assert @fixture.options() == [worker_path: "/first/worker"]
    refute @fixture.__mix_recompile__?()

    File.write!(path, "[{worker_path, <<\"/other/worker\">>}].\n")
    assert @fixture.__mix_recompile__?()
    compile_fixture()
    assert @fixture.options() == [worker_path: "/other/worker"]

    File.rm!(path)
    assert @fixture.options() == [worker_path: "/other/worker"]
    assert @fixture.__mix_recompile__?()

    System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    assert @fixture.__mix_recompile__?()
    compile_fixture()
    assert @fixture.options() == []
    refute @fixture.__mix_recompile__?()
  end

  defp compile_fixture do
    :code.purge(@fixture)
    :code.delete(@fixture)

    @source
    |> File.read!()
    |> String.replace("defmodule LoopexCli.ProviderLaunch do", "defmodule #{@fixture} do")
    |> Code.compile_string(@source)
  end
end
