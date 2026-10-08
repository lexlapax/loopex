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
