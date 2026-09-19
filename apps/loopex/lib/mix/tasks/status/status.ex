defmodule Loopex.Checks.Status do
  @moduledoc """
  ## Concept

  Validates the repository's visible project state and its two-depth
  documentation as one connected whole: paired documents, index chains, the
  canonical milestone register, the summaries derived from it, and ADR status
  shape.

  The property is that a reader who consults the repository gets one answer. A
  register that disagrees with a plan or a summary that disagrees with the
  register both describe a project state that does not exist.

  ## Technical depth

  Everything here reads the current tree. Nothing walks Git history and nothing
  compares bytes against an earlier revision, so the check costs a document read
  and finishes in seconds.

  Ordering is deliberate. Document classification runs first, so nothing reaches
  the semantic checks unclassified; then links and indexes, then the register and
  its derived capsules, then ADR status, then the rejoin barrier. Each stage
  assumes the previous one held, which is why the first failure is reported and
  the rest is not attempted: a structural defect produces a cascade of derived
  complaints that bury the one that matters.

  `validate/1` returns a list of messages rather than raising, so a caller can
  report and exit non-zero without an exception trace, and so the checks are
  callable from a test with in-memory documents and no repository at all.
  """

  alias Loopex.Checks.Adr
  alias Loopex.Checks.Documents
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Paths
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

  The document set is the whole input. No revision resolver, history reader, or
  artifact reader is consulted, so the same call validates a real checkout and an
  in-memory fixture identically.
  """
  @spec validate(map()) :: [String.t()]
  def validate(documents) do
    {adr_paths, plan_names} = Documents.document_topology(documents)
    Documents.validate_local_links(documents)
    Documents.validate_directory_indexes(documents)
    require_present!(documents)

    plans_text = Map.fetch!(documents, @index)
    {values, summary_line} = Register.current_status(plans_text)
    rows = Register.register(plans_text)

    Register.closed_product_checkpoint(
      Map.fetch!(values, "Last closed product checkpoint"),
      rows
    )

    phase = Register.integrated_phase(Map.fetch!(values, "Integrated phase"), rows)

    expected_summary = Register.summary(phase, rows)

    if summary_line != expected_summary do
      raise Invalid, "#{@index}: Revision status is not derived from phase and register"
    end

    Register.readme_block(Map.fetch!(documents, "README.md"), expected_summary)

    adr_statuses =
      Map.new(adr_paths, fn path ->
        {path, Adr.validate(Map.fetch!(documents, path), path)}
      end)

    require_derived_capsule!(rows, values, adr_statuses)
    require_register_matches_plans!(rows, plan_names)

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

  # Concept: one field, one owner.
  #
  # Technical depth: `Last closed product checkpoint` is excluded here because
  # `Register.closed_product_checkpoint/2` owns it, and owning it twice made the
  # two disagree the moment a milestone closed: the derived capsule pins the seed
  # value for every state, while the checkpoint rule requires the final Closed
  # milestone once one exists. Both cannot hold. Excluding it is not a relaxation
  # -- the dedicated check still enforces the seed value until the first closure
  # and an exact `` `name` — YYYY-MM-DD `` after it, which is stricter than the
  # capsule ever was for this field.
  @checkpoint_field "Last closed product checkpoint"

  # Concept: the same rule, applied to the field naming the kind of state the
  # repository is in.
  #
  # Technical depth: `Integrated phase` was the second field the capsule owned
  # twice, and it lost the argument the same way and for longer. `@seed_blocked`
  # assigned it once, no builder overrode it for any state, and this comparison
  # then required both primary records to keep saying "Pre-implementation
  # planning" after M0 and M1 had closed with product on `main`. The two records
  # agreed with each other, which is exactly why nothing caught it.
  # `Register.integrated_phase/2` owns the field now and derives it from the
  # register's `Closed` rows. Excluding it here is again stricter, not looser: the
  # capsule could only ever demand one constant for every lifecycle state, while
  # the owner demands the value the register implies and refuses the other one.
  # The constant was not simply wrong, which is why it survived: it was right
  # until the first milestone closed and wrong ever after, so what it gave was
  # one-sided protection rather than none.
  #
  # The owner is consulted here in `validate/1` rather than in the parser because
  # this value derives from the register, not from the shape of the text, and
  # `Register.current_status/1` reads shape alone.
  @phase_field "Integrated phase"

  # Concept: the fields whose owners live outside the lifecycle capsule.
  @derived_fields [@checkpoint_field, @phase_field]

  # Concept: the capsule describes the current delivery milestone and its one
  # permitted Open successor.
  #
  # Technical depth: `Register.milestone_roles/1` validates the entire ordered
  # register before anything is selected. Closed milestones are history; one
  # delivery milestone may be followed by one Open planning lookahead. With no
  # delivery milestone, an Open or founding Blocked candidate describes the
  # state; between milestones the last Closed row does.
  defp require_derived_capsule!(rows, values, adr_statuses) do
    roles = Register.milestone_roles(rows)
    closed = Enum.filter(rows, fn {_name, state} -> state == "Closed" end)

    expected =
      case {roles.delivery, roles.open, roles.blocked, closed} do
        {{delivery_name, delivery_state}, {open_name, "Open"}, nil, _closed} ->
          Register.expected_capsule(
            {delivery_name, delivery_state},
            {open_name, "Open"},
            adr_statuses
          )

        {{name, state}, nil, nil, _closed} ->
          Register.expected_capsule(state, name, adr_statuses)

        {nil, {name, "Open"}, nil, _closed} ->
          Register.expected_capsule("Open", name, adr_statuses)

        {nil, nil, {name, "Blocked"}, _closed} ->
          Register.expected_capsule("Blocked", name, adr_statuses)

        {nil, nil, nil, [_ | _] = done} ->
          {name, "Closed"} = List.last(done)
          Register.expected_capsule("Closed", name, adr_statuses)

        {nil, nil, nil, []} ->
          raise Invalid, "#{@index}: milestone register is empty"
      end
      |> Map.drop(@derived_fields)

    if Map.drop(values, @derived_fields) != expected do
      raise Invalid, "#{@index}: the register state requires its exact derived status capsule"
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
