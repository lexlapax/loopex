defmodule LoopexCli.M7AttemptHeadsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames, as: Frames
  alias Mix.Tasks.Loopex.M7Evidence.AttemptHeads, as: Heads

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  test "greatest sequence wins for every ordering and identical duplicates" do
    lines = [line("campaign", 2, @a), line("campaign", 10, @b), line("campaign", 1, @a)]

    for permutation <- permutations(lines) do
      text = "### Progress and Evidence\n" <> Enum.join(permutation, "\n") <> "\n"
      expected = %{"campaign_id" => "campaign", "sequence" => 10, "digest" => @b}
      assert Heads.select(text, "campaign") == {:ok, expected}
      assert Heads.select(text <> line("campaign", 10, @b), "campaign") == {:ok, expected}
    end
  end

  test "conflicting equal sequences refuse even below the greatest head" do
    for sequence <- [1, 10], order <- [false, true] do
      lines = [
        line("campaign", 10, @a),
        line("campaign", sequence, @a),
        line("campaign", sequence, @b)
      ]

      lines = if order, do: Enum.reverse(lines), else: lines

      assert Heads.select(Enum.join(lines, "\n"), "campaign") ==
               {:error, :conflicting_committed_attempt_heads}
    end
  end

  test "foreign campaign lines never select or conflict with the pinned campaign" do
    text =
      Enum.join(
        [
          line("previous", 100, @a),
          line("previous", 100, @b),
          "index-head: previous malformed",
          line("campaign-other", 500, @b),
          line("campaign", 3, @a)
        ],
        "\n"
      )

    assert Heads.select(text, "campaign") ==
             {:ok, %{"campaign_id" => "campaign", "sequence" => 3, "digest" => @a}}
  end

  test "every malformed relevant retained line refuses despite a valid greater head" do
    valid = line("campaign", 9, @a)

    for malformed <- [
          "index-head: campaign",
          "index-head: campaign 1",
          line("campaign", 0, @a),
          "index-head: campaign 01 " <> @a,
          "index-head: campaign -1 " <> @a,
          "index-head: campaign +1 " <> @a,
          "index-head: campaign 1.0 " <> @a,
          "index-head: campaign 1 " <> String.upcase(@a),
          "index-head: campaign 1 " <> String.duplicate("a", 63),
          "index-head: campaign 1 " <> String.duplicate("g", 64),
          "index-head: campaign 1 " <> @a <> " extra",
          " " <> line("campaign", 1, @a),
          line("campaign", 1, @a) <> " ",
          line("campaign", 1, @a) <> "\r",
          "index-head:  campaign 1 " <> @a,
          "index-head:campaign 1 " <> @a,
          "index-head:\tcampaign 1 " <> @a,
          "index-head: campaign\t1 " <> @a
        ],
        text <- [malformed <> "\n" <> valid, valid <> "\n" <> malformed] do
      assert Heads.select(text, "campaign") == {:error, :invalid_committed_attempt_head_line}
    end
  end

  test "missing current campaign head remains unavailable rather than trusting genesis" do
    for text <- ["", "ordinary prose", line("previous", 99, @a)] do
      assert Heads.select(text, "campaign") == {:error, :committed_attempt_head_unavailable}
    end

    assert Heads.verify("ordinary prose", "campaign", nil) ==
             {:error, :committed_attempt_head_unavailable}
  end

  test "invalid arguments and invalid UTF-8 refuse without interpreting text" do
    for {text, campaign} <- [
          {nil, "campaign"},
          {<<255>>, "campaign"},
          {"", nil},
          {"", ""},
          {"", <<255>>},
          {"", "two words"},
          {"", " campaign"},
          {"", "campaign\n"}
        ] do
      assert Heads.select(text, campaign) == {:error, :invalid_committed_attempt_head_lines}
    end
  end

  test "large decimal sequences retain precision and campaign tokens retain UTF-8" do
    sequence = 18_446_744_073_709_551_616

    assert Heads.select(line("猫", sequence, @a), "猫") ==
             {:ok, %{"campaign_id" => "猫", "sequence" => sequence, "digest" => @a}}
  end

  test "selected anchor admits its exact prefix and extensions but refuses stale fork and foreign chains" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{"value" => "original"})
    {:ok, third, three} = Frames.encode("campaign", 3, two["digest"], %{})
    {:ok, fork, changed} = Frames.encode("campaign", 2, one["digest"], %{"value" => "changed"})
    {:ok, fork_tail, _} = Frames.encode("campaign", 3, changed["digest"], %{})
    {:ok, foreign, _} = Frames.encode("previous", 1, nil, %{})
    text = line("campaign", 2, two["digest"]) <> "\n" <> line("campaign", 1, one["digest"])

    assert Heads.verify(text, "campaign", first <> second) == {:ok, head(two)}
    assert Heads.verify(text, "campaign", first <> second <> third) == {:ok, head(three)}

    for bytes <- [first, first <> fork <> fork_tail, foreign] do
      assert Heads.verify(text, "campaign", bytes) == {:error, :committed_attempt_head_mismatch}
    end

    assert Heads.verify(text, "campaign", nil) == {:error, :attempt_index_unavailable}
    assert Heads.verify(text, "campaign", "") == {:error, :empty_attempt_chain}
  end

  test "a selected anchor never hides an unresolved tail or corrupted chain" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, _} = Frames.encode("campaign", 2, one["digest"], %{})
    text = line("campaign", 1, one["digest"])
    tail = String.trim_trailing(second, "\n")

    assert Heads.verify(text, "campaign", first <> tail) ==
             {:error, {:incomplete_attempt_append, head(one), tail}}

    assert Heads.verify(text, "campaign", first <> first) == {:error, :invalid_attempt_chain}
  end

  defp line(campaign, sequence, digest), do: "index-head: #{campaign} #{sequence} #{digest}"
  defp head(record), do: Map.take(record, ~w(campaign_id sequence digest))
  defp permutations([]), do: [[]]

  defp permutations(values),
    do: for(value <- values, tail <- permutations(values -- [value]), do: [value | tail])
end
