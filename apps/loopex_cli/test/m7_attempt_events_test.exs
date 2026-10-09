defmodule LoopexCli.M7AttemptEventsTest do
  use ExUnit.Case, async: true

  alias LoopexCli.ConfigJson
  alias Mix.Tasks.Loopex.M7Evidence.AttemptEvents, as: Events
  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames, as: Frames

  # Concept: These eleven synthetic records are independent codec examples.
  # Technical depth: Literal unsigned bytes and SHA-256 come from accepted
  # ADR 0057, recomputed with Python stdlib without importing this codec.
  @vectors [
    {~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}|,
     "d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826"},
    {~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5"},
    {~S|{"body":{"destination_host_id":"host-2","destination_writer_id":"writer-2","handoff_id":"handoff-1","host_id":"host-1","kind":"writer_relinquished","ownership_epoch":1,"preceding_head":{"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":1},"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "285463e0818ca08fdedd7b9982a730ef988e91be5836a0db538e4f45967e4f92"},
    {~S|{"body":{"handoff_id":"handoff-1","host_id":"host-2","kind":"writer_accepted","ownership_epoch":2,"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"relinquishment_head":{"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":1},"source_host_id":"host-1","source_ownership_epoch":1,"source_revocation":{"reference":"/evidence/m7/revocation.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"source_writer_id":"writer-1","transfer":{"reference":"/evidence/m7/transfer.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-2"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "d2c5f982622c28b46a1648d0b9c7df6017395ccd23c78bcaae14586725c91462"},
    {~S|{"body":{"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"host_id":"host-1","kind":"campaign_succession","ownership_epoch":1,"predecessor_head":{"campaign_id":"m7-predecessor","digest":"0000000000000000000000000000000000000000000000000000000000000000","sequence":9},"prior_rows":{"reference":"/evidence/m7/prior-rows.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"unavailable_interval":{"reference":"/evidence/m7/lost-interval.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "bdaf0d9d78dbb747b7387d9ded9ffab601df8527d5ac4f9e16c48f504a3db033"},
    {~S|{"body":{"attempt_id":null,"authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/preflight.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":null,"manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"evidence_incomplete_pre_dispatch","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"not_dispatched","subcase_key":null,"verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "7cb3e21266e5c4ec45b1f9a57c54f9b1cc53b6d52205ce28fdc0b6bffccddda9"},
    {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "7bb7ac0cb7333a66833516619eee03250280729058164bf0b29ac54e33d595d5"},
    {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "5628498f4787d5084a5c6432f1fd2347462de02fe3475f91ecd06169e36dff6e"},
    {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "ff16d18d75a9a27f1a43a73167ce6c1226c4e2cc8e4be0e751fb55c9f2ea3b1d"},
    {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "11241759f571d3d4e579dd66ebfc6e7937175cb9e23c471fc8d06abb0677d16b"},
    {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":{"reference":"/evidence/m7/authorization.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"authorized_candidate_sha":"2222222222222222222222222222222222222222","candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"authorized_next_candidate","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
     "6a668940882a3289b48ecbf8167155d87d84fa042cce42a75bbc8b29f05c8232"}
  ]

  for {{preimage, digest}, index} <- Enum.with_index(@vectors, 1) do
    test "ADR 0057 literal independent vector #{index} fixes the complete canonical record" do
      preimage = unquote(preimage)
      digest = unquote(digest)
      assert Base.encode16(:crypto.hash(:sha256, preimage), case: :lower) == digest
      assert {:ok, unsigned} = ConfigJson.decode(preimage)

      expected =
        String.replace(
          preimage,
          ~s("campaign_id":"m7-vector","previous_digest"),
          ~s("campaign_id":"m7-vector","digest":"#{digest}","previous_digest")
        )

      assert {:ok, line, record} = encode(unsigned)
      assert line == expected <> "\n"
      assert record == Map.put(unsigned, "digest", digest)
      assert {:ok, ^record} = Events.decode(expected)
    end
  end

  test "every variant is closed and all required nullable members remain required" do
    for index <- 0..10 do
      original = vector(index)
      body = original["body"]
      rejects(Map.put(original, "body", Map.put(body, "unknown", nil)))

      for key <- Map.keys(body) do
        rejects(Map.put(original, "body", Map.delete(body, key)))
      end
    end
  end

  test "current kinds and integer versions have no aliases or fallback" do
    for index <- 0..10, version <- [nil, 0, 2, 1.0, true, "1"] do
      rejects(put_in(vector(index), ["body", "version"], version))
    end

    for kind <- [nil, "Case", "case_started", "writer", "unknown", :genesis] do
      rejects(put_in(vector(0), ["body", "kind"], kind))
    end

    rejects(put_in(vector(0), ["body", "codec_version"], 1.0))
    rejects(put_in(vector(0), ["body", "codec_version"], 2))
  end

  test "identities count UTF-8 bytes and exclude controls and invalid encoding" do
    good = String.duplicate("猫", 85) <> "x"
    assert byte_size(good) == 256

    for field <- ~w(writer_id host_id lane_id logical_matrix_id case_key subcase_key attempt_id) do
      assert {:ok, _, _} = encode(put_in(vector(6), ["body", field], good))

      for bad <- ["", good <> "x", <<255>>, "x\n", "x\t", "x\0", "x" <> <<127>>, :opaque, 1] do
        rejects(put_in(vector(6), ["body", field], bad))
      end
    end

    for {index, fields} <- [
          {1, ~w(writer_id host_id)},
          {2, ~w(destination_writer_id destination_host_id handoff_id)},
          {3, ~w(source_writer_id source_host_id handoff_id)}
        ],
        field <- fields do
      assert {:ok, _, _} = encode(put_in(vector(index), ["body", field], good))

      for bad <- ["", good <> "x", "x" <> <<127>>, <<255>>] do
        rejects(put_in(vector(index), ["body", field], bad))
      end
    end

    assert {:ok, _, _} =
             encode(put_in(vector(4), ["body", "predecessor_head", "campaign_id"], good))

    rejects(put_in(vector(4), ["body", "predecessor_head", "campaign_id"], good <> "x"))
    genesis = vector(0) |> Map.put("campaign_id", good) |> put_in(["body", "campaign_id"], good)
    assert {:ok, _, _} = encode(genesis)

    rejects(
      genesis
      |> Map.put("campaign_id", good <> "x")
      |> put_in(["body", "campaign_id"], good <> "x")
    )

    assert {:ok, _, _} = encode(put_in(vector(9), ["body", "reviewer_id"], good))
    rejects(put_in(vector(9), ["body", "reviewer_id"], good <> "x"))
  end

  test "genesis and designation enforce their local envelope positions" do
    rejects(
      Map.put(vector(0), "sequence", 2)
      |> Map.put("previous_digest", String.duplicate("a", 64))
    )

    rejects(put_in(vector(0), ["body", "campaign_id"], "different"))
    rejects(Map.put(vector(1), "sequence", 3))
    rejects(put_in(vector(1), ["body", "ownership_epoch"], 2))
  end

  test "relinquishment joins every preceding-head member without assuming host authority" do
    original = vector(2)

    for {key, value} <- [
          {"campaign_id", "different"},
          {"sequence", 2},
          {"digest", String.duplicate("b", 64)},
          {"extra", nil}
        ] do
      rejects(
        put_in(
          original,
          ["body", "preceding_head"],
          Map.put(original["body"]["preceding_head"], key, value)
        )
      )
    end

    rejects(put_in(original, ["body", "destination_writer_id"], original["body"]["writer_id"]))
    rejects(put_in(original, ["body", "handoff_id"], ""))
    rejects(put_in(original, ["body", "quiescence"], nil))

    assert {:ok, _, _} =
             encode(
               put_in(original, ["body", "destination_host_id"], original["body"]["host_id"])
             )
  end

  test "acceptance joins the preceding relinquishment head and exact next epoch" do
    original = vector(3)

    for {key, value} <- [
          {"campaign_id", "different"},
          {"sequence", 2},
          {"digest", String.duplicate("b", 64)}
        ] do
      rejects(
        put_in(
          original,
          ["body", "relinquishment_head"],
          Map.put(original["body"]["relinquishment_head"], key, value)
        )
      )
    end

    rejects(put_in(original, ["body", "source_writer_id"], original["body"]["writer_id"]))
    rejects(put_in(original, ["body", "ownership_epoch"], 1))
    rejects(put_in(original, ["body", "source_ownership_epoch"], 2))

    for field <- ~w(quiescence source_revocation transfer) do
      rejects(put_in(original, ["body", field], nil))
    end
  end

  test "ownership epochs retain exact uint64 precision and cannot wrap" do
    maximum = 18_446_744_073_709_551_615

    original =
      vector(3)
      |> put_in(["body", "source_ownership_epoch"], maximum - 1)
      |> put_in(["body", "ownership_epoch"], maximum)

    assert {:ok, line, record} = encode(original)
    assert line =~ "18446744073709551615"
    assert {:ok, ^record} = Events.decode(strip_lf(line))

    for bad <- [0, -1, maximum + 1, 1.0, "1", true, nil] do
      rejects(put_in(vector(7), ["body", "ownership_epoch"], bad))
    end

    rejects(
      original
      |> put_in(["body", "source_ownership_epoch"], maximum)
      |> put_in(["body", "ownership_epoch"], maximum + 1)
    )
  end

  test "envelope and head quantities remain exact positive integers beyond uint64" do
    sequence = 18_446_744_073_709_551_617

    original =
      vector(2)
      |> Map.put("sequence", sequence)
      |> put_in(["body", "preceding_head", "sequence"], sequence - 1)

    assert {:ok, line, record} = encode(original)
    assert line =~ Integer.to_string(sequence)
    assert {:ok, ^record} = Events.decode(strip_lf(line))

    for bad <- [0, -1, 1.0, true, "2"] do
      rejects(put_in(vector(2), ["body", "preceding_head", "sequence"], bad))
      rejects(Map.put(vector(6), "sequence", bad))
    end
  end

  test "succession validates the foreign head while designation order remains a replay obligation" do
    original = vector(4)

    rejects(
      put_in(original, ["body", "predecessor_head", "campaign_id"], original["campaign_id"])
    )

    assert {:ok, _, _} = encode(Map.put(original, "sequence", 4))
    rejects(put_in(original, ["body", "ownership_epoch"], 2))

    for field <- ~w(prior_rows unavailable_interval disposition) do
      rejects(put_in(original, ["body", field], nil))
    end
  end

  test "evidence references are closed maps with exact digest domains" do
    original = vector(7)
    reference = hd(original["body"]["evidence"])

    for changed <- [
          Map.put(reference, "extra", nil),
          Map.delete(reference, "sha256"),
          Map.delete(reference, "reference"),
          Map.put(reference, "sha256", String.duplicate("A", 64)),
          Map.put(reference, "sha256", String.duplicate("a", 63)),
          Map.put(reference, "sha256", <<255>>)
        ] do
      rejects(put_in(original, ["body", "evidence"], [changed]))
    end

    for field <- ~w(manifest_digest specification_digest) do
      for bad <- [
            String.duplicate("A", 64),
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            nil
          ] do
        rejects(put_in(original, ["body", field], bad))
      end
    end

    for bad <- [
          String.duplicate("A", 40),
          String.duplicate("a", 39),
          String.duplicate("a", 41),
          nil
        ] do
      rejects(put_in(original, ["body", "candidate_sha"], bad))
    end
  end

  test "absolute references are literal safe POSIX paths and have an exact byte ceiling" do
    original = vector(7)
    valid = "/" <> String.duplicate("猫", 1365)
    assert byte_size(valid) == 4096
    assert {:ok, _, _} = encode(with_reference(original, valid))

    assert {:ok, _, _} =
             encode(with_reference(original, "/retained/space and 'quote'/result.json"))

    for bad <- [
          "/",
          "//a",
          "/a//b",
          "/a/",
          "/a/./b",
          "/a/../b",
          "relative/file",
          "~/file",
          valid <> "x",
          "/a\n",
          "/a" <> <<127>>,
          <<255>>
        ] do
      rejects(with_reference(original, bad))
    end
  end

  test "Git references pin a current revision and closed documentation path and anchor" do
    sha = String.duplicate("a", 40)
    original = vector(7)

    for good <- [
          "git:#{sha}:docs/evidence/check.md",
          "git:#{sha}:docs/ADR_0057/example-v1.md#a1-b2"
        ] do
      assert {:ok, _, _} = encode(with_reference(original, good))
    end

    for bad <- [
          "git:#{String.upcase(sha)}:docs/check.md",
          "git:#{sha}:apps/check.md",
          "git:#{sha}:docs/../check.md",
          "git:#{sha}:docs/./check.md",
          "git:#{sha}:docs//check.md",
          "git:#{sha}:docs/check.txt",
          "git:#{sha}:docs/check.md#",
          "git:#{sha}:docs/check.md#Upper",
          "git:#{sha}:docs/check.md#a_b",
          "git:#{sha}:docs/check.md#two#anchors",
          "git:#{sha}:docs/猫.md"
        ] do
      rejects(with_reference(original, bad))
    end
  end

  test "evidence requires one to sixty-four references and a whole-record budget" do
    original = vector(7)
    reference = hd(original["body"]["evidence"])

    assert {:ok, _, _} =
             encode(put_in(original, ["body", "evidence"], List.duplicate(reference, 64)))

    for bad <- [[], List.duplicate(reference, 65), [reference | :improper], %{}, "evidence"] do
      rejects(put_in(original, ["body", "evidence"], bad))
    end
  end

  test "not-dispatched explicitly retains no-execution evidence and optional unavailable review" do
    original = vector(5)
    assert {:ok, _, _} = encode(put_in(original, ["body", "mechanical_result"], nil))
    reference = hd(original["body"]["evidence"])

    reviewed =
      original
      |> put_in(["body", "verdict"], "evidence_unavailable")
      |> put_in(["body", "reviewer_id"], "reviewer")
      |> put_in(["body", "diagnosis"], reference)

    assert {:ok, _, _} = encode(reviewed)

    for changed <- [
          put_in(original, ["body", "attempt_id"], "attempt"),
          put_in(original, ["body", "evidence"], nil),
          put_in(original, ["body", "mechanical_result"], "pass"),
          put_in(reviewed, ["body", "diagnosis"], nil),
          put_in(reviewed, ["body", "reviewer_id"], nil),
          put_in(reviewed, ["body", "verdict"], "pass")
        ] do
      rejects(changed)
    end
  end

  test "started records retain an attempt and execution path before any result or review" do
    original = vector(6)
    rejects(put_in(original, ["body", "attempt_id"], nil))
    rejects(put_in(original, ["body", "evidence"], nil))

    for field <-
          ~w(mechanical_result verdict diagnosis disposition reviewer_id authorized_candidate_sha authorization_evidence) do
      value =
        case field do
          "mechanical_result" -> "pass"
          "verdict" -> "pass"
          "reviewer_id" -> "reviewer"
          "authorized_candidate_sha" -> String.duplicate("b", 40)
          _ -> hd(original["body"]["evidence"])
        end

      rejects(put_in(original, ["body", field], value))
    end
  end

  test "completed records separate mechanics from reviewed truth and preserve absent evidence" do
    original = vector(7)

    missing =
      original
      |> put_in(["body", "mechanical_result"], "evidence_incomplete_post_dispatch")
      |> put_in(["body", "evidence"], nil)

    assert {:ok, _, _} = encode(missing)

    for result <-
          ~w(pass required_action_absent assertion_failed evidence_incomplete_post_dispatch provider_environment_failure) do
      assert {:ok, _, _} = encode(put_in(original, ["body", "mechanical_result"], result))
    end

    for changed <- [
          put_in(original, ["body", "attempt_id"], nil),
          put_in(original, ["body", "mechanical_result"], nil),
          put_in(original, ["body", "mechanical_result"], "evidence_incomplete_pre_dispatch"),
          put_in(original, ["body", "evidence"], nil),
          put_in(original, ["body", "verdict"], "pass"),
          put_in(original, ["body", "reviewer_id"], "reviewer")
        ] do
      rejects(changed)
    end
  end

  test "reviewed verdicts require a named reviewer and non-pass diagnosis" do
    original = vector(9)

    for verdict <-
          ~w(product_failure model_nonconformance evidence_unavailable environment_failure) do
      assert {:ok, _, _} = encode(put_in(original, ["body", "verdict"], verdict))
    end

    for changed <- [
          put_in(original, ["body", "diagnosis"], nil),
          put_in(original, ["body", "reviewer_id"], nil),
          put_in(original, ["body", "verdict"], nil),
          put_in(original, ["body", "mechanical_result"], "evidence_incomplete_pre_dispatch")
        ] do
      rejects(changed)
    end

    pass =
      vector(7)
      |> put_in(["body", "state"], "reviewed")
      |> put_in(["body", "verdict"], "pass")
      |> put_in(["body", "reviewer_id"], "reviewer")

    assert {:ok, _, _} = encode(pass)
    rejects(put_in(pass, ["body", "mechanical_result"], "assertion_failed"))
    rejects(put_in(pass, ["body", "evidence"], nil))

    missing =
      original
      |> put_in(["body", "mechanical_result"], "evidence_incomplete_post_dispatch")
      |> put_in(["body", "evidence"], nil)

    assert {:ok, _, _} = encode(missing)
    rejects(put_in(missing, ["body", "verdict"], "pass"))
  end

  test "authorization retains a failed original candidate and mandatory causal references" do
    original = vector(10)

    rejects(
      put_in(original, ["body", "authorized_candidate_sha"], original["body"]["candidate_sha"])
    )

    rejects(put_in(original, ["body", "verdict"], "pass"))

    for field <-
          ~w(attempt_id mechanical_result verdict reviewer_id diagnosis disposition authorized_candidate_sha authorization_evidence) do
      rejects(put_in(original, ["body", field], nil))
    end

    for index <- 5..9 do
      rejects(
        put_in(vector(index), ["body", "authorized_candidate_sha"], String.duplicate("b", 40))
      )

      rejects(
        put_in(
          vector(index),
          ["body", "authorization_evidence"],
          original["body"]["authorization_evidence"]
        )
      )
    end
  end

  test "every nested duplicate and escaped duplicate spelling refuses before semantic admission" do
    for {preimage, digest} <- @vectors do
      bytes =
        String.replace(
          preimage,
          ~s("campaign_id":"m7-vector","previous_digest"),
          ~s("campaign_id":"m7-vector","digest":"#{digest}","previous_digest")
        )

      assert {:ok, record} = Events.decode(bytes)
      assert record["digest"] == digest

      for member <- [~s("kind":"), ~s("sha256":"), ~s("sequence":)] do
        if String.contains?(bytes, member) do
          duplicated =
            case member do
              ~s("kind":") ->
                String.replace(bytes, ~s("kind":), ~s("kind":"duplicate","kind":), global: false)

              ~s("sha256":") ->
                String.replace(bytes, ~s("sha256":), ~s("sha256":"duplicate","sha256":),
                  global: false
                )

              _ ->
                String.replace(bytes, ~s("sequence":), ~S("sequence":1,"seque\u006ece":),
                  global: false
                )
            end

          assert {:error, {:duplicate_member, _}} = ConfigJson.decode(duplicated)
          assert Events.decode(duplicated) == {:error, :invalid_attempt_event}
        end
      end
    end
  end

  test "canonical byte order, punctuation, integer syntax, LF and digest remain mandatory" do
    {:ok, line, _} = encode(vector(7))
    bytes = strip_lf(line)

    for changed <- [
          " " <> bytes,
          bytes <> " ",
          line,
          bytes <> "\n\n",
          String.replace(bytes, ~s("ownership_epoch":1), ~s("ownership_epoch":1.0)),
          String.replace(bytes, ~s("ownership_epoch":1), ~s("ownership_epoch":1e0)),
          String.replace(bytes, "attempt-1", "attempt-2"),
          <<255>>,
          String.duplicate("x", 65_537)
        ] do
      assert Events.decode(changed) == {:error, :invalid_attempt_event}
    end
  end

  test "the body codec preserves the exact full-envelope ceiling and first-over refusal" do
    original = vector(7)
    reference = hd(original["body"]["evidence"]) |> Map.put("reference", "/a")
    base = put_in(original, ["body", "evidence"], List.duplicate(reference, 16))
    assert {:ok, line, _} = encode(base)
    room = 65_536 - (byte_size(line) - 1)

    evidence =
      for index <- 1..16 do
        added = div(room, 16) + if(index <= rem(room, 16), do: 1, else: 0)
        Map.put(reference, "reference", "/a" <> String.duplicate("x", added))
      end

    at_cap = put_in(base, ["body", "evidence"], evidence)
    assert {:ok, full, record} = encode(at_cap)
    assert byte_size(full) == 65_537
    assert {:ok, ^record} = Events.decode(strip_lf(full))
    assert Events.decode(strip_lf(full) <> " ") == {:error, :invalid_attempt_event}
    [first | remaining] = evidence

    rejects(
      put_in(at_cap, ["body", "evidence"], [
        Map.update!(first, "reference", &(&1 <> "x")) | remaining
      ])
    )
  end

  test "implementation terms and framing-only bodies cannot enter the accepted current union" do
    for body <- [
          nil,
          [],
          %{},
          %{"kind" => "genesis", "version" => 1, "codec_version" => 1, "campaign_id" => self()},
          %{kind: "genesis"},
          %{"kind" => "case", "version" => 1, "evidence" => [fn -> :ok end]}
        ] do
      rejects(Map.put(vector(0), "body", body))
    end

    for state <- [nil, "unknown", "Completed", :completed] do
      rejects(put_in(vector(7), ["body", "state"], state))
    end

    for mechanical <- ["unknown", "product_failure", :pass],
        verdict <- ["unknown", "assertion_failed", :pass] do
      rejects(put_in(vector(7), ["body", "mechanical_result"], mechanical))
      rejects(put_in(vector(9), ["body", "verdict"], verdict))
    end
  end

  # Concept: These are complete legal control chains, not concatenated body examples.
  # Technical depth: Python stdlib derived canonical unsigned bytes and SHA-256
  # independently; preceding heads and successor sequence three are literal.
  @ownership_chains [
    {"handoff", %{"writer_id" => "writer-2", "host_id" => "host-2", "ownership_epoch" => 2},
     [
       {~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}|,
        "d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826",
        ~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","previous_digest":null,"sequence":1,"version":1}| <>
          "\n"},
       {~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
        "398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5",
        ~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}| <>
          "\n"},
       {~S|{"body":{"destination_host_id":"host-2","destination_writer_id":"writer-2","handoff_id":"handoff-1","host_id":"host-1","kind":"writer_relinquished","ownership_epoch":1,"preceding_head":{"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":2},"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}|,
        "02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da",
        ~S|{"body":{"destination_host_id":"host-2","destination_writer_id":"writer-2","handoff_id":"handoff-1","host_id":"host-1","kind":"writer_relinquished","ownership_epoch":1,"preceding_head":{"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":2},"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}| <>
          "\n"},
       {~S|{"body":{"handoff_id":"handoff-1","host_id":"host-2","kind":"writer_accepted","ownership_epoch":2,"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"relinquishment_head":{"campaign_id":"m7-vector","digest":"02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da","sequence":3},"source_host_id":"host-1","source_ownership_epoch":1,"source_revocation":{"reference":"/evidence/m7/revocation.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"source_writer_id":"writer-1","transfer":{"reference":"/evidence/m7/transfer.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-2"},"campaign_id":"m7-vector","previous_digest":"02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da","sequence":4,"version":1}|,
        "ade107d02dee578f715f235d1c9a293d9b4ae2b92059c457bf99600a20351220",
        ~S|{"body":{"handoff_id":"handoff-1","host_id":"host-2","kind":"writer_accepted","ownership_epoch":2,"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"relinquishment_head":{"campaign_id":"m7-vector","digest":"02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da","sequence":3},"source_host_id":"host-1","source_ownership_epoch":1,"source_revocation":{"reference":"/evidence/m7/revocation.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"source_writer_id":"writer-1","transfer":{"reference":"/evidence/m7/transfer.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-2"},"campaign_id":"m7-vector","digest":"ade107d02dee578f715f235d1c9a293d9b4ae2b92059c457bf99600a20351220","previous_digest":"02740df72c4e3ecaddf49efc05efc6ebe1aca35fbe7c84f3c7b699b54b62e0da","sequence":4,"version":1}| <>
          "\n"}
     ]},
    {"successor", %{"writer_id" => "writer-1", "host_id" => "host-1", "ownership_epoch" => 1},
     [
       {~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}|,
        "d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826",
        ~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","previous_digest":null,"sequence":1,"version":1}| <>
          "\n"},
       {~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
        "398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5",
        ~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}| <>
          "\n"},
       {~S|{"body":{"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"host_id":"host-1","kind":"campaign_succession","ownership_epoch":1,"predecessor_head":{"campaign_id":"m7-predecessor","digest":"0000000000000000000000000000000000000000000000000000000000000000","sequence":9},"prior_rows":{"reference":"/evidence/m7/prior-rows.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"unavailable_interval":{"reference":"/evidence/m7/lost-interval.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}|,
        "47c887e33aa15a7b50fbd65276f10b52b0f5750ea534687ecc2c86f71821a5a1",
        ~S|{"body":{"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"host_id":"host-1","kind":"campaign_succession","ownership_epoch":1,"predecessor_head":{"campaign_id":"m7-predecessor","digest":"0000000000000000000000000000000000000000000000000000000000000000","sequence":9},"prior_rows":{"reference":"/evidence/m7/prior-rows.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"unavailable_interval":{"reference":"/evidence/m7/lost-interval.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"47c887e33aa15a7b50fbd65276f10b52b0f5750ea534687ecc2c86f71821a5a1","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}| <>
          "\n"}
     ]}
  ]

  for {name, owner, rows} <- @ownership_chains do
    test "independent literal #{name} chain fixes ordered ownership and complete bytes" do
      owner = unquote(Macro.escape(owner))
      rows = unquote(Macro.escape(rows))

      {bytes, last} =
        Enum.reduce(rows, {"", nil}, fn {preimage, digest, line}, {bytes, _last} ->
          assert Base.encode16(:crypto.hash(:sha256, preimage), case: :lower) == digest
          assert {:ok, unsigned} = ConfigJson.decode(preimage)
          assert {:ok, ^line, record} = encode(unsigned)
          assert record == Map.put(unsigned, "digest", digest)
          assert {:ok, ^record} = Events.decode(strip_lf(line))
          {bytes <> line, record}
        end)

      assert {:ok, projection} = Events.verify_ownership(bytes)
      assert projection.head == ownership_head(last)
      assert projection.owner == owner
      assert projection.pending == nil
      assert {:ok, ^projection} = Events.verify_ownership(bytes, ownership_head(last))
    end
  end

  test "genesis and designation prefixes preserve exactly the known ownership facts" do
    {genesis, [first]} = ownership_chain([ownership_body(0)])

    assert Events.verify_ownership(genesis) ==
             {:ok, %{head: ownership_head(first), owner: nil, pending: nil, succession: nil}}

    {bytes, [_, designation]} = ownership_chain(ownership_prefix())
    assert {:ok, projection} = Events.verify_ownership(bytes)
    assert projection.head == ownership_head(designation)
    assert projection.owner == ownership_tuple(ownership_body(1))
    assert projection.pending == nil
    assert projection.succession == nil
  end

  test "body-valid non-genesis starts and non-designation second records refuse ordering" do
    ownership_ok!(ownership_prefix())

    for bodies <- [
          [ownership_body(6)],
          [ownership_body(0), ownership_body(6)],
          [ownership_body(0), ownership_body(4)],
          [ownership_body(0), ownership_body(2)]
        ] do
      {bytes, _} = ownership_chain(bodies)
      assert {:ok, _} = Frames.verify(bytes)
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "full-chain framing does not replace closed body admission or permit repeated controls" do
    ownership_ok!(ownership_prefix())

    for bodies <- [
          [%{}],
          ownership_prefix() ++ [ownership_body(0)],
          ownership_prefix() ++ [ownership_body(1)]
        ] do
      {bytes, _} = framed_ownership_chain(bodies)
      assert {:ok, _} = Frames.verify(bytes)
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_event}
    end
  end

  test "succession is first after designation and cannot recur or follow a case" do
    bodies = ownership_prefix() ++ [ownership_body(4)]
    projection = ownership_ok!(bodies)
    assert projection.succession == ownership_body(4)

    for changed <- [
          bodies ++ [ownership_body(4)],
          ownership_prefix() ++ [ownership_body(6), ownership_body(4)]
        ] do
      {bytes, _} = ownership_chain(changed)
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end

    assert {:ok, _, _} = encode(vector(4))
  end

  test "succession must name the designated writer and host without authenticating its references" do
    original = ownership_body(4)
    ownership_ok!(ownership_prefix() ++ [original])

    for key <- ~w(writer_id host_id) do
      changed = Map.put(original, key, "different")
      {bytes, _} = ownership_chain(ownership_prefix() ++ [changed])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "each case record must retain the exact currently designated tuple" do
    original = ownership_body(6)
    ownership_ok!(ownership_prefix() ++ [original])

    for {key, value} <- [
          {"writer_id", "different"},
          {"host_id", "different"},
          {"ownership_epoch", 2},
          {"ownership_epoch", 18_446_744_073_709_551_615}
        ] do
      changed = Map.put(original, key, value)
      {bytes, _} = ownership_chain(ownership_prefix() ++ [changed])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "relinquishment must be issued by the current owner" do
    original = ownership_body(2)
    ownership_ok!(ownership_prefix() ++ [original])

    for {key, value} <- [
          {"writer_id", "different"},
          {"host_id", "different"},
          {"ownership_epoch", 2}
        ] do
      changed = Map.put(original, key, value)
      {bytes, _} = ownership_chain(ownership_prefix() ++ [changed])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "pending relinquishment retains the exact original head and body without advancing owner" do
    {bytes, records} = ownership_chain(ownership_prefix() ++ [ownership_body(2)])
    last = List.last(records)
    assert {:ok, projection} = Events.verify_ownership(bytes)
    assert projection.owner == ownership_tuple(ownership_body(1))
    assert projection.pending == %{"head" => ownership_head(last), "body" => last["body"]}
    assert projection.head == ownership_head(last)
    assert {:ok, ^projection} = Events.verify_ownership(bytes, ownership_head(last))
  end

  test "no case or another control can follow a pending relinquishment instead of acceptance" do
    prefix = ownership_prefix() ++ [ownership_body(2)]
    ownership_ok!(prefix)
    ownership_ok!(prefix ++ [ownership_body(3)])

    for next <- [ownership_body(6), ownership_body(2), ownership_body(4)] do
      {bytes, _} = ownership_chain(prefix ++ [next])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "body-valid acceptance mutations must match every original handoff tuple and quiescence field" do
    prefix = ownership_prefix() ++ [ownership_body(2)]
    original = ownership_body(3)
    ownership_ok!(prefix ++ [original])

    changes = [
      Map.put(original, "writer_id", "different"),
      Map.put(original, "host_id", "different"),
      Map.put(original, "source_writer_id", "different"),
      Map.put(original, "source_host_id", "different"),
      Map.merge(original, %{"source_ownership_epoch" => 2, "ownership_epoch" => 3}),
      Map.merge(original, %{
        "source_ownership_epoch" => 18_446_744_073_709_551_614,
        "ownership_epoch" => 18_446_744_073_709_551_615
      }),
      Map.put(original, "handoff_id", "different"),
      put_in(original, ["quiescence", "reference"], "/evidence/m7/different.json"),
      put_in(original, ["quiescence", "sha256"], String.duplicate("b", 64))
    ]

    for changed <- changes do
      {bytes, _} = ownership_chain(prefix ++ [changed])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "acceptance head and exact epoch cannot be replaced even within an otherwise authentic chain" do
    prefix = ownership_prefix() ++ [ownership_body(2)]
    original = ownership_body(3)
    ownership_ok!(prefix ++ [original])
    {prefix_bytes, records} = ownership_chain(prefix)
    head = ownership_head(List.last(records))
    valid = Map.put(original, "relinquishment_head", head)

    for changed <- [
          put_in(valid, ["relinquishment_head", "campaign_id"], "foreign"),
          put_in(valid, ["relinquishment_head", "sequence"], 2),
          put_in(valid, ["relinquishment_head", "digest"], String.duplicate("b", 64)),
          Map.put(valid, "ownership_epoch", 3),
          Map.merge(valid, %{
            "source_ownership_epoch" => 18_446_744_073_709_551_615,
            "ownership_epoch" => 18_446_744_073_709_551_616
          })
        ] do
      assert {:ok, line, _} = Frames.encode("m7-vector", 4, head["digest"], changed)
      assert {:ok, _} = Frames.verify(prefix_bytes <> line)
      assert Events.verify_ownership(prefix_bytes <> line) == {:error, :invalid_attempt_event}
    end
  end

  test "a body-valid acceptance without an outstanding relinquishment refuses" do
    ownership_ok!(ownership_prefix() ++ [ownership_body(2), ownership_body(3)])
    {bytes, _} = ownership_chain(ownership_prefix() ++ [ownership_body(3)])
    assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
  end

  test "completed handoff advances case ownership and a fresh return handoff advances it again" do
    prefix = ownership_prefix() ++ [ownership_body(2), ownership_body(3)]
    owner_two = ownership_tuple(ownership_body(3))
    case_two = Map.merge(ownership_body(6), owner_two)
    projection = ownership_ok!(prefix ++ [case_two])
    assert projection.owner == owner_two

    return_relinquishment =
      ownership_body(2)
      |> Map.merge(owner_two)
      |> Map.merge(%{
        "destination_writer_id" => "writer-1",
        "destination_host_id" => "host-1",
        "handoff_id" => "handoff-2"
      })

    return_acceptance =
      ownership_body(3)
      |> Map.merge(%{
        "writer_id" => "writer-1",
        "host_id" => "host-1",
        "ownership_epoch" => 3,
        "source_writer_id" => "writer-2",
        "source_host_id" => "host-2",
        "source_ownership_epoch" => 2,
        "handoff_id" => "handoff-2"
      })

    owner_three = ownership_tuple(return_acceptance)
    case_three = Map.merge(ownership_body(6), owner_three)
    bodies = prefix ++ [case_two, return_relinquishment, return_acceptance, case_three]
    projection = ownership_ok!(bodies)
    assert projection.owner == owner_three
    assert projection.pending == nil

    for stale <- [ownership_body(6), case_two] do
      {bytes, _} = ownership_chain(bodies ++ [stale])
      assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "previously used handoff identities cannot be reused by the new owner" do
    prefix = ownership_prefix() ++ [ownership_body(2), ownership_body(3)]

    next =
      ownership_body(2)
      |> Map.merge(ownership_tuple(ownership_body(3)))
      |> Map.merge(%{"destination_writer_id" => "writer-1", "destination_host_id" => "host-1"})

    ownership_ok!(prefix ++ [Map.put(next, "handoff_id", "fresh")])
    {bytes, _} = ownership_chain(prefix ++ [next])
    assert Events.verify_ownership(bytes) == {:error, :invalid_attempt_ownership}
  end

  test "ownership projection deliberately proves neither case transitions nor actual quiescence" do
    started = ownership_body(6)

    not_dispatched =
      ownership_body(5)
      |> Map.put("logical_matrix_id", started["logical_matrix_id"])
      |> Map.put("subcase_key", started["subcase_key"])

    for cases <- [[started, not_dispatched], [started]] do
      bodies = ownership_prefix() ++ cases ++ [ownership_body(2), ownership_body(3)]
      projection = ownership_ok!(bodies)
      assert projection.owner == ownership_tuple(ownership_body(3))
      assert projection.pending == nil
      assert projection.succession == nil
      assert Enum.sort(Map.keys(projection)) == [:head, :owner, :pending, :succession]
    end
  end

  test "committed anchors still require exact full history rather than a valid stale copy or fork" do
    bodies = ownership_prefix() ++ [ownership_body(6)]
    {bytes, [first, designation, _case]} = ownership_chain(bodies)
    assert {:ok, projection} = Events.verify_ownership(bytes)

    for anchor <- [ownership_head(first), ownership_head(designation), projection.head] do
      assert Events.verify_ownership(bytes, anchor) == {:ok, projection}
    end

    {stale, _} = ownership_chain(ownership_prefix())

    assert Events.verify_ownership(stale, projection.head) ==
             {:error, :committed_attempt_head_mismatch}

    fork = Map.put(ownership_body(6), "attempt_id", "another-attempt")
    {forked, _} = ownership_chain(ownership_prefix() ++ [fork])
    assert {:ok, _} = Events.verify_ownership(forked)

    assert Events.verify_ownership(forked, projection.head) ==
             {:error, :committed_attempt_head_mismatch}

    assert Events.verify_ownership(bytes, nil) == {:error, :invalid_committed_attempt_head}
  end

  test "all incomplete final line cuts remain unresolved even after the committed anchor" do
    {prefix, records} = ownership_chain(ownership_prefix())
    head = ownership_head(List.last(records))
    {complete, _} = ownership_chain(ownership_prefix() ++ [ownership_body(2)])
    line = binary_part(complete, byte_size(prefix), byte_size(complete) - byte_size(prefix))
    ownership_ok!(ownership_prefix() ++ [ownership_body(2)])

    for size <- 1..(byte_size(line) - 1) do
      tail = binary_part(line, 0, size)
      expected = {:error, {:incomplete_attempt_append, head, tail}}
      assert Events.verify_ownership(prefix <> tail) == expected
      assert Events.verify_ownership(prefix <> tail, head) == expected
    end

    assert Events.verify_ownership("{") == {:error, {:incomplete_attempt_append, nil, "{"}}
  end

  test "invalid, reordered and oversized framing refuses before any ownership projection" do
    {bytes, _} = ownership_chain(ownership_prefix())
    ownership_ok!(ownership_prefix())
    [genesis, designation, ""] = String.split(bytes, "\n")

    for invalid <- [
          nil,
          "",
          bytes <> "\n",
          designation <> "\n" <> genesis <> "\n",
          String.duplicate("x", 65_537)
        ] do
      assert Events.verify_ownership(invalid) == Frames.verify(invalid)
      refute match?({:ok, _}, Events.verify_ownership(invalid))
    end
  end

  # Concept: These full case chains retain an original consumed attempt.
  # Technical depth: Python stdlib independently hashes each unsigned envelope,
  # including genesis, designation and every linked case record. References are
  # synthetic and establish no evidence admission or reviewer authority.
  @case_chains [
    {"pass",
     [
       {~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}|,
        "d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826",
        ~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","previous_digest":null,"sequence":1,"version":1}| <>
          "\n"},
       {~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
        "398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5",
        ~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}|,
        "587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","sequence":4,"version":1}|,
        "514ce32bc02653eecb9b1e1312f24d3f8bf18a84435071575e1096a88b75368e",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"514ce32bc02653eecb9b1e1312f24d3f8bf18a84435071575e1096a88b75368e","previous_digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","sequence":4,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"pass","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"514ce32bc02653eecb9b1e1312f24d3f8bf18a84435071575e1096a88b75368e","sequence":5,"version":1}|,
        "02414152567ff93a3d4935ead5884b28e13b81c1898c80eef918b0d42ccc5e9d",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"pass","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"02414152567ff93a3d4935ead5884b28e13b81c1898c80eef918b0d42ccc5e9d","previous_digest":"514ce32bc02653eecb9b1e1312f24d3f8bf18a84435071575e1096a88b75368e","sequence":5,"version":1}| <>
          "\n"}
     ]},
    {"failed authorization",
     [
       {~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}|,
        "d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826",
        ~S|{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","previous_digest":null,"sequence":1,"version":1}| <>
          "\n"},
       {~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}|,
        "398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5",
        ~S|{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}|,
        "587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","previous_digest":"398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5","sequence":3,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","sequence":4,"version":1}|,
        "375ddba7a008cd5de047368dfea7eaab8083b46fbd547d6d62979d574c38e21d",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"375ddba7a008cd5de047368dfea7eaab8083b46fbd547d6d62979d574c38e21d","previous_digest":"587d1e8cb08be34d402f50a8bc977dc2096a8a07e7705099326afcfdad7dc2f3","sequence":4,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"375ddba7a008cd5de047368dfea7eaab8083b46fbd547d6d62979d574c38e21d","sequence":5,"version":1}|,
        "6c8bd8f8b25650e779430609f18612a462cfc30ac4354e5ec32eb70069dea94e",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"6c8bd8f8b25650e779430609f18612a462cfc30ac4354e5ec32eb70069dea94e","previous_digest":"375ddba7a008cd5de047368dfea7eaab8083b46fbd547d6d62979d574c38e21d","sequence":5,"version":1}| <>
          "\n"},
       {~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":{"reference":"/evidence/m7/authorization.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"authorized_candidate_sha":"2222222222222222222222222222222222222222","candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"authorized_next_candidate","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"6c8bd8f8b25650e779430609f18612a462cfc30ac4354e5ec32eb70069dea94e","sequence":6,"version":1}|,
        "d1cb38cfa05eb2ae22820970573d3c830b48e4e4d8034f3b15986f58572bd9bd",
        ~S|{"body":{"attempt_id":"attempt-1","authorization_evidence":{"reference":"/evidence/m7/authorization.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"authorized_candidate_sha":"2222222222222222222222222222222222222222","candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"authorized_next_candidate","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","digest":"d1cb38cfa05eb2ae22820970573d3c830b48e4e4d8034f3b15986f58572bd9bd","previous_digest":"6c8bd8f8b25650e779430609f18612a462cfc30ac4354e5ec32eb70069dea94e","sequence":6,"version":1}| <>
          "\n"}
     ]}
  ]

  for {name, rows} <- @case_chains do
    test "independent literal #{name} chain fixes original case records and final head" do
      rows = unquote(Macro.escape(rows))

      records =
        Enum.map(rows, fn {preimage, digest, line} ->
          assert Base.encode16(:crypto.hash(:sha256, preimage), case: :lower) == digest
          assert {:ok, unsigned} = ConfigJson.decode(preimage)
          assert {:ok, ^line, record} = encode(unsigned)
          assert record == Map.put(unsigned, "digest", digest)
          assert {:ok, ^record} = Events.decode(strip_lf(line))
          record
        end)

      bytes = Enum.map_join(rows, fn {_, _, line} -> line end)
      assert {:ok, projection} = Events.verify_case_history(bytes)
      assert_case_records(projection, records)
      assert projection.ownership.head == ownership_head(List.last(records))
      assert {:ok, ^projection} = Events.verify_case_history(bytes, projection.ownership.head)
      history = projection.histories |> Map.values() |> hd()
      assert history.state == List.last(records)["body"]["state"]
      assert history.unresolved == false
      assert hd(history.records)["body"]["attempt_id"] == "attempt-1"

      assert Enum.at(history.records, 1)["body"]["mechanical_result"] ==
               List.last(history.records)["body"]["mechanical_result"]
    end
  end

  test "case-free verified prefixes retain exact ownership without inventing histories" do
    for bodies <- [Enum.take(ownership_prefix(), 1), ownership_prefix()] do
      {bytes, _} = ownership_chain(bodies)
      assert {:ok, ownership} = Events.verify_ownership(bytes)

      assert Events.verify_case_history(bytes) ==
               {:ok, %{ownership: ownership, histories: %{}, records: [], unresolved: []}}
    end
  end

  test "initial pre-dispatch observation and direct started histories retain nullable matrix identity" do
    for matrix <- [nil, "matrix-1"] do
      started = Map.put(case_body("started"), "logical_matrix_id", matrix)
      observed = Map.merge(ownership_body(5), case_locator(started))

      for cases <- [[started], [observed, started]] do
        projection = case_ok!(ownership_prefix() ++ cases)
        [history] = Map.values(projection.histories)
        assert history.state == "started"
        assert List.last(history.records)["body"]["logical_matrix_id"] === matrix
        assert List.last(history.records)["body"]["attempt_id"] == "attempt-1"
        assert length(history.records) == length(cases)
      end
    end
  end

  test "unfinished started history stays consumed and preserves its execution-path evidence" do
    bodies = ownership_prefix() ++ [case_body("started")]
    {bytes, records} = ownership_chain(bodies)
    assert {:ok, projection} = Events.verify_case_history(bytes)
    assert_case_records(projection, records)
    [history] = Map.values(projection.histories)
    assert history.state == "started"
    assert history.records == [List.last(records)]
    assert List.last(history.records)["body"]["mechanical_result"] == nil
    assert List.last(history.records)["body"]["evidence"] == case_body("started")["evidence"]
  end

  test "each accepted mechanical result and independent verdict survives review and non-pass authorization" do
    routes = [
      {"pass", "pass"},
      {"pass", "product_failure"},
      {"required_action_absent", "model_nonconformance"},
      {"assertion_failed", "model_nonconformance"},
      {"assertion_failed", "product_failure"},
      {"evidence_incomplete_post_dispatch", "evidence_unavailable"},
      {"provider_environment_failure", "environment_failure"}
    ]

    for {mechanical, verdict} <- routes do
      completed = Map.put(case_body("completed"), "mechanical_result", mechanical)

      completed =
        if verdict == "evidence_unavailable",
          do: Map.put(completed, "evidence", nil),
          else: completed

      reviewed = reviewed_body(completed, verdict)
      cases = [case_body("started"), completed, reviewed]
      cases = if verdict == "pass", do: cases, else: cases ++ [authorized_body(reviewed)]
      projection = case_ok!(ownership_prefix() ++ cases)
      [history] = Map.values(projection.histories)
      assert Enum.at(history.records, 1)["body"] == completed
      assert List.last(history.records)["body"]["mechanical_result"] == mechanical
      assert List.last(history.records)["body"]["verdict"] == verdict
      assert List.last(history.records)["body"]["candidate_sha"] == completed["candidate_sha"]
    end
  end

  test "complete null-matrix pre-merge history stays bound to its original lane without coercion" do
    cases =
      Enum.map(
        [
          case_body("started"),
          case_body("completed"),
          case_body("reviewed"),
          case_body("authorized_next_candidate")
        ],
        &Map.put(&1, "logical_matrix_id", nil)
      )

    projection = case_ok!(ownership_prefix() ++ cases)
    [history] = Map.values(projection.histories)
    assert Enum.all?(history.records, &is_nil(&1["body"]["logical_matrix_id"]))
    assert history.state == "authorized_next_candidate"
    case_refuses!(ownership_prefix() ++ [hd(cases), case_body("completed")])
  end

  test "a locally non-pass authorization cannot replace an original reviewed pass" do
    completed = Map.put(case_body("completed"), "mechanical_result", "pass")
    reviewed = reviewed_body(completed, "pass")

    non_pass =
      Map.merge(reviewed, %{
        "verdict" => "product_failure",
        "diagnosis" => ownership_body(9)["diagnosis"]
      })

    authorized = authorized_body(non_pass)
    case_refuses!(ownership_prefix() ++ [case_body("started"), completed, reviewed, authorized])
  end

  test "post-dispatch records without original started and completed facts refuse as orphans" do
    for cases <- [
          [case_body("completed")],
          [case_body("reviewed")],
          [case_body("authorized_next_candidate")],
          [case_body("started"), case_body("reviewed")],
          [case_body("started"), case_body("completed"), case_body("authorized_next_candidate")]
        ] do
      case_refuses!(ownership_prefix() ++ cases)
    end
  end

  test "purported completion cannot change any execution identity or hide a replacement under another locator" do
    changes = [
      {"manifest_digest", String.duplicate("b", 64)},
      {"specification_digest", String.duplicate("c", 64)},
      {"candidate_sha", String.duplicate("2", 40)},
      {"lane_id", "different-lane"},
      {"logical_matrix_id", nil},
      {"case_key", "different-case"},
      {"subcase_key", nil},
      {"attempt_id", "different-attempt"}
    ]

    for {field, value} <- changes do
      completed = Map.put(case_body("completed"), field, value)
      case_refuses!(ownership_prefix() ++ [case_body("started"), completed])
    end
  end

  test "every review and authorization identity remains bound to the original consumed row" do
    for state <- ["reviewed", "authorized_next_candidate"],
        {field, value} <- [
          {"manifest_digest", String.duplicate("b", 64)},
          {"specification_digest", String.duplicate("c", 64)},
          {"candidate_sha", String.duplicate("3", 40)},
          {"lane_id", "other"},
          {"logical_matrix_id", nil},
          {"case_key", "other"},
          {"subcase_key", nil},
          {"attempt_id", "other"}
        ] do
      prefix = [case_body("started"), case_body("completed")]
      prefix = if state == "reviewed", do: prefix, else: prefix ++ [case_body("reviewed")]
      case_refuses!(ownership_prefix() ++ prefix ++ [Map.put(case_body(state), field, value)])
    end
  end

  test "consumed regressions and duplicate starts or completions refuse while ownership-only regression remains valid" do
    started = case_body("started")
    completed = case_body("completed")
    reviewed = case_body("reviewed")
    authorized = case_body("authorized_next_candidate")
    not_dispatched = Map.merge(ownership_body(5), case_locator(started))

    for cases <- [
          [started, not_dispatched],
          [started, started],
          [started, completed, started],
          [started, completed, completed],
          [started, completed, reviewed, completed],
          [started, completed, reviewed, authorized, reviewed],
          [started, completed, reviewed, authorized, authorized]
        ] do
      case_refuses!(ownership_prefix() ++ cases)
    end

    ownership_ok!(ownership_prefix() ++ [started, not_dispatched])
  end

  test "original completion result cannot change during review or authorization" do
    for state <- ["reviewed", "authorized_next_candidate"] do
      prefix = [case_body("started"), case_body("completed")]
      prefix = if state == "reviewed", do: prefix, else: prefix ++ [case_body("reviewed")]
      changed = Map.put(case_body(state), "mechanical_result", "pass")
      case_refuses!(ownership_prefix() ++ prefix ++ [changed])
    end
  end

  test "review appends its diagnosis and named reviewer while retaining original boundary records and heads" do
    completed =
      case_body("completed")
      |> Map.put("diagnosis", ownership_body(4)["prior_rows"])
      |> Map.put("disposition", ownership_body(4)["disposition"])

    reviewed = reviewed_body(completed, "product_failure")

    {bytes, records} =
      ownership_chain(ownership_prefix() ++ [case_body("started"), completed, reviewed])

    assert {:ok, projection} = Events.verify_case_history(bytes)
    assert_case_records(projection, records)
    [history] = Map.values(projection.histories)
    assert Enum.at(history.records, 1)["body"] == completed
    assert List.last(history.records)["body"] == reviewed
    assert Enum.at(history.records, 1)["digest"] == Enum.at(records, 3)["digest"]
  end

  test "authorization retains the exact original reviewed evidence reviewer verdict and failure candidate" do
    prefix =
      ownership_prefix() ++ [case_body("started"), case_body("completed"), case_body("reviewed")]

    authorized = case_body("authorized_next_candidate")
    projection = case_ok!(prefix ++ [authorized])
    [history] = Map.values(projection.histories)
    assert List.last(history.records)["body"] == authorized
    assert authorized["authorized_candidate_sha"] != authorized["candidate_sha"]

    for changed <- [
          Map.put(authorized, "reviewer_id", "other-reviewer"),
          Map.put(authorized, "verdict", "product_failure"),
          Map.put(authorized, "evidence", case_body("started")["evidence"])
        ] do
      case_refuses!(prefix ++ [changed])
    end
  end

  test "null completion evidence stays absent through review and authorization without acquiring a pass" do
    completed =
      Map.merge(case_body("completed"), %{
        "mechanical_result" => "evidence_incomplete_post_dispatch",
        "evidence" => nil
      })

    reviewed = reviewed_body(completed, "evidence_unavailable")
    authorized = authorized_body(reviewed)

    projection =
      case_ok!(ownership_prefix() ++ [case_body("started"), completed, reviewed, authorized])

    [history] = Map.values(projection.histories)
    assert Enum.all?(Enum.drop(history.records, 1), &is_nil(&1["body"]["evidence"]))

    assert List.last(history.records)["body"]["mechanical_result"] ==
             "evidence_incomplete_post_dispatch"

    case_refuses!(
      ownership_prefix() ++
        [
          case_body("started"),
          completed,
          Map.merge(reviewed, %{
            "mechanical_result" => "pass",
            "evidence" => case_body("completed")["evidence"]
          })
        ]
    )
  end

  test "independent interleaved subcase histories can retain the same attempt identity without global uniqueness policy" do
    one = [case_body("started"), case_body("completed"), case_body("reviewed")]
    two = Enum.map(one, &Map.put(&1, "subcase_key", "V1.2"))
    interleaved = Enum.zip(one, two) |> Enum.flat_map(fn {left, right} -> [left, right] end)
    projection = case_ok!(ownership_prefix() ++ interleaved)
    assert map_size(projection.histories) == 2

    assert Enum.all?(Map.values(projection.histories), fn history ->
             length(history.records) == 3 and
               hd(history.records)["body"]["attempt_id"] == "attempt-1"
           end)
  end

  test "completed case can be reviewed after valid handoff with both original and new authors retained" do
    reviewed = Map.merge(case_body("reviewed"), ownership_tuple(ownership_body(3)))

    bodies =
      ownership_prefix() ++
        [
          case_body("started"),
          case_body("completed"),
          ownership_body(2),
          ownership_body(3),
          reviewed
        ]

    projection = case_ok!(bodies)
    [history] = Map.values(projection.histories)

    assert ownership_tuple(Enum.at(history.records, 1)["body"]) ==
             ownership_tuple(ownership_body(1))

    assert ownership_tuple(List.last(history.records)["body"]) ==
             ownership_tuple(ownership_body(3))

    assert projection.ownership.owner == ownership_tuple(ownership_body(3))
    assert Enum.map(history.records, & &1["sequence"]) == [3, 4, 7]
  end

  test "pending ownership remains pending and each ownership error propagates unchanged" do
    bodies =
      ownership_prefix() ++ [case_body("started"), case_body("completed"), ownership_body(2)]

    projection = case_ok!(bodies)
    assert projection.ownership.pending != nil
    assert projection.ownership.owner == ownership_tuple(ownership_body(1))

    for invalid <- [
          bodies ++ [case_body("reviewed")],
          ownership_prefix() ++ [Map.put(case_body("started"), "writer_id", "other")],
          ownership_prefix() ++ [ownership_body(3)]
        ] do
      {bytes, _} = ownership_chain(invalid)
      assert Events.verify_case_history(bytes) == Events.verify_ownership(bytes)
      assert Events.verify_case_history(bytes) == {:error, :invalid_attempt_ownership}
    end
  end

  test "complete framing body and anchor failures propagate without replacing exact unresolved tails" do
    {prefix, records} = ownership_chain(ownership_prefix() ++ [case_body("started")])
    head = ownership_head(List.last(records))

    {complete, _} =
      ownership_chain(ownership_prefix() ++ [case_body("started"), case_body("completed")])

    line = binary_part(complete, byte_size(prefix), byte_size(complete) - byte_size(prefix))

    for size <- 1..(byte_size(line) - 1) do
      tail = binary_part(line, 0, size)
      expected = {:error, {:incomplete_attempt_append, head, tail}}
      assert Events.verify_case_history(prefix <> tail) == expected
      assert Events.verify_case_history(prefix <> tail, head) == expected
    end

    for invalid <- [nil, "", prefix <> "\n", String.duplicate("x", 65_537), "{"] do
      assert Events.verify_case_history(invalid) == Events.verify_ownership(invalid)
    end

    {invalid_body, _} = framed_ownership_chain(ownership_prefix() ++ [%{}])
    assert Events.verify_case_history(invalid_body) == {:error, :invalid_attempt_event}
    assert Events.verify_case_history(prefix, nil) == {:error, :invalid_committed_attempt_head}

    {fork, _} =
      ownership_chain(ownership_prefix() ++ [Map.put(case_body("started"), "attempt_id", "fork")])

    assert Events.verify_case_history(fork, head) == {:error, :committed_attempt_head_mismatch}
    {stale, _} = ownership_chain(ownership_prefix())
    assert Events.verify_case_history(stale, head) == {:error, :committed_attempt_head_mismatch}
    assert {:ok, projection} = Events.verify_case_history(complete)

    for anchor <- Enum.map(records, &ownership_head/1) ++ [projection.ownership.head] do
      assert Events.verify_case_history(complete, anchor) == {:ok, projection}
    end
  end

  test "local same-candidate and pass authorization refusals still precede case replay" do
    authorized = case_body("authorized_next_candidate")

    for changed <- [
          Map.put(authorized, "authorized_candidate_sha", authorized["candidate_sha"]),
          Map.merge(authorized, %{"mechanical_result" => "pass", "verdict" => "pass"})
        ] do
      {bytes, _} = framed_ownership_chain(ownership_prefix() ++ [changed])
      assert Events.verify_case_history(bytes) == {:error, :invalid_attempt_event}
    end
  end

  test "repeated pre-dispatch observations remain explicitly unresolved with every body retained" do
    observed = Map.merge(ownership_body(5), case_locator(case_body("started")))
    changed = Map.put(observed, "evidence", case_body("started")["evidence"])

    {bytes, records} =
      ownership_chain(ownership_prefix() ++ [observed, changed, case_body("started")])

    assert {:unresolved, projection} = Events.verify_case_history(bytes)
    assert_case_records(projection, records)
    [history] = Map.values(projection.histories)
    assert history.state == "not_dispatched"
    assert history.unresolved
    assert hd(projection.unresolved).reason == :repeated_not_dispatched
    assert Enum.map(history.records, & &1["body"]) == [observed, changed, case_body("started")]

    assert {:unresolved, ^projection} =
             Events.verify_case_history(bytes, projection.ownership.head)
  end

  test "identical and changed additional reviews retain both originals without selecting a later verdict" do
    reviewed = case_body("reviewed")

    for next <- [
          reviewed,
          Map.merge(reviewed, %{"reviewer_id" => "other", "verdict" => "product_failure"})
        ] do
      {bytes, records} =
        ownership_chain(
          ownership_prefix() ++
            [case_body("started"), case_body("completed"), reviewed, next, authorized_body(next)]
        )

      assert {:unresolved, projection} = Events.verify_case_history(bytes)
      assert_case_records(projection, records)
      [history] = Map.values(projection.histories)
      assert history.state == "reviewed"
      assert history.unresolved
      assert hd(projection.unresolved).reason == :additional_review
      assert Enum.at(history.records, 2)["body"] == reviewed
      assert Enum.at(history.records, 3)["body"] == next
    end
  end

  test "review evidence replacement or augmentation retains completion and reports unresolved semantics" do
    completed = case_body("completed")
    reviewed = case_body("reviewed")

    for evidence <- [
          case_body("started")["evidence"],
          completed["evidence"] ++ case_body("started")["evidence"]
        ] do
      changed = Map.put(reviewed, "evidence", evidence)

      {bytes, records} =
        ownership_chain(ownership_prefix() ++ [case_body("started"), completed, changed])

      assert {:unresolved, projection} = Events.verify_case_history(bytes)
      assert_case_records(projection, records)
      assert hd(projection.unresolved).reason == :changed_review_evidence
      [history] = Map.values(projection.histories)
      assert Enum.at(history.records, 1)["body"] == completed
      assert List.last(history.records)["body"] == changed
    end
  end

  test "authorization diagnosis or existing disposition changes remain unresolved with original review retained" do
    reviewed = Map.put(case_body("reviewed"), "disposition", ownership_body(4)["disposition"])
    authorized = authorized_body(reviewed)

    for changed <- [
          Map.put(authorized, "diagnosis", ownership_body(4)["prior_rows"]),
          Map.put(authorized, "disposition", ownership_body(4)["prior_rows"])
        ] do
      {bytes, records} =
        ownership_chain(
          ownership_prefix() ++ [case_body("started"), case_body("completed"), reviewed, changed]
        )

      assert {:unresolved, projection} = Events.verify_case_history(bytes)
      assert_case_records(projection, records)
      assert hd(projection.unresolved).reason == :changed_authorization_boundary_references
      [history] = Map.values(projection.histories)
      assert Enum.at(history.records, 2)["body"] == reviewed
      assert List.last(history.records)["body"] == changed
    end
  end

  test "suspended single lane reuses exact original pass records and proposes only its untouched case" do
    first = [lane_started("first"), lane_completed("first")]
    reviewed = reviewed_body(List.last(first), "pass")
    bodies = ownership_prefix() ++ first ++ [reviewed, lane_pending("second")]
    {result, records} = lane_call(bodies, lane_selection(["first", "second"]), :continue)
    assert {:ok, plan} = result
    assert plan.reason == nil
    assert plan.case_history.records == Enum.drop(records, 2)
    assert [reused] = plan.reused
    assert reused.history.records == Enum.slice(records, 2, 3)
    assert [pending] = plan.remaining
    assert pending.pin["case_key"] == "second"
    assert pending.history.records == [List.last(records)]
    assert pending.history.state == "not_dispatched"
    assert lane_call(bodies, plan.selection, :continue) == {result, records}
  end

  test "a lane containing only original pre-dispatch observations proposes them in pinned order" do
    bodies = ownership_prefix() ++ [lane_pending("first"), lane_pending("second")]
    assert {{:ok, plan}, _} = lane_call(bodies, lane_selection(["first", "second"]), :continue)
    assert plan.reused == []
    assert Enum.map(plan.remaining, & &1.pin["case_key"]) == ["first", "second"]
    assert Enum.all?(plan.remaining, &is_nil(hd(&1.history.records)["body"]["attempt_id"]))
  end

  test "an ended pass lane cannot be selected again as either fresh work or a continuation" do
    bodies = ownership_prefix() ++ [lane_started("first"), lane_completed("first")]
    {bytes, records} = ownership_chain(bodies)
    head = ownership_head(List.last(records))
    selection = lane_selection(["first"])

    assert {:blocked, ended} =
             Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, :continue)

    assert ended.reason == :lane_already_ended
    assert ended.reused == [] and ended.remaining == []

    assert {:blocked, fresh} =
             Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, :new)

    assert fresh.reason == :lane_continuation_required
    assert fresh.case_history == ended.case_history
  end

  test "an unfinished started case stops the lane before its later pre-dispatch case" do
    bodies = ownership_prefix() ++ [lane_started("first"), lane_pending("second")]

    assert {{:blocked, plan}, records} =
             lane_call(bodies, lane_selection(["first", "second"]), :continue)

    assert plan.reason == :consumed_lane_failure
    assert plan.remaining == [] and plan.reused == []
    assert plan.case_history.records == Enum.drop(records, 2)
    assert hd(plan.case_history.records)["body"]["evidence"] == lane_started("first")["evidence"]
  end

  test "every consumed non-pass mechanical result stops before later selected work" do
    for mechanical <-
          ~w(required_action_absent assertion_failed evidence_incomplete_post_dispatch provider_environment_failure) do
      completed = Map.put(lane_completed("first"), "mechanical_result", mechanical)

      completed =
        if mechanical == "evidence_incomplete_post_dispatch",
          do: Map.put(completed, "evidence", nil),
          else: completed

      bodies = ownership_prefix() ++ [lane_started("first"), completed, lane_pending("second")]

      assert {{:blocked, plan}, _} =
               lane_call(bodies, lane_selection(["first", "second"]), :continue)

      assert plan.reason == :consumed_lane_failure
      assert Enum.at(plan.case_history.records, 1)["body"] == completed
      assert plan.remaining == []
    end
  end

  test "all independent cause verdicts retain consumption and a failed review cannot turn mechanics into reuse" do
    for verdict <-
          ~w(pass product_failure model_nonconformance evidence_unavailable environment_failure) do
      completed = lane_completed("first")
      reviewed = reviewed_body(completed, verdict)

      bodies =
        ownership_prefix() ++ [lane_started("first"), completed, reviewed, lane_pending("second")]

      {result, _} = lane_call(bodies, lane_selection(["first", "second"]), :continue)

      if verdict == "pass" do
        assert {:ok, plan} = result
        assert length(plan.reused) == 1
      else
        assert {:blocked, plan} = result
        assert plan.reason == :consumed_lane_failure
        assert plan.reused == [] and plan.remaining == []
      end

      assert elem(result, 1).case_history.records |> Enum.at(2) |> Map.fetch!("body") == reviewed
    end
  end

  test "later authorization never resets consumption on the failed original candidate" do
    completed = Map.put(lane_completed("first"), "mechanical_result", "assertion_failed")
    reviewed = reviewed_body(completed, "product_failure")
    authorized = authorized_body(reviewed)

    bodies =
      ownership_prefix() ++
        [lane_started("first"), completed, reviewed, authorized, lane_pending("second")]

    assert {{:blocked, plan}, _} =
             lane_call(bodies, lane_selection(["first", "second"]), :continue)

    assert plan.reason == :consumed_lane_failure
    assert Enum.at(plan.case_history.records, 3)["body"] == authorized
    assert plan.remaining == []
  end

  test "fresh invocation cannot bypass a recorded pre-dispatch lane by choosing new mode" do
    bodies = ownership_prefix() ++ [lane_pending("first")]
    assert {{:blocked, plan}, _} = lane_call(bodies, lane_selection(["first"]), :new)
    assert plan.reason == :lane_continuation_required
    assert plan.case_history.records |> hd() |> Map.fetch!("body") == lane_pending("first")
  end

  test "missing continuation histories do not acquire no-execution proof from absence" do
    for cases <- [[], [lane_pending("first")]] do
      {result, _} =
        lane_call(ownership_prefix() ++ cases, lane_selection(["first", "second"]), :continue)

      assert {:unresolved, plan} = result
      assert plan.reason in [:lane_history_unavailable, :not_dispatched_evidence_unavailable]
      assert plan.reused == [] and plan.remaining == []
      assert length(plan.case_history.records) == length(cases)
    end
  end

  test "selected manifest and specification digests must equal the retained case pins" do
    bodies = ownership_prefix() ++ [lane_pending("first")]
    base = lane_selection(["first"])

    changed_spec =
      put_in(base, ["cases"], [
        Map.put(hd(base["cases"]), "specification_digest", String.duplicate("a", 64))
      ])

    for selection <- [Map.put(base, "manifest_digest", String.duplicate("b", 64)), changed_spec] do
      assert {{:blocked, plan}, _} = lane_call(bodies, selection, :continue)
      assert plan.reason == :attempt_selection_pin_mismatch
      assert plan.case_history.records |> hd() |> Map.fetch!("body") == lane_pending("first")
    end
  end

  test "omitted same-lane history stays visible and prevents a partial selection from claiming continuation" do
    bodies = ownership_prefix() ++ [lane_pending("first"), lane_pending("second")]
    assert {{:unresolved, plan}, _} = lane_call(bodies, lane_selection(["first"]), :continue)
    assert plan.reason == :unselected_lane_history
    assert length(plan.case_history.records) == 2
    assert plan.remaining == []
  end

  test "a new candidate retains head-recorded originals and proposes its own full selection without borrowing passes" do
    bodies =
      ownership_prefix() ++
        [lane_started("first"), lane_completed("first"), lane_pending("second")]

    {bytes, records} = ownership_chain(bodies)
    old_head = ownership_head(Enum.at(records, 1))
    new_head = ownership_head(List.last(records))
    text = head_line(new_head) <> "\n" <> head_line(old_head) <> "\n" <> head_line(new_head)

    selection =
      Map.put(lane_selection(["first", "second"]), "candidate_sha", String.duplicate("2", 40))

    assert {:ok, plan} = Events.verify_lane_history(bytes, text, "m7-vector", selection, :new)
    assert plan.committed_head == new_head
    assert plan.case_history.records == Enum.drop(records, 2)
    assert plan.reused == []
    assert Enum.map(plan.remaining, & &1.pin["case_key"]) == ["first", "second"]
    assert Enum.all?(plan.remaining, &is_nil(&1.history))
    assert List.last(plan.case_history.records)["body"]["state"] == "not_dispatched"
  end

  test "new-lane post-head barrier uses every original consumed record independent of its latest state or locator" do
    completed = Map.put(lane_completed("other"), "mechanical_result", "assertion_failed")
    reviewed = reviewed_body(completed, "product_failure")
    cases = [lane_started("other"), completed, reviewed, authorized_body(reviewed)]
    cases = Enum.map(cases, &Map.put(&1, "lane_id", "other-lane"))

    for count <- 1..4 do
      bodies = ownership_prefix() ++ Enum.take(cases, count)
      assert {{:blocked, plan}, _} = lane_call(bodies, lane_selection(["first"]), :new)
      assert plan.reason == :post_head_consumed_case
      assert length(plan.case_history.records) == count
      assert plan.remaining == []
    end
  end

  test "consumed records at or before the committed head do not create a fictitious post-head barrier" do
    bodies =
      ownership_prefix() ++
        [
          Map.put(lane_started("other"), "lane_id", "other-lane"),
          Map.put(lane_completed("other"), "lane_id", "other-lane")
        ]

    {bytes, records} = ownership_chain(bodies)
    head = ownership_head(List.last(records))

    assert {:ok, plan} =
             Events.verify_lane_history(
               bytes,
               head_line(head),
               "m7-vector",
               lane_selection(["first"]),
               :new
             )

    assert plan.reused == []
    assert [%{history: nil}] = plan.remaining
    assert Enum.all?(plan.case_history.records, &(&1["sequence"] <= head["sequence"]))
  end

  test "fresh full invocation refuses consumed matrix history even after its latest head was committed" do
    for matrix <- ["matrix-1", "different-matrix"] do
      bodies =
        ownership_prefix() ++
          Enum.map(
            [lane_started("first"), lane_completed("first")],
            &Map.put(&1, "logical_matrix_id", matrix)
          )

      {bytes, records} = ownership_chain(bodies)
      head = ownership_head(List.last(records))
      selection = Map.put(lane_selection(["first"]), "logical_matrix_id", "new-matrix")

      assert {:blocked, plan} =
               Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, :new)

      assert plan.reason == :fresh_matrix_already_consumed
      assert plan.remaining == []
    end
  end

  test "completed pre-merge rows remain separate from a prospective full matrix requiring invocation joins" do
    bodies = ownership_prefix() ++ [lane_started("first"), lane_completed("first")]
    {bytes, records} = ownership_chain(bodies)
    head = ownership_head(List.last(records))
    selection = Map.put(lane_selection(["first"]), "logical_matrix_id", "matrix-1")

    assert {:unresolved, plan} =
             Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, :new)

    assert plan.reason == :matrix_invocation_join_required
    assert plan.reused == [] and plan.remaining == []
    assert is_nil(hd(plan.case_history.records)["body"]["logical_matrix_id"])
  end

  test "a same-matrix continuation retains its identities but cannot invent complete invocation joins" do
    bodies =
      ownership_prefix() ++
        Enum.map(
          [lane_started("first"), lane_completed("first"), lane_pending("second")],
          &Map.put(&1, "logical_matrix_id", "matrix-1")
        )

    selection = Map.put(lane_selection(["first", "second"]), "logical_matrix_id", "matrix-1")
    assert {{:unresolved, plan}, _} = lane_call(bodies, selection, :continue)
    assert plan.reason == :matrix_invocation_join_required
    assert plan.remaining == []
    assert Enum.all?(plan.case_history.records, &(&1["body"]["logical_matrix_id"] == "matrix-1"))
  end

  test "a consumed failure in another lane of the same matrix blocks further case proposals" do
    other_started =
      Map.merge(lane_started("other"), %{
        "lane_id" => "other-lane",
        "logical_matrix_id" => "matrix-1"
      })

    pending = Map.put(lane_pending("first"), "logical_matrix_id", "matrix-1")
    bodies = ownership_prefix() ++ [other_started, pending]
    selection = Map.put(lane_selection(["first"]), "logical_matrix_id", "matrix-1")
    assert {{:blocked, plan}, _} = lane_call(bodies, selection, :continue)
    assert plan.reason == :consumed_matrix_failure
    assert plan.case_history.records |> hd() |> Map.fetch!("body") == other_started
  end

  test "other null-matrix lane consumption cannot be guessed into or out of this invocation" do
    for completed <- [
          lane_completed("other"),
          Map.put(lane_completed("other"), "mechanical_result", "assertion_failed")
        ],
        matrix <- [nil, "matrix-1"] do
      cases =
        Enum.map(
          [lane_started("other"), completed],
          &Map.merge(&1, %{"lane_id" => "other-lane", "logical_matrix_id" => matrix})
        )

      bodies = ownership_prefix() ++ cases ++ [lane_pending("first")]
      assert {{:unresolved, plan}, _} = lane_call(bodies, lane_selection(["first"]), :continue)
      assert plan.reason == :multi_lane_invocation_join_required
      assert plan.remaining == [] and plan.reused == []
    end
  end

  test "an unexecuted subcase of a consumed case never becomes a new independent retry proposal" do
    first =
      Enum.map(
        [lane_started("group"), lane_completed("group")],
        &Map.put(&1, "subcase_key", "one")
      )

    pending = Map.put(lane_pending("group"), "subcase_key", "two")

    selection =
      lane_selection([
        Map.take(hd(first), ~w(case_key specification_digest subcase_key)),
        Map.take(pending, ~w(case_key specification_digest subcase_key))
      ])

    assert {{:unresolved, plan}, _} =
             lane_call(ownership_prefix() ++ first ++ [pending], selection, :continue)

    assert plan.reason == :grouped_subcase_join_required
    assert plan.remaining == []
  end

  test "independent completed cases may share an attempt identity without losing their original histories" do
    bodies =
      ownership_prefix() ++
        [
          lane_started("first"),
          lane_completed("first"),
          lane_started("second"),
          lane_completed("second"),
          lane_pending("third")
        ]

    assert {{:ok, plan}, _} =
             lane_call(bodies, lane_selection(["first", "second", "third"]), :continue)

    assert Enum.map(plan.reused, & &1.pin["case_key"]) == ["first", "second"]
    assert Enum.all?(plan.reused, &(hd(&1.history.records)["body"]["attempt_id"] == "attempt-1"))
    assert Enum.map(plan.remaining, & &1.pin["case_key"]) == ["third"]
  end

  test "later completed selection cannot conceal an earlier untouched case or reorder the pinned work" do
    bodies =
      ownership_prefix() ++
        [lane_pending("first"), lane_started("second"), lane_completed("second")]

    assert {{:unresolved, plan}, _} =
             lane_call(bodies, lane_selection(["first", "second"]), :continue)

    assert plan.reason == :noncontiguous_case_order
    assert length(plan.case_history.records) == 3
    assert plan.reused == [] and plan.remaining == []
  end

  test "missing writer designation and pending handoff retain ownership uncertainty without proposing work" do
    cases = [
      [ownership_body(0)],
      ownership_prefix() ++ [lane_pending("first"), ownership_body(2)]
    ]

    for bodies <- cases do
      {bytes, records} = ownership_chain(bodies)
      head = ownership_head(hd(records))

      assert {:unresolved, plan} =
               Events.verify_lane_history(
                 bytes,
                 head_line(head),
                 "m7-vector",
                 lane_selection(["first"]),
                 :new
               )

      assert plan.reason in [:writer_designation_unavailable, :pending_writer_handoff]
      assert plan.remaining == []
    end
  end

  test "previously unresolved repeated observations and changed reviews propagate the exact original case result" do
    observed = lane_pending("first")
    completed = lane_completed("first")

    changed_review =
      Map.put(reviewed_body(completed, "pass"), "evidence", lane_started("first")["evidence"])

    for cases <- [[observed, observed], [lane_started("first"), completed, changed_review]] do
      {bytes, records} = ownership_chain(ownership_prefix() ++ cases)
      head = ownership_head(Enum.at(records, 1))
      expected = Events.verify_case_history(bytes, head)
      assert {:unresolved, _} = expected

      assert Events.verify_lane_history(
               bytes,
               head_line(head),
               "m7-vector",
               lane_selection(["first"]),
               :continue
             ) == expected
    end
  end

  test "framing ownership anchor and incomplete-tail errors propagate before lane planning" do
    {bytes, records} = ownership_chain(ownership_prefix() ++ [lane_pending("first")])
    head = ownership_head(List.last(records))
    text = head_line(head)
    selection = lane_selection(["first"])
    {stale, _} = ownership_chain(ownership_prefix())

    {bad_owner, _} =
      ownership_chain(
        ownership_prefix() ++ [Map.put(lane_pending("first"), "writer_id", "other")]
      )

    for input <- [bytes <> "{", stale, bad_owner] do
      assert Events.verify_lane_history(input, text, "m7-vector", selection, :continue) ==
               Events.verify_case_history(input, head)
    end

    assert Events.verify_lane_history(bytes, "", "m7-vector", selection, :continue) ==
             {:error, :committed_attempt_head_unavailable}

    conflicting = Map.put(head, "digest", String.duplicate("a", 64))

    assert Events.verify_lane_history(
             bytes,
             text <> "\n" <> head_line(conflicting),
             "m7-vector",
             selection,
             :continue
           ) == {:error, :conflicting_committed_attempt_heads}
  end

  test "private lane selection is closed and refuses ambiguous repeated keys improper tails and invalid modes" do
    {bytes, records} = ownership_chain(ownership_prefix())
    text = head_line(ownership_head(List.last(records)))
    base = lane_selection(["first"])
    pin = hd(base["cases"])

    invalid = [
      nil,
      %{},
      Map.put(base, "extra", true),
      Map.put(base, "candidate_sha", "bad"),
      Map.put(base, "logical_matrix_id", :matrix),
      Map.put(base, "cases", []),
      Map.put(base, "cases", [pin, pin]),
      Map.put(base, "cases", [pin | :tail]),
      Map.put(base, "cases", [Map.put(pin, "extra", nil)]),
      Map.put(base, "cases", [Map.delete(pin, "subcase_key")])
    ]

    for selection <- invalid do
      assert Events.verify_lane_history(bytes, text, "m7-vector", selection, :new) ==
               {:error, :invalid_attempt_lane_selection}
    end

    assert Events.verify_lane_history(bytes, text, "m7-vector", base, :retry) ==
             {:error, :invalid_attempt_lane_selection}
  end

  test "an authorized later candidate still requires actual authority evidence instead of trusting reference syntax" do
    completed =
      Map.put(lane_completed("first"), "mechanical_result", "provider_environment_failure")

    reviewed = reviewed_body(completed, "environment_failure")
    authorized = authorized_body(reviewed)

    {bytes, records} =
      ownership_chain(
        ownership_prefix() ++ [lane_started("first"), completed, reviewed, authorized]
      )

    head = ownership_head(List.last(records))

    selection =
      Map.put(lane_selection(["first"]), "candidate_sha", authorized["authorized_candidate_sha"])

    assert {:unresolved, plan} =
             Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, :new)

    assert plan.reason == :prior_failure_authority_join_required
    assert plan.case_history.records == Enum.drop(records, 2)
    assert plan.reused == [] and plan.remaining == []
  end

  test "a head-recorded pre-dispatch row cannot establish continuation or old-host abandonment discovery" do
    bodies =
      ownership_prefix() ++
        [lane_started("first"), lane_completed("first"), lane_pending("second")]

    {bytes, records} = ownership_chain(bodies)
    head = ownership_head(List.last(records))

    assert {:unresolved, plan} =
             Events.verify_lane_history(
               bytes,
               head_line(head),
               "m7-vector",
               lane_selection(["first", "second"]),
               :continue
             )

    assert plan.reason == :head_recorded_lane_join_required
    assert plan.case_history.records == Enum.drop(records, 2)
    assert plan.reused == [] and plan.remaining == []
  end

  test "different candidate lane and matrix identities cannot borrow this lane's pre-dispatch proof" do
    bodies = ownership_prefix() ++ [lane_pending("first")]

    for {field, value} <- [
          {"candidate_sha", String.duplicate("2", 40)},
          {"lane_id", "different-lane"},
          {"logical_matrix_id", "matrix-1"}
        ] do
      selection = Map.put(lane_selection(["first"]), field, value)
      assert {{:unresolved, plan}, _} = lane_call(bodies, selection, :continue)
      assert plan.reason in [:lane_history_unavailable, :matrix_invocation_join_required]
      assert plan.remaining == [] and plan.reused == []
      assert plan.case_history.records |> hd() |> Map.fetch!("body") == lane_pending("first")
    end
  end

  @reference_abc "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "complete reference bytes preserve every original consumed record without adding authority" do
    {cases, supplied} = evidence_history()
    {bytes, records} = ownership_chain(ownership_prefix() ++ cases)
    assert {:ok, projection} = Events.verify_case_history(bytes)
    supplied = Map.put(supplied, "/unused", "CALLER_OWNED_BYTES_MUST_NOT_RETURN")

    assert {:ok, ^projection} = Events.verify_case_evidence(bytes, supplied)

    assert {:ok, ^projection} =
             Events.verify_case_evidence(bytes, projection.ownership.head, supplied)

    assert_case_records(projection, records)
    [history] = Map.values(projection.histories)
    assert history.state == "authorized_next_candidate"
    assert List.last(history.records)["body"]["verdict"] == "environment_failure"
    refute inspect(projection) =~ "CALLER_OWNED_BYTES_MUST_NOT_RETURN"
  end

  test "verified bytes leave case-free pre-dispatch and unfinished consumed histories unchanged" do
    {[started | _], supplied} = evidence_history()
    observed = Map.put(ownership_body(5), "evidence", started["evidence"])

    for cases <- [[], [observed], [started]] do
      {bytes, _} = ownership_chain(ownership_prefix() ++ cases)
      assert {:ok, projection} = Events.verify_case_history(bytes)
      assert {:ok, ^projection} = Events.verify_case_evidence(bytes, supplied)

      assert {:ok, ^projection} =
               Events.verify_case_evidence(bytes, projection.ownership.head, supplied)
    end

    {bytes, _} = ownership_chain(ownership_prefix() ++ [started])
    assert {:ok, projection} = Events.verify_case_history(bytes)

    for supplied <- [nil, [], :unavailable, MapSet.new()] do
      assert {:unavailable,
              %{case_history: ^projection, reference: nil, reason: :invalid_reference_bytes}} =
               Events.verify_case_evidence(bytes, supplied)
    end
  end

  test "each retained reference requires its exact complete binary including LF" do
    {[started, completed, reviewed, authorized] = cases, supplied} = evidence_history()
    {bytes, _} = ownership_chain(ownership_prefix() ++ cases)
    assert {:ok, projection} = Events.verify_case_history(bytes)

    references = [
      {"evidence", hd(started["evidence"])},
      {"evidence", hd(completed["evidence"])},
      {"diagnosis", reviewed["diagnosis"]},
      {"disposition", authorized["disposition"]},
      {"authorization_evidence", authorized["authorization_evidence"]}
    ]

    for {member, reference} <- references do
      path = reference["reference"]

      mutations = [
        {Map.delete(supplied, path), :missing_reference_bytes},
        {Map.put(supplied, path, "abd"), :digest_mismatch},
        {Map.put(supplied, path, "abc\n"), :digest_mismatch},
        {Map.put(supplied, path, nil), :nonbinary_reference_bytes},
        {Map.put(supplied, path, ["abc"]), :nonbinary_reference_bytes}
      ]

      for {changed, reason} <- mutations do
        assert {:unavailable, unavailable} = Events.verify_case_evidence(bytes, changed)
        assert unavailable.case_history == projection
        assert unavailable.member == member
        assert unavailable.reference == reference
        assert unavailable.reason == reason
        assert unavailable.head in Enum.map(projection.records, &ownership_head/1)

        assert {:unavailable, ^unavailable} =
                 Events.verify_case_evidence(bytes, projection.ownership.head, changed)
      end
    end
  end

  test "null post-dispatch evidence remains unavailable through review and authorization" do
    {[started, completed, reviewed, authorized], supplied} = evidence_history()

    completed =
      Map.merge(completed, %{
        "evidence" => nil,
        "mechanical_result" => "evidence_incomplete_post_dispatch"
      })

    reviewed =
      reviewed_body(completed, "evidence_unavailable")
      |> Map.put("diagnosis", reviewed["diagnosis"])

    authorized =
      authorized_body(reviewed)
      |> Map.put("disposition", authorized["disposition"])
      |> Map.put("authorization_evidence", authorized["authorization_evidence"])

    for cases <- [
          [started, completed],
          [started, completed, reviewed],
          [started, completed, reviewed, authorized]
        ] do
      {bytes, records} = ownership_chain(ownership_prefix() ++ cases)
      assert {:ok, projection} = Events.verify_case_history(bytes)

      assert {:unavailable, unavailable} = Events.verify_case_evidence(bytes, supplied)

      assert unavailable.case_history == projection
      assert unavailable.member == "evidence"
      assert unavailable.reference == nil
      assert unavailable.reason == :absent_evidence

      assert {:unavailable, ^unavailable} =
               Events.verify_case_evidence(bytes, projection.ownership.head, supplied)

      assert_case_records(projection, records)
      [history] = Map.values(projection.histories)
      assert history.state == List.last(cases)["state"]
      assert Enum.all?(Enum.drop(history.records, 1), &is_nil(&1["body"]["evidence"]))
    end
  end

  test "repeated references retain their records and conflicting same-path digests cannot share bytes" do
    {[started, completed, reviewed, authorized], supplied} = evidence_history()
    reference = hd(started["evidence"])
    cases = [started, completed, reviewed, authorized]
    cases = Enum.map(cases, &Map.put(&1, "evidence", [reference, reference]))
    {bytes, _} = ownership_chain(ownership_prefix() ++ cases)
    assert {:ok, projection} = Events.verify_case_history(bytes)
    assert {:ok, ^projection} = Events.verify_case_evidence(bytes, supplied)

    conflicting =
      Map.put(
        reference,
        "sha256",
        "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9"
      )

    cases =
      Enum.map(cases, fn body ->
        if body["state"] in ["reviewed", "authorized_next_candidate"],
          do: Map.put(body, "diagnosis", conflicting),
          else: body
      end)

    {bytes, _} = ownership_chain(ownership_prefix() ++ cases)
    assert {:ok, projection} = Events.verify_case_history(bytes)

    for content <- ["abc", "abd"] do
      assert {:unavailable, %{case_history: ^projection, reason: :digest_mismatch}} =
               Events.verify_case_evidence(
                 bytes,
                 Map.put(supplied, reference["reference"], content)
               )
    end
  end

  test "evidence bytes admit empty non-UTF8 and above-frame-size binaries without a new cap" do
    {[started | _], _} = evidence_history()
    path = hd(started["evidence"])["reference"]

    for {content, digest} <- [
          {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
          {<<0, 255, 10>>, "712450d3c4a79eea9509e75dc1dacdeff58034df538536cfae2da882bd8a0c50"},
          {String.duplicate("a", 65_537),
           "008ffc88d3c96a9f307524eb361e47c5222a887fc45fa0c1fb8d429c5c23b430"}
        ] do
      reference = %{"reference" => path, "sha256" => digest}

      {bytes, _} =
        ownership_chain(ownership_prefix() ++ [Map.put(started, "evidence", [reference])])

      assert {:ok, projection} = Events.verify_case_history(bytes)
      assert {:ok, ^projection} = Events.verify_case_evidence(bytes, %{path => content})
    end
  end

  test "history errors anchors incomplete tails and unresolved reviews propagate before byte checks" do
    {[started, completed, reviewed | _], supplied} = evidence_history()
    {bytes, records} = ownership_chain(ownership_prefix() ++ [started, completed, reviewed])
    head = ownership_head(List.last(records))

    {orphan, _} = ownership_chain(ownership_prefix() ++ [completed])
    {foreign, _} = ownership_chain(ownership_prefix() ++ [Map.put(started, "writer_id", "other")])
    {invalid_body, _} = framed_ownership_chain(ownership_prefix() ++ [%{}])

    for invalid <- [nil, "", "{", orphan, foreign, invalid_body, bytes <> "{"] do
      assert Events.verify_case_evidence(invalid, nil) == Events.verify_case_history(invalid)

      assert Events.verify_case_evidence(invalid, head, nil) ==
               Events.verify_case_history(invalid, head)
    end

    assert Events.verify_case_evidence(bytes, nil, supplied) ==
             {:error, :invalid_committed_attempt_head}

    {fork, _} =
      ownership_chain(ownership_prefix() ++ [Map.put(started, "attempt_id", "other")])

    assert Events.verify_case_evidence(fork, head, supplied) ==
             {:error, :committed_attempt_head_mismatch}

    {unresolved, _} =
      ownership_chain(ownership_prefix() ++ [started, completed, reviewed, reviewed])

    assert {:unresolved, projection} = Events.verify_case_history(unresolved)
    assert {:unresolved, ^projection} = Events.verify_case_evidence(unresolved, %{})

    assert {:unresolved, ^projection} =
             Events.verify_case_evidence(unresolved, projection.ownership.head, nil)
  end

  test "matching case bytes leave pending ownership and recorded pass verdicts as existing facts" do
    {[started, completed | _], supplied} = evidence_history()
    completed = Map.put(completed, "mechanical_result", "pass")
    reviewed = reviewed_body(completed, "pass")

    {bytes, _} =
      ownership_chain(ownership_prefix() ++ [started, completed, reviewed, ownership_body(2)])

    assert {:ok, projection} = Events.verify_case_history(bytes)
    assert projection.ownership.pending != nil
    assert {:ok, ^projection} = Events.verify_case_evidence(bytes, supplied)
    [history] = Map.values(projection.histories)
    assert history.state == "reviewed"
    assert List.last(history.records)["body"]["verdict"] == "pass"
    assert List.last(history.records)["body"]["authorized_candidate_sha"] == nil
  end

  defp evidence_history do
    reference = fn path -> %{"reference" => path, "sha256" => @reference_abc} end
    execution = reference.("/evidence/m7/execution-path.json")
    result = reference.("/evidence/m7/complete.log")
    diagnosis = reference.("/evidence/m7/diagnosis.json")

    disposition =
      reference.(
        "git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance"
      )

    authorization = reference.("/evidence/m7/authorization.json")
    started = Map.put(case_body("started"), "evidence", [execution])
    completed = Map.put(case_body("completed"), "evidence", [result])
    reviewed = reviewed_body(completed, "environment_failure") |> Map.put("diagnosis", diagnosis)

    authorized =
      authorized_body(reviewed)
      |> Map.put("disposition", disposition)
      |> Map.put("authorization_evidence", authorization)

    supplied =
      Map.new(
        [execution, result, diagnosis, disposition, authorization],
        &{&1["reference"], "abc"}
      )

    {[started, completed, reviewed, authorized], supplied}
  end

  defp lane_started(key) do
    Map.merge(case_body("started"), %{
      "case_key" => key,
      "subcase_key" => nil,
      "logical_matrix_id" => nil
    })
  end

  defp lane_completed(key) do
    Map.merge(case_body("completed"), %{
      "case_key" => key,
      "subcase_key" => nil,
      "logical_matrix_id" => nil,
      "mechanical_result" => "pass"
    })
  end

  defp lane_pending(key), do: Map.merge(ownership_body(5), case_locator(lane_started(key)))

  defp lane_selection(keys) do
    Map.merge(
      Map.take(
        lane_started("first"),
        ~w(candidate_sha lane_id logical_matrix_id manifest_digest)
      ),
      %{
        "cases" =>
          Enum.map(keys, fn
            key when is_binary(key) ->
              Map.take(lane_started(key), ~w(case_key specification_digest subcase_key))

            pin ->
              pin
          end)
      }
    )
  end

  defp lane_call(bodies, selection, mode) do
    {bytes, records} = ownership_chain(bodies)
    head = ownership_head(Enum.at(records, 1))
    {Events.verify_lane_history(bytes, head_line(head), "m7-vector", selection, mode), records}
  end

  defp head_line(head),
    do: "index-head: #{head["campaign_id"]} #{head["sequence"]} #{head["digest"]}"

  defp case_locator(body),
    do: Map.take(body, ~w(candidate_sha lane_id logical_matrix_id case_key subcase_key))

  defp case_body("started"), do: ownership_body(6)
  defp case_body("completed"), do: ownership_body(8)
  defp case_body("reviewed"), do: ownership_body(9)
  defp case_body("authorized_next_candidate"), do: ownership_body(10)

  defp reviewed_body(completed, verdict) do
    Map.merge(completed, %{
      "state" => "reviewed",
      "verdict" => verdict,
      "reviewer_id" => "reviewer-1",
      "diagnosis" =>
        if(verdict == "pass", do: completed["diagnosis"], else: ownership_body(9)["diagnosis"])
    })
  end

  defp authorized_body(reviewed) do
    Map.merge(reviewed, %{
      "state" => "authorized_next_candidate",
      "authorized_candidate_sha" => ownership_body(10)["authorized_candidate_sha"],
      "authorization_evidence" => ownership_body(10)["authorization_evidence"],
      "disposition" => reviewed["disposition"] || ownership_body(10)["disposition"]
    })
  end

  defp case_ok!(bodies) do
    {bytes, records} = ownership_chain(bodies)
    assert {:ok, projection} = Events.verify_case_history(bytes)
    assert_case_records(projection, records)
    projection
  end

  defp case_refuses!(bodies) do
    {bytes, _} = ownership_chain(bodies)
    assert {:ok, _} = Events.verify_ownership(bytes)
    assert Events.verify_case_history(bytes) == {:error, :invalid_attempt_case_history}
  end

  defp assert_case_records(projection, records) do
    cases = Enum.filter(records, &(&1["body"]["kind"] == "case"))
    assert projection.records == cases

    for {locator, history} <- projection.histories do
      assert history.records == Enum.filter(cases, &(case_locator(&1["body"]) == locator))
    end
  end

  defp ownership_prefix, do: [ownership_body(0), ownership_body(1)]
  defp ownership_body(index), do: vector(index)["body"]
  defp ownership_tuple(body), do: Map.take(body, ~w(writer_id host_id ownership_epoch))
  defp ownership_head(record), do: Map.take(record, ~w(campaign_id sequence digest))

  defp ownership_ok!(bodies) do
    {bytes, _} = ownership_chain(bodies)
    assert {:ok, projection} = Events.verify_ownership(bytes)
    projection
  end

  defp ownership_chain(bodies) do
    {bytes, records} = framed_ownership_chain(bodies)

    for record <- records do
      assert {:ok, line, ^record} = encode(record)
      assert {:ok, ^record} = Events.decode(strip_lf(line))
    end

    assert {:ok, _} = Frames.verify(bytes)
    {bytes, records}
  end

  defp framed_ownership_chain(bodies) do
    {bytes, records, _head} =
      Enum.reduce(bodies, {"", [], nil}, fn original, {bytes, records, head} ->
        body =
          case original["kind"] do
            "writer_relinquished" -> Map.put(original, "preceding_head", head)
            "writer_accepted" -> Map.put(original, "relinquishment_head", head)
            _ -> original
          end

        sequence = length(records) + 1
        previous = if is_nil(head), do: nil, else: head["digest"]
        assert {:ok, line, record} = Frames.encode("m7-vector", sequence, previous, body)
        {bytes <> line, records ++ [record], ownership_head(record)}
      end)

    {bytes, records}
  end

  defp vector(index) do
    {preimage, _} = Enum.at(@vectors, index)
    {:ok, unsigned} = ConfigJson.decode(preimage)
    unsigned
  end

  defp encode(record),
    do:
      Events.encode(
        record["campaign_id"],
        record["sequence"],
        record["previous_digest"],
        record["body"]
      )

  defp rejects(record) do
    assert encode(record) == {:error, :invalid_attempt_event}

    case Frames.encode(
           record["campaign_id"],
           record["sequence"],
           record["previous_digest"],
           record["body"]
         ) do
      {:ok, line, _} -> assert Events.decode(strip_lf(line)) == {:error, :invalid_attempt_event}
      {:error, :invalid_attempt_frame} -> :ok
    end
  end

  defp with_reference(record, value) do
    reference = hd(record["body"]["evidence"]) |> Map.put("reference", value)
    put_in(record, ["body", "evidence"], [reference])
  end

  defp strip_lf(line), do: binary_part(line, 0, byte_size(line) - 1)
end
