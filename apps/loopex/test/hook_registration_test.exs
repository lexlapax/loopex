defmodule Loopex.HookRegistrationTest do
  @moduledoc """
  ## Concept

  Proves the registration check rejects the two defects a text search cannot see:
  a hook registered under the wrong event, and a hook registered with the wrong
  matcher. Both leave every event name, matcher, and script name present in the
  file, so searching for each independently would report success while the hook
  never ran where it was needed.

  ## Technical depth

  Each case starts from the repository's own configuration and moves exactly one
  thing, so the case fails for the reason it names rather than because a
  hand-written fixture was incomplete. The unmodified configuration is asserted to
  pass first, which is what makes the mutations meaningful.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.HookRegistration

  setup do
    path = Path.join(LoopexTest.Repo.root(), ".claude/settings.json")
    {:ok, settings: File.read!(path)}
  end

  test "the repository configuration registers every hook correctly", %{settings: settings} do
    assert [] == HookRegistration.check_settings(settings)
  end

  test "a hook registered under the wrong event is rejected", %{settings: settings} do
    # The two event blocks trade places, so after-edit.sh is registered under
    # PreToolUse and the two guards under PostToolUse. Every event name, matcher,
    # and script name is still present in the file and the JSON is still valid;
    # only which event runs which hook has changed.
    moved =
      settings
      |> String.replace("\"PreToolUse\": [", "\"TradedEvent\": [")
      |> String.replace("\"PostToolUse\": [", "\"PreToolUse\": [")
      |> String.replace("\"TradedEvent\": [", "\"PostToolUse\": [")

    assert moved != settings
    reasons = HookRegistration.check_settings(moved)

    assert reasons != []
    assert Enum.any?(reasons, &(&1 =~ "after-edit.sh"))
    assert Enum.any?(reasons, &(&1 =~ "guard-bash.sh"))
  end

  test "a hook registered with the wrong matcher is rejected", %{settings: settings} do
    # The filesystem guard keeps its event and its script name, and loses one tool
    # from its matcher.
    narrowed =
      String.replace(
        settings,
        "\"matcher\": \"Read|Grep|Glob|Edit|Write|NotebookEdit\"",
        "\"matcher\": \"Read|Grep|Glob|Edit|Write\""
      )

    assert narrowed != settings
    reasons = HookRegistration.check_settings(narrowed)

    assert reasons != []
    assert Enum.any?(reasons, &(&1 =~ "guard-filesystem.sh"))
  end

  test "two hooks swapped between event blocks are rejected", %{settings: settings} do
    # The defect a per-name search cannot see: both scripts are present, both
    # events are present, and both matchers are present.
    swapped =
      settings
      |> String.replace("guard-bash.sh", "PLACEHOLDER")
      |> String.replace("guard-filesystem.sh", "guard-bash.sh")
      |> String.replace("PLACEHOLDER", "guard-filesystem.sh")

    reasons = HookRegistration.check_settings(swapped)

    assert reasons != []
    assert Enum.any?(reasons, &(&1 =~ "guard-bash.sh"))
    assert Enum.any?(reasons, &(&1 =~ "guard-filesystem.sh"))
  end

  test "an unreadable or malformed configuration is a violation, not a skip" do
    assert ["" <> _reason] = HookRegistration.check_settings("{\"hooks\": ")
    assert ["" <> _missing] = HookRegistration.check_settings("{}")
    assert ["" <> _shape] = HookRegistration.check_settings("[]")
  end
end
