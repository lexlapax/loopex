defmodule Loopex.Checks.Status do
  @moduledoc """
  ## Concept

  Validates the repository's visible project state and its two-depth
  documentation as one connected whole: paired documents, index chains, the
  canonical milestone register and the summaries derived from it, ADR and plan
  governance, and the immutability of every accepted record across reachable
  history.

  The property is that a reader who consults the repository gets one answer. A
  register that disagrees with a plan, a summary that disagrees with the register,
  or an accepted record that has quietly changed all describe a project state
  that does not exist.

  ## Technical depth

  Ordering is deliberate. Document classification runs first, so nothing reaches
  the semantic checks unclassified; then links and indexes, then the register and
  its derived capsules, then ADR and plan governance, then the two history walks,
  then the rejoin barrier. Each stage assumes the previous one held, which is why
  the first failure is reported and the rest is not attempted: a structural defect
  produces a cascade of derived complaints that bury the one that matters.

  `validate/2` returns a list of messages rather than raising, so a caller can
  report and exit non-zero without an exception trace, and so the checks are
  callable from a test with in-memory documents and no repository at all.
  """

  alias Loopex.Checks.Adr
  alias Loopex.Checks.Documents
  alias Loopex.Checks.History
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Plan
  alias Loopex.Checks.Register

  @index "docs/plans/README.md"

  @required [
    "README.md",
    @index,
    "docs/vision.md",
    "docs/vision-technical.md",
    "docs/roadmap.md",
    "docs/roadmap-technical.md",
    "docs/developer/development-charter.md",
    "docs/developer/development-charter-technical.md"
  ]

  @rejoin_source_heading "## 22. Ownership and serial barriers"
  @rejoin_copy_heading "## The Enduring Rejoin Order"

  @doc """
  ## Concept

  Validates a document set and returns the messages describing what is wrong, or
  an empty list when everything holds.

  ## Technical depth

  Options are the three ways the checks reach outside the document set, each
  defaulting to absent:

    * `:resolve_file` — a function returning one file's text at one revision;
      without it, a bound candidate cannot be verified and any record that needs
      one fails as unavailable.
    * `:plan_history` — a function returning the reachable history; without it the
      history walk reports unavailable evidence rather than passing.
    * `:read_artifact` — a function returning one bound artifact's bytes from the
      working tree; without it the current-tree artifact comparison is skipped,
      because there is no tree to compare against.
  """
  @spec validate(map(), keyword()) :: [String.t()]
  def validate(documents, options \\ []) do
    resolve_file = Keyword.get(options, :resolve_file)
    plan_history = Keyword.get(options, :plan_history)
    read_artifact = Keyword.get(options, :read_artifact)

    {adr_paths, plan_names} = Documents.document_topology(documents)
    Documents.validate_local_links(documents)
    Documents.validate_directory_indexes(documents)
    require_present!(documents)

    plans_text = Map.fetch!(documents, @index)
    {values, summary_line} = Register.current_status(plans_text)
    rows = Register.register(plans_text)
    Register.checkpoint(Map.fetch!(values, "Last integrated checkpoint"), rows)

    expected_summary = Register.summary(Map.fetch!(values, "Integrated phase"), rows)

    if summary_line != expected_summary do
      raise Invalid, "#{@index}: Revision status is not derived from phase and register"
    end

    Register.readme_block(Map.fetch!(documents, "README.md"), expected_summary)

    adr_statuses =
      Map.new(adr_paths, fn path ->
        {path,
         Adr.validate(
           Map.fetch!(documents, path),
           Map.fetch!(documents, Paths.technical(path)),
           path,
           resolve_file
         )}
      end)

    require_derived_capsule!(rows, values, adr_statuses)
    require_register_matches_plans!(rows, plan_names)

    verify_current_artifacts!(documents, plan_names, read_artifact)

    state_by_name = Map.new(rows)

    Enum.each(plan_names, fn name ->
      Plan.governance(
        Map.fetch!(documents, "docs/plans/#{name}.md"),
        Map.fetch!(documents, "docs/plans/#{name}-technical.md"),
        Map.fetch!(documents, "docs/plans/#{name}-gate.md"),
        name,
        Map.fetch!(state_by_name, name),
        resolve_file
      )
    end)

    history = plan_history && plan_history.()
    History.governance_history(governed_documents(documents, adr_paths), governance_only(history))
    History.artifact_history(history)

    verify_rejoin_barrier!(documents)
    []
  rescue
    error in Invalid -> [Exception.message(error)]
  end

  defp require_present!(documents) do
    required =
      @required ++
        Enum.flat_map(Register.bootstrap_adrs(), &[&1, Paths.technical(&1)])

    Enum.each(required, fn path ->
      unless Map.has_key?(documents, path) do
        raise Invalid, "#{path}: missing"
      end
    end)
  end

  # Concept: every representable register state derives its exact status capsule.
  # Technical depth: enforcement covers exactly one registered milestone today.
  # Registering a second one must extend this deliberately, because "which
  # milestone does the capsule describe" has no single answer otherwise.
  # Concept: one field, one owner.
  #
  # Technical depth: `Last integrated checkpoint` is excluded here because
  # `Register.checkpoint/2` owns it, and owning it twice made the two disagree the
  # moment a milestone closed: the derived capsule pins the seed value for every
  # state, while the checkpoint rule requires the final Closed milestone once one
  # exists. Both cannot hold. Excluding it is not a relaxation -- `checkpoint/2`
  # still enforces the seed value until the first closure and an exact
  # `` `name` — YYYY-MM-DD `` after it, which is stricter than the capsule ever
  # was for this field.
  @checkpoint_field "Last integrated checkpoint"

  # Concept: the capsule describes the milestone that is currently active.
  #
  # Technical depth: this covered exactly one registered milestone and raised
  # otherwise, telling the next transition to extend it rather than relax it --
  # which is this transition, the first to register a second milestone. Closed
  # milestones are history and do not drive the capsule; exactly one active
  # milestone does. With none active the last Closed one describes the state,
  # which is what a repository between milestones looks like. More than one
  # active is already refused by `Register.summary/2`, and is refused here too
  # rather than picking one by position.
  defp require_derived_capsule!(rows, values, adr_statuses) do
    active = Enum.filter(rows, fn {_name, state} -> state in Register.active_states() end)
    closed = Enum.filter(rows, fn {_name, state} -> state == "Closed" end)

    describing =
      case {active, closed} do
        {[one], _any} -> [one]
        {[], [_ | _] = done} -> [List.last(done)]
        {[], []} -> rows
        {_many, _any} -> rows
      end

    require_single_capsule!(describing, values, adr_statuses)
  end

  defp require_single_capsule!(rows, values, adr_statuses) do
    case rows do
      [{name, state}] ->
        expected =
          Map.delete(Register.expected_capsule(state, name, adr_statuses), @checkpoint_field)

        if Map.delete(values, @checkpoint_field) != expected do
          raise Invalid, "#{@index}: the register state requires its exact derived status capsule"
        end

      _other ->
        raise Invalid,
              "#{@index}: lifecycle enforcement covers exactly one registered milestone; " <>
                "extend it before registering another"
    end
  end

  defp require_register_matches_plans!(rows, plan_names) do
    represented =
      rows |> Enum.reject(fn {_name, state} -> state == "Blocked" end) |> MapSet.new(&elem(&1, 0))

    if MapSet.new(plan_names) != represented do
      raise Invalid,
            "docs/plans: paired plan triples and non-Blocked register rows must match exactly"
    end

    :ok
  end

  # Concept: a gate binds artifacts outside its own bytes, so the current tree is
  # compared against every digest the gate declares.
  # Technical depth: skipped when no reader is supplied, because an in-memory
  # document set has no working tree to read.
  defp verify_current_artifacts!(_documents, _plan_names, nil), do: :ok

  defp verify_current_artifacts!(documents, plan_names, read_artifact) do
    Enum.each(plan_names, fn name ->
      gate_path = "docs/plans/#{name}-gate.md"

      documents
      |> Map.fetch!(gate_path)
      |> Plan.bound_artifacts(gate_path)
      |> Enum.each(fn {digest, target} ->
        case read_artifact.(target) do
          nil ->
            raise Invalid, "#{gate_path}: bound artifact #{target} is missing"

          content ->
            if Markdown.digest(content) != digest do
              raise Invalid,
                    "#{gate_path}: bound artifact #{target} does not match its locked digest"
            end
        end
      end)
    end)
  end

  defp governed_documents(documents, adr_paths) do
    adr_set =
      adr_paths |> Enum.flat_map(&[&1, Paths.technical(&1)]) |> MapSet.new()

    Map.filter(documents, fn {path, _text} ->
      MapSet.member?(adr_set, path) or
        (String.starts_with?(path, "docs/plans/") and path != @index and
           String.ends_with?(path, ".md"))
    end)
  end

  # Concept: the governance walk owns documents; the artifact walk owns bound
  # executables and configuration. Each is given only what it governs.
  defp governance_only(nil), do: nil

  defp governance_only({head, snapshots}) do
    filtered =
      Enum.map(snapshots, fn {revision, parents, files} ->
        {revision, parents,
         Map.filter(files, fn {path, _text} -> String.starts_with?(path, "docs/") end)}
      end)

    {head, filtered}
  end

  # Concept: the enduring rejoin order exists once, in the vision, and the roadmap
  # carries a byte-identical copy.
  # Technical depth: the copy is compared rather than described, so the readable
  # projection cannot drift from the authority. The payload's shape is checked too:
  # an initial step and at least one transition, each later step marked, so an
  # empty or malformed barrier list cannot pass as a recorded order.
  defp verify_rejoin_barrier!(documents) do
    source =
      Markdown.block(
        Map.fetch!(documents, "docs/vision-technical.md"),
        "docs/vision-technical.md",
        :rejoin_source,
        @rejoin_source_heading
      )

    copy =
      Markdown.block(
        Map.fetch!(documents, "docs/roadmap-technical.md"),
        "docs/roadmap-technical.md",
        :rejoin_copy,
        @rejoin_copy_heading
      )

    if source != copy do
      raise Invalid, "docs/roadmap-technical.md: rejoin block differs from vision technical §22"
    end

    if length(source) < 4 or Enum.at(source, 0) != "```text" or List.last(source) != "```" do
      raise Invalid, "docs/vision-technical.md: rejoin payload must be one complete text fence"
    end

    steps = source |> Enum.drop(1) |> Enum.drop(-1)
    [first | rest] = steps

    if length(steps) < 2 or String.trim(first) == "" or String.starts_with?(first, "-> ") do
      raise Invalid,
            "docs/vision-technical.md: rejoin payload needs an initial step and at least one transition"
    end

    if Enum.any?(rest, fn step ->
         not String.starts_with?(step, "-> ") or
           String.trim(binary_part(step, 3, byte_size(step) - 3)) == ""
       end) do
      raise Invalid, "docs/vision-technical.md: every later rejoin step must start with '-> '"
    end

    :ok
  end
end
