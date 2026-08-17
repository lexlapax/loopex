defmodule Loopex.StatusFixtures do
  @moduledoc """
  ## Concept

  Compact in-memory document sets for the status checks. A fixture repository is
  the smallest set of documents that passes every check, so a test states one
  mutation and asserts it fails — which keeps each case about one property rather
  than about assembling a valid repository.

  Nothing here touches the checkout. The checks take documents, a revision
  resolver, and a history reader as data, so the adversarial cases can build
  histories, merges, and candidate revisions that no real repository would
  contain.

  ## Technical depth

  Every fixture is exact text, because the checks compare bytes. Digests are
  computed from the fixtures themselves rather than pasted, so a fixture edit does
  not silently turn a governance test into a digest-mismatch test.

  The resolver recognises a small set of synthetic revision names: `a`, `b`, and
  `c` repeated forty times stand for the acceptance candidate, an alternate
  candidate, and the closure candidate; `d` and `e` stand for the two ADR
  candidates. Those are the shapes the bound-bytes grammar accepts, so the
  fixtures exercise the real parser rather than a relaxed one.
  """

  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Status

  @summary "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `M0` is blocked."

  @open_summary "**Revision status:** Pre-implementation planning; active milestone `M0` is open; no next candidate is recorded."

  @closed_summary "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded."

  @gate "# Gate\n"

  @gate_separators [
    "\r\n",
    "\r",
    "\v",
    "\f",
    "\x1C",
    "\x1D",
    "\x1E",
    "\u0085",
    "\u2028",
    "\u2029"
  ]

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
  def gate, do: @gate
  def gate_separators, do: @gate_separators
  def adr_paths, do: @adr_paths
  def blocked_row, do: @blocked_row
  def blockers_text, do: @blockers_text

  def concept_marker_start, do: "<!-- loopex:plan-concept-envelope:start -->"
  def concept_marker_end, do: "<!-- loopex:plan-concept-envelope:end -->"
  def technical_marker_start, do: "<!-- loopex:plan-technical-envelope:start -->"
  def technical_marker_end, do: "<!-- loopex:plan-technical-envelope:end -->"

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
    | Integrated phase | Pre-implementation planning |
    | Last integrated checkpoint | Seed bootstrap — 2026-08-15 |
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
        concept_digest = Markdown.digest(proposal)
        technical_digest = Markdown.digest(adr_technical(number))

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

  def envelope_digest(text, start, stop) do
    lines = String.split(text, "\n")
    from = Enum.find_index(lines, &(&1 == start))
    to = Enum.find_index(lines, &(&1 == stop))
    Markdown.digest(Enum.join(Enum.slice(lines, (from + 1)..(to - 1)//1), "\n"))
  end

  def plan(options \\ []) do
    governed = Keyword.get(options, :governed, false)
    closed = Keyword.get(options, :closed, false)
    gate_text = Keyword.get(options, :gate, @gate)
    progress = Keyword.get(options, :progress) || if(closed, do: "Proved", else: "Open")

    empty = "— | — | —"
    concept_digest = envelope_digest(envelope(), concept_marker_start(), concept_marker_end())

    technical_digest =
      envelope_digest(technical_plan(), technical_marker_start(), technical_marker_end())

    gate_digest = Markdown.digest(gate_text)

    bound = fn candidate ->
      "candidate `#{String.duplicate(candidate, 40)}`; " <>
        "concept `sha256:#{concept_digest}`; " <>
        "technical `sha256:#{technical_digest}`; gate `sha256:#{gate_digest}`"
    end

    acceptance =
      case governed do
        true -> "Maintainer | [disposition](../vision.md#concept) | #{bound.("a")}"
        false -> empty
      end

    closure =
      case closed do
        true -> "Maintainer | [disposition](../roadmap.md#concept) | #{bound.("c")}"
        false -> empty
      end

    plan_text(acceptance, closure, progress)
  end

  defp plan_text(acceptance, closure, progress_state) do
    """
    #{plan_preamble()}
    #{envelope()}

    ## Workstreams

    One direct workstream.

    ## Progress and Evidence

    | # | State | Evidence |
    | --- | --- | --- |
    | 1 | #{progress_state} | — |

    ## Governance Records

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    | Acceptance | #{acceptance} |
    | Closure | #{closure} |
    """
  end

  def plan_snapshot(concept, gate_text \\ nil, technical \\ nil) do
    base = %{
      "docs/plans/M0.md" => concept,
      "docs/plans/M0-technical.md" => technical || technical_plan()
    }

    case gate_text do
      nil -> base
      found -> Map.put(base, "docs/plans/M0-gate.md", found)
    end
  end

  def adr_snapshot(number, concept) do
    path = Enum.at(@adr_paths, number - 1)

    %{
      path => concept,
      String.replace_suffix(path, ".md", "-technical.md") => adr_technical(number)
    }
  end

  @doc """
  ## Concept

  The fixture resolver: what a synthetic revision contains.

  ## Technical depth

  Only the revision names the fixtures use resolve; everything else is
  unavailable, which is how a test asserts that an unresolvable candidate fails
  rather than passing silently.
  """
  def resolve(historical_gate \\ @gate) do
    fn sha, path ->
      candidates = [
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        String.duplicate("c", 40)
      ]

      cond do
        String.ends_with?(path, "M0-gate.md") and sha in candidates ->
          historical_gate

        String.ends_with?(path, "M0-technical.md") and sha in candidates ->
          technical_plan()

        String.ends_with?(path, "M0.md") and sha in Enum.take(candidates, 2) ->
          plan()

        String.ends_with?(path, "M0.md") and sha == String.duplicate("c", 40) ->
          plan(governed: true, progress: "Proved")

        path == Enum.at(@adr_paths, 0) and sha == String.duplicate("d", 40) ->
          adr(1)

        path == String.replace_suffix(Enum.at(@adr_paths, 0), ".md", "-technical.md") and
            sha == String.duplicate("d", 40) ->
          adr_technical(1)

        path == Enum.at(@adr_paths, 1) and sha == String.duplicate("e", 40) ->
          adr(2)

        path == String.replace_suffix(Enum.at(@adr_paths, 1), ".md", "-technical.md") and
            sha == String.duplicate("e", 40) ->
          adr_technical(2)

        true ->
          nil
      end
    end
  end

  @doc """
  ## Concept

  Runs the status checks over a fixture document set and returns the messages.

  ## Technical depth

  A single-parent history is synthesised from the supplied revisions, rooted at a
  synthetic empty commit, so every case exercises the real history walk rather
  than the unavailable-history path.
  """
  def checked(documents, options \\ []) do
    historical_gate = Keyword.get(options, :historical_gate, @gate)
    plan_history = Keyword.get(options, :plan_history, [])
    read_artifact = Keyword.get(options, :read_artifact)

    {snapshots, head} =
      Enum.reduce(plan_history, {[{"fixture-root", [], %{}}], "fixture-root"}, fn {revision,
                                                                                   plans},
                                                                                  {acc, parent} ->
        {acc ++ [{revision, [parent], plans}], revision}
      end)

    Status.validate(documents,
      resolve_file: resolve(historical_gate),
      plan_history: fn -> {head, snapshots} end,
      read_artifact: read_artifact
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
      "| Blockers | `M0` is open and not accepted; the recorded acceptance " <>
        "authority must accept both normative envelopes and the gate |"
    )
    |> String.replace(
      "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
      "| Next maintainer decision | Accept or reject the `M0` plan pair and gate |"
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

  @doc """
  ## Concept

  A fixture document set with `M0` registered as Open and its plan triple present.

  ## Technical depth

  Used by every bound-artifact case, because a gate is only reachable once the
  milestone is registered with links, and the derived summary and capsule must
  move with it.
  """
  def open_milestone_documents(gate_text) do
    documents()
    |> Map.update!("docs/plans/README.md", fn text ->
      text
      |> String.replace(
        @blocked_row,
        "| `M0` | Open | [concept](M0.md) | " <>
          "[technical depth](M0-technical.md) | [gate](M0-gate.md) |"
      )
      |> String.replace(@summary, @open_summary)
      |> open_capsule()
    end)
    |> Map.update!("README.md", &String.replace(&1, @summary, @open_summary))
    |> Map.put("docs/plans/M0.md", plan())
    |> Map.put("docs/plans/M0-technical.md", technical_plan())
    |> Map.put("docs/plans/M0-gate.md", gate_text)
  end
end
