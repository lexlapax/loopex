defmodule Loopex.StatusFixtures do
  @moduledoc """
  ## Concept

  Compact in-memory document sets for the status checks. A fixture repository is
  the smallest set of documents that passes every check, so a test states one
  mutation and asserts it fails — which keeps each case about one property rather
  than about assembling a valid repository.

  Nothing here touches the checkout. The checks take the documents as data, so a
  case can build a repository state that no real checkout would contain.

  ## Technical depth

  Every fixture is exact text, because the checks compare bytes. A governance row
  carries digest-shaped and revision-shaped constants rather than real hashes:
  the checks read those cells for shape only, so a computed digest would suggest
  a comparison that no longer happens.
  """

  alias Loopex.Checks.Status

  @summary "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `M0` is blocked."

  @open_summary "**Revision status:** Pre-implementation planning; active milestone `M0` is open; no next candidate is recorded."

  # Concept: a register carrying a `Closed` row derives the closed phase, so the
  # sentence a closed fixture must carry differs from the seed sentence in the
  # phase as well as in the milestone clauses.
  @closed_phase "Closed milestone product baseline"

  @closed_summary "**Revision status:** #{@closed_phase}; no milestone is active; no next candidate is recorded."

  @planning_phase_cell "| Integrated phase | Pre-implementation planning |"

  @gate """
  # Gate

  ## Acceptance Command

  `mix test test/example_test.exs`
  """

  @adr_paths [
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md"
  ]

  @blocked_row "| `M0` | Blocked | — | — | — |"

  @blockers_cell "| Blockers | [ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before M0 opens; a replacement requires a governed guard change |"

  @blockers_text "[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before M0 opens; a replacement requires a governed guard change"

  def summary, do: @summary
  def open_summary, do: @open_summary
  def closed_summary, do: @closed_summary

  @doc """
  ## Concept

  Rewrites a fixture document's Integrated phase cell to the phase a register
  carrying a `Closed` row derives.

  ## Technical depth

  The phase is owned by `Register.integrated_phase/2` rather than by the derived
  capsule, so a fixture that closes a milestone has to move this cell explicitly.
  A test that forgets to gets the phase owner's failure, which is the behaviour
  being fixtured, not a fixture bug.
  """
  def closed_phase_cell(text) do
    String.replace(text, @planning_phase_cell, "| Integrated phase | #{@closed_phase} |")
  end

  def gate, do: @gate

  def adr_paths, do: @adr_paths
  def blocked_row, do: @blocked_row

  def rejoin do
    """
    ```text
    durable local session and operation truth
    -> multi-client attachment and protocol candidate
    ```
    """
    |> String.trim_trailing("\n")
  end

  def current do
    """
    <!-- loopex:current-status:start -->
    ## Current Status

    #{@summary}

    | Field | Value |
    | --- | --- |
    #{@planning_phase_cell}
    | Last closed product checkpoint | Seed bootstrap — 2026-08-15 |
    #{@blockers_cell}
    | Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
    | Next maintainer decision | Disposition ADR 0001 and ADR 0002 |
    | Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
    | Validation | `bash scripts/check-bootstrap.sh` |
    <!-- loopex:current-status:end -->
    """
    |> String.trim_trailing("\n")
  end

  def register do
    """
    <!-- loopex:milestone-register:start -->
    ## Milestone Register

    | Milestone | State | Concept | Technical depth | Gate |
    | --- | --- | --- | --- | --- |
    #{@blocked_row}
    <!-- loopex:milestone-register:end -->
    """
    |> String.trim_trailing("\n")
  end

  def readme do
    """
    # Loopex

    <!-- loopex:readme-status:start -->
    ## Where Things Stand

    #{@summary}

    [Canonical milestone status and plan records](docs/plans/)
    <!-- loopex:readme-status:end -->
    """
  end

  def plan_preamble do
    """
    <a id="concept"></a>
    ## Concept

    Technical depth: [Milestone technical depth](M0-technical.md#technical-depth)
    """
  end

  def envelope do
    """
    <!-- loopex:plan-concept-envelope:start -->
    ## Normative Concept Envelope

    <a id="concept-plan-purpose"></a>
    ### Purpose

    Prove one bounded behavior.

    <a id="concept-plan-outcomes"></a>
    ### Outcomes

    | # | Outcome | Evidence class | Gate selector |
    | --- | --- | --- | --- |
    | 1 | One bounded outcome | focused test | `test/example_test.exs` |

    Technical depth: [Evidence obligations and mapping](M0-technical.md#technical-plan-evidence)

    <a id="concept-plan-scope"></a>
    ### Scope

    Only the bounded outcome.

    Technical depth: [Prerequisites and acceptance points](M0-technical.md#technical-plan-prerequisites)
    Technical depth: [Ownership and rejoin barriers](M0-technical.md#technical-plan-ownership)
    Technical depth: [Compatibility mechanics](M0-technical.md#technical-plan-compatibility)
    Technical depth: [Migration and rollback](M0-technical.md#technical-plan-migration)
    Technical depth: [Packaging mechanics](M0-technical.md#technical-plan-packaging)
    Technical depth: [Proportional minimalism budget](M0-technical.md#technical-plan-minimalism)

    <a id="concept-plan-non-goals"></a>
    ### Non-Goals

    No public freeze.

    Technical depth: [Deferral acceptance points](M0-technical.md#technical-plan-prerequisites)
    <!-- loopex:plan-concept-envelope:end -->
    """
    |> String.trim_trailing("\n")
  end

  def technical_plan do
    """
    <a id="technical-depth"></a>
    ## Technical depth

    Concept: [Milestone concept](M0.md#concept)

    <!-- loopex:plan-technical-envelope:start -->
    ## Normative Technical Envelope

    <a id="technical-plan-prerequisites"></a>
    ### Prerequisites and Acceptance Points

    Concept: [Milestone scope](M0.md#concept-plan-scope)
    Concept: [Milestone non-goals](M0.md#concept-plan-non-goals)

    Prerequisites are accepted before plan acceptance.

    <a id="technical-plan-ownership"></a>
    ### Ownership, Decision Owners, and Rejoin Barriers

    Concept: [Milestone scope](M0.md#concept-plan-scope)

    The maintainer owns decisions; there is one serial rejoin.

    <a id="technical-plan-evidence"></a>
    ### Evidence Obligations and Mapping

    Concept: [Milestone outcomes](M0.md#concept-plan-outcomes)

    Outcome 1 maps to the named focused test.

    <a id="technical-plan-compatibility"></a>
    ### Compatibility

    Concept: [Milestone scope](M0.md#concept-plan-scope)

    No compatibility claim.

    <a id="technical-plan-migration"></a>
    ### Migration and Rollback

    Concept: [Milestone scope](M0.md#concept-plan-scope)

    Rollback removes the candidate.

    <a id="technical-plan-packaging"></a>
    ### Packaging

    Concept: [Milestone scope](M0.md#concept-plan-scope)

    No package or release.

    <a id="technical-plan-minimalism"></a>
    ### Proportional Minimalism Budget

    Concept: [Milestone scope](M0.md#concept-plan-scope)

    Use direct code; add no abstraction without two concrete examples.
    <!-- loopex:plan-technical-envelope:end -->
    """
  end

  def adr_technical(number) do
    concept_name = @adr_paths |> Enum.at(number - 1) |> String.replace_prefix("docs/adr/", "")

    """
    # 000#{number}. Decision #{number}: Technical depth

    <a id="technical-depth"></a>
    ## Technical depth

    Concept: [Decision](#{concept_name}#concept)

    Exact constraints for decision #{number}.
    """
  end

  def adr(number, accepted \\ false) do
    path = Enum.at(@adr_paths, number - 1)

    technical_name =
      path
      |> String.replace_prefix("docs/adr/", "")
      |> String.replace_suffix(".md", "-technical.md")

    proposal = """
    # 000#{number}. Decision #{number}

    <a id="concept"></a>
    ## Concept

    Technical depth: [Decision details](#{technical_name}#technical-depth)

    - **Status:** Proposed
    - **Date:** 2026-08-15
    - **Decision owner:** Maintainer

    ## Governance Record

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    | Acceptance | — | — | — |

    ## Context

    Concrete decision context for #{path}.

    ## Decision

    Choose the bounded decision.
    """

    case accepted do
      false ->
        proposal

      true ->
        candidate = String.duplicate(if(number == 1, do: "d", else: "e"), 40)
        concept_digest = String.duplicate(if(number == 1, do: "1d", else: "1e"), 32)
        technical_digest = String.duplicate(if(number == 1, do: "2d", else: "2e"), 32)

        proposal
        |> String.replace("- **Status:** Proposed", "- **Status:** Accepted")
        |> String.replace(
          "| Acceptance | — | — | — |",
          "| Acceptance | Maintainer | [disposition](../vision.md#concept) | " <>
            "candidate `#{candidate}`; concept `sha256:#{concept_digest}`; " <>
            "technical `sha256:#{technical_digest}` |"
        )
    end
  end

  @doc """
  ## Concept

  The fixture milestone plan's Concept document.

  ## Technical depth

  Carries the sections a plan document has -- the envelope, the workstreams, the
  progress table, and the governance rows -- because the documentation checks
  read its links and anchors. The governance rows are left empty: nothing
  validates their contents any more, and filling them in would suggest something
  does.
  """
  def plan do
    """
    #{plan_preamble()}
    #{envelope()}

    ## Workstreams

    One direct workstream.

    ## Progress and Evidence

    | # | State | Evidence |
    | --- | --- | --- |
    | 1 | Open | — |

    ## Governance Records

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    | Acceptance | — | — | — |
    | Closure | — | — | — |
    """
  end

  def documents do
    base = %{
      "README.md" => readme(),
      "docs/README.md" => """
      # Documentation

      [Root](../README.md)
      [Developer](developer/README.md)
      [Decisions](adr/README.md)
      [Plans](plans/README.md)
      [Vision](vision.md#concept)
      [Vision technical](vision-technical.md#technical-depth)
      [Roadmap](roadmap.md#concept)
      [Roadmap technical](roadmap-technical.md#technical-depth)
      [Development charter](developer/development-charter.md#concept)
      [Development charter technical](developer/development-charter-technical.md#technical-depth)
      [ADR 0001](adr/0001-repository-and-application-layout.md#concept)
      [ADR 0001 technical](adr/0001-repository-and-application-layout-technical.md#technical-depth)
      [ADR 0002](adr/0002-bootstrap-runtime-floor.md#concept)
      [ADR 0002 technical](adr/0002-bootstrap-runtime-floor-technical.md#technical-depth)
      """,
      "docs/plans/README.md" =>
        "# Plans\n\n[Documentation](../README.md)\n\n#{current()}\n\n#{register()}\n",
      "docs/adr/README.md" => "# Decisions\n\n[Documentation](../README.md)\n",
      "docs/developer/README.md" =>
        "# Developer documentation\n\n[Documentation](../README.md)\n",
      "docs/vision.md" =>
        "# Vision\n\n<a id=\"concept\"></a>\n## Concept\n\n" <>
          "Technical depth: [Vision details](vision-technical.md#technical-depth)\n",
      "docs/vision-technical.md" =>
        "# Vision: Technical depth\n\n<a id=\"technical-depth\"></a>\n" <>
          "## Technical depth\n\nConcept: [Vision](vision.md#concept)\n\n" <>
          "## 22. Ownership and serial barriers\n\n" <>
          "<!-- loopex:rejoin-source:start -->\n#{rejoin()}\n<!-- loopex:rejoin-source:end -->\n",
      "docs/roadmap.md" =>
        "# Roadmap\n\n<a id=\"concept\"></a>\n## Concept\n\n" <>
          "Technical depth: [Roadmap details](roadmap-technical.md#technical-depth)\n",
      "docs/roadmap-technical.md" =>
        "# Roadmap: Technical depth\n\n<a id=\"technical-depth\"></a>\n" <>
          "## Technical depth\n\nConcept: [Roadmap](roadmap.md#concept)\n\n" <>
          "## The Enduring Rejoin Order\n\n" <>
          "<!-- loopex:rejoin-copy:start -->\n#{rejoin()}\n<!-- loopex:rejoin-copy:end -->\n",
      "docs/developer/development-charter.md" =>
        "# Development charter\n\n<a id=\"concept\"></a>\n" <>
          "## Concept\n\nTechnical depth: [Charter mechanics]" <>
          "(development-charter-technical.md#technical-depth)\n",
      "docs/developer/development-charter-technical.md" =>
        "# Development charter: Technical depth\n\n" <>
          "<a id=\"technical-depth\"></a>\n## Technical depth\n\n" <>
          "Concept: [Development charter](development-charter.md#concept)\n",
      "docs/developer/agent-context-map.md" =>
        "# Context map\n\n[Product definition](../vision.md#concept)\n"
    }

    Enum.reduce(1..2, base, fn number, acc ->
      path = Enum.at(@adr_paths, number - 1)

      acc
      |> Map.put(path, adr(number))
      |> Map.put(String.replace_suffix(path, ".md", "-technical.md"), adr_technical(number))
    end)
  end

  @doc """
  ## Concept

  Runs the status checks over a fixture document set and returns the messages.

  ## Technical depth

  The checks read the document set and nothing else, so this is one call. It
  exists so a case names what it is doing rather than reaching for the module.
  """
  def checked(documents), do: Status.validate(documents)

  @doc """
  ## Concept

  The status capsule a Closed milestone derives.

  ## Technical depth

  Written by the transition that first recorded `Closed`, which is what the
  register's catch-all demands rather than permitting the check to be relaxed.
  Rewrites the four fields the Closed derivation changes, plus the phase, which
  `Register.integrated_phase/2` owns and which a `Closed` row moves off its
  planning value. The checkpoint is left alone because
  `Register.closed_product_checkpoint/2` owns that field and derives it from the
  milestone's identity and date rather than from the lifecycle state.
  """
  def closed_capsule(text) do
    text
    |> closed_phase_cell()
    |> String.replace(
      @blockers_cell,
      "| Blockers | None; `M0` is closed and its governance row is recorded |"
    )
    |> String.replace(
      "| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |",
      "| Authorized work | Explicitly authorized planning, ADR, and review work only; " <>
        "no product implementation until the next milestone is accepted |"
    )
    |> String.replace(
      "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
      "| Next maintainer decision | Open the next milestone, or defer it |"
    )
    |> String.replace(
      "| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |",
      "| Next transition | Write the next milestone's plan pair and move it to Open |"
    )
  end

  @doc """
  ## Concept

  The fixture plans index rewritten into its derived Open capsule.

  ## Technical depth

  Rewrites exactly the three fields the Open derivation changes, so a test that
  opens a milestone does not silently also change the authorised-work boundary.
  """
  def open_capsule(text) do
    text
    |> String.replace(
      @blockers_cell,
      "| Blockers | `M0` is open and not accepted; the maintainer must accept " <>
        "its plan pair |"
    )
    |> String.replace(
      "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
      "| Next maintainer decision | Accept or reject the `M0` plan pair |"
    )
    |> String.replace(
      "| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |",
      "| Next transition | Record the acceptance governance row and move `M0` to Accepted |"
    )
  end

  @doc """
  ## Concept

  A fixture document set with the named bootstrap ADRs accepted and the derived
  blocked capsule updated to match.

  ## Technical depth

  The capsule text is a function of which ADRs remain unresolved, so accepting one
  or both must rewrite it. That coupling is the point of the fixture: it proves the
  capsule is derived from the ADR records rather than transcribed.
  """
  def accepted_adr_documents(accepted) do
    documents =
      Enum.reduce(accepted, documents(), fn number, acc ->
        Map.put(acc, Enum.at(@adr_paths, number - 1), adr(number, true))
      end)

    unresolved = Enum.reject([1, 2], &(&1 in accepted))
    index = Map.fetch!(documents, "docs/plans/README.md")

    updated =
      case unresolved do
        [number] ->
          filename =
            @adr_paths |> Enum.at(number - 1) |> String.replace_prefix("docs/adr/", "")

          index
          |> String.replace(
            @blockers_text,
            "[ADR 000#{number}](../adr/#{filename}#concept) must be accepted before M0 opens; " <>
              "a replacement requires a governed guard change"
          )
          |> String.replace(
            "Disposition ADR 0001 and ADR 0002",
            "Disposition ADR 000#{number}"
          )

        [] ->
          index
          |> String.replace(@blockers_text, "M0 has not been explicitly opened gate-first")
          |> String.replace("Disposition ADR 0001 and ADR 0002", "Explicitly open or defer M0")
          |> String.replace(
            "After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first",
            "Create the branch-only M0 Concept plan, Technical depth plan, and red gate; " <>
              "install lifecycle-specific status checks; and move M0 to Open"
          )

        _both ->
          index
      end

    Map.put(documents, "docs/plans/README.md", updated)
  end
end
