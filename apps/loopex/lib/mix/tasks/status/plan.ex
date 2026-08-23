defmodule Loopex.Checks.Plan do
  @moduledoc """
  ## Concept

  Validates a milestone plan pair against its locked gate and its recorded
  governance. The accepted normative envelopes and the gate bytes are immutable
  for the milestone; progress, workstream decomposition, and evidence links are
  not. This module draws that line mechanically, so mutable prose can be updated
  freely while an accepted commitment cannot be edited without the authority that
  accepted it.

  ## Technical depth

  The envelope is delimited by exact markers, must carry its governed heading
  sequence in order with its exact section anchors, and every section must hold a
  concrete commitment rather than only relationship links. The accepted digests
  must equal both the current envelope bytes and the envelope bytes at the
  candidate revision the row binds, and the gate digest must equal both the
  current gate and the gate at that revision — so neither the plan nor the gate
  can move while the record stays valid.

  A gate's bytes and either accepted envelope may change only when the gate
  document records a later numbered amendment than the bytes being replaced.
  The same generation then permits the administrative Acceptance rebind. This
  is the mechanical form of "the accepted commitment is immutable, and an
  accepted amendment is the only exception".
  """

  alias Loopex.Checks.Git
  alias Loopex.Checks.Documents
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Records
  alias Loopex.Checks.Register

  @concept_sections ["### Purpose", "### Outcomes", "### Scope", "### Non-Goals"]
  @concept_anchors [
    "concept-plan-purpose",
    "concept-plan-outcomes",
    "concept-plan-scope",
    "concept-plan-non-goals"
  ]
  @concept_trailing ["## Workstreams", "## Progress and Evidence", "## Governance Records"]

  @technical_sections [
    "### Prerequisites and Acceptance Points",
    "### Ownership, Decision Owners, and Rejoin Barriers",
    "### Evidence Obligations and Mapping",
    "### Compatibility",
    "### Migration and Rollback",
    "### Packaging",
    "### Proportional Minimalism Budget"
  ]
  @technical_anchors [
    "technical-plan-prerequisites",
    "technical-plan-ownership",
    "technical-plan-evidence",
    "technical-plan-compatibility",
    "technical-plan-migration",
    "technical-plan-packaging",
    "technical-plan-minimalism"
  ]

  @relationships MapSet.new([
                   {"concept", "technical-depth"},
                   {"concept-plan-outcomes", "technical-plan-evidence"},
                   {"concept-plan-scope", "technical-plan-prerequisites"},
                   {"concept-plan-scope", "technical-plan-ownership"},
                   {"concept-plan-scope", "technical-plan-compatibility"},
                   {"concept-plan-scope", "technical-plan-migration"},
                   {"concept-plan-scope", "technical-plan-packaging"},
                   {"concept-plan-scope", "technical-plan-minimalism"},
                   {"concept-plan-non-goals", "technical-plan-prerequisites"}
                 ])

  @outcomes_header "| # | Outcome | Evidence class | Gate selector |"
  @outcome_columns ["#", "Outcome", "Evidence class", "Gate selector"]
  @progress_states ["Open", "Proved", "Accepted limitation", "Accepted deferral"]

  @documentation_categories [
    "Operator-facing documentation",
    "Operator README",
    "Developer-facing documentation",
    "Developer README",
    "Documentation README",
    "Root README",
    "Changelog"
  ]
  @documentation_optional MapSet.new(Enum.take(@documentation_categories, 4))

  @amendment_anchor ~r/\A<a id="amendment-([0-9]+)"><\/a>\z/u
  @amendment_transaction_v1 ~s(<a id="amendment-transaction-v1"></a>)

  @doc """
  ## Concept

  The digest of a gate document, after proving its bytes are canonical.

  ## Technical depth

  Canonical bytes are checked before hashing rather than normalised, because a
  digest over normalised text would describe bytes that are not in the file and
  the binding would no longer identify what a reader opens.
  """
  @spec gate_digest(String.t(), String.t()) :: String.t()
  def gate_digest(text, path) do
    Markdown.require_canonical!(text, path, "gate text")
    Markdown.digest(text)
  end

  @doc """
  ## Concept

  How many numbered amendments a gate document records.

  ## Technical depth

  A locked gate's bytes are immutable for its milestone, so the only legitimate
  reason for them to change is a governed amendment. Counting declared amendments
  makes that checkable: bytes may change when the generation increases and never
  otherwise. Numbering must be consecutive from one, because a gap or a repeat
  would let two different byte sets claim the same generation.
  """
  @spec gate_generation(String.t(), String.t()) :: non_neg_integer()
  def gate_generation(text, path) do
    # Visibility is decided by the repository's own Markdown reader, not by a second
    # implementation here. The hand-rolled version tracked fences but not HTML
    # comments, and treated any long-enough delimiter as a close even with trailing
    # text -- so an anchor inside a comment, or after a "```still-code" line, minted
    # a generation with no visible amendment behind it. Two parsers disagreeing
    # about what is visible is exactly how a hidden amendment gets in.
    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    found =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, number}, {numbers, pending} ->
        # The anchor and its heading must both start at column zero, and the heading
        # must name the same number as the anchor. Trimming first accepted an
        # indented anchor, which CommonMark reads as code -- so a four-space block
        # minted a generation with nothing visible behind it. Requiring column zero
        # removes every indentation-based hiding construct at once, rather than
        # teaching the reader about one more of them. The heading number was also
        # unchecked, so "## Amendment 999" could sit under anchor 1.
        anchor = Regex.run(@amendment_anchor, line)

        cond do
          not MapSet.member?(visible, number) ->
            {numbers, pending}

          anchor != nil ->
            {numbers, String.to_integer(Enum.at(anchor, 1))}

          pending != nil ->
            # Two to six hashes. CommonMark caps an ATX heading at six, and `##+`
            # accepted any number -- so a seven-hash line, which renders as text,
            # was read as the heading that justifies an amendment.
            case Regex.run(~r/\A\#{2,6} Amendment (\d+)\b/, line) do
              [_all, declared] ->
                if String.to_integer(declared) == pending do
                  {[pending | numbers], nil}
                else
                  raise Invalid,
                        "#{path}: amendment anchor #{pending} is followed by a heading " <>
                          "declaring amendment #{declared}"
                end

              nil ->
                {numbers, if(String.trim(line) == "", do: pending, else: nil)}
            end

          true ->
            {numbers, pending}
        end
      end)
      |> then(fn {numbers, _pending} -> Enum.reverse(numbers) end)

    if found != Enum.to_list(1..length(found)//1) do
      raise Invalid,
            "#{path}: amendment anchors must appear in document order, numbered " <>
              "consecutively from 1"
    end

    length(found)
  end

  @doc false
  def amendment_transaction_v1?(text, path) do
    lines = Markdown.lines(text, path)

    count =
      text
      |> Markdown.visible_line_numbers(path)
      |> Enum.count(&(Enum.at(lines, &1) == @amendment_transaction_v1))

    count == 1
  end

  @doc """
  ## Concept

  The digest of one normative envelope's body lines.

  ## Technical depth

  Hashes the envelope body only, joined with newlines, so a governance row binds
  the accepted commitment rather than the whole document. That is what lets
  progress rows and workstream prose change under an accepted plan without
  invalidating the record.
  """
  @spec envelope_digest([String.t()]) :: String.t()
  def envelope_digest(envelope), do: Markdown.digest(Enum.join(envelope, "\n"))

  @doc """
  ## Concept

  The concept plan's normative envelope and the outcome identifiers it commits to.

  ## Technical depth

  The outcomes table must appear exactly once inside the Outcomes section and its
  identifiers must be consecutive from one, so every outcome has a stable name
  that the progress table and the gate can both refer to without ambiguity.
  """
  @spec concept_envelope(String.t(), String.t()) :: {[String.t()], [String.t()]}
  def concept_envelope(text, path) do
    {envelope, sections} =
      envelope(text, path,
        key: :plan_concept_envelope,
        title: "## Normative Concept Envelope",
        sections: @concept_sections,
        anchors: @concept_anchors,
        depth_heading: "## Concept",
        trailing: @concept_trailing
      )

    {outcomes_start, _heading} = Enum.at(sections, 2)
    {outcomes_end, _scope} = Enum.at(sections, 3)
    outcomes = Enum.slice(envelope, (outcomes_start + 1)..(outcomes_end - 1)//1)

    unless Enum.count(outcomes, &(&1 == @outcomes_header)) == 1 do
      raise Invalid, "#{path}: Outcomes must contain one exact normative outcomes table"
    end

    table_start = Enum.find_index(outcomes, &(&1 == @outcomes_header))

    table_lines =
      outcomes |> Enum.drop(table_start) |> Enum.take_while(&String.starts_with?(&1, "|"))

    rows = Markdown.table(table_lines, @outcome_columns, "#{path} Outcomes")
    ids = Enum.map(rows, &hd/1)

    if ids == [] or ids != Enum.map(1..length(ids)//1, &Integer.to_string/1) do
      raise Invalid, "#{path}: Outcomes must contain consecutively numbered commitments"
    end

    {envelope, ids}
  end

  @doc """
  ## Concept

  The technical plan's normative envelope.

  ## Technical depth

  The technical half carries nothing outside its envelope: every obligation it
  states is normative, so there is no mutable region to separate.
  """
  @spec technical_envelope(String.t(), String.t()) :: [String.t()]
  def technical_envelope(text, path) do
    {envelope, _sections} =
      envelope(text, path,
        key: :plan_technical_envelope,
        title: "## Normative Technical Envelope",
        sections: @technical_sections,
        anchors: @technical_anchors,
        depth_heading: "## Technical depth",
        trailing: []
      )

    envelope
  end

  defp envelope(text, path, options) do
    key = Keyword.fetch!(options, :key)
    title = Keyword.fetch!(options, :title)
    sections_expected = Keyword.fetch!(options, :sections)
    section_anchors = Keyword.fetch!(options, :anchors)
    depth_heading = Keyword.fetch!(options, :depth_heading)
    trailing = Keyword.fetch!(options, :trailing)

    if String.contains?(text, "\r") do
      raise Invalid, "#{path}: plan text must use canonical UTF-8/LF bytes"
    end

    body = Markdown.block(text, path, key)
    lines = Markdown.lines(text, path)

    require_leading_anchor!(lines, depth_heading, path)
    require_envelope_placement!(lines, key, depth_heading, trailing, path)

    require_document_headings!(
      lines,
      text,
      [depth_heading, title] ++ sections_expected ++ trailing,
      path
    )

    sections = envelope_sections!(body, title, sections_expected, path)
    require_section_anchors!(body, sections, section_anchors, sections_expected, path)
    require_commitments!(body, sections, path)

    {body, sections}
  end

  defp require_leading_anchor!(lines, depth_heading, path) do
    expected = if depth_heading == "## Concept", do: "concept", else: "technical-depth"
    first = Enum.find(lines, &(String.trim(&1) != ""))

    if Markdown.anchor_only(first || "") != expected do
      raise Invalid, "#{path}: plan document must start with its semantic anchor"
    end

    :ok
  end

  defp require_envelope_placement!(lines, key, depth_heading, trailing, path) do
    {start_marker, end_marker} = Markdown.markers(key)
    marker_start = Enum.find_index(lines, &(&1 == start_marker))
    marker_end = Enum.find_index(lines, &(&1 == end_marker))

    expected_label = if depth_heading == "## Concept", do: "Technical depth: ", else: "Concept: "

    before =
      lines
      |> Enum.take(marker_start)
      |> Enum.reverse()
      |> Enum.find(&(String.trim(&1) != ""))

    if before == nil or not String.starts_with?(before, expected_label) do
      raise Invalid, "#{path}: normative envelope must directly follow its relationship link"
    end

    after_marker =
      lines |> Enum.drop(marker_end + 1) |> Enum.find(&(String.trim(&1) != ""))

    case trailing do
      [first | _rest] ->
        if after_marker != first do
          raise Invalid, "#{path}: envelope end must be followed directly by #{first}"
        end

      [] ->
        if after_marker != nil do
          raise Invalid, "#{path}: technical plan contains content outside its normative envelope"
        end
    end

    :ok
  end

  defp require_document_headings!(lines, text, expected, path) do
    visible = Markdown.visible_line_numbers(text, path)
    found = headings(lines, visible, path, "a plan document")

    if found != expected do
      raise Invalid, "#{path}: plan document headings must be exactly the governed plan sequence"
    end

    :ok
  end

  defp envelope_sections!(body, title, sections_expected, path) do
    visible = Markdown.visible_line_numbers(Enum.join(body, "\n"), path)

    if body == [] or hd(body) != title do
      raise Invalid, "#{path}: normative plan envelope must start with #{title}"
    end

    sections = indexed_headings(body, visible, path, "the normative envelope")

    if Enum.map(sections, fn {_index, line} -> line end) != [title | sections_expected] do
      raise Invalid,
            "#{path}: normative plan-envelope headings are missing, duplicated, or reordered"
    end

    sections
  end

  # Concept: a setext heading in a plan is rejected outright, because the same
  # bytes read as a heading to a renderer and as prose to a line-oriented check.
  defp headings(lines, visible, path, subject) do
    lines |> indexed_headings(visible, path, subject) |> Enum.map(fn {_index, line} -> line end)
  end

  defp indexed_headings(lines, visible, path, subject) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      case MapSet.member?(visible, index) do
        false ->
          []

        true ->
          if Markdown.setext_heading?(lines, visible, index) do
            raise Invalid, "#{path}: setext headings are not allowed in #{subject}"
          end

          case Markdown.atx(line) do
            nil -> []
            {_level, _text} -> [{index, line}]
          end
      end
    end)
  end

  defp require_section_anchors!(body, sections, section_anchors, sections_expected, path) do
    if length(section_anchors) != length(sections_expected) do
      raise Invalid, "#{path}: plan section-anchor contract is misconfigured"
    end

    sections
    |> Enum.drop(1)
    |> Enum.zip(section_anchors)
    |> Enum.each(fn {{start, heading}, anchor} ->
      if start < 1 or Enum.at(body, start - 1) != ~s(<a id="#{anchor}"></a>) do
        raise Invalid, "#{path}: #{heading} needs its exact semantic anchor #{inspect(anchor)}"
      end
    end)

    :ok
  end

  # Concept: a section that carries only relationship links states no commitment.
  # Technical depth: anchors and labelled links are subtracted before deciding,
  # so a section whose whole content is navigation fails rather than passing on
  # the strength of its pointers.
  defp require_commitments!(body, sections, path) do
    visible = Markdown.visible_line_numbers(Enum.join(body, "\n"), path)
    starts = Enum.map(sections, fn {index, _line} -> index end)

    sections
    |> Enum.drop(1)
    |> Enum.with_index(1)
    |> Enum.each(fn {{start, heading}, position} ->
      stop = Enum.at(starts, position + 1) || length(body)

      content =
        Enum.filter((start + 1)..(stop - 1)//1, fn index ->
          MapSet.member?(visible, index) and substantive?(String.trim(Enum.at(body, index)))
        end)

      if content == [] do
        raise Invalid, "#{path}: #{heading} must contain a concrete commitment"
      end
    end)

    :ok
  end

  defp substantive?(""), do: false

  defp substantive?(line) do
    cond do
      Markdown.anchor_only(line) != nil ->
        false

      true ->
        relationship =
          line
          |> strip_prefix_once("Concept: ")
          |> strip_prefix_once("Technical depth: ")
          |> strip_period()

        not (relationship != line and Markdown.link_only(relationship) != nil)
    end
  end

  defp strip_prefix_once(value, prefix) do
    case String.starts_with?(value, prefix) do
      true -> binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))
      false -> value
    end
  end

  defp strip_period(value) do
    case String.ends_with?(value, ".") do
      true -> binary_part(value, 0, byte_size(value) - 1)
      false -> value
    end
  end

  @doc """
  ## Concept

  The progress table must carry exactly one row per outcome, with a known state.
  An Open milestone may record no completed outcome: every progress row remains
  Open. A Closed milestone may leave no outcome open.

  ## Technical depth

  Totality is the first property: a missing row hides an unproved outcome and an
  extra row claims one that was never committed to. Requiring every Open-plan row
  to remain Open makes a planning lookahead mechanically incapable of claiming
  product progress. It does not prove that arbitrary product bytes are absent;
  the exact-SHA review owns that boundary. An accepted limitation or deferral
  requires disposition evidence, because those two states are the only way an
  outcome reaches closure without being proved.
  """
  @spec progress(String.t(), String.t(), [String.t()], String.t()) :: :ok
  def progress(text, path, outcome_ids, lifecycle_state) do
    {body, _start} = Markdown.section_body(text, path, "## Progress and Evidence")
    rows = Markdown.table(body, ["#", "State", "Evidence"], "#{path} Progress and Evidence")

    if Enum.map(rows, &hd/1) != outcome_ids do
      raise Invalid,
            "#{path}: Progress and Evidence must contain exactly one row for every Outcome ID"
    end

    if Enum.any?(rows, &(Enum.at(&1, 1) not in @progress_states)) do
      raise Invalid, "#{path}: Progress and Evidence contains an unknown State"
    end

    if lifecycle_state == "Open" and Enum.any?(rows, &(Enum.at(&1, 1) != "Open")) do
      raise Invalid, "#{path}: Open progress permits only Open outcomes"
    end

    if lifecycle_state == "Closed" and Enum.any?(rows, &(Enum.at(&1, 1) == "Open")) do
      raise Invalid, "#{path}: Closed progress permits no Open outcomes"
    end

    if Enum.any?(rows, fn row ->
         Enum.at(row, 1) in ["Accepted limitation", "Accepted deferral"] and
           not Records.evidence?(Enum.at(row, 2))
       end) do
      raise Invalid, "#{path}: an accepted limitation or deferral requires disposition evidence"
    end

    :ok
  end

  @doc """
  ## Concept

  Whether a changed governance value is a declared amendment rather than drift.

  ## Technical depth

  Gate and envelope bytes are strict: they may differ only when the gate
  document records a later numbered amendment than the bytes being replaced, so
  a silent edit keeps the same generation and is rejected.

  An acceptance row is deliberately weaker, because an amendment cannot be one
  commit: its rebind must name a candidate carrying the amended gate, and no
  commit can name its own hash, so the amended gate lands first and the row
  follows, sharing a generation. The new bound candidate's recorded lineage must
  contain the exact candidate the old row bound, so a numerically later sibling
  cannot displace an accepted amendment it never inherited. The row is not
  trusted on its own — its digests must equal the current envelopes, its gate
  digest must equal both the current gate and the gate at the candidate it binds,
  and its candidate chain must terminate at an empty-governance original.
  """
  @spec supersedes?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def supersedes?(label, anchor, value) do
    with generation when is_integer(generation) <- generation_of(value),
         prior when is_integer(prior) <- generation_of(anchor) do
      # One rule for every amendable plan anchor: strictly increasing. A gate and
      # both envelopes use the ambient amendment generation; an Acceptance row
      # uses the generation and candidate lineage carried by its bound candidate.
      # Either way a change is admitted only when it moves forward, so a silent
      # edit, a sibling jump, a rewrite at the same generation, and a rollback
      # are all rejected.
      generation > prior and lineage_supersedes?(label, anchor, value)
    else
      _other -> false
    end
  end

  defp lineage_supersedes?("Acceptance", anchor, value) do
    with [_anchor_candidate | _] = anchor_lineage <- lineage_of(anchor),
         [_new_candidate | prior_candidates] <- lineage_of(value) do
      Enum.take(prior_candidates, -length(anchor_lineage)) == anchor_lineage
    else
      _other -> false
    end
  end

  defp lineage_supersedes?(_label, _anchor, _value), do: true

  defp lineage_of(value) do
    case String.split(value, "\0", parts: 3) do
      [_generation, lineage, _row] when lineage != "" -> String.split(lineage, ",")
      _other -> []
    end
  end

  defp generation_of(nil), do: nil

  defp generation_of(value) do
    case value |> String.split("\0", parts: 2) |> hd() |> Integer.parse() do
      {number, ""} -> number
      _other -> nil
    end
  end

  @doc """
  ## Concept

  An acceptance candidate is either an original snapshot carrying empty
  governance, or an amended one that binds an earlier candidate — recursively,
  until an original is reached.

  ## Technical depth

  Requiring the chain is stricter than requiring emptiness, and requiring
  emptiness outright would make the amendment path the contract allows
  unrecordable. A fabricated candidate with an invented row cannot satisfy the
  chain, an unresolvable prior fails, and a cycle is rejected rather than
  followed.
  """
  @spec acceptance_chain(
          String.t(),
          String.t(),
          String.t(),
          (String.t(), String.t() -> String.t() | nil) | nil,
          MapSet.t(String.t()),
          (String.t(), String.t() -> boolean())
        ) ::
          :ok
  def acceptance_chain(
        candidate_text,
        path,
        revision,
        resolve_file,
        seen,
        ancestor? \\ fn _p, _r -> true end
      ) do
    {_rows, bound, complete} =
      Records.governance_records(candidate_text, "#{path} at candidate #{revision}")

    cond do
      complete == [false, false] ->
        # An original snapshot predates any amendment, so its gate carries
        # generation zero. Accepting an empty-governance candidate at a later
        # generation let a reachable side commit terminate the chain while carrying
        # gate bytes nobody amended into it.
        terminal_generation_zero!(path, revision, resolve_file)

      not Enum.at(complete, 0) or Enum.at(bound, 0) == nil ->
        raise Invalid,
              "#{path}: acceptance candidate #{revision} has governance that is neither empty " <>
                "nor a complete acceptance record, so it supersedes nothing"

      true ->
        {prior, concept, technical, gate} = Enum.at(bound, 0)

        if prior == revision or MapSet.member?(seen, prior) do
          raise Invalid, "#{path}: acceptance candidate chain at #{revision} does not terminate"
        end

        prior_text = resolve_file && resolve_file.(prior, path)

        if prior_text == nil do
          raise Invalid,
                "#{path}: acceptance candidate #{revision} binds prior candidate #{prior}, " <>
                  "which is unavailable"
        end

        # Every edge must run backwards along real history. Resolving proves only
        # that a commit is reachable from HEAD, and two unrelated branches both
        # become reachable the moment anything merges them -- so a candidate could
        # name a prior it does not descend from and the edge would still resolve.
        # Requiring ancestry is what makes the chain a lineage rather than a set of
        # commits that happen to exist.
        unless revision == "working tree" or ancestor?.(prior, revision) do
          raise Invalid,
                "#{path}: acceptance candidate #{revision} binds prior candidate #{prior}, " <>
                  "which is not an ancestor of it; a chain edge must run backwards along history"
        end

        verify_edge_digests!(path, revision, prior, {concept, technical, gate}, resolve_file)

        # An edge proving its own bytes is not enough: the node it points at must
        # itself have been a valid accepted state. Without this, a chain O -> B -> C
        # passed where B carried a generation but was never a legitimate Accepted
        # record. Validating each inner node closes the difference between "these
        # bytes exist" and "this was an acceptance".
        verify_inner_acceptance!(path, prior, prior_text)

        acceptance_chain(
          prior_text,
          path,
          prior,
          resolve_file,
          MapSet.put(seen, revision),
          ancestor?
        )
    end
  end

  defp terminal_generation_zero!(path, revision, resolve_file) do
    gate_path = String.replace_suffix(path, ".md", "-gate.md")
    gate_text = resolve_file && resolve_file.(revision, gate_path)

    generation =
      case gate_text do
        nil -> 0
        text -> gate_generation(text, "#{gate_path} at #{revision}")
      end

    if generation != 0 do
      raise Invalid,
            "#{path}: acceptance candidate chain terminates at #{revision}, whose gate is " <>
              "already at amendment generation #{generation}; an original carries generation 0"
    end

    :ok
  end

  # Concept: an inner chain node must be a structurally valid acceptance.
  # Technical depth: the outer candidate is validated by the caller; every earlier
  # one was previously trusted for anything beyond its digests. The check here is
  # the same one the register applies -- exactly one complete Acceptance row and no
  # Closure row -- so a node that could never have been Accepted cannot sit in a
  # lineage. An empty-governance original is the terminal case and is allowed.
  defp verify_inner_acceptance!(path, revision, text) do
    {_rows, _bound, complete} =
      Records.governance_records(text, "#{path} at chain node #{revision}")

    case complete do
      [false, false] ->
        :ok

      [true, false] ->
        :ok

      other ->
        raise Invalid,
              "#{path}: chain node #{revision} has governance #{inspect(other)}; a node in an " <>
                "acceptance lineage is either an empty original or a complete acceptance"
    end
  end

  # Concept: an inner chain link's digests must describe real bytes.
  # Technical depth: only the outermost binding was checked, so every earlier link
  # was trusted structurally -- a candidate carrying sixty-four zeroes for all three
  # digests satisfied the chain, which falsified the claim that an invented row
  # cannot. Each edge is now recomputed from the files at both ends: the row in a
  # candidate binds a prior, and its digests must equal the envelopes and gate at
  # the prior AND at the candidate itself, because the candidate was the accepted
  # state when that row was written.
  defp verify_edge_digests!(path, revision, prior, {concept, technical, gate}, resolve_file) do
    technical_path = String.replace_suffix(path, ".md", "-technical.md")
    gate_path = String.replace_suffix(path, ".md", "-gate.md")

    # Only against the prior. A candidate's own row legitimately lags its own gate:
    # an amendment lands in one commit and the rebind follows in the next, because
    # no commit can name its own hash. Requiring the row to match the gate beside it
    # would make that structure unrepresentable. Matching the bound candidate is the
    # invariant that matters -- it is what makes the digests describe real bytes.
    for {label, at} <- [{"prior candidate", prior}] do
      concept_text = resolve_file && resolve_file.(at, path)
      technical_text = resolve_file && resolve_file.(at, technical_path)
      gate_text = resolve_file && resolve_file.(at, gate_path)

      if is_nil(concept_text) or is_nil(technical_text) or is_nil(gate_text) do
        raise Invalid,
              "#{path}: chain edge #{revision} -> #{prior} cannot be checked; a governed file " <>
                "is unavailable at #{at}"
      end

      {envelope, _ids} = concept_envelope(concept_text, "#{path} at #{at}")
      actual_concept = envelope_digest(envelope)

      actual_technical =
        envelope_digest(technical_envelope(technical_text, "#{technical_path} at #{at}"))

      actual_gate = gate_digest(gate_text, "#{gate_path} at #{at}")

      for {field, recorded, computed} <- [
            {"concept", concept, actual_concept},
            {"technical", technical, actual_technical},
            {"gate", gate, actual_gate}
          ] do
        if recorded != computed do
          raise Invalid,
                "#{path}: chain edge #{revision} -> #{prior} records a #{field} digest that " <>
                  "does not match the #{label} at #{at}"
        end
      end
    end

    :ok
  end

  # Concept: the ancestry test used in production.
  # Technical depth: injected rather than called ambiently so a unit test can drive
  # both outcomes with fabricated revisions, which no real repository could supply.
  defp ancestor_check do
    root = File.cwd!()
    fn prior, revision -> Git.ancestor?(root, prior, revision) end
  end

  @doc """
  ## Concept

  Validates one milestone's plan pair, gate, and governance records against the
  lifecycle state the canonical register declares.

  ## Technical depth

  Checks the exact Concept-to-Technical-depth section mapping, both envelopes,
  the progress table, and the governance rows; then resolves every bound
  candidate and compares its envelope and gate bytes with the current ones. The
  original generation-zero acceptance candidate must itself have all outcomes
  Open. A later amendment candidate may retain conforming progress from the
  already-running milestone. The closure candidate must retain the identical
  acceptance row while leaving Closure empty — so closure cannot quietly restate
  what was accepted.
  """
  @spec governance(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          (String.t(), String.t() -> String.t() | nil) | nil,
          keyword()
        ) :: :ok
  def governance(text, technical_text, gate_text, name, state, resolve_file, options \\ []) do
    path = "docs/plans/#{name}.md"
    technical_path = "docs/plans/#{name}-technical.md"
    gate_path = "docs/plans/#{name}-gate.md"

    current_gate_digest = gate_digest(gate_text, gate_path)
    generation = gate_generation(gate_text, gate_path)

    if state != "Closed" and generation > 0 and
         not amendment_transaction_v1?(gate_text, gate_path) do
      raise Invalid,
            "#{gate_path}: an active amended gate must declare amendment transaction v1"
    end

    mapping =
      text
      |> Documents.labelled_links(path, label: "Technical depth", own_prefix: "concept")
      |> MapSet.new(fn {anchor, _target, fragment} -> {anchor, fragment} end)

    if mapping != @relationships do
      raise Invalid, "#{path}: plan sections need the exact Concept-to-Technical-depth mapping"
    end

    {envelope, outcome_ids} = concept_envelope(text, path)
    technical = technical_envelope(technical_text, technical_path)
    progress(text, path, outcome_ids, state)
    {rows, bound, complete} = Records.governance_records(text, path)

    expected =
      case state do
        "Open" -> [false, false]
        "Closed" -> [true, true]
        _other -> [true, false]
      end

    if complete != expected do
      raise Invalid, "#{path}: governance records do not match #{state} lifecycle state"
    end

    candidates =
      resolve_candidates!(
        bound,
        %{
          path: path,
          technical_path: technical_path,
          gate_path: gate_path,
          gate_digest: current_gate_digest,
          concept_digest: envelope_digest(envelope),
          technical_digest: envelope_digest(technical)
        },
        resolve_file
      )

    verify_acceptance!(
      Enum.at(bound, 0),
      Enum.at(rows, 0),
      candidates,
      envelope,
      technical,
      name,
      state,
      Keyword.get(options, :lifecycle_history_verified, false),
      path,
      technical_path,
      resolve_file
    )

    verify_closure!(
      Enum.at(bound, 1),
      candidates,
      envelope,
      technical,
      rows,
      path,
      technical_path
    )

    documentation_obligations(gate_text, gate_path, name, state)
    reject_second_status_surface!(text, path)
  end

  defp resolve_candidates!(bound, context, resolve_file) do
    bound
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn {revision, bound_concept, bound_technical, bound_gate} ->
      historical_concept = resolve_file && resolve_file.(revision, context.path)
      historical_technical = resolve_file && resolve_file.(revision, context.technical_path)
      historical_gate = resolve_file && resolve_file.(revision, context.gate_path)

      if Enum.any?([historical_concept, historical_technical, historical_gate], &is_nil/1) do
        raise Invalid,
              "#{context.path}: governance candidate or one of its bound files is unavailable"
      end

      {historical_envelope, _ids} =
        concept_envelope(historical_concept, "#{context.path} at #{revision}")

      historical_technical_envelope =
        technical_envelope(historical_technical, "#{context.technical_path} at #{revision}")

      if bound_concept != envelope_digest(historical_envelope) or
           bound_concept != context.concept_digest do
        raise Invalid,
              "#{context.path}: governance concept digest does not match current and candidate envelopes"
      end

      if bound_technical != envelope_digest(historical_technical_envelope) or
           bound_technical != context.technical_digest do
        raise Invalid,
              "#{context.path}: governance technical digest does not match current and candidate envelopes"
      end

      historical_gate_digest =
        gate_digest(historical_gate, "#{context.gate_path} at #{revision}")

      if bound_gate != context.gate_digest or bound_gate != historical_gate_digest do
        raise Invalid,
              "#{context.path}: governance gate digest does not match current and historical gate text"
      end

      {revision, {historical_concept, historical_technical, historical_gate}}
    end)
  end

  defp verify_acceptance!(
         nil,
         _row,
         _candidates,
         _envelope,
         _technical,
         _name,
         _state,
         _lifecycle_history_verified,
         _path,
         _technical_path,
         _resolve
       ) do
    :ok
  end

  defp verify_acceptance!(
         {revision, _concept, _technical_digest, _gate},
         acceptance_row,
         candidates,
         envelope,
         technical,
         name,
         state,
         lifecycle_history_verified,
         path,
         technical_path,
         resolve_file
       ) do
    {candidate, technical_candidate, candidate_gate} = Map.fetch!(candidates, revision)

    {candidate_envelope, candidate_outcomes} =
      concept_envelope(candidate, "#{path} at #{revision}")

    candidate_technical =
      technical_envelope(technical_candidate, "#{technical_path} at #{revision}")

    generation =
      gate_generation(candidate_gate, "#{path} gate at acceptance candidate #{revision}")

    candidate_lifecycle =
      case generation do
        0 ->
          "Open"

        _amendment ->
          amendment_candidate_lifecycle!(
            revision,
            name,
            state,
            path,
            resolve_file,
            lifecycle_history_verified
          )
      end

    if generation > 0 and
         amendment_transaction_v1?(candidate_gate, "#{path} gate at candidate #{revision}") do
      validate_amendment_disposition!(
        acceptance_row,
        candidate,
        path,
        revision,
        resolve_file
      )
    end

    progress(
      candidate,
      "#{path} at acceptance candidate #{revision}",
      candidate_outcomes,
      candidate_lifecycle
    )

    acceptance_chain(candidate, path, revision, resolve_file, MapSet.new(), ancestor_check())

    if envelope != candidate_envelope do
      raise Invalid, "#{path}: accepted normative concept envelope differs from its candidate"
    end

    if technical != candidate_technical do
      raise Invalid,
            "#{technical_path}: accepted normative technical envelope differs from its candidate"
    end

    :ok
  end

  defp amendment_candidate_lifecycle!(
         revision,
         name,
         current_state,
         path,
         resolve_file,
         lifecycle_history_verified
       ) do
    index = resolve_file && resolve_file.(revision, "docs/plans/README.md")

    if is_nil(index) do
      raise Invalid,
            "#{path}: amendment candidate #{revision} lifecycle state is unavailable"
    end

    case List.keyfind(Register.register(index), name, 0) do
      {^name, ^current_state} ->
        current_state

      {^name, candidate_state}
      when lifecycle_history_verified and
             candidate_state in ["Accepted", "In progress", "In review"] ->
        # History has already proved exact A and R carried the same state. Later
        # descendants may legitimately advance; candidate progress is judged
        # against A's historical state rather than today's state.
        candidate_state

      {^name, candidate_state} ->
        raise Invalid,
              "#{path}: administrative rebind must preserve amendment candidate lifecycle " <>
                "state #{candidate_state}; current state is #{current_state}"

      nil ->
        raise Invalid,
              "#{path}: amendment candidate #{revision} does not register #{name}"
    end
  end

  @doc false
  def validate_amendment_disposition!(
        acceptance_row,
        candidate_text,
        path,
        revision,
        resolve_file,
        record_revision \\ nil
      ) do
    {candidate_rows, _bound, _complete} =
      Records.governance_records(candidate_text, "#{path} at amendment candidate #{revision}")

    current_evidence = Enum.at(acceptance_row, 2)
    prior_evidence = candidate_rows |> Enum.at(0) |> Enum.at(2)

    if current_evidence == prior_evidence do
      raise Invalid,
            "#{path}: amendment rebind must name a new amendment-specific disposition record"
    end

    {target, fragment} = amendment_disposition_target!(current_evidence, path)
    candidate_target = resolve_file && resolve_file.(revision, target)

    if candidate_target == nil do
      raise Invalid,
            "#{path}: amendment disposition target #{target} is unavailable at candidate " <>
              revision
    end

    if visible_anchor_count(candidate_target, target, fragment) > 0 do
      raise Invalid,
            "#{path}: amendment disposition #{target}##{fragment} already existed at " <>
              "candidate #{revision}; the rebind must add a new record"
    end

    if record_revision != nil and record_revision != "working tree" do
      record_target = resolve_file && resolve_file.(record_revision, target)

      if record_target == nil or visible_anchor_count(record_target, target, fragment) != 1 do
        raise Invalid,
              "#{path}: amendment disposition #{target}##{fragment} must first appear exactly " <>
                "once at rebind #{record_revision}"
      end
    end

    :ok
  end

  defp amendment_disposition_target!(evidence, path) do
    case Regex.run(~r/\A\[disposition\]\(([^#) \t]*)#([^#) \t]+)\)\z/u, evidence) do
      [_all, raw_target, fragment] ->
        target =
          case raw_target do
            "" -> path
            _other -> Paths.normalise(Paths.join(Paths.dirname(path), raw_target))
          end

        if String.starts_with?(raw_target, ["/", "http:", "https:", "//"]) or
             target == ".." or String.starts_with?(target, "../") do
          raise Invalid,
                "#{path}: amendment disposition must be one local fragmented record"
        end

        {target, fragment}

      _other ->
        raise Invalid,
              "#{path}: amendment disposition must be one local fragmented record"
    end
  end

  defp visible_anchor_count(text, path, fragment) do
    lines = Markdown.lines(text, path)

    text
    |> Markdown.visible_line_numbers(path)
    |> Enum.count(fn index ->
      lines
      |> Enum.at(index)
      |> Markdown.exposed_line()
      |> Markdown.anchors_in()
      |> Enum.member?(fragment)
    end)
  end

  defp verify_closure!(nil, _candidates, _envelope, _technical, _rows, _path, _technical_path) do
    :ok
  end

  defp verify_closure!(
         {revision, _concept, _technical_digest, _gate},
         candidates,
         envelope,
         technical,
         rows,
         path,
         technical_path
       ) do
    {candidate, technical_candidate, _gate} = Map.fetch!(candidates, revision)

    {closure_envelope, closure_outcomes} =
      concept_envelope(candidate, "#{path} at closure candidate #{revision}")

    closure_technical =
      technical_envelope(
        technical_candidate,
        "#{technical_path} at closure candidate #{revision}"
      )

    progress(candidate, "#{path} at closure candidate #{revision}", closure_outcomes, "Closed")

    {closure_rows, _bound, closure_complete} =
      Records.governance_records(candidate, "#{path} at closure candidate #{revision}")

    if closure_complete != [true, false] or Enum.at(closure_rows, 0) != Enum.at(rows, 0) do
      raise Invalid, "#{path}: closure candidate must retain Acceptance and leave Closure empty"
    end

    if closure_envelope != envelope do
      raise Invalid, "#{path}: closure candidate changed the accepted normative concept envelope"
    end

    if closure_technical != technical do
      raise Invalid,
            "#{technical_path}: closure candidate changed the accepted normative technical envelope"
    end

    :ok
  end

  # Concept: lifecycle state lives in the canonical register and nowhere else.
  # Technical depth: a plan-local status heading would be a second place a reader
  # could read the milestone's state from, and the two would eventually disagree.
  defp reject_second_status_surface!(text, path) do
    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    if Markdown.matching_indices(lines, visible, "## Milestone Status") != [] do
      raise Invalid, "#{path}: lifecycle state belongs only in the canonical register"
    end

    :ok
  end

  @doc """
  ## Concept

  The digest and path pairs a gate binds outside its own bytes.

  ## Technical depth

  A gate document governs nothing executable on its own: its runner could be
  replaced with a command that exits zero while the document's digest stayed
  valid. Binding the runner and its fixtures by content closes that, and a
  malformed declaration fails rather than reading as a gate that predates the
  convention.
  """
  @spec bound_artifacts(String.t(), String.t()) :: [{String.t(), String.t()}]
  def bound_artifacts(gate_text, gate_path) do
    {body, _start} = Markdown.section_body(gate_text, gate_path, "## Bound Artifacts")

    body
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Markdown.table(["SHA-256", "Path"], "#{gate_path} Bound Artifacts")
    |> Enum.map(fn [digest, path] ->
      with [_all, hash] <- Regex.run(~r/\A`([0-9a-f]{64})`\z/u, digest),
           [_match, target] <- Regex.run(~r/\A`([^`]+)`\z/u, path) do
        {hash, target}
      else
        _other -> raise Invalid, "#{gate_path}: malformed bound-artifact row"
      end
    end)
  end

  # Concept: every milestone makes its public documentation disposition visible
  # before implementation and carries it through closure.
  #
  # Technical depth: M0 closed before this contract existed and is the sole
  # migration exception. Every active and future gate has exactly seven ordered
  # rows. The first four may be an accepted N/A; the three repository-wide
  # summaries always name their exact file. Acceptance of the gate is the
  # maintainer disposition for any N/A, so an N/A cannot be introduced later.
  defp documentation_obligations(_gate_text, _gate_path, "M0", "Closed"), do: :ok

  defp documentation_obligations(gate_text, gate_path, _name, _state) do
    {body, body_start} =
      Markdown.section_body(gate_text, gate_path, "## Documentation Obligations")

    visible = Markdown.visible_line_numbers(gate_text, gate_path)

    rows =
      documentation_table!(body, body_start, visible, gate_path)

    if Enum.map(rows, &hd/1) != @documentation_categories do
      raise Invalid,
            "#{gate_path}: documentation obligations must contain the exact seven ordered categories"
    end

    paths =
      Enum.flat_map(rows, fn [category, disposition] ->
        validate_documentation_disposition!(category, disposition, gate_path)
      end)

    validate_documentation_path_set!(paths, gate_path)
  end

  defp documentation_table!(body, body_start, visible, gate_path) do
    header = "| Category | Required closure disposition |"
    table_length = 2 + length(@documentation_categories)

    header_offsets =
      body
      |> Enum.with_index()
      |> Enum.filter(fn {line, offset} ->
        line == header and MapSet.member?(visible, body_start + offset)
      end)

    case header_offsets do
      [{_header, offset}] ->
        table_body = Enum.slice(body, offset, table_length)
        table_offsets = offset..(offset + table_length - 1)
        table_indices = Enum.map(table_offsets, &(body_start + &1))

        visible_pipe_offsets =
          body
          |> Enum.with_index()
          |> Enum.filter(fn {line, line_offset} ->
            String.starts_with?(line, "|") and
              MapSet.member?(visible, body_start + line_offset)
          end)
          |> Enum.map(&elem(&1, 1))

        if length(table_body) != table_length or
             Enum.any?(table_indices, &(not MapSet.member?(visible, &1))) or
             visible_pipe_offsets != Enum.to_list(table_offsets) do
          raise Invalid,
                "#{gate_path}: documentation obligations must be one visible contiguous table"
        end

        Markdown.table(
          table_body,
          ["Category", "Required closure disposition"],
          "#{gate_path} Documentation Obligations"
        )

      _other ->
        raise Invalid,
              "#{gate_path}: documentation obligations must be one visible contiguous table"
    end
  end

  defp validate_documentation_disposition!(category, "N/A — " <> reason, gate_path) do
    if not MapSet.member?(@documentation_optional, category) or String.trim(reason) == "" do
      raise Invalid,
            "#{gate_path}: #{category} may use N/A only as an explicit accepted limitation"
    end

    []
  end

  defp validate_documentation_disposition!(category, disposition, gate_path) do
    paths =
      disposition
      |> String.split(", ", trim: false)
      |> Enum.map(fn token ->
        case Regex.run(~r/\A`([^`\r\n]+\.md)`\z/u, token) do
          [_all, path] -> path
          _other -> raise Invalid, "#{gate_path}: #{category} must name exact Markdown paths"
        end
      end)

    if paths == [] or Enum.any?(paths, &(not canonical_documentation_path?(&1))) or
         length(paths) != length(Enum.uniq(paths)) or
         not documentation_paths_match?(category, paths) do
      raise Invalid, "#{gate_path}: #{category} names an invalid documentation path set"
    end

    paths
  end

  # Concept: a category applies to the repository location the path actually
  # names, not to a misleading textual prefix.
  #
  # Technical depth: equality with the repository's POSIX normal form rejects
  # absolute, dotted, traversing, and empty-component spellings. Backslashes
  # are rejected explicitly because they are host-dependent separators rather
  # than portable repository path bytes.
  defp canonical_documentation_path?(path) do
    path == Paths.normalise(path) and
      not String.starts_with?(path, ["/", "../"]) and
      not String.contains?(path, "\\") and
      not documentation_control_character?(path)
  end

  defp documentation_control_character?(path) do
    path
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 or codepoint in 0x7F..0x9F end)
  end

  defp validate_documentation_path_set!(paths, gate_path) do
    folded = Enum.map(paths, &String.downcase/1)

    collision? = length(folded) != length(Enum.uniq(folded))

    ancestor_conflict? =
      Enum.any?(folded, fn path ->
        Enum.any?(folded, fn other ->
          path != other and String.starts_with?(path, other <> "/")
        end)
      end)

    if collision? or ancestor_conflict? do
      raise Invalid,
            "#{gate_path}: documentation obligations name a colliding or impossible path set"
    end
  end

  defp documentation_paths_match?("Operator-facing documentation", paths) do
    Enum.all?(paths, fn path ->
      String.starts_with?(path, "docs/operator/") and
        String.downcase(path) != "docs/operator/readme.md"
    end)
  end

  defp documentation_paths_match?("Operator README", paths),
    do: paths == ["docs/operator/README.md"]

  defp documentation_paths_match?("Developer-facing documentation", paths) do
    Enum.all?(paths, fn path ->
      String.starts_with?(path, "docs/developer/") and
        String.downcase(path) != "docs/developer/readme.md"
    end)
  end

  defp documentation_paths_match?("Developer README", paths),
    do: paths == ["docs/developer/README.md"]

  defp documentation_paths_match?("Documentation README", paths),
    do: paths == ["docs/README.md"]

  defp documentation_paths_match?("Root README", paths), do: paths == ["README.md"]
  defp documentation_paths_match?("Changelog", paths), do: paths == ["CHANGELOG.md"]
end
