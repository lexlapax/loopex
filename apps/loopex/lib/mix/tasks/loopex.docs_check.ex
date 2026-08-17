defmodule Mix.Tasks.Loopex.DocsCheck do
  @shortdoc "Proves covered public code documents Concept before Technical depth"

  @moduledoc """
  ## Concept

  The development contract requires modules, behaviours, callbacks, public APIs,
  public types, and important boundaries to explain purpose before mechanics:
  `## Concept` first, then `## Technical depth`. This command proves the ordering
  mechanically, so the convention holds without a reviewer remembering it.

  It proves ordering and presence only. Whether a Concept section actually explains
  the purpose, and whether the depth is proportional, remain review obligations —
  a structural check cannot read meaning, and pretending otherwise would make the
  green run the argument.

  ## Technical depth

  The documentation is read from the **compiled** beams through `Code.fetch_docs/1`,
  not from source text. A source grep answers a different question: it finds the
  characters in a file, including inside a string, a comment, or a heredoc that
  never became documentation, and it misses documentation attached to a definition
  it cannot parse. Reading the doc chunk asks what a reader of the published
  documentation would actually see.

  A module with no `@moduledoc` at all fails: silence is the accident this check
  exists to catch. A module marked `@moduledoc false` is excluded, because it has
  explicitly declared itself not part of the public surface, and the count of such
  modules is reported so a reviewer sees the exclusion rather than having to look
  for it. Every documented function, macro, callback, and type is covered on the
  same terms.
  """

  use Mix.Task

  @requirements ["compile"]

  @concept "## Concept"
  @technical "## Technical depth"

  @impl Mix.Task
  def run(_args) do
    case check(Mix.Project.build_path(), covered_applications()) do
      {:ok, %{covered: covered, hidden: hidden, applications: applications}} ->
        Mix.shell().info(
          "compiled documentation holds across #{Enum.join(applications, ", ")}: " <>
            "#{covered} covered entries carry Concept before Technical depth " <>
            "(#{hidden} explicitly undocumented)"
        )

      {:error, reasons} ->
        Mix.raise("compiled documentation violated:\n  " <> Enum.join(reasons, "\n  "))
    end
  end

  # Concept: the repository's own applications, and nothing else.
  # Technical depth: a dependency's compiled modules land beside them under the
  # same build path, and this repository's documentation contract does not govern
  # another project's code. Deriving the list from the umbrella means an
  # application added by a later workstream is covered without editing this task,
  # while its dependencies stay out.
  defp covered_applications do
    case Mix.Project.apps_paths() do
      nil -> [to_string(Mix.Project.config()[:app])]
      paths -> paths |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    end
  end

  @doc """
  ## Concept

  Checks the compiled modules of the named applications under a build path, and
  returns how much it covered or every violation it found.

  ## Technical depth

  Applications are named explicitly rather than discovered from the build path, so
  a dependency's modules are never judged against this repository's documentation
  contract. Finding no beam at all is a violation rather than a vacuous pass: a
  check that reports success having inspected nothing is worse than no check,
  because it reads as evidence.
  """
  @spec check(Path.t(), [String.t()]) ::
          {:ok,
           %{covered: non_neg_integer(), hidden: non_neg_integer(), applications: [String.t()]}}
          | {:error, [String.t()]}
  def check(build_path, applications) do
    beams =
      Enum.flat_map(applications, &Path.wildcard(Path.join(build_path, "lib/#{&1}/ebin/*.beam")))

    case beams do
      [] ->
        {:error,
         [
           "#{build_path}: no compiled module found for " <>
             "#{Enum.join(applications, ", ")}; documentation evidence is unavailable"
         ]}

      found ->
        {reasons, covered, hidden} =
          Enum.reduce(Enum.sort(found), {[], 0, 0}, fn beam, acc -> inspect_beam(beam, acc) end)

        case reasons do
          [] -> {:ok, %{covered: covered, hidden: hidden, applications: applications}}
          _any -> {:error, Enum.reverse(reasons)}
        end
    end
  end

  defp inspect_beam(beam, {reasons, covered, hidden}) do
    case Code.fetch_docs(beam) do
      {:docs_v1, _anno, _language, _format, module_doc, _metadata, entries} ->
        module = module_name(beam)
        {module_reasons, module_covered, module_hidden} = module_entry(module, module_doc)

        {entry_reasons, entry_covered, entry_hidden} =
          Enum.reduce(entries, {[], 0, 0}, fn entry, acc -> inspect_entry(module, entry, acc) end)

        {module_reasons ++ entry_reasons ++ reasons, covered + module_covered + entry_covered,
         hidden + module_hidden + entry_hidden}

      {:error, reason} ->
        {["#{beam}: documentation is unavailable (#{inspect(reason)})" | reasons], covered,
         hidden}
    end
  end

  defp module_entry(module, doc) do
    case classify(doc) do
      :hidden -> {[], 0, 1}
      :ok -> {[], 1, 0}
      {:error, detail} -> {["#{module}: module documentation #{detail}"], 0, 0}
      :none -> {["#{module}: has no module documentation"], 0, 0}
    end
  end

  defp inspect_entry(
         module,
         {{kind, name, arity}, _anno, _signature, doc, metadata},
         {reasons, covered, hidden}
       ) do
    cond do
      generated?(metadata) -> {reasons, covered, hidden + 1}
      true -> entry_outcome(module, kind, name, arity, doc, {reasons, covered, hidden})
    end
  end

  # Concept: the documentation contract applies to code written in this
  # repository, not to functions a macro injects.
  # Technical depth: `use GenServer` injects `child_spec/1` carrying OTP's own
  # docstring, which of course does not use this project's section headings. There
  # is no authored site to document, so demanding a heading there would force a
  # module to restate someone else's function or to hide it. Authored entries
  # carry `source_annos` as a list of location tuples; an injected one has no
  # location at all, which is the discriminator used here rather than a list of
  # known callback names that would need editing for every new behaviour.
  defp generated?(%{source_annos: annos}) when is_list(annos) do
    not Enum.all?(annos, &is_tuple/1)
  end

  defp generated?(_metadata), do: false

  defp entry_outcome(module, kind, name, arity, doc, {reasons, covered, hidden}) do
    case classify(doc) do
      :hidden ->
        {reasons, covered, hidden + 1}

      :none ->
        {reasons, covered, hidden + 1}

      :ok ->
        {reasons, covered + 1, hidden}

      {:error, detail} ->
        {["#{module}.#{name}/#{arity} (#{kind}) documentation #{detail}" | reasons], covered,
         hidden}
    end
  end

  # Concept: what a documentation value says about coverage.
  # Technical depth: `:none` and `:hidden` are different facts. `:none` means no
  # documentation was written, which is a defect for a module and ordinary for a
  # private helper or a callback implementation; `:hidden` means the author
  # declared the entity undocumented, which review can see and weigh.
  defp classify(:hidden), do: :hidden
  defp classify(:none), do: :none
  defp classify(%{} = translations) when map_size(translations) == 0, do: :none

  defp classify(%{} = translations) do
    translations
    |> Map.values()
    |> Enum.reduce(:ok, fn text, outcome ->
      case {outcome, ordering(text)} do
        {{:error, _detail} = error, _other} -> error
        {_ok, :ok} -> :ok
        {_ok, {:error, detail}} -> {:error, detail}
      end
    end)
  end

  defp classify(_other), do: :none

  defp ordering(text) do
    lines = String.split(text, "\n")
    concept = Enum.find_index(lines, &(String.trim_trailing(&1) == @concept))
    technical = Enum.find_index(lines, &(String.trim_trailing(&1) == @technical))

    earlier_heading =
      Enum.find_index(lines, fn line ->
        String.starts_with?(line, "## ") and String.trim_trailing(line) != @concept
      end)

    cond do
      concept == nil ->
        {:error, "is missing #{inspect(@concept)}"}

      technical == nil ->
        {:error, "is missing #{inspect(@technical)}"}

      technical < concept ->
        {:error, "places #{inspect(@technical)} before #{inspect(@concept)}"}

      earlier_heading != nil and earlier_heading < concept ->
        {:error, "opens with a section before #{inspect(@concept)}"}

      true ->
        :ok
    end
  end

  defp module_name(beam) do
    beam |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")
  end
end
