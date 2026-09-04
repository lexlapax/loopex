defmodule Loopex.Checks.Register do
  @moduledoc """
  ## Concept

  Validates the canonical milestone register and the two derived summaries that
  must agree with it. Three primary records carry project state — the register,
  the plans index's status capsule, and the README's derived summary — and a
  reader who consults any one of them must get the same answer.

  The capsule is *derived*, not written: for each representable lifecycle state
  there is exactly one correct set of status values, and this module computes it.
  A state nobody has added a derivation for fails closed, so the transition that
  first records it must add lifecycle enforcement rather than relax the check.

  ## Technical depth

  The register is an exact table whose link cells are determined by state: a
  Blocked milestone has no plan files yet and therefore no links, and every other
  state must link all three. Two fields are derived from the register's `Closed`
  rows by their own rule rather than by the lifecycle capsule — the integrated
  phase and the last closed product checkpoint — because the capsule derives from
  one milestone's state and those two describe the history behind it. The
  revision-status sentence is recomputed from that derived phase and the register
  rows and compared byte for byte, in both the plans index and the README, so a
  stale summary cannot survive a transition.

  Authorised work widens only at acceptance. The blocked, open, accepted, and
  in-progress capsules inherit that boundary explicitly rather than each
  restating it, which is what stops implementation from quietly authorising
  itself.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Names

  @index "docs/plans/README.md"

  @fields [
    "Integrated phase",
    "Last closed product checkpoint",
    "Blockers",
    "Authorized work",
    "Next maintainer decision",
    "Next transition",
    "Validation"
  ]

  @states ["Blocked", "Open", "Accepted", "In progress", "In review", "Closed"]
  @delivery_states ["Accepted", "In progress", "In review"]

  @seed_checkpoint "Seed bootstrap — 2026-08-15"
  @validation "`bash scripts/check-bootstrap.sh`"

  # Concept: the repository is either still before its first closed milestone or
  # past it. Those are the only two phases the register can prove, so those are
  # the only two this vocabulary has.
  #
  # Technical depth: a `Closed` row is the one product fact the checked-out bytes
  # carry. Anything finer — which branch integrated what, whether a release
  # followed, how much of the product is live — is a Git or publication fact this
  # checker deliberately does not claim, for the reason recorded in
  # `Loopex.Checks.Status`. The closed value names the kind of state and stops
  # there: the milestone's identity and date belong to
  # `Last closed product checkpoint`, so the two fields never restate each other,
  # and it says nothing about what may now be done, which `Authorized work` owns
  # alone. "Baseline" is the plans index's own word for what a Closed row
  # identifies, so the phase and the index it heads speak one vocabulary.
  @planning_phase "Pre-implementation planning"
  @closed_product_phase "Closed milestone product baseline"

  @bootstrap_adrs [
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md"
  ]
  @adr_names %{
    "docs/adr/0001-repository-and-application-layout.md" => "ADR 0001",
    "docs/adr/0002-bootstrap-runtime-floor.md" => "ADR 0002"
  }

  @m1_adrs [
    "docs/adr/0006-store-transaction-and-owner-epoch.md",
    "docs/adr/0007-local-executor-grant-job-receipt.md"
  ]

  @m1_adr_names %{
    "docs/adr/0006-store-transaction-and-owner-epoch.md" => "ADR 0006",
    "docs/adr/0007-local-executor-grant-job-receipt.md" => "ADR 0007"
  }

  @m1_implementation_adr "docs/adr/0008-owner-succession-recovery-and-runtime-placement.md"

  # Concept: a milestone whose plan pair names prerequisite decisions cannot be
  # accepted, implemented, or reviewed while any of them is still Proposed.
  #
  # Technical depth: the generic Open, Accepted, In progress, and In review
  # derivations discarded `adr_statuses` entirely, so a milestone with three
  # outstanding prerequisites derived "None; it is accepted and implementation
  # may proceed" the moment its own row moved. The set is declared here per
  # milestone because this is the capsule's own wording table: it decides which
  # outstanding decisions the displayed status names as the next thing to do.
  # Enforcement does not live here. The history walk reads each plan companion's
  # own `### Prerequisites and Acceptance Points` declaration at the revision it
  # is judging, so a milestone missing from this table is a capsule that says
  # less, never a milestone that goes unchecked. Each entry names the Concept
  # file and its display name; the technical companion follows by path
  # convention.
  @prerequisite_adrs %{
    "M2" => [
      {"docs/adr/0009-tool-executor-and-grant-contracts.md", "ADR 0009"},
      {"docs/adr/0010-provider-continuation-and-context-staging.md", "ADR 0010"},
      {"docs/adr/0011-session-input-algebra-and-streaming.md", "ADR 0011"}
    ],
    "M3" => [
      {"docs/adr/0002-bootstrap-runtime-floor.md", "ADR 0002"}
    ]
  }

  # Concept: the base every derived capsule starts from.
  #
  # Technical depth: `Integrated phase` is deliberately absent. It used to be
  # assigned here, no builder ever overrode it, and the comparison in
  # `Loopex.Checks.Status` therefore required the document to keep the seed value
  # for every representable lifecycle state, Closed included. A constant no
  # derivation can move does not belong in a derived capsule, so the field now has
  # a dedicated owner and no base value to inherit.
  @seed_blocked %{
    "Last closed product checkpoint" => @seed_checkpoint,
    "Blockers" =>
      "[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and " <>
        "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before " <>
        "M0 opens; a replacement requires a governed guard change",
    "Authorized work" =>
      "Explicitly authorized planning, ADR, bootstrap, and review work only; " <>
        "no product implementation",
    "Next maintainer decision" => "Disposition ADR 0001 and ADR 0002",
    "Next transition" =>
      "After the prerequisites are accepted, the maintainer explicitly opens " <>
        "`M0` gate-first",
    "Validation" => @validation
  }

  @doc """
  ## Concept

  The bootstrap ADR paths whose acceptance the blocked-candidate capsule is
  derived from.

  ## Technical depth

  Named here because the capsule text changes as each is dispositioned, so the
  derivation and the list it reads have to stay in one place.
  """
  @spec bootstrap_adrs() :: [String.t()]
  def bootstrap_adrs, do: @bootstrap_adrs

  @doc """
  ## Concept

  The register states the contract defines.

  ## Technical depth

  Exposed so plan and register validation read the same lifecycle vocabulary.
  """
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  ## Concept

  The states that authorize delivery work for one accepted milestone.

  ## Technical depth

  `Open` is deliberately absent. An Open milestone is a plan-and-gate candidate;
  when an earlier milestone is still delivering, it is the sole planning
  lookahead and cannot become a second implementation authority.
  """
  @spec delivery_states() :: [String.t()]
  def delivery_states, do: @delivery_states

  @doc """
  ## Concept

  Reads the Current Status capsule and returns its field values.

  ## Technical depth

  The block's shape is fixed — heading, blank, summary, blank, then the exact
  field table — so the summary sentence has one position and cannot be duplicated
  or moved. Field order is exact too, since a reordered table is how a value ends
  up read under the wrong name.
  """
  @spec current_status(String.t()) :: {%{String.t() => String.t()}, String.t()}
  def current_status(text) do
    block = Markdown.block(text, @index, :current)

    if length(block) != 13 or Enum.at(block, 0) != "## Current Status" or
         Enum.at(block, 1) != "" or Enum.at(block, 3) != "" do
      raise Invalid, "#{@index}: Current Status block has the wrong shape"
    end

    rows =
      block
      |> Enum.drop(4)
      |> Markdown.table(["Field", "Value"], "#{@index} Current Status")

    if Enum.map(rows, &hd/1) != @fields do
      raise Invalid, "#{@index}: Current Status fields are missing, duplicated, or reordered"
    end

    values = Map.new(rows, fn [field, value] -> {field, value} end)

    if Map.fetch!(values, "Validation") != @validation do
      raise Invalid, "#{@index}: Validation must name the exact bootstrap aggregate"
    end

    {values, Enum.at(block, 2)}
  end

  @doc """
  ## Concept

  Reads the Milestone Register and returns one `{name, state}` per row.

  ## Technical depth

  Names are validated and checked for case collisions, and the three link cells
  must match exactly what the state implies. A Blocked milestone has no plan files
  yet, so links would resolve to nothing; every other state must link all three,
  so a reader always reaches the plan pair and gate from the register.
  """
  @spec register(String.t()) :: [{String.t(), String.t()}]
  def register(text) do
    block = Markdown.block(text, @index, :register)

    if length(block) < 4 or Enum.at(block, 0) != "## Milestone Register" or
         Enum.at(block, 1) != "" do
      raise Invalid, "#{@index}: Milestone Register block has the wrong shape"
    end

    block
    |> Enum.drop(2)
    |> Markdown.table(
      ["Milestone", "State", "Concept", "Technical depth", "Gate"],
      "#{@index} Milestone Register"
    )
    |> Enum.reduce({[], MapSet.new()}, fn row, {rows, seen} ->
      [raw_name, state, concept, technical, gate] = row
      name = Names.milestone!(raw_name, "#{@index} Milestone Register")
      folded = String.downcase(name)

      if MapSet.member?(seen, folded) do
        raise Invalid, "#{@index}: duplicate or case-colliding milestone #{inspect(name)}"
      end

      unless state in @states do
        raise Invalid, "#{@index}: unknown milestone state #{inspect(state)}"
      end

      expected =
        case state do
          "Blocked" ->
            ["—", "—", "—"]

          _other ->
            [
              "[concept](#{name}.md)",
              "[technical depth](#{name}-technical.md)",
              "[gate](#{name}-gate.md)"
            ]
        end

      if [concept, technical, gate] != expected do
        raise Invalid,
              "#{@index}: #{name} has incorrect paired plan/gate links for #{state}"
      end

      {[{name, state} | rows], MapSet.put(seen, folded)}
    end)
    |> then(fn {rows, _seen} -> Enum.reverse(rows) end)
  end

  @doc """
  ## Concept

  The one correct revision-status sentence for a phase and a set of register rows.

  ## Technical depth

  One Accepted delivery milestone may coexist with one immediately following
  Open planning candidate. With no delivery milestone, Open remains the current
  plan candidate as before. Closed history must precede either role; every other
  shape fails closed.
  """
  @spec summary(String.t(), [{String.t(), String.t()}]) :: String.t()
  def summary(phase, rows) do
    roles = milestone_roles(rows)

    status =
      case {roles.delivery, roles.open} do
        {{name, state}, _lookahead} ->
          "active milestone `#{name}` is #{String.downcase(state)}"

        {nil, {name, "Open"}} ->
          "active milestone `#{name}` is open"

        {nil, nil} ->
          "no milestone is active"
      end

    next =
      case {roles.delivery, roles.open, roles.blocked} do
        {delivery, {name, "Open"}, nil} when not is_nil(delivery) ->
          "next candidate `#{name}` is open"

        {_delivery, nil, {name, "Blocked"}} ->
          "next candidate `#{name}` is blocked"

        _other ->
          "no next candidate is recorded"
      end

    "**Revision status:** #{phase}; #{status}; #{next}."
  end

  @doc """
  ## Concept

  Classifies the register into closed history, one delivery milestone, and one
  planning lookahead.

  ## Technical depth

  After zero or more Closed rows, the accepted tails are empty, one founding
  Blocked row, one Open candidate, one delivery milestone in `Accepted`,
  `In progress`, or `In review`, or an Accepted delivery milestone immediately
  followed by one Open successor. The predecessor stays Accepted because the
  lookahead branches from its governance-only integration, not its product
  branch. This admits one bounded planning lookahead without creating a second
  implementation authority or an unbounded queue.
  """
  @spec milestone_roles([{String.t(), String.t()}]) :: %{
          delivery: {String.t(), String.t()} | nil,
          open: {String.t(), String.t()} | nil,
          blocked: {String.t(), String.t()} | nil
        }
  def milestone_roles(rows) do
    {_closed, tail} = Enum.split_while(rows, fn {_name, state} -> state == "Closed" end)

    case tail do
      [] ->
        %{delivery: nil, open: nil, blocked: nil}

      [{_name, "Blocked"} = blocked] ->
        %{delivery: nil, open: nil, blocked: blocked}

      [{_name, "Open"} = open] ->
        %{delivery: nil, open: open, blocked: nil}

      [{_name, state} = delivery] when state in @delivery_states ->
        %{delivery: delivery, open: nil, blocked: nil}

      [
        {_delivery_name, "Accepted"} = delivery,
        {_open_name, "Open"} = open
      ] ->
        %{delivery: delivery, open: open, blocked: nil}

      _other ->
        raise Invalid,
              "#{@index}: rows must be Closed history followed by at most one delivery " <>
                "milestone and one Open successor"
    end
  end

  @doc """
  ## Concept

  Checks the last-closed-product-checkpoint field against the register: it names
  the final Closed milestone once one exists, and stays at the seed value until
  then.

  ## Technical depth

  The closed form is `` `name` — YYYY-MM-DD `` with a real calendar date, so a
  malformed or impossible date fails rather than reading as a recorded
  integration.
  """
  @spec closed_product_checkpoint(String.t(), [{String.t(), String.t()}]) :: :ok
  def closed_product_checkpoint(value, rows) do
    closed = for {name, "Closed"} <- rows, do: name

    case List.last(closed) do
      nil ->
        if value != @seed_checkpoint do
          raise Invalid,
                "#{@index}: seed checkpoint must remain until the first milestone closes"
        end

        :ok

      last ->
        valid =
          with [_all, name, date] <-
                 Regex.run(~r/\A`([^`]+)` — ([0-9]{4}-[0-9]{2}-[0-9]{2})\z/u, value),
               {:ok, _parsed} <- Date.from_iso8601(date) do
            name == last
          else
            _other -> false
          end

        unless valid do
          raise Invalid,
                "#{@index}: Last closed product checkpoint must name the final Closed row"
        end

        :ok
    end
  end

  @doc """
  ## Concept

  The phase the register implies: `Pre-implementation planning` until a milestone
  closes, and `Closed milestone product baseline` once one has.

  ## Technical depth

  Derived from the `Closed` rows and nothing else, which is what makes the value
  checkable: no prose, no branch, and no run is consulted. `Closed` rows are
  history and must precede every later state, so a `Closed` row after a
  non-Closed one is not a register whose phase is merely unknown — it is a
  register shape the lifecycle does not represent, and it raises here rather than
  being counted into a friendly answer.
  """
  @spec integrated_phase([{String.t(), String.t()}]) :: String.t()
  def integrated_phase(rows) do
    {closed, tail} = Enum.split_while(rows, fn {_name, state} -> state == "Closed" end)

    if Enum.any?(tail, fn {_name, state} -> state == "Closed" end) do
      raise Invalid,
            "#{@index}: Closed milestones must precede every later milestone state"
    end

    case closed do
      [] -> @planning_phase
      [_ | _] -> @closed_product_phase
    end
  end

  @doc """
  ## Concept

  Checks the Integrated phase field against the register and returns the derived
  phase the revision-status sentence is composed from.

  ## Technical depth

  Mirrors `closed_product_checkpoint/2`: one field, one owner, and the document's
  value compared against a derivation rather than against a constant. Returning
  the phase rather than `:ok` is what anchors the sentence — the summary is
  composed from what the register implies, so the cell and the sentence cannot
  agree with each other while both disagree with the register.
  """
  @spec integrated_phase(String.t(), [{String.t(), String.t()}]) :: String.t()
  def integrated_phase(value, rows) do
    expected = integrated_phase(rows)

    if value != expected do
      raise Invalid,
            "#{@index}: Integrated phase must be #{inspect(expected)}, derived from the " <>
              "register's Closed rows"
    end

    expected
  end

  @doc """
  ## Concept

  The README's derived status block: the same summary sentence and a visible link
  to the canonical plan records.

  ## Technical depth

  Compared as an exact line list, so neither the sentence nor the link can drift
  from the register, and the block must sit under the `# Loopex` heading rather
  than anywhere a marker happens to appear.
  """
  @spec readme_block(String.t(), String.t()) :: :ok
  def readme_block(text, expected_summary) do
    unless String.starts_with?(text, "# Loopex\n") do
      raise Invalid, "README.md: # Loopex must be the first line"
    end

    block = Markdown.block(text, "README.md", :readme, "# Loopex")

    expected = [
      "## Where Things Stand",
      "",
      expected_summary,
      "",
      "[Canonical milestone status and plan records](docs/plans/)"
    ]

    if block != expected do
      raise Invalid,
            "README.md: status block must be the exact derived summary and visible plans link"
    end

    :ok
  end

  @doc """
  ## Concept

  The exact status capsule the registered delivery and planning roles require.

  ## Technical depth

  A single role derives from its lifecycle state. The one composite form is an
  Accepted predecessor plus an Open successor. Every other composite fails
  closed rather than letting two roles silently share one authority surface.
  """
  @spec expected_capsule(
          String.t() | {String.t(), String.t()},
          String.t() | {String.t(), String.t()},
          %{String.t() => String.t()}
        ) ::
          %{String.t() => String.t()}
  def expected_capsule("Blocked", name, adr_statuses) do
    if name != "M0" do
      raise Invalid,
            "#{@index}: the blocked-candidate capsule is derived from the founding ADR records " <>
              "and applies only to M0"
    end

    blocked_values(adr_statuses)
  end

  def expected_capsule("Open", "M1", adr_statuses), do: m1_open_values(adr_statuses)

  def expected_capsule("Open", name, adr_statuses) do
    base =
      @seed_blocked
      |> Map.put(
        "Blockers",
        "`#{name}` is open and not accepted; the recorded acceptance authority must " <>
          "accept both normative envelopes and the gate"
      )
      |> Map.put("Next maintainer decision", "Accept or reject the `#{name}` plan pair and gate")
      |> Map.put(
        "Next transition",
        "Record the acceptance governance row and move `#{name}` to Accepted"
      )

    case unresolved_prerequisites(name, adr_statuses) do
      [] ->
        base

      unresolved ->
        base
        |> Map.put(
          "Blockers",
          "#{join_and(prerequisite_links(unresolved))} must be accepted before the " <>
            "`#{name}` plan pair and gate can be accepted"
        )
        |> Map.put(
          "Next maintainer decision",
          "Disposition #{join_and(prerequisite_names(unresolved))}"
        )
        |> Map.put(
          "Next transition",
          "After #{prerequisite_subject(unresolved)} accepted, accept or reject the " <>
            "`#{name}` plan pair and gate"
        )
    end
  end

  def expected_capsule("Accepted", "M1", adr_statuses) do
    case m1_implementation_accepted?(adr_statuses) do
      true ->
        accepted_values("M1")

      false ->
        accepted_values("M1")
        |> Map.put(
          "Blockers",
          "[ADR 0008](../adr/0008-owner-succession-recovery-and-runtime-placement.md#concept) " <>
            "must be accepted before Workstream A is revised and Workstream B is completed"
        )
        |> Map.put("Next maintainer decision", "Accept or reject ADR 0008")
        |> Map.put(
          "Next transition",
          "After ADR 0008 is accepted, revise Workstream A, rejoin Workstream B, and turn " <>
            "the locked gate green"
        )
    end
  end

  def expected_capsule("Accepted", name, adr_statuses) do
    require_prerequisites_accepted!(name, "Accepted", adr_statuses)
    accepted_values(name)
  end

  def expected_capsule(
        {delivery_name, "Accepted"},
        {lookahead_name, "Open"},
        adr_statuses
      ) do
    delivery = expected_capsule("Accepted", delivery_name, adr_statuses)

    delivery
    |> Map.put(
      "Authorized work",
      "Implementation inside the accepted `#{delivery_name}` envelopes and locked gate on " <>
        "its designated milestone branch; planning, gate construction, and review for Open " <>
        "`#{lookahead_name}`; no milestone product bytes integrate before closure and no " <>
        "`#{lookahead_name}` product implementation"
    )
    |> lookahead_values(delivery_name, lookahead_name, adr_statuses)
    |> successor_prerequisites(lookahead_name, adr_statuses)
  end

  def expected_capsule({_delivery_name, state}, {_lookahead_name, "Open"}, _adr_statuses) do
    raise Invalid,
          "#{@index}: an Open successor requires an Accepted predecessor, not #{state}"
  end

  def expected_capsule("In progress", "M1", adr_statuses) do
    require_m1_implementation_accepted!("In progress", adr_statuses)
    in_progress_values("M1")
  end

  def expected_capsule("In progress", name, adr_statuses) do
    require_prerequisites_accepted!(name, "In progress", adr_statuses)
    in_progress_values(name)
  end

  # Concept: the milestone awaits an independent verdict, and the register states
  # that lifecycle fact rather than any claim about a run.
  #
  # Technical depth: authorized work does not widen here — acceptance remains the
  # only transition that widens it. What changes is that the next decision returns
  # to the maintainer, because a reviewer produces findings and only an acceptance
  # authority closes. This capsule used to assert that the milestone "has a green
  # gate on every locked lane", and the comment above it asserted "the gate is
  # green": a claim about a run, in a derivation that cannot observe one, true by
  # construction for any milestone in review whether green or red. The status check
  # then enforced that a canonical record keep asserting it. A gate verdict belongs
  # to retained evidence at a named candidate. The first correction removed the
  # claim from the record and left it in the comment directly above -- which is the
  # same defect, in the place the next reader looks first.
  def expected_capsule("In review", "M1", adr_statuses) do
    require_m1_implementation_accepted!("In review", adr_statuses)
    in_review_values("M1")
  end

  def expected_capsule("In review", name, adr_statuses) do
    require_prerequisites_accepted!(name, "In review", adr_statuses)
    in_review_values(name)
  end

  # Concept: a closed milestone authorises nothing until the next one opens.
  #
  # Technical depth: this clause is written by the transition that first records
  # `Closed`, which is what the catch-all below demands rather than permitting the
  # check to be relaxed. Authorized work narrows back to planning and review: a
  # closed envelope grants no further implementation, and the next milestone opens
  # gate-first with its own plan pair and locked gate. The blocker field states the
  # closure rather than a gate verdict, because a canonical record should not
  # assert a run it cannot observe.
  def expected_capsule("Closed", name, adr_statuses) do
    require_prerequisites_accepted!(name, "Closed", adr_statuses)

    @seed_blocked
    |> Map.put("Blockers", "None; `#{name}` is closed and its governance row is recorded")
    |> Map.put(
      "Authorized work",
      "Explicitly authorized planning, ADR, and review work only; no product " <>
        "implementation until the next milestone is accepted"
    )
    |> Map.put("Next maintainer decision", "Open the next milestone gate-first, or defer it")
    |> Map.put(
      "Next transition",
      "Create the next milestone's plan pair and red gate, and move it to Open"
    )
  end

  def expected_capsule(state, _name, _adr_statuses) do
    raise Invalid,
          "#{@index}: milestone state #{inspect(state)} has no derived status capsule; " <>
            "the transition that first records it must add lifecycle enforcement rather " <>
            "than relax this check"
  end

  @doc """
  ## Concept

  The decisions a milestone's plan pair declares must carry recorded acceptance
  before that milestone is accepted or implemented.

  ## Technical depth

  Exposed because two checks need one table. The live capsule derivation reads it
  to refuse an Accepted-or-later state and to name what an Open milestone waits
  on; the governance history walk reads it to judge every revision, since the
  live view only ever asks about the milestone whose capsule is displayed.
  """
  @spec prerequisite_adrs(String.t()) :: [{String.t(), String.t()}]
  def prerequisite_adrs(name), do: Map.get(@prerequisite_adrs, name, [])

  defp in_progress_values(name) do
    name
    |> accepted_values()
    |> Map.put("Blockers", "None; `#{name}` is in progress against its locked gate")
    |> Map.put("Next transition", "Turn the locked gate green, then move `#{name}` to In review")
  end

  defp in_review_values(name) do
    name
    |> accepted_values()
    |> Map.put(
      "Blockers",
      "None; `#{name}` awaits independent review of its closure candidate"
    )
    |> Map.put(
      "Next maintainer decision",
      "Close `#{name}` or reject its closure candidate on the review findings"
    )
    |> Map.put(
      "Next transition",
      "Record the closure governance row and move `#{name}` to Closed"
    )
  end

  defp lookahead_values(capsule, "M1", lookahead_name, adr_statuses) do
    if m1_implementation_accepted?(adr_statuses) do
      generic_lookahead_values(capsule, "M1", lookahead_name)
    else
      capsule
      |> Map.put(
        "Blockers",
        capsule["Blockers"] <>
          "; `#{lookahead_name}` acceptance, integration, and product implementation also " <>
          "wait until `M1` closes and the Open candidate is refreshed and independently " <>
          "reviewed on that closed base"
      )
      |> Map.put(
        "Next maintainer decision",
        "Accept or reject ADR 0008; `#{lookahead_name}` cannot be accepted before `M1` closes"
      )
      |> Map.put(
        "Next transition",
        "After ADR 0008 is accepted, revise Workstream A, rejoin Workstream B, turn the " <>
          "locked `M1` gate green, and close it; then refresh and independently review " <>
          "`#{lookahead_name}` on that closed base"
      )
    end
  end

  defp lookahead_values(capsule, delivery_name, lookahead_name, _adr_statuses) do
    generic_lookahead_values(capsule, delivery_name, lookahead_name)
  end

  # Concept: the successor's own outstanding decisions are the successor's
  # blocker, and the composite capsule is the only place they can be read.
  #
  # Technical depth: every `lookahead_values/4` clause discarded the successor's
  # ADR statuses, so the one shape that carries an Open milestone without running
  # the Open derivation stated nothing about that milestone's prerequisites. The
  # delivery half already refuses to derive Accepted with one outstanding, so the
  # gap was confined to what the successor's own row reports. This runs after
  # whichever clause built the capsule, so a delivery-specific branch cannot
  # bypass it the way calling `generic_lookahead_values/3` directly would.
  defp successor_prerequisites(capsule, lookahead_name, adr_statuses) do
    case unresolved_prerequisites(lookahead_name, adr_statuses) do
      [] ->
        capsule

      unresolved ->
        Map.put(
          capsule,
          "Next maintainer decision",
          "#{capsule["Next maintainer decision"]}; `#{lookahead_name}` also waits on " <>
            "#{join_and(prerequisite_links(unresolved))}, which " <>
            "#{prerequisite_verb(unresolved)} not accepted"
        )
        |> Map.put(
          "Blockers",
          "#{capsule["Blockers"]}; `#{lookahead_name}` additionally waits on " <>
            "#{join_and(prerequisite_names(unresolved))}"
        )
    end
  end

  defp generic_lookahead_values(capsule, delivery_name, lookahead_name) do
    capsule
    |> Map.put(
      "Blockers",
      "None for `#{delivery_name}` delivery; `#{lookahead_name}` acceptance, integration, " <>
        "and product implementation wait until `#{delivery_name}` closes and the Open " <>
        "candidate is refreshed and independently reviewed on that closed base"
    )
    |> Map.put(
      "Next maintainer decision",
      "None until `#{delivery_name}` is ready for independent review; `#{lookahead_name}` " <>
        "cannot be accepted before `#{delivery_name}` closes"
    )
    |> Map.put(
      "Next transition",
      "Turn the locked `#{delivery_name}` gate green and close it; then refresh and " <>
        "independently review `#{lookahead_name}` on that closed base"
    )
  end

  defp require_m1_implementation_accepted!(state, adr_statuses) do
    unless m1_implementation_accepted?(adr_statuses) do
      raise Invalid,
            "#{@index}: M1 cannot move to #{state} before ADR 0008 is accepted"
    end
  end

  defp m1_implementation_accepted?(adr_statuses) do
    Map.fetch!(adr_statuses, @m1_implementation_adr) == "Accepted"
  end

  # Concept: an outstanding prerequisite is one the register can still see is not
  # Accepted.
  #
  # Technical depth: a declared prerequisite that is not a registered ADR is a
  # governed failure rather than a missing key, because silently treating it as
  # resolved is the one outcome this guard exists to prevent.
  defp unresolved_prerequisites(name, adr_statuses) do
    @prerequisite_adrs
    |> Map.get(name, [])
    |> Enum.filter(fn {path, adr_name} ->
      case Map.fetch(adr_statuses, path) do
        {:ok, status} ->
          status != "Accepted"

        :error ->
          raise Invalid,
                "#{@index}: `#{name}` names #{adr_name} as a prerequisite but #{path} is not " <>
                  "a registered ADR"
      end
    end)
  end

  defp require_prerequisites_accepted!(name, state, adr_statuses) do
    case unresolved_prerequisites(name, adr_statuses) do
      [] ->
        :ok

      unresolved ->
        raise Invalid,
              "#{@index}: `#{name}` cannot move to #{state} before " <>
                "#{join_and(prerequisite_names(unresolved))} #{prerequisite_verb(unresolved)} " <>
                "accepted"
    end
  end

  defp prerequisite_names(unresolved), do: Enum.map(unresolved, fn {_path, name} -> name end)

  defp prerequisite_links(unresolved) do
    Enum.map(unresolved, fn {path, name} -> adr_link(path, name) end)
  end

  defp prerequisite_verb([_one]), do: "is"
  defp prerequisite_verb(_many), do: "are"

  defp prerequisite_subject([_one]), do: "the prerequisite is"
  defp prerequisite_subject(_many), do: "the prerequisites are"

  defp join_and([one]), do: one
  defp join_and([first, second]), do: "#{first} and #{second}"

  defp join_and(items) do
    {leading, [last]} = Enum.split(items, -1)
    Enum.join(leading, ", ") <> ", and " <> last
  end

  # Concept: acceptance is the only transition that widens authorized work, and it
  # widens it to the accepted envelopes and locked gate, no further.
  defp accepted_values(name) do
    @seed_blocked
    |> Map.put("Blockers", "None; `#{name}` is accepted and implementation may proceed")
    |> Map.put(
      "Authorized work",
      "Implementation inside the accepted `#{name}` envelopes and its locked gate on the " <>
        "designated milestone branch; no milestone product bytes integrate before closure"
    )
    |> Map.put(
      "Next maintainer decision",
      "None until `#{name}` is ready for independent review"
    )
    |> Map.put(
      "Next transition",
      "Turn the locked gate green, then move `#{name}` to In progress and In review"
    )
  end

  # Concept: M1 cannot reach plan acceptance while either architecture decision
  # that shapes its store or executor outcome remains Proposed.
  #
  # Technical depth: derive the blocker, decision, and transition from the two
  # ADR records independently. This makes accepting either one remove exactly
  # that prerequisite while preserving the planning-only authority boundary.
  defp m1_open_values(adr_statuses) do
    unresolved = Enum.filter(@m1_adrs, &(Map.fetch!(adr_statuses, &1) != "Accepted"))

    {blockers, decision, transition} =
      case unresolved do
        [] ->
          {
            "`M1` remains open and unaccepted; its revised plan-pair and gate candidate " <>
              "awaits independent review",
            "Independently review the exact revised `M1` candidate",
            "After a clear review, accept or reject the `M1` plan pair and gate"
          }

        [path] ->
          name = Map.fetch!(@m1_adr_names, path)
          link = adr_link(path, name)

          {
            "#{link} must be accepted before the `M1` plan pair and gate can be accepted",
            "Disposition #{name}",
            "After the prerequisite is accepted, revise and independently review the " <>
              "`M1` plan pair and gate"
          }

        paths ->
          [first, second] = Enum.map(paths, &adr_link(&1, Map.fetch!(@m1_adr_names, &1)))

          {
            "#{first} and #{second} must be accepted before the `M1` plan pair and gate " <>
              "can be accepted",
            "Disposition ADR 0006 and ADR 0007",
            "After both prerequisites are accepted, revise and independently review the " <>
              "`M1` plan pair and gate"
          }
      end

    @seed_blocked
    |> Map.put("Blockers", blockers)
    |> Map.put("Next maintainer decision", decision)
    |> Map.put("Next transition", transition)
  end

  defp adr_link(path, name) do
    filename = Loopex.Checks.Paths.strip_prefix(path, "docs/adr/")
    "[#{name}](../adr/#{filename}#concept)"
  end

  defp blocked_values(adr_statuses) do
    unresolved = Enum.filter(@bootstrap_adrs, &(Map.fetch!(adr_statuses, &1) != "Accepted"))

    case unresolved do
      [path] ->
        name = Map.fetch!(@adr_names, path)
        filename = Loopex.Checks.Paths.strip_prefix(path, "docs/adr/")

        @seed_blocked
        |> Map.put(
          "Blockers",
          "[#{name}](../adr/#{filename}#concept) must be accepted before M0 opens; " <>
            "a replacement requires a governed guard change"
        )
        |> Map.put("Next maintainer decision", "Disposition #{name}")

      [] ->
        @seed_blocked
        |> Map.put("Blockers", "M0 has not been explicitly opened gate-first")
        |> Map.put("Next maintainer decision", "Explicitly open or defer M0")
        |> Map.put(
          "Next transition",
          "Create the branch-only M0 Concept plan, Technical depth plan, and red gate; " <>
            "install lifecycle-specific status checks; and move M0 to Open"
        )

      _both ->
        @seed_blocked
    end
  end
end
