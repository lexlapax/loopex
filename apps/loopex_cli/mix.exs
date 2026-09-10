defmodule LoopexCli.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_cli,
      loopex_role: :client,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # The demonstration stack is a support module rather than a test file, and
      # without this the test loader warns that it matches no filter -- a warning
      # on every run of a checkpoint that is required to carry none.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      # The command an operator types is `loopex`. Without an explicit name the
      # escript takes the application's, and the documentation would be
      # describing a command that does not exist under that name.
      escript: [main_module: LoopexCli, name: :loopex],
      aliases: ["escript.build": [&build_pair/1]],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: []]

  defp build_pair(args) do
    root = Path.expand("../..", __DIR__)
    {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    adapter = Path.expand("../loopex_llm_reqllm", __DIR__)
    build_path = Mix.Project.build_path() |> Path.expand()
    elixir_bin = Path.expand("../../bin", List.to_string(:code.lib_dir(:elixir)))
    mix = Path.expand("../../bin/mix", List.to_string(:code.lib_dir(:mix)))
    command = Path.join(elixir_bin, "elixir")

    {output, status} =
      System.cmd(command, [mix, "loopex.provider.build" | args],
        cd: adapter,
        env: [
          {"MIX_ENV", Atom.to_string(Mix.env())},
          {"MIX_TARGET", Atom.to_string(Mix.target())},
          # Preserve the effective path across the child project's different
          # working directory, including a relative MIX_BUILD_ROOT override.
          {"MIX_BUILD_PATH", build_path},
          {"PATH",
           Path.join(List.to_string(:code.root_dir()), "bin") <>
             ":" <>
             System.get_env("PATH", "")},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil},
          {"OPENAI_API_KEY", nil}
        ],
        stderr_to_stdout: true
      )

    Mix.shell().info(output)
    unless status == 0, do: Mix.raise("provider companion build refused")
    configuration = Path.join(build_path, "loopex_provider.launch")
    previous = System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", configuration)

    try do
      # Concept: every command build embeds the configuration just emitted by
      # its companion build, including when Mix already compiled this project.
      # Technical depth: task discovery and earlier alias steps can mark each
      # compiler as complete. Reenable the entire compile chain before forcing
      # the environment-dependent ProviderLaunch module to read the new file.
      tasks = ["compile", "compile.all", "compile.protocols"]
      compilers = Mix.Project.config()[:compilers] || Mix.compilers()
      tasks = tasks ++ Enum.map(compilers, &"compile.#{&1}")
      Enum.each(tasks, &Mix.Task.reenable/1)
      Mix.Task.run("compile", ["--force", "--warnings-as-errors"])
      Mix.Tasks.Escript.Build.run([])

      {current_source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)

      {status, 0} =
        System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"], cd: root)

      unless source == current_source and status == "",
        do: Mix.raise("command source changed while building the provider pair")
    after
      if previous,
        do: System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", previous),
        else: System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    end
  end

  # Concept: the operator command is a client and a peer surface.
  #
  # Technical depth: it owns no loop, no durable session truth, no cursor truth,
  # no Store access, and no authority decision. It depends on the runtime for the
  # public facade and on exactly one composition for wiring, which is the whole
  # of what a client may declare in production.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_composition, in_umbrella: true}
    ]
  end
end
