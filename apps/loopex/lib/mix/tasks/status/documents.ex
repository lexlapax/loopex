defmodule Loopex.Checks.Documents do
  @moduledoc """
  ## Concept

  Keeps the repository's two-depth documentation complete and connected. Every
  substantive concept document has exactly one technical companion, each names
  the other through one unambiguous entry, every directory indexes what it
  contains, and every local link resolves.

  The property being protected is navigability: a document a reader can only find
  by already knowing it exists is not documented, and a pair whose two halves
  disagree is not one authority.

  ## Technical depth

  Structural only. It reads relationship anchors, exact heading bytes, reciprocal
  link targets and fragments, index chains, and the small inline-link grammar the
  repository allows — and interprets no prose. Whether a Technical depth section
  actually explains its Concept remains a review judgment; this module proves the
  two are wired together and that no active document falls outside a declared
  class.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Names
  alias Loopex.Checks.Paths

  @adr_concept_path ~r|\Adocs/adr/[0-9]{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md\z|u
  @code_span_label ~r/\A\[`[^`\]\r\n]+`\]\z/u

  @fixed_pairs ["docs/vision.md", "docs/roadmap.md", "docs/developer/development-charter.md"]

  # Concept: developer documents whose companion is an operator document.
  #
  # Technical depth: the charter's pairing rule exists so a decision cannot hide
  # in one half of a pair. These documents carry both depths in one file and are
  # paired across audiences instead -- each links to the operator runbook that
  # covers the same subject, and each of those links back -- so the reciprocal
  # obligation is met by a real companion rather than by a second file that would
  # exist only to satisfy a suffix.
  @exact_exceptions [
    "docs/README.md",
    "docs/developer/agent-context-map.md",
    "docs/developer/agent-adapter-smoke.md",
    "docs/developer/runtime-and-embedding.md",
    "docs/developer/agent-loop-and-tools.md",
    "docs/developer/compatibility-surfaces.md"
  ]

  @unpaired_prefixes [
    "docs/archive/",
    "docs/operator/",
    "docs/generated/",
    "docs/evidence/",
    "docs/schemas/",
    "docs/fixtures/"
  ]

  @repository_exception_prefixes ["conformance/", "schemas/", "fixtures/", "test/fixtures/"]

  @repository_exception_paths [
    ~r|\A\.agents/skills/[a-z0-9]+(?:-[a-z0-9]+)*/SKILL\.md\z|u,
    ~r|\A\.claude/agents/[a-z0-9]+(?:-[a-z0-9]+)*\.md\z|u,
    ~r|\A\.github/ISSUE_TEMPLATE/[^/]+\.md\z|u,
    ~r|\A\.github/PULL_REQUEST_TEMPLATE/[^/]+\.md\z|u,
    ~r|\A\.github/pull_request_template\.md\z|u
  ]

  @root_exceptions ["AGENTS.md", "README.md", "DEVELOPMENT.md", "CHANGELOG.md", "CLAUDE.md"]

  @doc """
  ## Concept

  Whether a path is an ADR concept document.

  ## Technical depth

  ADR concept files are numbered and hyphen-slugged, and the technical companion
  is excluded by suffix, so a companion is never mistaken for a decision of its
  own.
  """
  @spec adr_concept?(String.t()) :: boolean()
  def adr_concept?(path) do
    Regex.match?(@adr_concept_path, path) and not String.ends_with?(path, "-technical.md")
  end

  @doc """
  ## Concept

  Every ADR concept path present in a document set, sorted.

  ## Technical depth

  Discovered rather than listed, so adding an ADR brings it under validation in
  the same change that creates it.
  """
  @spec adr_concept_paths(map()) :: [String.t()]
  def adr_concept_paths(documents) do
    documents |> Map.keys() |> Enum.filter(&adr_concept?/1) |> Enum.sort()
  end

  @doc """
  ## Concept

  Classifies every active Markdown path, validates every pair it discovers, and
  returns the ADR concept paths and milestone plan names it found.

  ## Technical depth

  Runs before any semantic status validation so a new document cannot silently
  fall outside the documentation model. Required pairs, discovered pairs, ADR
  pairs, and plan triples are enumerated; operational, index, adapter, skill,
  gate, and archived paths are explicit exceptions rather than a catch-all. A
  path that matches nothing fails: an unknown class is unvalidated content, and
  unvalidated content is exactly where an ungoverned claim survives.
  """
  @spec document_topology(map()) :: {[String.t()], [String.t()]}
  def document_topology(documents) do
    reject_colliding_paths!(documents)

    adr_concepts = adr_concept_paths(documents)
    pairs = MapSet.union(MapSet.new(@fixed_pairs), MapSet.new(adr_concepts))
    pairs = documents |> Map.keys() |> Enum.reduce(pairs, &add_discovered_pair/2)

    Enum.each(Enum.sort(pairs), &validate_pair(documents, &1))

    plan_names = plan_names!(documents)

    Enum.each(plan_names, fn name ->
      Names.milestone!("`#{name}`", "docs/plans/#{name}.md")
      validate_pair(documents, "docs/plans/#{name}.md")
    end)

    pair_paths =
      pairs |> Enum.flat_map(&[&1, Paths.technical(&1)]) |> MapSet.new()

    require_indexed!(documents, pair_paths)
    reject_unknown_classes!(documents, pair_paths, plan_names)

    {adr_concepts, plan_names}
  end

  defp reject_colliding_paths!(documents) do
    documents
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, folded ->
      if String.ends_with?(path, "-technical-technical.md") do
        raise Invalid, "#{path}: doubled technical suffix is not a document class"
      end

      key = String.downcase(path)

      case Map.fetch(folded, key) do
        {:ok, prior} when prior != path ->
          raise Invalid, "#{path}: Markdown path collides by case with #{prior}"

        _other ->
          Map.put_new(folded, key, path)
      end
    end)

    :ok
  end

  defp add_discovered_pair(path, pairs) do
    excluded =
      not String.starts_with?(path, "docs/") or path in @exact_exceptions or
        String.ends_with?(path, "/README.md") or String.starts_with?(path, "docs/adr/") or
        String.starts_with?(path, "docs/plans/") or
        Enum.any?(@unpaired_prefixes, &String.starts_with?(path, &1))

    case excluded do
      true ->
        pairs

      false ->
        concept =
          case String.ends_with?(path, "-technical.md") do
            true -> Paths.concept(path)
            false -> path
          end

        MapSet.put(pairs, concept)
    end
  end

  defp plan_names!(documents) do
    {concepts, technical, gates} =
      documents
      |> Map.keys()
      |> Enum.reduce({MapSet.new(), MapSet.new(), MapSet.new()}, fn path, acc ->
        classify_plan_path(path, acc)
      end)

    if concepts != technical or concepts != gates do
      raise Invalid,
            "docs/plans: concept, technical depth, and gate files must form exact triples"
    end

    Enum.sort(concepts)
  end

  defp classify_plan_path(path, {concepts, technical, gates} = acc) do
    case String.starts_with?(path, "docs/plans/") and path != "docs/plans/README.md" do
      false ->
        acc

      true ->
        relative = Paths.strip_prefix(path, "docs/plans/")

        if String.contains?(relative, "/") do
          raise Invalid, "#{path}: nested plan Markdown is not allowed"
        end

        cond do
          String.ends_with?(relative, "-technical.md") ->
            {concepts, MapSet.put(technical, Paths.strip_suffix(relative, "-technical.md")),
             gates}

          String.ends_with?(relative, "-gate.md") ->
            {concepts, technical, MapSet.put(gates, Paths.strip_suffix(relative, "-gate.md"))}

          true ->
            {MapSet.put(concepts, Paths.strip_suffix(relative, ".md")), technical, gates}
        end
    end
  end

  defp require_indexed!(documents, pair_paths) do
    index = Map.get(documents, "docs/README.md")

    if index == nil do
      raise Invalid, "docs/README.md: documentation index is missing"
    end

    indexed = visible_local_link_targets(index, "docs/README.md")
    missing = pair_paths |> MapSet.difference(indexed) |> Enum.sort()

    if missing != [] do
      raise Invalid,
            "docs/README.md: active document pairs are missing from the index: " <>
              Enum.join(missing, ", ")
    end

    :ok
  end

  defp reject_unknown_classes!(documents, pair_paths, plan_names) do
    plan_paths =
      for name <- plan_names,
          suffix <- [".md", "-technical.md", "-gate.md"],
          into: MapSet.new() do
        "docs/plans/#{name}#{suffix}"
      end

    Enum.each(Enum.sort(Map.keys(documents)), fn path ->
      unless MapSet.member?(pair_paths, path) or MapSet.member?(plan_paths, path) or
               class_exception?(path) do
        raise Invalid, "#{path}: unknown active Markdown document class"
      end
    end)
  end

  defp class_exception?(path) do
    path in @root_exceptions or path in @exact_exceptions or
      String.ends_with?(path, "/README.md") or
      Enum.any?(@unpaired_prefixes, &String.starts_with?(path, &1)) or
      Enum.any?(@repository_exception_prefixes, &String.starts_with?(path, &1)) or
      path |> Paths.basename() |> String.downcase() |> String.starts_with?("license") or
      Enum.any?(@repository_exception_paths, &Regex.match?(&1, path))
  end

  @doc """
  ## Concept

  Validates one concept and technical-depth pair: both halves exist, each
  announces its own depth once, and every relationship link between them is
  reciprocal and resolves.

  ## Technical depth

  Paths, anchor prefixes, fragments, and relationship bytes are compared exactly;
  no prose is interpreted. The reciprocity comparison is set equality in both
  directions, so a forward link with no matching backlink and a backlink with no
  matching forward link both fail — one-way navigation is the common form of a
  pair drifting apart.
  """
  @spec validate_pair(map(), String.t()) :: :ok
  def validate_pair(documents, concept_path) do
    technical_path = Paths.technical(concept_path)

    unless Map.has_key?(documents, concept_path) do
      raise Invalid, "#{concept_path}: paired concept document is missing"
    end

    unless Map.has_key?(documents, technical_path) do
      raise Invalid, "#{technical_path}: paired technical document is missing"
    end

    concept_text = Map.fetch!(documents, concept_path)
    technical_text = Map.fetch!(documents, technical_path)

    {concept_anchor, concept_target, technical_fragment} =
      relationship(concept_text, concept_path,
        heading: "## Concept",
        own_prefix: "concept",
        label: "Technical depth"
      )

    {technical_anchor, technical_target, concept_fragment} =
      relationship(technical_text, technical_path,
        heading: "## Technical depth",
        own_prefix: "technical",
        label: "Concept"
      )

    expected_technical = Paths.relative_target(concept_path, technical_path)
    expected_concept = Paths.relative_target(technical_path, concept_path)

    if concept_target != expected_technical do
      raise Invalid, "#{concept_path}: Technical depth link must name its own companion"
    end

    if technical_target != expected_concept do
      raise Invalid, "#{technical_path}: Concept link must name its own companion"
    end

    concept_anchors = anchors(concept_text, concept_path, "concept")
    technical_anchors = anchors(technical_text, technical_path, "technical")

    unless MapSet.member?(concept_anchors, concept_fragment) do
      raise Invalid, "#{technical_path}: Concept fragment does not resolve exactly once"
    end

    unless MapSet.member?(technical_anchors, technical_fragment) do
      raise Invalid, "#{concept_path}: Technical depth fragment does not resolve exactly once"
    end

    if concept_fragment != concept_anchor or technical_fragment != technical_anchor do
      raise Invalid, "#{concept_path}: paired relationship links are not reciprocal"
    end

    concept_links =
      labelled_links(concept_text, concept_path, label: "Technical depth", own_prefix: "concept")

    technical_links =
      labelled_links(technical_text, technical_path, label: "Concept", own_prefix: "technical")

    reject_label(concept_text, concept_path, "Concept")
    reject_label(technical_text, technical_path, "Technical depth")

    if Enum.any?(concept_links, fn {_anchor, target, _fragment} ->
         target != expected_technical
       end) do
      raise Invalid,
            "#{concept_path}: labelled Technical depth links may name only its companion"
    end

    if Enum.any?(concept_links, fn {_anchor, _target, fragment} ->
         not MapSet.member?(technical_anchors, fragment)
       end) do
      raise Invalid, "#{concept_path}: Technical depth fragment does not resolve exactly once"
    end

    if Enum.any?(technical_links, fn {_anchor, target, _fragment} ->
         target != expected_concept
       end) do
      raise Invalid, "#{technical_path}: labelled Concept links may name only its companion"
    end

    if Enum.any?(technical_links, fn {_anchor, _target, fragment} ->
         not MapSet.member?(concept_anchors, fragment)
       end) do
      raise Invalid, "#{technical_path}: Concept fragment does not resolve exactly once"
    end

    forward =
      MapSet.new(concept_links, fn {anchor, _target, fragment} -> {anchor, fragment} end)

    backward =
      MapSet.new(
        companion_backlinks(technical_text, technical_path,
          companion_target: expected_concept,
          own_prefix: "technical"
        )
      )

    if forward != backward do
      raise Invalid, "#{concept_path}: labelled relationship links are not reciprocal"
    end

    :ok
  end

  @doc """
  ## Concept

  Reads the single top-level relationship one paired document carries: its own
  depth anchor, and the companion path and fragment it points at.

  ## Technical depth

  Accepts only a governed semantic anchor, the exact canonical heading bytes, an
  optional blank line, and one labelled Markdown link. The document may carry an
  H1 title before the anchor and nothing else, so the relationship is the first
  substantive thing a reader meets. The returned fragment is resolved by the
  caller once both halves have been parsed.
  """
  @spec relationship(String.t(), String.t(), keyword()) :: {String.t(), String.t(), String.t()}
  def relationship(text, path, options) do
    heading = Keyword.fetch!(options, :heading)
    own_prefix = Keyword.fetch!(options, :own_prefix)
    label = Keyword.fetch!(options, :label)

    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)
    expected_text = Paths.strip_prefix(heading, "## ")

    heading_index =
      case heading_indices(lines, visible, expected_text) do
        [index] -> index
        _other -> raise Invalid, "#{path}: expected exactly one visible #{heading}"
      end

    if Enum.at(lines, heading_index) != heading do
      raise Invalid, "#{path}: #{heading} must use its exact canonical ATX heading"
    end

    anchor = relationship_anchor!(lines, visible, heading_index, heading, own_prefix, path)
    require_bare_preamble!(lines, heading_index - 1, heading, path)
    {target, fragment} = relationship_link!(lines, visible, heading_index, heading, label, path)
    {anchor, target, fragment}
  end

  defp heading_indices(lines, visible, expected_text) do
    visible
    |> Enum.sort()
    |> Enum.flat_map(fn index ->
      line = Enum.at(lines, index)

      atx = if Markdown.atx(line) == {2, expected_text}, do: [index], else: []

      setext =
        if String.trim(line) == expected_text and MapSet.member?(visible, index + 1) and
             Regex.match?(~r/\A {0,3}-+[ \t]*\z/u, Enum.at(lines, index + 1) || "") do
          [index]
        else
          []
        end

      atx ++ setext
    end)
  end

  defp relationship_anchor!(lines, visible, heading_index, heading, own_prefix, path) do
    anchor_index = heading_index - 1

    unless MapSet.member?(visible, anchor_index) do
      raise Invalid, "#{path}: #{heading} needs an immediately preceding semantic anchor"
    end

    anchor = Markdown.anchor_only(Enum.at(lines, anchor_index))

    if anchor == nil or not depth_anchor?(anchor, own_prefix) do
      expected = if own_prefix == "concept", do: "concept", else: "technical-depth"

      raise Invalid,
            "#{path}: #{heading} needs the explicit #{inspect(expected)} relationship anchor"
    end

    anchor
  end

  defp require_bare_preamble!(lines, anchor_index, heading, path) do
    preamble =
      lines |> Enum.take(max(anchor_index, 0)) |> Enum.reject(&(String.trim(&1) == ""))

    title =
      case preamble do
        [single] -> Markdown.atx(single)
        _other -> nil
      end

    valid =
      preamble == [] or match?({1, text} when text != "", title)

    unless valid do
      raise Invalid,
            "#{path}: paired document must start with an optional H1 and its #{heading} relationship"
    end

    :ok
  end

  defp relationship_link!(lines, visible, heading_index, heading, label, path) do
    prefix = "#{label}: "
    first = heading_index + 1

    link_index =
      case first < length(lines) and Enum.at(lines, first) == "" do
        true -> first + 1
        false -> first
      end

    line = Enum.at(lines, link_index) || ""

    unless MapSet.member?(visible, link_index) and String.starts_with?(line, prefix) do
      raise Invalid, "#{path}: #{heading} must be followed immediately by #{label}: link"
    end

    case Markdown.link_only(strip_period(Paths.strip_prefix(line, prefix))) do
      nil -> raise Invalid, "#{path}: #{label} relationship must be one exact Markdown link"
      {_label, destination} -> fragmented!(destination, label, path)
    end
  end

  defp fragmented!(destination, label, path) do
    with 1 <- Markdown.occurrences(destination, "#"),
         [target, fragment] <- String.split(destination, "#", parts: 2),
         true <- target != "" and fragment != "" do
      {target, fragment}
    else
      _other -> raise Invalid, "#{path}: #{label} relationship needs one nonempty fragment"
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

  Whether an anchor belongs to the depth a document owns.

  ## Technical depth

  A depth owns its own relationship anchor — `concept` or `technical-depth` — and
  every anchor prefixed with its depth name. Cross-depth anchors are rejected so
  a fragment always identifies which half of a pair it lives in.
  """
  @spec depth_anchor?(String.t(), String.t()) :: boolean()
  def depth_anchor?(anchor, prefix) do
    own = if prefix == "concept", do: "concept", else: "technical-depth"
    anchor == own or String.starts_with?(anchor, prefix <> "-")
  end

  @doc """
  ## Concept

  Every semantic anchor a document declares, each of which must resolve exactly
  once and carry the document's own depth prefix.

  ## Technical depth

  A duplicated anchor makes a fragment ambiguous, which would let a reciprocal
  link appear to resolve while pointing at the wrong section, so duplication is a
  failure rather than a warning.
  """
  @spec anchors(String.t(), String.t(), String.t()) :: MapSet.t(String.t())
  def anchors(text, path, prefix) do
    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    found =
      visible
      |> Enum.sort()
      |> Enum.reduce(MapSet.new(), fn index, acc ->
        lines
        |> Enum.at(index)
        |> Markdown.exposed_line()
        |> Markdown.anchors_in()
        |> Enum.reduce(acc, fn anchor, inner ->
          unless depth_anchor?(anchor, prefix) do
            raise Invalid,
                  "#{path}: semantic anchor #{inspect(anchor)} has the wrong depth prefix"
          end

          if MapSet.member?(inner, anchor) do
            raise Invalid, "#{path}: semantic anchor #{inspect(anchor)} must resolve exactly once"
          end

          MapSet.put(inner, anchor)
        end)
      end)

    if MapSet.size(found) == 0 do
      raise Invalid, "#{path}: no visible #{prefix}-... semantic anchor"
    end

    found
  end

  @doc """
  ## Concept

  Every labelled cross-depth relationship link in a document, as
  `{owning anchor, target, fragment}`.

  ## Technical depth

  A labelled link belongs to the anchored section it appears under, so the last
  anchor seen on or before the line is the owner. A link with no owning anchor of
  the document's own depth is rejected: an unowned relationship cannot be checked
  for reciprocity, and an unreciprocated relationship is how the two depths drift.
  """
  @spec labelled_links(String.t(), String.t(), keyword()) :: [
          {String.t(), String.t(), String.t()}
        ]
  def labelled_links(text, path, options) do
    label = Keyword.fetch!(options, :label)
    own_prefix = Keyword.fetch!(options, :own_prefix)
    prefix = "#{label}: "

    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    {links, _anchor} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, index}, {links, current} ->
        case MapSet.member?(visible, index) do
          false ->
            {links, current}

          true ->
            exposed = Markdown.exposed_line(line)
            current = List.last(Markdown.anchors_in(exposed)) || current

            case String.starts_with?(exposed, prefix) do
              false ->
                {links, current}

              true ->
                unless current != nil and depth_anchor?(current, own_prefix) do
                  raise Invalid,
                        "#{path}: #{label} link needs a preceding #{own_prefix}-... anchor"
                end

                payload = strip_period(Paths.strip_prefix(exposed, prefix))

                case Markdown.link_only(payload) do
                  nil ->
                    raise Invalid,
                          "#{path}: #{label} relationship must be one exact fragmented link"

                  {_text, destination} ->
                    unless Markdown.occurrences(destination, "#") == 1 do
                      raise Invalid,
                            "#{path}: #{label} relationship must be one exact fragmented link"
                    end

                    {target, fragment} = fragmented!(destination, label, path)
                    {[{current, target, fragment} | links], current}
                end
            end
        end
      end)

    links = Enum.reverse(links)

    if length(Enum.uniq(links)) != length(links) do
      raise Invalid, "#{path}: duplicate #{label} relationship"
    end

    links
  end

  @doc """
  ## Concept

  The reciprocal relationships a technical document carries back to its concept
  companion, as `{companion fragment, owning anchor}`.

  ## Technical depth

  Only links on an anchor-bearing line or on an explicit `Concept: ` line count.
  Every other mention of the companion is ordinary prose, and treating prose as a
  relationship would make reciprocity pass by accident.
  """
  @spec companion_backlinks(String.t(), String.t(), keyword()) :: [{String.t(), String.t()}]
  def companion_backlinks(text, path, options) do
    companion_target = Keyword.fetch!(options, :companion_target)
    own_prefix = Keyword.fetch!(options, :own_prefix)

    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    {backlinks, _anchor} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, index}, {found, current} ->
        case MapSet.member?(visible, index) do
          false ->
            {found, current}

          true ->
            exposed = Markdown.exposed_line(line)
            anchors = Markdown.anchors_in(exposed)
            current = List.last(anchors) || current

            relevant =
              current != nil and depth_anchor?(current, own_prefix) and
                (anchors != [] or String.starts_with?(exposed, "Concept: "))

            case relevant do
              false -> {found, current}
              true -> {collect_backlinks(exposed, companion_target, current, found), current}
            end
        end
      end)

    backlinks = Enum.reverse(backlinks)

    if length(Enum.uniq(backlinks)) != length(backlinks) do
      raise Invalid, "#{path}: duplicate reciprocal companion relationship"
    end

    backlinks
  end

  defp collect_backlinks(exposed, companion_target, current, found) do
    exposed
    |> Markdown.links_in()
    |> Enum.reduce(found, fn {_start, _all, _label, destination}, acc ->
      case Markdown.occurrences(destination, "#") == 1 do
        false ->
          acc

        true ->
          [target, fragment] = String.split(destination, "#", parts: 2)

          case target == companion_target and fragment != "" do
            true -> [{fragment, current} | acc]
            false -> acc
          end
      end
    end)
  end

  @doc """
  ## Concept

  Fails when a document uses the relationship label that belongs to the other
  depth.

  ## Technical depth

  A concept document declaring `Concept: ` or a technical document declaring
  `Technical depth: ` inverts the direction of the pair. The reciprocity check
  would then compare two sets that describe the same direction twice, so the
  label is rejected outright.
  """
  @spec reject_label(String.t(), String.t(), String.t()) :: :ok
  def reject_label(text, path, label) do
    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    offending =
      Enum.any?(visible, fn index ->
        lines |> Enum.at(index) |> Markdown.exposed_line() |> String.starts_with?("#{label}: ")
      end)

    if offending do
      raise Invalid, "#{path}: #{label} relationship label belongs in the other depth"
    end

    :ok
  end

  @doc """
  ## Concept

  The repository-relative targets of every governed local Markdown link in a
  document.

  ## Technical depth

  Fragments are dropped and absolute or scheme-bearing destinations are skipped,
  so the result is the set of documents this one actually points at. The index
  chain is verified against this set rather than against prose, which is what
  makes "indexed" a structural property.
  """
  @spec visible_local_link_targets(String.t(), String.t()) :: MapSet.t(String.t())
  def visible_local_link_targets(text, path) do
    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    visible
    |> Enum.sort()
    |> Enum.reduce(MapSet.new(), fn index, acc ->
      lines
      |> Enum.at(index)
      |> Markdown.exposed_line()
      |> markdown_links(path)
      |> Enum.reduce(acc, fn {_start, _all, _label, destination}, inner ->
        target = destination |> String.split("#", parts: 2) |> hd()

        case local_target?(target) do
          false -> inner
          true -> MapSet.put(inner, Paths.normalise(Paths.join(Paths.dirname(path), target)))
        end
      end)
    end)
  end

  defp local_target?(""), do: false

  defp local_target?(target) do
    not String.starts_with?(target, "/") and
      not (target |> String.split("/", parts: 2) |> hd() |> String.contains?(":"))
  end

  @doc """
  ## Concept

  The inline links in one governed line, accepting only the repository's small
  unambiguous link grammar.

  ## Technical depth

  Reference links, titled links, images, nested brackets, and empty labels are
  rejected, because each has a second form that a line-oriented resolver reads
  differently from a renderer. One exception is allowed: a label that is entirely
  one code span, which renders as a link and is unambiguous, and which the
  repository uses to link a filename. That exception needs the raw line, so it
  applies only where the caller supplies it.
  """
  @spec markdown_links(String.t(), String.t(), String.t() | nil) ::
          [{non_neg_integer(), String.t(), String.t(), String.t()}]
  def markdown_links(line, path, raw_line \\ nil) do
    matches = Markdown.links_in(line)

    if Enum.any?(matches, fn {start, _all, _label, _destination} ->
         start > 0 and binary_part(line, start - 1, 1) == "!"
       end) do
      raise Invalid, "#{path}: unsupported Markdown image syntax"
    end

    Enum.each(matches, fn {_start, _all, label, destination} ->
      unless String.trim(label) != "" or code_span_label?(raw_line, destination) do
        raise Invalid, "#{path}: unsupported Markdown link syntax"
      end
    end)

    reject_unsupported_remainder!(line, matches, path)
    matches
  end

  defp code_span_label?(nil, _destination), do: false

  defp code_span_label?(raw_line, destination) do
    not String.contains?(raw_line, "[](") and
      raw_line
      |> Markdown.links_in()
      |> Enum.any?(fn {_start, _all, label, found} ->
        found == destination and Regex.match?(@code_span_label, "[" <> label <> "]")
      end)
  end

  defp reject_unsupported_remainder!(line, matches, path) do
    remainder =
      Enum.reduce(matches, line, fn {start, all, _label, _destination}, acc ->
        binary_part(acc, 0, start) <>
          String.duplicate(" ", byte_size(all)) <>
          binary_part(acc, start + byte_size(all), byte_size(acc) - start - byte_size(all))
      end)

    if String.contains?(remainder, "](") or
         Regex.match?(~r/\[[^\]\r\n]+\]\(/u, remainder) or
         Regex.match?(~r/\[[^\]\r\n]+\]\[[^\]\r\n]*\]/u, remainder) or
         Regex.match?(~r/\A[ \t]*\[(?!\^)[^\]\r\n]+\]:/u, remainder) do
      raise Invalid, "#{path}: unsupported Markdown link syntax"
    end

    :ok
  end

  @doc """
  ## Concept

  Every documentation directory indexes what it contains, and the chain of
  indexes reaches the root README.

  ## Technical depth

  A directory holding Markdown must carry a `README.md`; the documentation index
  must link the root README and every directory index; and every directory index
  must link back. The chain is checked structurally rather than described in
  prose, because a document reachable only by knowing it exists is not
  documented.
  """
  @spec validate_directory_indexes(map()) :: :ok
  def validate_directory_indexes(documents) do
    directories =
      documents
      |> Map.keys()
      |> Enum.filter(&(String.starts_with?(&1, "docs/") and String.ends_with?(&1, ".md")))
      |> Enum.map(&Paths.dirname/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(directories, fn directory ->
      unless Map.has_key?(documents, Paths.join(directory, "README.md")) do
        raise Invalid, "#{directory}: directory with Markdown needs a README.md index"
      end
    end)

    root_index = "docs/README.md"
    root_targets = visible_local_link_targets(Map.fetch!(documents, root_index), root_index)

    unless MapSet.member?(root_targets, "README.md") do
      raise Invalid, "#{root_index}: must link back to the root README.md"
    end

    directories
    |> Enum.reject(&(&1 == "docs"))
    |> Enum.each(fn directory ->
      index = Paths.join(directory, "README.md")

      unless MapSet.member?(root_targets, index) do
        raise Invalid, "#{root_index}: must link the #{directory}/ index"
      end

      targets = visible_local_link_targets(Map.fetch!(documents, index), index)

      unless MapSet.member?(targets, root_index) do
        raise Invalid, "#{index}: must link back to #{root_index}"
      end
    end)

    :ok
  end

  @doc """
  ## Concept

  Every governed local Markdown link resolves to a document that exists, and
  every explicit fragment resolves to exactly one semantic anchor there.

  ## Technical depth

  Archived documents are skipped: they are immutable historical bytes whose links
  described a tree that no longer exists, and rewriting them to satisfy a check
  would destroy the record. A destination naming a directory must have at least
  one document under it, so a link to a directory index cannot outlive the
  directory.
  """
  @spec validate_local_links(map()) :: :ok
  def validate_local_links(documents) do
    documents
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&String.starts_with?(&1, "docs/archive/"))
    |> Enum.each(fn source ->
      text = Map.fetch!(documents, source)
      lines = Markdown.lines(text, source)
      visible = Markdown.visible_line_numbers(text, source)

      visible
      |> Enum.sort()
      |> Enum.each(fn index ->
        raw = Enum.at(lines, index)

        raw
        |> Markdown.exposed_line()
        |> markdown_links(source, raw)
        |> Enum.each(fn {_start, _all, _label, destination} ->
          resolve_link!(documents, source, destination)
        end)
      end)
    end)

    :ok
  end

  defp resolve_link!(documents, source, destination) do
    cond do
      String.starts_with?(destination, ["http://", "https://", "mailto:", "//"]) ->
        :ok

      String.contains?(destination, "?") ->
        raise Invalid, "#{source}: unsupported local Markdown query destination"

      true ->
        [raw_target | rest] = String.split(destination, "#", parts: 2)
        fragment = List.first(rest)
        resolve_local!(documents, source, destination, raw_target, fragment)
    end
  end

  defp resolve_local!(documents, source, destination, raw_target, fragment) do
    if String.starts_with?(raw_target, "/") do
      raise Invalid, "#{source}: local Markdown link escapes the repository"
    end

    target =
      case raw_target do
        "" -> source
        _other -> Paths.normalise(Paths.join(Paths.dirname(source), raw_target))
      end

    if target == ".." or String.starts_with?(target, "../") do
      raise Invalid, "#{source}: local Markdown link escapes the repository"
    end

    cond do
      String.ends_with?(raw_target, "/") ->
        prefix = Paths.strip_suffix(target, "/") <> "/"

        unless Enum.any?(Map.keys(documents), &String.starts_with?(&1, prefix)) do
          raise Invalid,
                "#{source}: local documentation directory does not resolve: #{destination}"
        end

      not Map.has_key?(documents, target) ->
        if String.ends_with?(raw_target, ".md") or fragment != nil do
          raise Invalid, "#{source}: local Markdown target does not resolve: #{destination}"
        end

      fragment != nil ->
        require_single_anchor!(documents, source, destination, target, fragment)

      true ->
        :ok
    end
  end

  defp require_single_anchor!(documents, source, destination, target, fragment) do
    anchor = ~s(<a id="#{fragment}"></a>)
    text = Map.fetch!(documents, target)
    lines = Markdown.lines(text, target)
    visible = Markdown.visible_line_numbers(text, target)

    count =
      visible
      |> Enum.map(&Markdown.occurrences(Enum.at(lines, &1), anchor))
      |> Enum.sum()

    unless count == 1 do
      raise Invalid,
            "#{source}: local Markdown fragment does not resolve exactly once: #{destination}"
    end

    :ok
  end
end
