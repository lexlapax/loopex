defmodule Loopex.Checks.History do
  @moduledoc """
  ## Concept

  Anchors immutable records across every reachable revision, not just the current
  tree. Checking only the checkout leaves a mutate-then-restore hole: one commit
  changes an accepted record or a bound artifact, a later commit restores it, and
  final validation passes while the intervening revision — which someone reviewed,
  built, or released from — carried different bytes.

  Merge divergence has the same shape. A branch that mutated a bound artifact can
  be merged by a commit whose tree is clean, so the mutation is contained in
  history without ever appearing in a final tree.

  ## Technical depth

  Two independent walks over the same reachable history. The governance walk owns
  documents: once a record completes, its bytes are pinned for every descendant,
  and a change is admitted only as a declared amendment. The artifact walk owns
  bound executables and configuration: once a gate binds a target, every
  descendant must keep binding it and every declared digest must match the file at
  that revision.

  Both propagate state along parent edges and reconcile at merges, so the result
  does not depend on traversal order. Two parents carrying different completed
  values for the same record is a conflict, not a merge — that is precisely the
  case where a merge would otherwise launder a mutation.
  """

  alias Loopex.Checks.Adr
  alias Loopex.Checks.Documents
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Names
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Plan
  alias Loopex.Checks.Records

  @adr_labels ["Acceptance", "accepted concept", "accepted technical depth"]
  @gate_labels ["accepted gate"]
  @plan_labels [
    "Acceptance",
    "Closure",
    "normative concept envelope",
    "normative technical envelope"
  ]

  @doc """
  ## Concept

  Every completed governance record stays byte-identical from the revision that
  first completed it through to the working tree, unless a declared amendment
  supersedes it.

  ## Technical depth

  History must be available: an absent walk is unavailable evidence, not a pass,
  because the hole it would leave is exactly the one this check exists to close.
  The traversal requires parent-first ordering and rejects duplicates, so a
  malformed or reordered history cannot skip an edge.

  A record that disappears from a revision fails, since deletion followed by
  restoration is the same mutate-then-restore pattern with the file removed
  instead of edited.
  """
  @spec governance_history(map(), {String.t(), [{String.t(), [String.t()], map()}]} | nil) :: :ok
  def governance_history(_current, nil) do
    raise Invalid, "governed documents: complete reachable governance history is unavailable"
  end

  def governance_history(current, {head, snapshots}) do
    all_paths =
      Enum.reduce(snapshots, MapSet.new(Map.keys(current)), fn {_revision, _parents, governed},
                                                               acc ->
        MapSet.union(acc, MapSet.new(Map.keys(governed)))
      end)

    adr_concepts = all_paths |> Enum.filter(&Documents.adr_concept?/1) |> MapSet.new()
    {plans, gates} = classify_primary!(all_paths, adr_concepts)

    primary =
      adr_concepts |> MapSet.union(plans) |> MapSet.union(gates) |> Enum.sort()

    walk = snapshots ++ [{"working tree", [head], current}]

    # Every revision's files, so an acceptance row can be judged against the gate
    # carried by the candidate it binds rather than only the ambient one.
    by_revision =
      Map.new(snapshots, fn {revision, _parents, governed} -> {revision, governed} end)

    Enum.reduce(walk, %{}, fn {revision, parents, governed}, inherited ->
      if Map.has_key?(inherited, revision) or
           Enum.any?(parents, &(not Map.has_key?(inherited, &1))) do
        raise Invalid, "governed documents: history is duplicated or not parent-first"
      end

      anchors =
        Map.new(primary, fn path ->
          {path,
           resolve_anchors!(
             path,
             revision,
             parents,
             governed,
             inherited,
             adr_concepts,
             by_revision
           )}
        end)

      Map.put(inherited, revision, anchors)
    end)

    :ok
  end

  defp classify_primary!(all_paths, adr_concepts) do
    Enum.reduce(Enum.sort(all_paths), {MapSet.new(), MapSet.new()}, fn path, {plans, gates} ->
      cond do
        MapSet.member?(adr_concepts, path) ->
          {plans, gates}

        String.ends_with?(path, "-technical.md") ->
          {plans, gates}

        true ->
          relative = Paths.strip_prefix(path, "docs/plans/")

          if not String.starts_with?(path, "docs/plans/") or String.contains?(relative, "/") or
               not String.ends_with?(relative, ".md") or relative == "README.md" do
            raise Invalid, "#{path}: invalid historical governed-document path"
          end

          gate? = String.ends_with?(relative, "-gate.md")

          name =
            case gate? do
              true -> Paths.strip_suffix(relative, "-gate.md")
              false -> Paths.strip_suffix(relative, ".md")
            end

          Names.milestone!("`#{name}`", path)

          case gate? do
            true -> {plans, MapSet.put(gates, path)}
            false -> {MapSet.put(plans, path), gates}
          end
      end
    end)
  end

  defp resolve_anchors!(
         path,
         revision,
         parents,
         governed,
         inherited,
         adr_concepts,
         by_revision
       ) do
    labels = labels(path, adr_concepts)

    from_parents =
      Enum.map(Enum.with_index(labels), fn {label, index} ->
        values =
          parents
          |> Enum.map(&(inherited |> Map.fetch!(&1) |> Map.fetch!(path) |> Enum.at(index)))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        case values do
          [] ->
            nil

          [single] ->
            single

          conflict ->
            reconcile!(conflict, path, revision, label, adr_concepts)
        end
      end)

    case Map.get(governed, path) do
      nil ->
        require_absence_allowed!(path, revision, governed, from_parents)
        from_parents

      text ->
        current = values(text, path, revision, governed, adr_concepts, by_revision)

        labels
        |> Enum.with_index()
        |> Enum.map(fn {label, index} ->
          advance!(
            path,
            revision,
            label,
            Enum.at(from_parents, index),
            Enum.at(current, index),
            adr_concepts
          )
        end)
    end
  end

  @doc """
  ## Concept

  Reconciles differing parent records at a merge, exposed so the property can be
  tested directly.

  ## Technical depth

  The reconciliation rule is small but it decides whether an accepted amendment can
  ever land, so it is tested against its own inputs rather than only through a
  constructed repository history.
  """
  @spec reconcile_for_test([String.t()], String.t(), String.t(), String.t(), [String.t()]) ::
          String.t()
  def reconcile_for_test(values, path, revision, label, adr_concepts) do
    reconcile!(values, path, revision, label, adr_concepts)
  end

  # Concept: parents may legitimately disagree when one of them amended the gate.
  # Technical depth: raising on every divergence made a merge that brings in an
  # accepted amendment unrepresentable -- the branch carrying it and the branch
  # without it meet with different anchors, which is the normal shape of landing
  # one. The rule here is the same strictly-increasing generation rule used for a
  # sequential change: exactly one candidate must supersede every other, and
  # anything else is still a conflict. Two sides at the same generation with
  # different bytes remain irreconcilable, which is the case worth refusing.
  defp reconcile!(values, path, revision, label, adr_concepts) do
    amendable = label in ["accepted gate", "Acceptance"] and path not in adr_concepts

    latest =
      case amendable do
        false ->
          nil

        true ->
          Enum.find(values, fn candidate ->
            Enum.all?(values, fn other ->
              other == candidate or Plan.supersedes?(label, other, candidate)
            end)
          end)
      end

    case latest do
      nil ->
        raise Invalid, "#{path}: conflicting completed #{label} records meet at #{revision}"

      winner ->
        winner
    end
  end

  defp require_absence_allowed!(path, revision, governed, from_parents) do
    if String.ends_with?(path, "-gate.md") do
      plan_path = Paths.strip_suffix(path, "-gate.md") <> ".md"

      if plan_accepted?(Map.get(governed, plan_path), plan_path, revision) do
        raise Invalid, "#{path}: gate is missing when Acceptance completes at #{revision}"
      end
    end

    if Enum.any?(from_parents, &(&1 != nil)) do
      raise Invalid, "#{path}: completed governance record disappeared at #{revision}"
    end

    :ok
  end

  defp advance!(path, revision, label, anchor, value, adr_concepts) do
    cond do
      anchor == nil ->
        value

      value == anchor ->
        anchor

      true ->
        amendable =
          label in ["accepted gate", "Acceptance"] and not MapSet.member?(adr_concepts, path)

        if amendable and Plan.supersedes?(label, anchor, value) do
          value
        else
          raise Invalid, "#{path}: completed #{label} governance record changed at #{revision}"
        end
    end
  end

  defp labels(path, adr_concepts) do
    cond do
      MapSet.member?(adr_concepts, path) -> @adr_labels
      String.ends_with?(path, "-gate.md") -> @gate_labels
      true -> @plan_labels
    end
  end

  # Concept: the values that identify a completed record, one per label.
  # Technical depth: a nil means "not completed here", so a later revision may
  # complete it; a non-nil value is pinned for every descendant. Values are joined
  # with NUL because no governance cell can contain one, which makes equality a
  # single comparison and lets the amendment generation ride in the same string.
  defp values(text, path, revision, governed, adr_concepts, by_revision) do
    historical_path = "#{path} at #{revision}"

    cond do
      MapSet.member?(adr_concepts, path) ->
        adr_values(text, path, historical_path, governed, revision)

      String.ends_with?(path, "-gate.md") ->
        gate_values(text, path, historical_path, governed, revision)

      true ->
        plan_values(text, path, historical_path, governed, revision, by_revision)
    end
  end

  defp adr_values(text, path, historical_path, governed, revision) do
    case Adr.record(text, historical_path, legacy_ok: true) do
      nil ->
        [nil, nil, nil]

      {_status, _row, false, _index, _row_index} ->
        [nil, nil, nil]

      {_status, row, true, _index, _row_index} ->
        technical_path = Paths.technical(path)

        case Map.get(governed, technical_path) do
          nil ->
            raise Invalid,
                  "#{technical_path}: accepted ADR technical depth disappeared at #{revision}"

          technical ->
            [Enum.join(row, "\0"), text, technical]
        end
    end
  end

  # Concept: the amendment generation of the gate at the candidate a row binds.
  # Technical depth: an unresolvable candidate yields nil, and Plan.supersedes?/3
  # treats a missing value as "not a supersession", so an unreachable candidate
  # cannot be used to claim one.
  defp bound_candidate_generation(row, path, by_revision) do
    gate_path = Paths.strip_suffix(path, ".md") <> "-gate.md"

    with [_decision, _authority, _evidence, bound] <- row,
         [_all, candidate] <- Regex.run(~r/candidate `([0-9a-f]{40})`/, bound),
         files when is_map(files) <- Map.get(by_revision, candidate),
         text when is_binary(text) <- Map.get(files, gate_path) do
      Plan.gate_generation(text, "#{gate_path} at #{candidate}")
    else
      _other -> nil
    end
  end

  defp gate_values(text, path, historical_path, governed, revision) do
    plan_path = Paths.strip_suffix(path, "-gate.md") <> ".md"

    case plan_accepted?(Map.get(governed, plan_path), plan_path, revision) do
      false ->
        [nil]

      true ->
        digest = Plan.gate_digest(text, historical_path)
        generation = Plan.gate_generation(text, historical_path)
        ["#{generation}\0#{digest}\0#{text}"]
    end
  end

  defp plan_values(text, path, historical_path, governed, revision, by_revision) do
    {rows, _bound, complete} = Records.governance_records(text, historical_path)

    case Enum.at(complete, 0) do
      false ->
        [nil, nil, nil, nil]

      true ->
        technical_path = Paths.strip_suffix(path, ".md") <> "-technical.md"

        technical =
          case Map.get(governed, technical_path) do
            nil ->
              raise Invalid,
                    "#{technical_path}: accepted plan technical depth disappeared at #{revision}"

            found ->
              found
          end

        {concept_envelope, _ids} = Plan.concept_envelope(text, historical_path)

        technical_envelope =
          Plan.technical_envelope(technical, "#{technical_path} at #{revision}")

        # The leading field is the amendment generation of the gate carried by the
        # candidate this row binds -- deliberately NOT the ambient generation of
        # the gate at this revision. Using the ambient one made the anchor change
        # at the amendment commit itself, where the row had not moved at all, and
        # tying a rebind to the ambient value also left the row freely rewritable
        # once any amendment existed. Comparing the bound candidates instead means
        # a rebind is admitted only when it moves to a genuinely later-amended
        # candidate, which is the same strictly-increasing rule the gate label uses.
        candidate_generation =
          bound_candidate_generation(Enum.at(rows, 0), path, by_revision)

        [
          "#{candidate_generation}\0" <> Enum.join(Enum.at(rows, 0), "\0"),
          if(Enum.at(complete, 1), do: Enum.join(Enum.at(rows, 1), "\0")),
          Enum.join(concept_envelope, "\n"),
          Enum.join(technical_envelope, "\n")
        ]
    end
  end

  defp plan_accepted?(nil, _path, _revision), do: false

  defp plan_accepted?(text, path, revision) do
    case String.contains?(text, "## Governance Records") do
      false ->
        false

      true ->
        {_rows, _bound, complete} = Records.governance_records(text, "#{path} at #{revision}")
        Enum.at(complete, 0)
    end
  end

  @doc """
  ## Concept

  Every artifact a gate binds matches its locked digest at every revision where
  that gate declares it, and no descendant may stop declaring it.

  ## Technical depth

  Once a gate binds a target, dropping the gate, dropping the declaration, or
  dropping a single row would each open a gap behind which a commit could mutate
  the artifact and a later commit restore it. All three therefore fail, and the
  binding set propagates along every parent so a merge cannot supply a clean tree
  that hides a mutated one.

  A malformed declaration is a failure rather than a gate that predates the
  convention: reading a broken table as "nothing bound here" would make the
  malformed state the cheapest way to unbind an artifact.
  """
  @spec artifact_history({String.t(), [{String.t(), [String.t()], map()}]} | nil) :: :ok
  def artifact_history(nil), do: :ok

  def artifact_history({_head, snapshots}) do
    Enum.reduce(snapshots, %{}, fn {revision, parents, files}, state ->
      inherited =
        Enum.reduce(parents, %{}, fn parent, acc ->
          state
          |> Map.get(parent, %{})
          |> Enum.reduce(acc, fn {gate_path, targets}, inner ->
            Map.update(inner, gate_path, targets, &MapSet.union(&1, targets))
          end)
        end)

      declared = declared_artifacts!(files, revision)
      require_binding_persists!(inherited, declared, files, revision)

      merged =
        Enum.reduce(declared, inherited, fn {gate_path, targets}, acc ->
          Map.update(acc, gate_path, targets, &MapSet.union(&1, targets))
        end)

      Map.put(state, revision, merged)
    end)

    :ok
  end

  defp declared_artifacts!(files, revision) do
    files
    |> Enum.sort()
    |> Enum.filter(fn {path, text} ->
      String.starts_with?(path, "docs/plans/") and String.ends_with?(path, "-gate.md") and
        text |> String.split("\n") |> Enum.any?(&(String.trim(&1) == "## Bound Artifacts"))
    end)
    |> Map.new(fn {path, text} ->
      artifacts =
        try do
          Plan.bound_artifacts(text, path)
        rescue
          error in Invalid ->
            raise Invalid,
                  "#{path} at #{revision}: bound-artifact declaration is malformed (#{Exception.message(error)})"
        end

      Enum.each(artifacts, fn {digest, target} ->
        case Map.get(files, target) do
          nil ->
            raise Invalid, "#{path} at #{revision}: bound artifact #{target} is missing"

          content ->
            if Markdown.digest(content) != digest do
              raise Invalid,
                    "#{path} at #{revision}: bound artifact #{target} does not match its locked digest"
            end
        end
      end)

      {path, MapSet.new(artifacts, fn {_digest, target} -> target end)}
    end)
  end

  defp require_binding_persists!(inherited, declared, files, revision) do
    inherited
    |> Enum.sort()
    |> Enum.each(fn {gate_path, targets} ->
      unless Map.has_key?(files, gate_path) do
        raise Invalid, "#{gate_path} at #{revision}: gate disappeared after binding artifacts"
      end

      unless Map.has_key?(declared, gate_path) do
        raise Invalid, "#{gate_path} at #{revision}: bound-artifact declaration disappeared"
      end

      dropped = targets |> MapSet.difference(Map.fetch!(declared, gate_path)) |> Enum.sort()

      case dropped do
        [] ->
          :ok

        [first | _rest] ->
          raise Invalid,
                "#{gate_path} at #{revision}: bound artifact #{first} is no longer declared"
      end
    end)
  end
end
