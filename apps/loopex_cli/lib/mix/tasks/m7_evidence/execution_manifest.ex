defmodule Mix.Tasks.Loopex.M7Evidence.ExecutionManifest do
  @moduledoc """
  ## Concept

  The committed M7 execution manifest: one attempts campaign, the three M7
  release lanes and their ordered cases, and exactly one owner for every
  V1–V13 operator step and subcase. It fixes mapping and specification before
  any execution; actual identities, outcomes and operators belong to retained
  execution records outside the repository. A case or owner still marked
  pending is unavailable evidence, never a pass.

  ## Technical depth

  The closed member `execution_manifest` of `test/fixtures/m7/manifest.json`
  holds `status: "pinned"`, `coverage: "V1-V13"`, `campaign_id`,
  `genesis_digest` (the SHA-256 of the campaign's canonical genesis record),
  `lanes`, `cases` and `operator_step_evidence`.

  Every numbered step of the accepted scenarios (74 steps) has one or more
  keys `Vn.m` or `Vn.m.<subcase>`; no key names another step. An owner is
  `case:<id>`, `test:<app-relative path>#<exact test name>`,
  `pending:<reason>` or `retired:<disposition>`. A mandatory attended step has
  at least one attended key, no pending or retired key, and every attended key
  is owned by an `m7-operator` case. Each case lists exactly the keys it owns,
  its lane, attendance, credential need, driver and status; lane lists hold
  exactly their cases in execution order. A case's specification digest is
  the canonical JSON digest of its entry, which the attempts index pins.
  `verify_owners/2` additionally proves each test owner is a literal test in
  its file. Nothing here opens an attempts index or runs a case.
  """

  alias LoopexProtocol.Canonical
  alias Mix.Tasks.Loopex.M7Evidence.AttemptEvents

  @steps [
    {1, 5},
    {2, 6},
    {3, 5},
    {4, 5},
    {5, 6},
    {6, 7},
    {7, 7},
    {8, 7},
    {9, 5},
    {10, 5},
    {11, 5},
    {12, 5},
    {13, 6}
  ]
  @mandatory ~w(V1.1 V1.2 V1.3 V1.4 V1.5 V12.1 V12.2 V11.1 V11.2 V2.1 V2.2 V2.3 V2.4 V2.5
                V3.1 V3.2 V4.1 V4.2 V4.3 V4.4 V5.1 V5.2 V5.3 V5.6 V6.1 V6.2 V6.3 V6.4 V6.5
                V6.6 V7.1 V7.2 V7.3 V7.4 V8.1 V8.2 V8.3 V8.4 V9.1 V9.2 V11.5 V10.1 V10.2
                V10.3 V10.4 V10.5 V13.1 V13.4 V13.5 V13.6)
  @lanes ~w(m7-operator m7-provider m7-rollback)
  @keys ~w(status coverage campaign_id genesis_digest lanes cases operator_step_evidence)
  @case_keys ~w(lane attended credential driver status steps)
  @drivers ~w(fixture-chat external-chat scenario-chat demonstration provider-wrapper release-lane)

  # The 74 numbered step identities of the accepted V1–V13 scenarios.
  @doc false
  def steps, do: for({v, count} <- @steps, n <- 1..count, do: "V#{v}.#{n}")

  @doc false
  def mandatory, do: @mandatory

  @doc false
  def validate(%{} = manifest) do
    with true <- closed?(manifest, @keys) or {:error, :invalid_execution_manifest},
         true <- manifest["status"] == "pinned" or {:error, :m7_execution_manifest_pending},
         true <- manifest["coverage"] == "V1-V13" or {:error, :invalid_execution_manifest},
         :ok <- genesis(manifest["campaign_id"], manifest["genesis_digest"]),
         :ok <- cases(manifest["cases"], manifest["lanes"]),
         :ok <- coverage(manifest["operator_step_evidence"], manifest["cases"]) do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_execution_manifest}

  # Canonical genesis digest of the pinned campaign.
  @doc false
  def genesis_digest(campaign) do
    body = %{"kind" => "genesis", "version" => 1, "campaign_id" => campaign, "codec_version" => 1}

    case AttemptEvents.encode(campaign, 1, nil, body) do
      {:ok, _line, record} -> {:ok, record["digest"]}
      _ -> {:error, :invalid_campaign}
    end
  end

  # The specification digest the attempts index pins for one case.
  @doc false
  def specification_digest(manifest, case_id),
    do: Canonical.digest_bytes(canonical(Map.put(manifest["cases"][case_id], "id", case_id)))

  # The private lane selection AttemptEvents and AttemptWriter admit for a
  # lane on a candidate commit. Pending cases make the lane unavailable.
  @doc false
  def selection(manifest, manifest_digest, lane, candidate, matrix) do
    cases = Map.get(manifest["lanes"], lane, [])
    pending = Enum.filter(cases, &(manifest["cases"][&1]["status"] != "ready"))

    cond do
      cases == [] ->
        {:error, :unknown_m7_lane}

      pending != [] ->
        {:error, {:m7_cases_pending, pending}}

      true ->
        {:ok,
         %{
           "candidate_sha" => candidate,
           "lane_id" => lane,
           "logical_matrix_id" => matrix,
           "manifest_digest" => manifest_digest,
           "cases" =>
             Enum.map(cases, fn id ->
               %{
                 "case_key" => id,
                 "subcase_key" => nil,
                 "specification_digest" => specification_digest(manifest, id)
               }
             end)
         }}
    end
  end

  # Pending owners and cases, for reports and the release refusal.
  @doc false
  def pending(manifest) do
    cases = for {id, entry} <- manifest["cases"], entry["status"] != "ready", do: id

    owners =
      for {key, %{"owner" => "pending:" <> _}} <- manifest["operator_step_evidence"], do: key

    %{cases: Enum.sort(cases), owners: Enum.sort(owners)}
  end

  # Prove every test owner names a literal test in its file under `root`.
  @doc false
  def verify_owners(manifest, root) do
    missing =
      for {key, %{"owner" => "test:" <> reference}} <- manifest["operator_step_evidence"],
          not literal_test?(root, reference),
          do: key

    if missing == [], do: :ok, else: {:error, {:m7_test_owner_missing, Enum.sort(missing)}}
  end

  defp literal_test?(root, reference) do
    with [path, name] <- String.split(reference, "#", parts: 2),
         true <- String.starts_with?(path, "apps/") and String.ends_with?(path, "_test.exs"),
         {:ok, source} <- File.read(Path.join(root, path)) do
      String.contains?(source, "test " <> inspect(name))
    else
      _ -> false
    end
  end

  defp genesis(campaign, digest) do
    case genesis_digest(campaign) do
      {:ok, ^digest} -> :ok
      _ -> {:error, :invalid_campaign_genesis}
    end
  end

  defp cases(cases, lanes) do
    valid =
      is_map(cases) and map_size(cases) > 0 and closed?(lanes, @lanes) and
        Enum.all?(cases, fn {id, entry} -> case_entry?(id, entry) end) and
        Enum.all?(@lanes, fn lane ->
          listed = lanes[lane]

          is_list(listed) and listed == Enum.uniq(listed) and
            Enum.sort(listed) ==
              Enum.sort(for {id, %{"lane" => ^lane}} <- cases, do: id)
        end)

    if valid, do: :ok, else: {:error, :invalid_m7_cases}
  end

  defp case_entry?(id, entry) do
    Regex.match?(~r/\Am7\.[a-z0-9.-]+\z/, id) and closed?(entry, @case_keys) and
      entry["lane"] in @lanes and is_boolean(entry["attended"]) and
      entry["attended"] == (entry["lane"] == "m7-operator") and
      is_boolean(entry["credential"]) and entry["driver"] in @drivers and
      status?(entry["status"]) and is_list(entry["steps"]) and entry["steps"] != [] and
      entry["steps"] == Enum.uniq(entry["steps"])
  end

  defp status?("ready"), do: true
  defp status?("pending:" <> reason), do: reason != ""
  defp status?(_), do: false

  defp coverage(evidence, cases) do
    steps = steps()

    with true <- is_map(evidence) or {:error, :invalid_operator_step_evidence},
         [] <- Enum.reject(evidence, &entry?/1) |> Enum.map(&elem(&1, 0)),
         [] <- Enum.reject(steps, fn step -> Enum.any?(Map.keys(evidence), &step?(&1, step)) end),
         [] <- Enum.reject(Map.keys(evidence), fn key -> Enum.any?(steps, &step?(key, &1)) end),
         [] <- mandatory_gaps(evidence, cases),
         :ok <- case_ownership(evidence, cases) do
      :ok
    else
      {:error, _} = error -> error
      keys when is_list(keys) -> {:error, {:invalid_operator_step_evidence, Enum.sort(keys)}}
    end
  end

  defp entry?({key, entry}) do
    Regex.match?(~r/\AV(?:[1-9]|1[0-3])\.[1-7](?:\.[a-z0-9-]+)?\z/, key) and
      closed?(entry, ~w(classification owner)) and
      entry["classification"] in ~w(attended automated retired) and
      owner?(entry["classification"], entry["owner"])
  end

  defp owner?("retired", "retired:" <> anchor), do: anchor != ""
  defp owner?("retired", _), do: false
  defp owner?("attended", "case:" <> _), do: true
  defp owner?("attended", _), do: false
  defp owner?("automated", "case:" <> _), do: true
  defp owner?("automated", "pending:" <> reason), do: reason != ""
  defp owner?("automated", "test:" <> reference), do: String.contains?(reference, "#")
  defp owner?(_, _), do: false

  defp step?(key, step), do: key == step or String.starts_with?(key, step <> ".")

  defp mandatory_gaps(evidence, cases) do
    Enum.reject(@mandatory, fn step ->
      keys = for {key, entry} <- evidence, step?(key, step), do: entry

      Enum.any?(keys, &(&1["classification"] == "attended")) and
        Enum.all?(keys, &(&1["classification"] != "retired")) and
        Enum.all?(keys, fn
          %{"classification" => "attended", "owner" => "case:" <> id} ->
            cases[id]["lane"] == "m7-operator"

          _ ->
            true
        end)
    end)
  end

  defp case_ownership(evidence, cases) do
    owned =
      Enum.group_by(
        for({key, %{"owner" => "case:" <> id}} <- evidence, do: {id, key}),
        &elem(&1, 0),
        &elem(&1, 1)
      )

    mismatched =
      for {id, entry} <- cases,
          Enum.sort(entry["steps"]) != Enum.sort(Map.get(owned, id, [])),
          do: id

    unknown = Map.keys(owned) -- Map.keys(cases)

    attended_mismatch =
      for {key, %{"owner" => "case:" <> id, "classification" => class}} <- evidence,
          Map.has_key?(cases, id),
          class == "attended" != cases[id]["attended"],
          do: key

    case {mismatched ++ unknown, attended_mismatch} do
      {[], []} -> :ok
      {cases, keys} -> {:error, {:inconsistent_m7_case_ownership, Enum.sort(cases ++ keys)}}
    end
  end

  defp canonical(value) do
    {:ok, encoded} = LoopexProtocol.Frame.encode(value)
    line = IO.iodata_to_binary(encoded)
    binary_part(line, 0, byte_size(line) - 1)
  end

  defp closed?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
