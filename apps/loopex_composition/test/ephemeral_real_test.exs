defmodule LoopexComposition.Ephemeral.RealTest do
  @moduledoc """
  ## Concept

  The release lane proves that the embedded API completes a hosted model turn
  through its in-VM provider path and proves teardown before returning.

  ## Technical depth

  The release wrapper supplies only ANTHROPIC_API_KEY to this process. This
  test neither copies nor prints that value. A fresh temporary workspace and
  a non-writing tool preset keep the call independent of user state.
  """

  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  @tag :real_provider
  @tag timeout: 180_000
  test "the embedded API answers in-process from Anthropic with the release credential" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-m6-embedded-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: Loopex.LLM.ReqLLM.default_model(),
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               deadline_ms: 90_000,
               timeout: 120_000
             )

    assert {:ok,
            %{
              outcome: :completed,
              profile: :ephemeral,
              text: text,
              tools: tools
            }} = Ephemeral.ask(session, "Answer in one short sentence: what is two plus two?")

    assert :ok = Ephemeral.stop_session(session)

    assert is_binary(text) and String.trim(text) != ""
    assert is_list(tools)
    IO.puts(:stderr, "loopex M6 embedded hosted model completed with proved session cleanup")
  end
end
