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

  The governance walk also judges each revision against the gate generation
  current *there*. A Closed milestone whose gate changed without the generation
  record that accepts the change is invalid at that revision and stays invalid,
  which is what makes splitting an artifact change from its generation row fatal
  rather than merely discouraged.
  """

  alias Loopex.Checks.Adr
  alias Loopex.Checks.Documents
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Names
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Plan
  alias Loopex.Checks.Records
  alias Loopex.Checks.Register

  @index "docs/plans/README.md"

  @adr_labels ["Acceptance", "accepted concept", "accepted technical depth"]
  @gate_labels ["accepted gate"]
  @plan_labels [
    "Acceptance",
    "Closure",
    "normative concept envelope",
    "normative technical envelope",
    "gate generations"
  ]

  @plan_fields 0..(length(@plan_labels) - 1)

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
  @spec governance_history(
          map(),
          {String.t(), [{String.t(), [String.t()], map()}]} | nil,
          (String.t(), String.t() -> String.t() | nil) | nil
        ) :: :ok
  def governance_history(current, history, resolve_file \\ nil)

  def governance_history(_current, nil, _resolve_file) do
    raise Invalid, "governed documents: complete reachable governance history is unavailable"
  end

  def governance_history(current, {head, snapshots}, resolve_file) do
    all_paths =
      Enum.reduce(snapshots, MapSet.new(Map.keys(current)), fn {_revision, _parents, governed},
                                                               acc ->
        MapSet.union(acc, MapSet.new(Map.keys(governed)))
      end)

    governed_paths =
      Enum.filter(all_paths, fn path ->
        String.starts_with?(path, "docs/plans/") or
          Documents.adr_concept?(path) or
          (String.ends_with?(path, "-technical.md") and
             Documents.adr_concept?(Paths.concept(path)))
      end)

    adr_concepts = governed_paths |> Enum.filter(&Documents.adr_concept?/1) |> MapSet.new()

    {plans, gates} =
      classify_primary!(MapSet.delete(MapSet.new(governed_paths), @index), adr_concepts)

    primary =
      adr_concepts |> MapSet.union(plans) |> MapSet.union(gates) |> Enum.sort()

    walk = snapshots ++ [{"working tree", [head], current}]

    # Every revision's files, so an acceptance row can be judged against the gate
    # carried by the candidate it binds rather than only the ambient one.
    by_revision =
      Map.new(snapshots, fn {revision, _parents, governed} -> {revision, governed} end)

    parents_by_revision =
      Map.new(snapshots, fn {revision, parents, _governed} -> {revision, parents} end)

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
             by_revision,
             parents_by_revision,
             resolve_file
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
         by_revision,
         parents_by_revision,
         resolve_file
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

        validate_revision_transaction!(
          path,
          revision,
          parents,
          governed,
          from_parents,
          current,
          adr_concepts,
          by_revision,
          parents_by_revision,
          resolve_file
        )

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

  defp validate_revision_transaction!(
         path,
         revision,
         parents,
         governed,
         from_parents,
         current,
         adr_concepts,
         by_revision,
         parents_by_revision,
         resolve_file
       ) do
    strict = strict_transaction?(path, revision, governed, adr_concepts)

    cond do
      MapSet.member?(adr_concepts, path) ->
        :ok

      strict and length(parents) > 1 and current != from_parents ->
        raise Invalid,
              "#{path}: governance transitions require one direct parent; #{revision} is a merge"

      String.ends_with?(path, "-gate.md") ->
        :ok

      true ->
        changed =
          @plan_fields
          |> Enum.filter(&(Enum.at(from_parents, &1) != Enum.at(current, &1)))

        current_generation = acceptance_generation(Enum.at(current, 0))

        if strict and
             (Enum.at(from_parents, 0) != nil or
                (is_integer(current_generation) and current_generation > 0)) do
          validate_plan_change_set!(
            changed,
            path,
            revision,
            parents,
            governed,
            from_parents,
            current,
            by_revision,
            parents_by_revision,
            resolve_file
          )
        else
          :ok
        end
    end
  end

  # Concept: both amendment transactions are strict about their revision shape,
  # so either marker turns the strict rules on.
  #
  # Technical depth: v2 is additive rather than a rebind, but its proposal and
  # its acceptance are still exactly two direct one-parent revisions. Leaving it
  # out of the strict set would let a merge carry a generation change that no
  # single revision is accountable for.
  defp strict_transaction?(path, revision, governed, adr_concepts) do
    cond do
      MapSet.member?(adr_concepts, path) ->
        false

      String.ends_with?(path, "-gate.md") ->
        declares_transaction?(Map.get(governed, path), "#{path} at #{revision}")

      true ->
        gate_path = Paths.strip_suffix(path, ".md") <> "-gate.md"
        declares_transaction?(Map.get(governed, gate_path), "#{gate_path} at #{revision}")
    end
  end

  defp declares_transaction?(nil, _path), do: false

  defp declares_transaction?(gate, path) do
    Plan.amendment_transaction_v1?(gate, path) or Plan.amendment_transaction_v2?(gate, path)
  end

  defp validate_plan_change_set!(
         [],
         _path,
         _revision,
         _parents,
         _governed,
         _from,
         _current,
         _by,
         _parents_by,
         _resolve_file
       ),
       do: :ok

  defp validate_plan_change_set!(
         [2, 3],
         path,
         revision,
         [parent],
         governed,
         from,
         _current,
         by_revision,
         _parents_by_revision,
         resolve_file
       ) do
    require_settled_amendment_parent!(
      path,
      revision,
      parent,
      Enum.at(from, 0),
      by_revision
    )

    require_same_lifecycle!(
      path,
      revision,
      parent,
      governed,
      by_revision,
      resolve_file,
      "amendment proposal"
    )
  end

  defp validate_plan_change_set!(
         [0],
         path,
         revision,
         [parent],
         governed,
         _from,
         current,
         by_revision,
         parents_by_revision,
         resolve_file
       ) do
    generation = acceptance_generation(Enum.at(current, 0))

    if is_integer(generation) and generation > 0 do
      require_direct_candidate!(path, revision, parent, Enum.at(current, 0))
      require_amendment_proposal!(path, parent, by_revision, parents_by_revision)

      require_same_lifecycle!(
        path,
        revision,
        parent,
        governed,
        by_revision,
        resolve_file,
        "amendment rebind"
      )

      validate_historical_disposition!(
        path,
        revision,
        parent,
        Enum.at(current, 0),
        by_revision,
        resolve_file
      )
    end

    :ok
  end

  defp validate_plan_change_set!(
         [0, 2, 3],
         path,
         revision,
         [_parent],
         _governed,
         from,
         current,
         _by_revision,
         _parents_by_revision,
         _resolve_file
       ) do
    if Enum.at(from, 0) != nil or acceptance_generation(Enum.at(current, 0)) != 0 do
      raise Invalid,
            "#{path}: amendment proposal and Acceptance rebind must be distinct revisions at " <>
              revision
    end

    :ok
  end

  defp validate_plan_change_set!(
         [1],
         _path,
         _revision,
         [_parent],
         _governed,
         _from,
         _current,
         _by,
         _parents_by,
         _resolve_file
       ),
       do: :ok

  # Concept: the additive proposal. One revision carries the amended gate, the
  # envelopes it re-anchors, and the new proposed generation row together.
  #
  # Technical depth: the envelopes appear in this change set because their
  # anchors carry the ambient gate generation, which the amended gate advances;
  # their bytes are still pinned by the immutable Acceptance digests. Both
  # authority rows are absent from the set, which is the property that makes this
  # transaction usable on a Closed plan at all. A parent that already carries an
  # unsettled proposal is refused, so generations cannot overlap.
  defp validate_plan_change_set!(
         [2, 3, 4],
         path,
         revision,
         [parent],
         governed,
         from,
         current,
         by_revision,
         _parents_by_revision,
         resolve_file
       ) do
    inherited = Plan.decode_generations(Enum.at(from, 4))
    proposed = Plan.decode_generations(Enum.at(current, 4))

    unless Plan.generation_proposal_appended?(inherited, proposed) do
      raise Invalid,
            "#{path}: a gate generation proposal at #{revision} appends exactly one proposed " <>
              "row and rewrites none"
    end

    if inherited == [] do
      require_settled_amendment_parent!(path, revision, parent, Enum.at(from, 0), by_revision)
    end

    require_same_lifecycle!(
      path,
      revision,
      parent,
      governed,
      by_revision,
      resolve_file,
      "gate generation proposal"
    )
  end

  # Concept: the additive rebind. It records who accepted the proposal and the
  # exact revision they reviewed, and changes nothing else.
  #
  # Technical depth: the completed row must bind the sole parent, because that
  # parent is the proposal whose bytes were reviewed. Requiring a new disposition
  # anchor that did not exist at the proposal is the same rule the rebinding
  # transaction uses: an acceptance is a record someone wrote after reviewing,
  # not a pointer reused from an earlier one.
  defp validate_plan_change_set!(
         [4],
         path,
         revision,
         [parent],
         governed,
         from,
         current,
         by_revision,
         _parents_by_revision,
         resolve_file
       ) do
    proposed = Plan.decode_generations(Enum.at(from, 4))
    accepted = Plan.decode_generations(Enum.at(current, 4))

    unless Plan.generation_proposal_completed?(proposed, accepted) do
      raise Invalid,
            "#{path}: a gate generation rebind at #{revision} completes exactly the proposed " <>
              "row it inherits"
    end

    row = List.last(accepted)

    if Enum.at(row, 3) != parent do
      raise Invalid,
            "#{path}: gate generation rebind at #{revision} must bind its sole proposal parent " <>
              parent
    end

    require_same_lifecycle!(
      path,
      revision,
      parent,
      governed,
      by_revision,
      resolve_file,
      "gate generation rebind"
    )

    Plan.validate_generation_disposition!(Enum.at(row, 2), path, parent, revision, resolve_file)
  end

  defp validate_plan_change_set!(
         changed,
         path,
         revision,
         _parents,
         _governed,
         _from,
         _current,
         _by,
         _parents_by,
         _resolve_file
       ) do
    raise Invalid,
          "#{path}: governance fields #{inspect(changed)} changed together at #{revision}; " <>
            "proposal, rebind, and closure are distinct one-parent revisions"
  end

  defp require_direct_candidate!(path, revision, parent, acceptance) do
    candidate = acceptance_candidate(acceptance)

    if candidate != parent do
      raise Invalid,
            "#{path}: Acceptance rebind at #{revision} must directly follow and bind its sole " <>
              "proposal parent #{parent}"
    end

    :ok
  end

  defp require_amendment_proposal!(path, candidate, by_revision, parents_by_revision) do
    case Map.get(parents_by_revision, candidate) do
      [proposal_parent] ->
        candidate_files = Map.fetch!(by_revision, candidate)
        parent_files = Map.fetch!(by_revision, proposal_parent)
        gate_path = Paths.strip_suffix(path, ".md") <> "-gate.md"

        candidate_generation =
          candidate_files
          |> Map.fetch!(gate_path)
          |> Plan.gate_generation("#{gate_path} at #{candidate}")

        parent_generation =
          parent_files
          |> Map.fetch!(gate_path)
          |> Plan.gate_generation("#{gate_path} at #{proposal_parent}")

        {candidate_rows, _candidate_bound, _candidate_complete} =
          candidate_files
          |> Map.fetch!(path)
          |> Records.governance_records("#{path} at #{candidate}")

        {parent_rows, _parent_bound, _parent_complete} =
          parent_files
          |> Map.fetch!(path)
          |> Records.governance_records("#{path} at #{proposal_parent}")

        if candidate_generation <= parent_generation or
             Enum.at(candidate_rows, 0) != Enum.at(parent_rows, 0) do
          raise Invalid,
                "#{path}: Acceptance may bind only the exact proposal revision that first " <>
                  "advanced the amendment generation while retaining the prior row"
        end

        :ok

      _other ->
        raise Invalid,
              "#{path}: amendment proposal #{candidate} must be a one-parent revision"
    end
  end

  defp require_settled_amendment_parent!(
         path,
         revision,
         parent,
         retained_acceptance,
         by_revision
       ) do
    gate_path = Paths.strip_suffix(path, ".md") <> "-gate.md"

    parent_generation =
      by_revision
      |> Map.fetch!(parent)
      |> Map.fetch!(gate_path)
      |> Plan.gate_generation("#{gate_path} at #{parent}")

    bound_generation = acceptance_generation(retained_acceptance)

    if not is_integer(bound_generation) or parent_generation != bound_generation do
      raise Invalid,
            "#{path}: amendment proposal at #{revision} cannot advance from unsettled " <>
              "parent #{parent}; its gate generation #{parent_generation} is not the " <>
              "Acceptance-bound generation #{inspect(bound_generation)}"
    end

    :ok
  end

  defp require_same_lifecycle!(
         path,
         revision,
         parent,
         governed,
         by_revision,
         resolve_file,
         transition
       ) do
    name = path |> Paths.strip_prefix("docs/plans/") |> Paths.strip_suffix(".md")
    current_state = lifecycle_state!(governed, name, path, revision, resolve_file)

    parent_state =
      lifecycle_state!(Map.fetch!(by_revision, parent), name, path, parent, resolve_file)

    if current_state != parent_state do
      raise Invalid,
            "#{path}: #{transition} at #{revision} changed lifecycle state from " <>
              "#{parent_state} to #{current_state}"
    end

    :ok
  end

  defp lifecycle_state!(files, name, path, revision, resolve_file) do
    index = Map.get(files, @index) || (resolve_file && resolve_file.(revision, @index))

    case index do
      nil ->
        raise Invalid, "#{path}: lifecycle state is unavailable at #{revision}"

      index ->
        case List.keyfind(Register.register(index), name, 0) do
          {^name, state} -> state
          nil -> raise Invalid, "#{path}: #{name} is not registered at #{revision}"
        end
    end
  end

  defp validate_historical_disposition!(
         path,
         revision,
         candidate,
         acceptance,
         by_revision,
         resolve_file
       ) do
    files = Map.fetch!(by_revision, candidate)
    candidate_text = Map.fetch!(files, path)
    row = acceptance_row(acceptance)

    Plan.validate_amendment_disposition!(
      row,
      candidate_text,
      path,
      candidate,
      resolve_file,
      revision
    )
  end

  defp acceptance_generation(nil), do: nil

  defp acceptance_generation(value) do
    case value |> String.split("\0", parts: 2) |> hd() |> Integer.parse() do
      {generation, ""} -> generation
      _other -> nil
    end
  end

  defp acceptance_candidate(value) do
    case String.split(value, "\0", parts: 3) do
      [_generation, lineage, _row] -> lineage |> String.split(",") |> hd()
    end
  end

  defp acceptance_row(value) do
    case String.split(value, "\0") do
      [_generation, _lineage | row] -> row
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

  # Concept: parents may legitimately disagree when one of them carries a
  # declared plan amendment.
  # Technical depth: raising on every divergence made a merge that brings in an
  # accepted amendment unrepresentable -- the branch carrying it and the branch
  # without it meet with different anchors, which is the normal shape of landing
  # one. The gate generation governs the accepted gate, both plan envelopes, and
  # the Acceptance rebind. Exactly one candidate must supersede every other, and
  # anything else is still a conflict. Two sides at the same generation with
  # different bytes remain irreconcilable.
  defp reconcile!(values, path, revision, label, adr_concepts) do
    amendable = plan_amendable?(label, path, adr_concepts)

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
        amendable = plan_amendable?(label, path, adr_concepts)

        if amendable and Plan.supersedes?(label, anchor, value) do
          value
        else
          raise Invalid, "#{path}: completed #{label} governance record changed at #{revision}"
        end
    end
  end

  defp plan_amendable?(label, path, adr_concepts) do
    label in [
      "accepted gate",
      "Acceptance",
      "normative concept envelope",
      "normative technical envelope",
      "gate generations"
    ] and not Enum.member?(adr_concepts, path)
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

    with candidate when is_binary(candidate) <- bound_candidate_revision(row),
         files when is_map(files) <- Map.get(by_revision, candidate),
         text when is_binary(text) <- Map.get(files, gate_path) do
      Plan.gate_generation(text, "#{gate_path} at #{candidate}")
    else
      _other -> nil
    end
  end

  # Concept: an Acceptance amendment supersedes the commitment it actually
  # inherits, not any lower generation found on a sibling branch.
  # Technical depth: encode the complete candidate chain already present in the
  # candidate plans. Merge and sequential reconciliation can then require the
  # prior accepted candidate to occur in the new lineage. Missing historical
  # candidate bytes stop the chain at that candidate; current plan governance
  # separately requires the complete reachable chain before a rebind can pass.
  defp bound_candidate_lineage(row, path, by_revision) do
    case bound_candidate_revision(row) do
      nil -> []
      candidate -> candidate_lineage(candidate, path, by_revision, MapSet.new())
    end
  end

  defp candidate_lineage(candidate, path, by_revision, seen) do
    cond do
      MapSet.member?(seen, candidate) ->
        [candidate]

      true ->
        next_seen = MapSet.put(seen, candidate)

        with files when is_map(files) <- Map.get(by_revision, candidate),
             text when is_binary(text) <- Map.get(files, path) do
          {_rows, bound, complete} =
            Records.governance_records(text, "#{path} at candidate #{candidate}")

          case {Enum.at(complete, 0), Enum.at(bound, 0)} do
            {true, {prior, _concept, _technical, _gate}} ->
              [candidate | candidate_lineage(prior, path, by_revision, next_seen)]

            _original_or_incomplete ->
              [candidate]
          end
        else
          _unavailable -> [candidate]
        end
    end
  end

  defp bound_candidate_revision([_decision, _authority, _evidence, bound]) do
    case Regex.run(~r/candidate `([0-9a-f]{40})`/, bound) do
      [_all, candidate] -> candidate
      _other -> nil
    end
  end

  defp bound_candidate_revision(_row), do: nil

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
    {rows, bound, complete} = Records.governance_records(text, historical_path)

    case Enum.at(complete, 0) do
      false ->
        Enum.map(@plan_fields, fn _field -> nil end)

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

        # The leading fields are the amendment generation and complete candidate
        # lineage carried by the candidate this row binds -- deliberately NOT the
        # ambient generation of the gate at this revision. Using the ambient one
        # made the anchor change at the amendment commit itself, where the row had
        # not moved at all. Generation prevents same-version rewrites; lineage
        # prevents a later-numbered sibling from displacing a candidate it did not
        # inherit.
        candidate_generation =
          bound_candidate_generation(Enum.at(rows, 0), path, by_revision)

        candidate_lineage =
          rows
          |> Enum.at(0)
          |> bound_candidate_lineage(path, by_revision)
          |> Enum.join(",")

        # Concept: a declared gate amendment is the one version boundary for the
        # accepted plan commitment as a whole.
        # Technical depth: prefix both envelope anchors with the ambient gate
        # generation. Their bytes may therefore change only in the commit that
        # advances that generation; same-generation edits, rollback, and merge
        # divergence still fail. Acceptance uses the bound candidate generation
        # above because its administrative rebind necessarily follows later.
        gate_path = Paths.strip_suffix(path, ".md") <> "-gate.md"

        gate =
          case Map.get(governed, gate_path) do
            nil -> raise Invalid, "#{gate_path}: accepted plan gate disappeared at #{revision}"
            found -> found
          end

        ambient_generation = Plan.gate_generation(gate, "#{gate_path} at #{revision}")
        generations = Plan.gate_generations(text, historical_path)

        require_generation_coupling!(%{
          path: path,
          gate_path: gate_path,
          revision: revision,
          gate: gate,
          generations: generations,
          ambient_generation: ambient_generation,
          closure: Enum.at(bound, 1)
        })

        [
          "#{candidate_generation}\0#{candidate_lineage}\0" <>
            Enum.join(Enum.at(rows, 0), "\0"),
          if(Enum.at(complete, 1), do: Enum.join(Enum.at(rows, 1), "\0")),
          "#{ambient_generation}\0" <> Enum.join(concept_envelope, "\n"),
          "#{ambient_generation}\0" <> Enum.join(technical_envelope, "\n"),
          Plan.generations_anchor(generations)
        ]
    end
  end

  # Concept: at every reachable revision, a Closed milestone's gate is either the
  # gate its Closure record bound or the gate a recorded generation binds.
  #
  # Technical depth: this is the check that makes splitting an amendment fatal.
  # The artifact walk already proves each revision's bound artifacts match the
  # gate declaration that revision carried, so changing an artifact forces
  # changing the gate, and changing an accepted gate forces advancing its
  # amendment generation. Requiring the matching generation row in the same
  # revision closes the remaining gap: a revision that moves the artifact and the
  # gate while leaving the record for later is invalid where it stands, and no
  # descendant can make it valid again.
  defp require_generation_coupling!(context) do
    %{path: path, gate_path: gate_path, revision: revision, generations: generations} = context
    declared = Plan.amendment_transaction_v2?(context.gate, "#{gate_path} at #{revision}")

    cond do
      generations == [] and declared ->
        raise Invalid,
              "#{gate_path} at #{revision}: a gate declaring amendment transaction v2 must " <>
                "record its accepted gate generations"

      generations == [] ->
        require_closure_gate_retained!(context)

      not declared ->
        raise Invalid,
              "#{gate_path} at #{revision}: a recorded gate generation requires the gate to " <>
                "declare amendment transaction v2"

      context.closure == nil ->
        raise Invalid,
              "#{path} at #{revision}: gate generations amend a Closed milestone's gate; an " <>
                "active milestone amends its accepted plan pair instead"

      List.last(generations).generation != context.ambient_generation ->
        raise Invalid,
              "#{path} at #{revision}: the highest gate generation must be the amendment " <>
                "generation the gate itself declares"

      true ->
        :ok
    end
  end

  defp require_closure_gate_retained!(%{closure: nil}), do: :ok

  defp require_closure_gate_retained!(context) do
    {_revision, _concept, _technical, bound_gate} = context.closure
    historical_path = "#{context.gate_path} at #{context.revision}"

    if Plan.gate_digest(context.gate, historical_path) != bound_gate do
      raise Invalid,
            "#{context.path} at #{context.revision}: the Closed milestone's gate no longer " <>
              "matches its Closure record and no gate generation accepts the change"
    end

    :ok
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
