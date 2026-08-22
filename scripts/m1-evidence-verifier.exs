defmodule Loopex.M1EvidenceVerifier do
  @moduledoc false

  @matrix_path "docs/evidence/M1-toolchain-matrix.md"
  @negative_path "docs/evidence/M1-negative-demonstrations.md"
  @plan_path "docs/plans/M1.md"
  @plans_readme "docs/plans/README.md"
  @root_readme "README.md"

  @matrix_start "<!-- loopex:m1-matrix:start -->"
  @matrix_end "<!-- loopex:m1-matrix:end -->"
  @matrix_prefix "# M1 Toolchain Matrix\n\n#{@matrix_start}\n```text\n"
  @matrix_suffix "```\n#{@matrix_end}\n"

  @empty_closure "| Closure | — | — | — |"
  @sha ~r/\A[0-9a-f]{40}\z/u
  @digest ~r/\A[0-9a-f]{64}\z/u
  @safe_path ~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*\z/u
  @token ~r/\A[\x21-\x7E]+\z/u
  @version ~r/\A[0-9]+(?:\.[0-9]+)*\z/u

  @identity_fields ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity recorded)
  @metadata_fields ~w(candidate gate_sha256 runner_sha256 launcher_sha256 exunit_runner_sha256 deps_budget_sha256 verifier_sha256 tool_versions_sha256 command)
  @capture_fields ~w(lane candidate gate_sha256 command elixir otp erts seed executed verdict exit wall os arch limits provider model endpoint adapter_build executor_build executor_identity tool_identity recorded)
  @m0_fields ~w(lane candidate gate_sha256 command elixir otp provider model endpoint verdict exit)

  @bound_artifacts [
    {"gate_sha256", "docs/plans/M1-gate.md"},
    {"runner_sha256", "scripts/check-m1-gate.sh"},
    {"launcher_sha256", "scripts/m1-gate-launcher.escript"},
    {"exunit_runner_sha256", "scripts/m1-exunit-runner.exs"},
    {"deps_budget_sha256", "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex"},
    {"verifier_sha256", "scripts/m1-evidence-verifier.exs"},
    {"tool_versions_sha256", ".tool-versions"}
  ]

  @negative_records [
    {"## Outcome 2: owner post-commit fence", "current_owner_post_commit_fence",
     "apps/loopex/test/session_lifecycle_test.exs"},
    {"## Outcome 3: atomic owner-epoch transaction", "store_atomic_admission_compare",
     "apps/loopex_store_local/test/store_conformance_test.exs"},
    {"## Outcome 3: commit-unknown domain fence", "commit_unknown_dispatch_fence",
     "apps/loopex_store_local/test/store_conformance_test.exs"},
    {"## Outcome 6: final executor validation", "executor_final_prestart_validation",
     "apps/loopex_executor_local/test/executor_test.exs"},
    {"## Outcome 8: no-blind-retry transition", "no_blind_retry_without_receipt",
     "apps/loopex_reference_client/test/end_to_end_recovery_test.exs"}
  ]
  @negative_fields ~w(mechanism_disabled selector observed_failure candidate artifact restored_sha256)

  @status_markers %{
    @plans_readme => [
      {"<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"},
      {"<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"}
    ],
    @root_readme => [
      {"<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"}
    ]
  }

  @spec pair(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def pair(root) do
    with :ok <- root?(root),
         {:ok, pairs} <- locked_pairs(root),
         {:ok, running} <- running_pair(),
         {lane, expected} when not is_nil(lane) <-
           Enum.find(pairs, fn {_lane, pair} ->
             pair.elixir == running.elixir and pair.otp == running.otp
           end) do
      {:ok,
       "LOOPEX_M1_PAIR lane=#{lane} elixir=#{expected.elixir} otp=#{expected.otp} " <>
         "erts=#{running.erts}"}
    else
      nil -> {:error, "the running VM is not one exact locked M1 toolchain pair"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec negative(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def negative(root, @negative_path) do
    with :ok <- root?(root),
         {:ok, bytes} <- current_blob(root, @negative_path),
         :ok <- canonical_text(bytes, @negative_path),
         {:ok, records} <- negative_document(bytes),
         :ok <- validate_negative_records(root, records) do
      :ok
    end
  end

  def negative(_root, _path),
    do: {:error, "negative evidence path must be #{@negative_path}"}

  @spec all(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def all(root, @matrix_path, @negative_path) do
    with :ok <- root?(root),
         :ok <- negative(root, @negative_path),
         {:ok, matrix} <- current_blob(root, @matrix_path),
         :ok <- canonical_text(matrix, @matrix_path),
         {:ok, metadata, captures, m0_rows} <- matrix_document(matrix),
         :ok <- validate_matrix(root, matrix, metadata, captures, m0_rows) do
      :ok
    end
  end

  def all(_root, _matrix, _negative),
    do: {:error, "evidence paths must be #{@matrix_path} and #{@negative_path}"}

  defp root?(root) do
    if is_binary(root) and Path.type(root) == :absolute and
         File.regular?(Path.join(root, "mix.exs")),
       do: :ok,
       else: {:error, "repository root must be an absolute checkout containing mix.exs"}
  end

  defp locked_pairs(root) do
    with {:ok, bytes} <- current_blob(root, ".tool-versions"),
         :ok <- canonical_text(bytes, ".tool-versions") do
      declarations =
        bytes
        |> String.split("\n")
        |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)

      case declarations do
        [
          "elixir 1.17.0-otp-26",
          "erlang 26.0",
          "elixir 1.20.3-otp-29",
          "erlang 29.0.5"
        ] ->
          {:ok,
           [
             {"floor", %{elixir: "1.17.0", otp: "26.0"}},
             {"current", %{elixir: "1.20.3", otp: "29.0.5"}}
           ]}

        _other ->
          {:error, ".tool-versions does not declare the two exact locked M1 pairs"}
      end
    end
  end

  defp running_pair do
    root = :code.root_dir() |> List.to_string()
    major = System.otp_release()
    otp_path = Path.join([root, "releases", major, "OTP_VERSION"])

    with {:ok, otp_bytes} <- File.read(otp_path),
         true <- Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)*\n\z/u, otp_bytes),
         otp = String.trim_trailing(otp_bytes, "\n"),
         erts = :erlang.system_info(:version) |> List.to_string(),
         true <- Regex.match?(@version, erts),
         true <- :file.native_name_encoding() == :utf8 do
      {:ok, %{elixir: System.version(), otp: otp, erts: erts}}
    else
      _other ->
        {:error, "the running VM's exact OTP, ERTS, or native UTF-8 encoding is unavailable"}
    end
  end

  defp matrix_document(bytes) do
    with true <- String.starts_with?(bytes, @matrix_prefix),
         true <- String.ends_with?(bytes, @matrix_suffix),
         size when size >= 0 <-
           byte_size(bytes) - byte_size(@matrix_prefix) - byte_size(@matrix_suffix),
         body <- binary_part(bytes, byte_size(@matrix_prefix), size),
         true <- String.ends_with?(body, "\n"),
         false <- String.ends_with?(body, "\n\n"),
         lines <- body |> String.trim_trailing("\n") |> String.split("\n"),
         [metadata_line, floor_capture, current_capture, linux_capture, floor_m0, current_m0] <-
           lines,
         {:ok, metadata} <- parse_record(metadata_line, "matrix", @metadata_fields),
         {:ok, floor_capture} <- parse_record(floor_capture, "capture", @capture_fields),
         {:ok, current_capture} <- parse_record(current_capture, "capture", @capture_fields),
         {:ok, linux_capture} <- parse_record(linux_capture, "capture", @capture_fields),
         {:ok, floor_m0} <- parse_record(floor_m0, "m0", @m0_fields),
         {:ok, current_m0} <- parse_record(current_m0, "m0", @m0_fields) do
      {:ok, metadata, [floor_capture, current_capture, linux_capture], [floor_m0, current_m0]}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "#{@matrix_path} must use the exact M1 six-line fenced grammar"}
    end
  end

  defp parse_record(line, kind, fields) do
    case String.split(line, " ") do
      [^kind | encoded] when length(encoded) == length(fields) ->
        encoded
        |> Enum.zip(fields)
        |> Enum.reduce_while({:ok, %{}}, fn {token, field}, {:ok, record} ->
          case String.split(token, "=", parts: 2) do
            [^field, value] when value != "" ->
              if Regex.match?(@token, value),
                do: {:cont, {:ok, Map.put(record, field, value)}},
                else: {:halt, {:error, "#{kind} #{field} is not one printable token"}}

            _other ->
              {:halt, {:error, "#{kind} fields are missing, reordered, or ambiguous"}}
          end
        end)

      _other ->
        {:error, "#{kind} fields are missing, reordered, or ambiguous"}
    end
  end

  defp validate_matrix(root, matrix, metadata, captures, m0_rows) do
    candidate = metadata["candidate"]

    with :ok <- sha(candidate, "matrix candidate"),
         :ok <- ancestor(root, candidate, "matrix candidate"),
         :ok <- exact(metadata["command"], "bash-p:scripts/check-m1-gate.sh", "matrix command"),
         :ok <- bound_artifacts(root, candidate, metadata),
         {:ok, pairs} <- locked_pairs(root),
         :ok <- captures(captures, pairs, candidate, metadata),
         :ok <- m0_rows(root, m0_rows, pairs, candidate),
         {:ok, evidence} <- evidence_commit(root, candidate, matrix),
         :ok <- lifecycle(root, evidence, matrix, metadata) do
      :ok
    end
  end

  defp bound_artifacts(root, candidate, metadata) do
    Enum.reduce_while(@bound_artifacts, :ok, fn {field, path}, :ok ->
      with digest <- metadata[field],
           :ok <- digest(digest, "matrix #{field}"),
           {:ok, committed} <- committed_blob(root, candidate, path),
           :ok <- digest_matches(committed, digest, "#{path} at source candidate"),
           {:ok, current} <- current_blob(root, path),
           :ok <- digest_matches(current, digest, "current #{path}") do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp captures(rows, pairs, candidate, metadata) do
    profiles = capture_profiles(pairs)
    expected_lanes = Enum.map(profiles, &elem(&1, 0))

    if Enum.map(rows, & &1["lane"]) != expected_lanes do
      {:error, "capture rows must be exactly floor, current, then linux-current"}
    else
      with :ok <- validate_capture_rows(rows, profiles, candidate, metadata),
           :ok <- capture_identities_agree(rows) do
        :ok
      end
    end
  end

  defp capture_profiles([{"floor", floor}, {"current", current}]) do
    [
      {"floor", floor, "darwin"},
      {"current", current, "darwin"},
      {"linux-current", current, "linux"}
    ]
  end

  defp validate_capture_rows(rows, profiles, candidate, metadata) do
    Enum.zip(rows, profiles)
    |> Enum.reduce_while(:ok, fn {row, {lane, pair, os}}, :ok ->
      with :ok <- exact(row["lane"], lane, "capture lane"),
           :ok <- exact(row["candidate"], candidate, "capture candidate"),
           :ok <- exact(row["gate_sha256"], metadata["gate_sha256"], "capture gate digest"),
           :ok <- exact(row["command"], metadata["command"], "capture command"),
           :ok <- exact(row["elixir"], pair.elixir, "#{lane} capture Elixir"),
           :ok <- exact(row["otp"], pair.otp, "#{lane} capture OTP"),
           :ok <- version(row["erts"], "#{lane} capture ERTS"),
           :ok <- integer(row["seed"], 0, 999_999, "#{lane} capture seed"),
           :ok <- integer(row["executed"], 1, 9_999_999, "#{lane} protected count"),
           :ok <- exact(row["verdict"], "CAPTURE", "#{lane} capture verdict"),
           :ok <- exact(row["exit"], "0", "#{lane} capture exit"),
           :ok <- audit_token(row["wall"], "#{lane} capture wall"),
           :ok <- exact(row["os"], os, "#{lane} capture os"),
           :ok <- audit_token(row["arch"], "#{lane} capture arch"),
           :ok <- resource_limits(row["limits"], "#{lane} capture limits"),
           :ok <- validate_capture_identity(row, lane) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_capture_identity(row, lane) do
    with :ok <- audit_token(row["provider"], "#{lane} capture provider"),
         :ok <- audit_token(row["model"], "#{lane} capture model"),
         :ok <- audit_token(row["endpoint"], "#{lane} capture endpoint"),
         :ok <-
           exact(
             row["adapter_build"],
             "loopex_llm_reqllm@0.0.0",
             "#{lane} capture adapter_build"
           ),
         :ok <-
           exact(
             row["executor_build"],
             "loopex_executor_local@0.0.0",
             "#{lane} capture executor_build"
           ),
         :ok <- audit_token(row["executor_identity"], "#{lane} capture executor_identity"),
         :ok <- audit_token(row["tool_identity"], "#{lane} capture tool_identity"),
         :ok <- utc_second(row["recorded"], "#{lane} capture recorded") do
      :ok
    end
  end

  defp capture_identities_agree([floor, current, linux]) do
    @identity_fields
    |> Enum.reject(&(&1 == "recorded"))
    |> Enum.reduce_while(:ok, fn field, :ok ->
      if floor[field] == current[field] and floor[field] == linux[field],
        do: {:cont, :ok},
        else: {:halt, {:error, "capture lanes disagree about #{field}"}}
    end)
  end

  defp m0_rows(root, rows, pairs, candidate) do
    expected_lanes = Enum.map(pairs, &elem(&1, 0))

    if Enum.map(rows, & &1["lane"]) != expected_lanes do
      {:error, "inherited M0 rows must be exactly floor then current"}
    else
      digests = Enum.map(rows, & &1["gate_sha256"])

      with true <- length(Enum.uniq(digests)) == 1,
           [m0_digest] <- Enum.uniq(digests),
           :ok <- digest(m0_digest, "M0 gate digest"),
           {:ok, committed} <- committed_blob(root, candidate, "docs/plans/M0-gate.md"),
           :ok <- digest_matches(committed, m0_digest, "M0 gate at source candidate"),
           {:ok, current} <- current_blob(root, "docs/plans/M0-gate.md"),
           :ok <- digest_matches(current, m0_digest, "current M0 gate") do
        Enum.zip(rows, pairs)
        |> Enum.reduce_while(:ok, fn {row, {lane, pair}}, :ok ->
          with :ok <- exact(row["lane"], lane, "M0 lane"),
               :ok <- exact(row["candidate"], candidate, "M0 candidate"),
               :ok <- exact(row["command"], "bash:scripts/check-m0-gate.sh", "M0 command"),
               :ok <- exact(row["elixir"], pair.elixir, "#{lane} M0 Elixir"),
               :ok <- exact(row["otp"], pair.otp, "#{lane} M0 OTP"),
               :ok <- audit_token(row["provider"], "#{lane} M0 provider"),
               :ok <- audit_token(row["model"], "#{lane} M0 model"),
               :ok <- audit_token(row["endpoint"], "#{lane} M0 endpoint"),
               :ok <- exact(row["verdict"], "GREEN", "#{lane} M0 verdict"),
               :ok <- exact(row["exit"], "0", "#{lane} M0 exit") do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      else
        false -> {:error, "inherited M0 rows disagree about the gate digest"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evidence_commit(root, candidate, matrix) do
    with {:ok, head} <- head(root),
         {:ok, commits} <- ancestry_commits(root, candidate, head) do
      matches =
        Enum.filter(commits, fn %{commit: commit, parents: parents} ->
          parents == [candidate] and
            changed_paths(root, candidate, commit) == {:ok, [@matrix_path]} and
            committed_blob(root, commit, @matrix_path) == {:ok, matrix}
        end)

      case matches do
        [%{commit: evidence}] ->
          {:ok, evidence}

        [] ->
          {:error, "no direct evidence-only child E of source candidate C reaches HEAD"}

        _other ->
          {:error, "more than one evidence-only child E of source candidate C reaches HEAD"}
      end
    end
  end

  defp lifecycle(root, evidence, matrix, metadata) do
    with {:ok, head} <- head(root),
         {:ok, evidence_plan} <- committed_blob(root, evidence, @plan_path),
         {:ok, :empty, @empty_closure} <- closure_row(evidence_plan),
         {:ok, current_plan} <- current_blob(root, @plan_path),
         {:ok, state, current_row} <- closure_row(current_plan) do
      case state do
        :empty ->
          if head == evidence,
            do: :ok,
            else: {:error, "an open descendant of evidence commit E is not an M1 gate candidate"}

        :closed ->
          closure_lifecycle(root, evidence, head, matrix, current_row, metadata)
      end
    else
      {:ok, :closed, _row} ->
        {:error, "evidence commit E already contains a completed Closure row"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp closure_lifecycle(root, evidence, head, matrix, current_row, metadata) do
    with {:ok, commits} <- ancestry_commits(root, evidence, head),
         {:ok, states} <- closure_states(root, evidence, commits) do
      first_completions =
        Enum.filter(commits, fn %{commit: commit, parents: parents} ->
          relevant_parents = Enum.filter(parents, &Map.has_key?(states, &1))

          states[commit] == :closed and relevant_parents != [] and
            Enum.all?(relevant_parents, &(states[&1] == :empty))
        end)

      case first_completions do
        [%{commit: transition, parents: [^evidence]}] ->
          with true <- closure_transition?(root, evidence, transition, metadata["gate_sha256"]),
               :ok <-
                 closed_candidate(current_row, transition, evidence, metadata["gate_sha256"]),
               :ok <- retained_history(root, commits, transition, matrix, current_row) do
            :ok
          else
            false ->
              {:error, "the first closure completion is not the exact transition-only child T"}

            {:error, reason} ->
              {:error, reason}
          end

        [_one] ->
          {:error, "the first closure completion is not a direct child T of evidence commit E"}

        [] ->
          {:error, "no first closure completion from evidence commit E reaches HEAD"}

        _other ->
          {:error, "more than one first closure completion from evidence commit E reaches HEAD"}
      end
    end
  end

  defp closure_states(root, evidence, commits) do
    Enum.reduce_while([%{commit: evidence} | commits], {:ok, %{}}, fn %{commit: commit},
                                                                      {:ok, states} ->
      with {:ok, plan} <- committed_blob(root, commit, @plan_path),
           {:ok, state, _row} <- closure_row(plan) do
        {:cont, {:ok, Map.put(states, commit, state)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp closure_transition?(root, evidence, transition, gate_digest) do
    changed_paths(root, evidence, transition) ==
      {:ok, Enum.sort([@plan_path, @plans_readme, @root_readme])} and
      plan_closure_only?(root, evidence, transition, gate_digest) and
      Enum.all?(@status_markers, fn {path, markers} ->
        status_blocks_only?(root, evidence, transition, path, markers)
      end)
  end

  defp plan_closure_only?(root, evidence, transition, gate_digest) do
    with {:ok, before} <- committed_blob(root, evidence, @plan_path),
         {:ok, after_bytes} <- committed_blob(root, transition, @plan_path),
         {:ok, :empty, @empty_closure} <- closure_row(before),
         {:ok, :closed, row} <- closure_row(after_bytes),
         :ok <- closed_candidate(row, transition, evidence, gate_digest) do
      replace_one_line(before, @empty_closure, row) == {:ok, after_bytes}
    else
      _other -> false
    end
  end

  defp status_blocks_only?(root, evidence, transition, path, markers) do
    with {:ok, before} <- committed_blob(root, evidence, path),
         {:ok, after_bytes} <- committed_blob(root, transition, path),
         {:ok, before_normal, before_blocks} <- normalize_blocks(before, markers),
         {:ok, after_normal, after_blocks} <- normalize_blocks(after_bytes, markers) do
      before_normal == after_normal and
        Enum.zip(before_blocks, after_blocks) |> Enum.all?(fn {left, right} -> left != right end)
    else
      _other -> false
    end
  end

  defp retained_history(root, commits, transition, matrix, closure) do
    descendants =
      Enum.filter(commits, fn %{commit: commit} ->
        ancestor?(root, transition, commit)
      end)

    Enum.reduce_while(descendants, :ok, fn %{commit: commit}, :ok ->
      with {:ok, ^matrix} <- committed_blob(root, commit, @matrix_path),
           {:ok, plan} <- committed_blob(root, commit, @plan_path),
           {:ok, :closed, ^closure} <- closure_row(plan) do
        {:cont, :ok}
      else
        _other ->
          {:halt,
           {:error,
            "a descendant of transition T changed the retained matrix or M1 Closure binding"}}
      end
    end)
  end

  defp closed_candidate(row, _transition, evidence, gate_digest) do
    expression =
      ~r/\A\| Closure \| ([^|]+) \| ([^|]+) \| candidate `([0-9a-f]{40})`; concept `sha256:([0-9a-f]{64})`; technical `sha256:([0-9a-f]{64})`; gate `sha256:([0-9a-f]{64})` \|\z/u

    case Regex.run(expression, row) do
      [_all, authority, authority_evidence, ^evidence, _concept, _technical, ^gate_digest] ->
        with :ok <- meaningful(authority, "Closure authority"),
             :ok <- meaningful(authority_evidence, "Closure authority evidence") do
          :ok
        end

      _other ->
        {:error, "M1 Closure must bind evidence commit E and the captured gate digest"}
    end
  end

  defp closure_row(bytes) do
    rows = bytes |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| Closure |"))

    case rows do
      [@empty_closure] -> {:ok, :empty, @empty_closure}
      [row] -> {:ok, :closed, row}
      _other -> {:error, "M1 plan must contain exactly one canonical Closure row"}
    end
  end

  defp replace_one_line(bytes, old, new) do
    lines = String.split(bytes, "\n", trim: false)
    positions = lines |> Enum.with_index() |> Enum.filter(fn {line, _index} -> line == old end)

    case positions do
      [{^old, index}] -> {:ok, lines |> List.replace_at(index, new) |> Enum.join("\n")}
      _other -> {:error, "M1 plan does not contain one empty Closure row"}
    end
  end

  defp normalize_blocks(bytes, markers) do
    Enum.with_index(markers)
    |> Enum.reduce_while({:ok, bytes, []}, fn {{start_marker, end_marker}, index},
                                              {:ok, normalized, blocks} ->
      with {:ok, content} <- one_block(normalized, start_marker, end_marker),
           {:ok, replaced} <- replace_block(normalized, start_marker, end_marker, index) do
        {:cont, {:ok, replaced, blocks ++ [content]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp one_block(bytes, start_marker, end_marker) do
    starts = :binary.matches(bytes, start_marker)
    ends = :binary.matches(bytes, end_marker)

    case {starts, ends} do
      {[{start_at, start_size}], [{end_at, _end_size}]}
      when end_at > start_at + start_size ->
        {:ok, binary_part(bytes, start_at + start_size, end_at - start_at - start_size)}

      _other ->
        {:error, "status document markers are missing, duplicated, or reordered"}
    end
  end

  defp replace_block(bytes, start_marker, end_marker, index) do
    with {:ok, _content} <- one_block(bytes, start_marker, end_marker),
         [{start_at, start_size}] <- :binary.matches(bytes, start_marker),
         [{end_at, _end_size}] <- :binary.matches(bytes, end_marker) do
      before = binary_part(bytes, 0, start_at + start_size)
      after_bytes = binary_part(bytes, end_at, byte_size(bytes) - end_at)
      {:ok, before <> "\n<LOOPEX_STATUS_BLOCK_#{index}>\n" <> after_bytes}
    else
      _other -> {:error, "status document markers are unavailable"}
    end
  end

  defp negative_document(bytes) do
    lines = String.split(bytes, "\n", trim: false)
    expected_count = 2 + length(@negative_records) * 6

    with true <- length(lines) == expected_count,
         ["# M1 Negative Demonstrations", "" | rest] <- lines,
         {:ok, records, [""]} <- take_negative_records(rest, @negative_records, []) do
      {:ok, records}
    else
      _other -> {:error, "#{@negative_path} must use the exact five-record skeleton"}
    end
  end

  defp take_negative_records(lines, [], records), do: {:ok, Enum.reverse(records), lines}

  defp take_negative_records(
         [heading, "", "```json", json, "```" | rest],
         [{heading, mechanism, selector} | expected],
         records
       ) do
    separator = if expected == [], do: rest, else: tl_if_blank(rest)

    case separator do
      {:error, reason} ->
        {:error, reason}

      remaining ->
        take_negative_records(remaining, expected, [{mechanism, selector, json} | records])
    end
  end

  defp take_negative_records(_lines, _expected, _records),
    do: {:error, "negative evidence section is malformed"}

  defp tl_if_blank(["" | rest]), do: rest
  defp tl_if_blank(_other), do: {:error, "negative evidence sections require one blank separator"}

  defp validate_negative_records(root, records) do
    Enum.reduce_while(records, :ok, fn {mechanism, selector, json}, :ok ->
      with {:ok, pairs} <- json_object(json),
           true <- Enum.map(pairs, &elem(&1, 0)) == @negative_fields,
           true <- canonical_json(pairs) == json,
           record <- Map.new(pairs),
           :ok <- exact(record["mechanism_disabled"], mechanism, "negative mechanism"),
           :ok <- exact(record["selector"], selector, "negative selector"),
           :ok <- meaningful_ascii(record["observed_failure"], "observed_failure"),
           :ok <- sha(record["candidate"], "negative candidate"),
           :ok <- ancestor(root, record["candidate"], "negative candidate"),
           :ok <- safe_artifact(record["artifact"]),
           {:ok, restored} <- restored_digest(record["restored_sha256"]),
           {:ok, committed} <- committed_blob(root, record["candidate"], record["artifact"]),
           :ok <- digest_matches(committed, restored, "negative candidate artifact"),
           {:ok, current} <- current_blob(root, record["artifact"]),
           :ok <- digest_matches(current, restored, "restored current artifact") do
        {:cont, :ok}
      else
        false -> {:halt, {:error, "negative JSON fields are missing, reordered, or extra"}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp json_object(<<"{", rest::binary>>), do: json_members(rest, [], MapSet.new())
  defp json_object(_other), do: {:error, "negative record must be one JSON object"}

  defp json_members(<<"}">>, pairs, _seen), do: {:ok, Enum.reverse(pairs)}

  defp json_members(bytes, pairs, seen) do
    with {:ok, key, <<":", rest::binary>>} <- json_string(bytes),
         false <- MapSet.member?(seen, key),
         {:ok, value, tail} <- json_string(rest) do
      case tail do
        <<",", remaining::binary>> ->
          json_members(remaining, [{key, value} | pairs], MapSet.put(seen, key))

        <<"}">> ->
          {:ok, Enum.reverse([{key, value} | pairs])}

        _other ->
          {:error, "negative JSON has trailing or malformed bytes"}
      end
    else
      true -> {:error, "negative JSON contains a duplicate key"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "negative JSON contains a malformed key or value"}
    end
  end

  defp json_string(<<"\"", rest::binary>>), do: json_string_bytes(rest, [])
  defp json_string(_other), do: {:error, "negative JSON values must be strings"}

  defp json_string_bytes(<<"\"", rest::binary>>, acc) do
    value = acc |> Enum.reverse() |> IO.iodata_to_binary()

    if String.valid?(value),
      do: {:ok, value, rest},
      else: {:error, "negative JSON string is not UTF-8"}
  end

  defp json_string_bytes(<<"\\", escaped, rest::binary>>, acc)
       when escaped in [?\", ?\\, ?/] do
    json_string_bytes(rest, [<<escaped>> | acc])
  end

  defp json_string_bytes(<<"\\b", rest::binary>>, acc),
    do: json_string_bytes(rest, [<<8>> | acc])

  defp json_string_bytes(<<"\\f", rest::binary>>, acc),
    do: json_string_bytes(rest, [<<12>> | acc])

  defp json_string_bytes(<<"\\n", rest::binary>>, acc),
    do: json_string_bytes(rest, ["\n" | acc])

  defp json_string_bytes(<<"\\r", rest::binary>>, acc),
    do: json_string_bytes(rest, ["\r" | acc])

  defp json_string_bytes(<<"\\t", rest::binary>>, acc),
    do: json_string_bytes(rest, ["\t" | acc])

  defp json_string_bytes(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    with {:ok, first} <- hex_codepoint(hex),
         {:ok, codepoint, tail} <- surrogate(first, rest),
         true <- codepoint <= 0x10FFFF do
      json_string_bytes(tail, [<<codepoint::utf8>> | acc])
    else
      _other -> {:error, "negative JSON contains an invalid Unicode escape"}
    end
  end

  defp json_string_bytes(<<byte, _rest::binary>>, _acc) when byte < 0x20,
    do: {:error, "negative JSON contains an unescaped control byte"}

  defp json_string_bytes(<<byte, rest::binary>>, acc),
    do: json_string_bytes(rest, [<<byte>> | acc])

  defp json_string_bytes(<<>>, _acc), do: {:error, "negative JSON string is unterminated"}

  defp canonical_json(pairs) do
    encoded =
      Enum.map_join(pairs, ",", fn {key, value} ->
        "\"#{json_escape(key)}\":\"#{json_escape(value)}\""
      end)

    "{" <> encoded <> "}"
  end

  defp json_escape(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map(fn
      ?\" -> "\\\""
      ?\\ -> "\\\\"
      8 -> "\\b"
      12 -> "\\f"
      ?\n -> "\\n"
      ?\r -> "\\r"
      ?\t -> "\\t"
      byte when byte < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(byte, 16), 4, "0")
      byte -> <<byte>>
    end)
    |> IO.iodata_to_binary()
  end

  defp hex_codepoint(hex) do
    case Integer.parse(hex, 16) do
      {number, ""} -> {:ok, number}
      _other -> {:error, :hex}
    end
  end

  defp surrogate(first, <<"\\u", hex::binary-size(4), rest::binary>>)
       when first in 0xD800..0xDBFF do
    with {:ok, second} when second in 0xDC00..0xDFFF <- hex_codepoint(hex) do
      {:ok, 0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00, rest}
    else
      _other -> {:error, :surrogate}
    end
  end

  defp surrogate(first, _rest) when first in 0xD800..0xDFFF,
    do: {:error, :surrogate}

  defp surrogate(first, rest), do: {:ok, first, rest}

  defp restored_digest("sha256:" <> digest) do
    case digest(digest, "restored_sha256") do
      :ok -> {:ok, digest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restored_digest(_other), do: {:error, "restored_sha256 is malformed"}

  defp safe_artifact(path) when is_binary(path) do
    parts = String.split(path, "/")

    if Regex.match?(@safe_path, path) and
         Enum.all?(parts, &(&1 not in [".", "..", ".git"])),
       do: :ok,
       else: {:error, "negative artifact is not a safe repository-relative path"}
  end

  defp safe_artifact(_other),
    do: {:error, "negative artifact must be a repository-relative string"}

  defp current_blob(root, path) do
    with :ok <- safe_repository_path(path),
         {:ok, entry} <- git(root, ["ls-files", "--stage", "--error-unmatch", "--", path]),
         [metadata, ^path] <- String.split(String.trim_trailing(entry, "\n"), "\t", parts: 2),
         [mode, object, "0"] <- String.split(metadata, " ", trim: true),
         true <- mode in ["100644", "100755"] and Regex.match?(@sha, object),
         {:ok, physical} <- ordinary_path(root, path),
         {:ok, bytes} <- File.read(physical) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "#{path} is not one tracked ordinary file"}
    end
  end

  defp committed_blob(root, commit, path) do
    with :ok <- safe_repository_path(path),
         :ok <- sha(commit, "commit"),
         {:ok, entry} <- git(root, ["ls-tree", "-z", commit, "--", path]),
         [metadata, ^path] <-
           String.split(String.trim_trailing(entry, <<0>>), "\t", parts: 2),
         [mode, "blob", object] <- String.split(metadata, " ", trim: true),
         true <- mode in ["100644", "100755"] and Regex.match?(@sha, object),
         {:ok, bytes} <- git(root, ["show", "#{commit}:#{path}"]) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "#{path} is not one committed ordinary file at #{commit}"}
    end
  end

  defp ordinary_path(root, path) do
    path
    |> String.split("/")
    |> Enum.reduce_while({:ok, root}, fn component, {:ok, prefix} ->
      next = Path.join(prefix, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: type}} when type in [:directory, :regular] ->
          {:cont, {:ok, next}}

        _other ->
          {:halt, {:error, "#{path} crosses a missing or non-ordinary path component"}}
      end
    end)
    |> case do
      {:ok, physical} ->
        if match?({:ok, %File.Stat{type: :regular}}, File.lstat(physical)),
          do: {:ok, physical},
          else: {:error, "#{path} is not an ordinary file"}

      error ->
        error
    end
  end

  defp safe_repository_path(path) when is_binary(path) do
    if Regex.match?(@safe_path, path) and
         Enum.all?(String.split(path, "/"), &(&1 not in [".", "..", ".git"])),
       do: :ok,
       else: {:error, "#{inspect(path)} is not a safe repository-relative path"}
  end

  defp safe_repository_path(_path), do: {:error, "repository path is not a string"}

  defp head(root) do
    with {:ok, output} <- git(root, ["rev-parse", "--verify", "HEAD"]),
         head <- String.trim_trailing(output, "\n"),
         :ok <- sha(head, "HEAD") do
      {:ok, head}
    end
  end

  defp ancestry_commits(_root, from, to) when from == to, do: {:ok, []}

  defp ancestry_commits(root, from, to) do
    with {:ok, output} <-
           git(root, ["rev-list", "--parents", "--ancestry-path", "#{from}..#{to}"]) do
      records =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [commit | parents] = String.split(line, " ", trim: true)
          %{commit: commit, parents: parents}
        end)

      if Enum.all?(records, fn %{commit: commit, parents: parents} ->
           Regex.match?(@sha, commit) and Enum.all?(parents, &Regex.match?(@sha, &1))
         end),
         do: {:ok, records},
         else: {:error, "Git ancestry output is malformed"}
    end
  end

  defp changed_paths(root, before, after_commit) do
    with {:ok, output} <-
           git(root, ["diff-tree", "--no-commit-id", "--name-only", "-r", before, after_commit]) do
      paths = String.split(output, "\n", trim: true)

      if Enum.all?(paths, &match?(:ok, safe_repository_path(&1))),
        do: {:ok, Enum.sort(paths)},
        else: {:error, "Git changed-path output is malformed"}
    end
  end

  defp ancestor(root, candidate, label) do
    if ancestor?(root, candidate, "HEAD"),
      do: :ok,
      else: {:error, "#{label} is not a reachable ancestor of HEAD"}
  end

  defp ancestor?(root, ancestor, descendant) do
    case git_status(root, ["merge-base", "--is-ancestor", ancestor, descendant]) do
      0 -> true
      _other -> false
    end
  end

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args],
           env: [{"GIT_OPTIONAL_LOCKS", "0"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, "Git evidence lookup failed for #{Enum.join(args, " ")}"}
    end
  rescue
    _exception -> {:error, "Git evidence lookup is unavailable"}
  end

  defp git_status(root, args) do
    case System.cmd("git", ["-C", root | args],
           env: [{"GIT_OPTIONAL_LOCKS", "0"}],
           stderr_to_stdout: true
         ) do
      {_output, status} -> status
    end
  rescue
    _exception -> 127
  end

  defp canonical_text(bytes, label) do
    canonical_bytes? =
      bytes
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte == ?\n or byte in 0x20..0x7E end)

    cond do
      not String.valid?(bytes) -> {:error, "#{label} must be UTF-8"}
      String.contains?(bytes, "\r") -> {:error, "#{label} must use LF line endings"}
      not canonical_bytes? -> {:error, "#{label} must contain only printable ASCII and LF"}
      not String.ends_with?(bytes, "\n") -> {:error, "#{label} must end with LF"}
      true -> :ok
    end
  end

  defp sha(value, label) when is_binary(value) do
    if Regex.match?(@sha, value),
      do: :ok,
      else: {:error, "#{label} must be one full lowercase SHA"}
  end

  defp sha(_value, label), do: {:error, "#{label} must be a string"}

  defp digest(value, label) when is_binary(value) do
    if Regex.match?(@digest, value),
      do: :ok,
      else: {:error, "#{label} must be one lowercase SHA-256"}
  end

  defp digest(_value, label), do: {:error, "#{label} must be a string"}

  defp digest_matches(bytes, expected, label) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, "#{label} does not match its SHA-256"}
  end

  defp exact(value, expected, _label) when value == expected, do: :ok
  defp exact(_value, expected, label), do: {:error, "#{label} must equal #{expected}"}

  defp version(value, label) do
    if is_binary(value) and Regex.match?(@version, value),
      do: :ok,
      else: {:error, "#{label} is not an exact numeric version"}
  end

  defp utc_second(value, label) when is_binary(value) do
    exact_shape =
      Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/u, value)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} when exact_shape ->
        if DateTime.to_iso8601(datetime) == value,
          do: :ok,
          else: {:error, "#{label} must be one canonical UTC RFC3339 second timestamp"}

      _other ->
        {:error, "#{label} must be one canonical UTC RFC3339 second timestamp"}
    end
  end

  defp utc_second(_value, label),
    do: {:error, "#{label} must be one canonical UTC RFC3339 second timestamp"}

  defp resource_limits(value, label) when is_binary(value) do
    with :ok <- audit_token(value, label),
         [nofile, nproc] <-
           Regex.run(
             ~r/\Acore-soft-0,core-hard-0,nofile-([^,]+),nproc-([^,]+)\z/u,
             value,
             capture: :all_but_first
           ),
         :ok <- canonical_limit(nofile),
         :ok <- canonical_limit(nproc) do
      :ok
    else
      _other ->
        {:error,
         "#{label} must use core-soft-0,core-hard-0,nofile-<integer|unlimited>,nproc-<integer|unlimited>"}
    end
  end

  defp resource_limits(_value, label),
    do:
      {:error,
       "#{label} must use core-soft-0,core-hard-0,nofile-<integer|unlimited>,nproc-<integer|unlimited>"}

  defp canonical_limit("unlimited"), do: :ok

  defp canonical_limit(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 ->
        if Integer.to_string(number) == value, do: :ok, else: {:error, :limit}

      _other ->
        {:error, :limit}
    end
  end

  defp integer(value, minimum, maximum, label) do
    case Integer.parse(value || "") do
      {number, ""} when number >= minimum and number <= maximum ->
        if Integer.to_string(number) == value,
          do: :ok,
          else: {:error, "#{label} must use canonical integer spelling"}

      _other ->
        {:error, "#{label} must be an integer from #{minimum} through #{maximum}"}
    end
  end

  defp audit_token(value, label) do
    if is_binary(value) and Regex.match?(@token, value) and
         String.downcase(value) not in ["tbd", "todo", "pending", "unknown", "-"] do
      :ok
    else
      {:error, "#{label} must be one populated printable token"}
    end
  end

  defp meaningful(value, label) when is_binary(value) do
    if value == String.trim(value) and value not in ["", "-", "—"] and
         String.downcase(value) not in ["tbd", "todo", "pending"] do
      :ok
    else
      {:error, "#{label} must be populated"}
    end
  end

  defp meaningful(_value, label), do: {:error, "#{label} must be a string"}

  defp meaningful_ascii(value, label) when is_binary(value) do
    printable = value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))

    if printable and value == String.trim(value) and value != "" and
         String.downcase(value) not in ["tbd", "todo", "pending"] do
      :ok
    else
      {:error, "#{label} must be populated printable ASCII"}
    end
  end

  defp meaningful_ascii(_value, label),
    do: {:error, "#{label} must be a string"}
end

defmodule Loopex.M1EvidenceVerifier.CLI do
  @moduledoc false

  def main(args) do
    result =
      case args do
        ["--pair", "--root", root] ->
          Loopex.M1EvidenceVerifier.pair(root)

        ["--root", root, "--negative", negative] ->
          case Loopex.M1EvidenceVerifier.negative(root, negative) do
            :ok -> {:ok, "M1 negative evidence OK"}
            {:error, reason} -> {:error, reason}
          end

        ["--root", root, "--matrix", matrix, "--negative", negative] ->
          case Loopex.M1EvidenceVerifier.all(root, matrix, negative) do
            :ok -> {:ok, "M1 evidence OK"}
            {:error, reason} -> {:error, reason}
          end

        _other ->
          {:error,
           "usage: m1-evidence-verifier.exs --pair --root ROOT | --root ROOT --negative PATH | --root ROOT --matrix PATH --negative PATH"}
      end

    case result do
      {:ok, line} ->
        IO.puts(line)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "M1 evidence verifier refused: #{reason}")
        System.halt(1)
    end
  rescue
    _exception ->
      IO.puts(:stderr, "M1 evidence verifier refused: evidence is unavailable")
      System.halt(1)
  catch
    _kind, _reason ->
      IO.puts(:stderr, "M1 evidence verifier refused: evidence is unavailable")
      System.halt(1)
  end
end

Loopex.M1EvidenceVerifier.CLI.main(System.argv())
