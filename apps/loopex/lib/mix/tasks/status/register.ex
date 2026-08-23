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
  state must link all three. The revision-status sentence is recomputed from the
  integrated phase and the register rows and compared byte for byte, in both the
  plans index and the README, so a stale summary cannot survive a transition.

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

  @seed_blocked %{
    "Integrated phase" => "Pre-implementation planning",
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

  def expected_capsule("Open", name, _adr_statuses) do
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

  def expected_capsule("Accepted", name, _adr_statuses), do: accepted_values(name)

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
  end

  def expected_capsule({_delivery_name, state}, {_lookahead_name, "Open"}, _adr_statuses) do
    raise Invalid,
          "#{@index}: an Open successor requires an Accepted predecessor, not #{state}"
  end

  def expected_capsule("In progress", "M1", adr_statuses) do
    require_m1_implementation_accepted!("In progress", adr_statuses)
    in_progress_values("M1")
  end

  def expected_capsule("In progress", name, _adr_statuses), do: in_progress_values(name)

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

  def expected_capsule("In review", name, _adr_statuses), do: in_review_values(name)

  # Concept: a closed milestone authorises nothing until the next one opens.
  #
  # Technical depth: this clause is written by the transition that first records
  # `Closed`, which is what the catch-all below demands rather than permitting the
  # check to be relaxed. Authorized work narrows back to planning and review: a
  # closed envelope grants no further implementation, and the next milestone opens
  # gate-first with its own plan pair and locked gate. The blocker field states the
  # closure rather than a gate verdict, because a canonical record should not
  # assert a run it cannot observe.
  def expected_capsule("Closed", name, _adr_statuses) do
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
          link = m1_adr_link(path, name)

          {
            "#{link} must be accepted before the `M1` plan pair and gate can be accepted",
            "Disposition #{name}",
            "After the prerequisite is accepted, revise and independently review the " <>
              "`M1` plan pair and gate"
          }

        paths ->
          [first, second] = Enum.map(paths, &m1_adr_link(&1, Map.fetch!(@m1_adr_names, &1)))

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

  defp m1_adr_link(path, name) do
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
