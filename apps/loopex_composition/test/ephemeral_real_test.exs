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
    token = "M6_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    File.write!(Path.join(root, "answer.txt"), token)

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: Loopex.LLM.ReqLLM.default_model(),
               cwd: root,
               tools: :read_only,
               max_tokens: 256,
               deadline_ms: 120_000,
               timeout: 150_000
             )

    assert {:ok,
            %{
              outcome: :completed,
              profile: :ephemeral,
              text: text,
              tools: tools
            }} =
             Ephemeral.ask(
               session,
               "Call loopex.read once with path answer.txt. Do not use another tool. " <>
                 "Then answer with the exact file contents. The contents are not in this prompt; do not guess."
             )

    assert [%{tool_id: "loopex.read", outcome: "completed"}] = tools
    assert String.contains?(text, token)

    assert {:ok, %{entries: entries, truncated: false}} = Ephemeral.history(session)

    tool_index =
      Enum.find_index(entries, &match?(%{role: :tool, tool_id: "loopex.read"}, &1))

    answer_index =
      Enum.find_index(entries, fn
        %{role: :assistant, text: answer} -> String.contains?(answer, token)
        _entry -> false
      end)

    assert is_integer(tool_index) and is_integer(answer_index) and tool_index < answer_index

    assert :ok = Ephemeral.stop_session(session)
    IO.puts(:stderr, "loopex M6 embedded hosted tool turn completed with proved cleanup")
  end
end
