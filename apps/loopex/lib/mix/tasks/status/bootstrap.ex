defmodule Loopex.Checks.Bootstrap do
  @moduledoc """
  ## Concept

  Structural assertions for the client adapters. `AGENTS.md` is the canonical
  tool-neutral contract; a vendor directory is an entry point that must defer to
  it. These checks prove the deferral is real: every adapter file loads the
  contract first and the context map second, no adapter pins an account-specific
  model, protected workflows require explicit invocation, and the hosted wrapper
  stays a thin caller of the repository command.

  What is being protected is that no policy lives only in a vendor directory. An
  adapter that reordered its pointers, added its own instructions, or widened a
  sandbox would be redefining authority in a place the contract does not govern.

  ## Technical depth

  Read-only, and reads tracked content only. A Git worktree created under a
  scanned directory puts a whole second copy of the repository inside it, so
  enumeration goes through the index rather than through a directory walk — the
  same reason the shell entrypoint's content scans use the index.

  The configuration formats are parsed by the repository's own readers rather than
  matched as text, because these assertions are about key sets and exact values:
  "this profile declares exactly these keys" cannot be answered by a search.
  """

  alias Loopex.Checks.Json
  alias Loopex.Checks.Toml

  @routing_guidance "routing and version-specific technical guidance"
  @stale_routing [
    "routing and current stage guidance",
    "routing and current-stage guidance",
    "routing and current milestone guidance",
    "routing and current-milestone guidance"
  ]

  @contract_pointer "AGENTS.md"
  @context_pointer "docs/developer/agent-context-map.md"

  @heredoc_free [
    "scripts/check-bootstrap.sh",
    "scripts/check-agent-bootstrap.sh",
    "scripts/check-gitignore.sh"
  ]

  @expected_sandboxes %{
    "mechanical_worker" => "workspace-write",
    "milestone_worker" => "workspace-write",
    "release_architect" => "read-only",
    "release_reviewer" => "read-only"
  }

  @allowed_role_keys MapSet.new([
                       "name",
                       "description",
                       "model_reasoning_effort",
                       "sandbox_mode",
                       "developer_instructions"
                     ])

  @role_prologue "Authority loads first: `AGENTS.md`, then " <>
                   "`docs/developer/agent-context-map.md` for routing and version-specific technical guidance. " <>
                   "This profile only frames the assigned role."

  @expected_claude_agents [".claude/agents/conformance-author.md", ".claude/agents/reviewer.md"]

  @protected_skills ["gate", "close-milestone"]

  @deny_path_tools ["Read", "Edit"]
  @inert_path_tools ["Grep", "Glob", "Write", "NotebookEdit"]

  @workflow ".github/workflows/agent-bootstrap.yml"
  @workflow_structure [
    "name: agent-bootstrap",
    "on:",
    "  push:",
    "    branches: [main]",
    "  pull_request:",
    "jobs:",
    "  seed-checks:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "        with:",
    "          fetch-depth: 0",
    "      - run: bash scripts/check-bootstrap.sh"
  ]

  @noncanonical [
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

  @doc """
  ## Concept

  Runs every adapter assertion against a repository root and returns the failures.

  ## Technical depth

  Accumulates reasons rather than stopping at the first, because these assertions
  are independent: an operator fixing a Codex profile should also see the Claude
  agent defect in the same run rather than discovering it on the next.
  """
  @spec check(Path.t()) :: [String.t()]
  def check(root) do
    heredoc_reasons(root) ++
      codex_reasons(root) ++
      claude_reasons(root) ++
      skill_reasons(root) ++
      workflow_reasons(root)
  end

  # Concept: a bootstrap shell check must not depend on a writable temporary file.
  # Technical depth: a here-document is materialised by the shell, so a read-only
  # reviewer with no writable temporary directory could not run the aggregate.
  defp heredoc_reasons(root) do
    Enum.flat_map(@heredoc_free, fn relative ->
      case read(root, relative) do
        {:ok, text} ->
          case String.contains?(text, "<<") do
            true -> ["#{relative}: bootstrap shell checks must not use here-documents"]
            false -> []
          end

        {:error, reason} ->
          [reason]
      end
    end)
  end

  defp codex_reasons(root) do
    with {:ok, text} <- read(root, ".codex/config.toml"),
         {:ok, config} <- decode_toml(text, ".codex/config.toml") do
      feature_reasons(config) ++
        pointer_reasons(text, ".codex/config.toml") ++
        role_reasons(root, config)
    else
      {:error, reason} -> [reason]
    end
  end

  defp feature_reasons(config) do
    case config |> Map.get("features", %{}) |> Map.get("multi_agent_v2") do
      true ->
        []

      other ->
        [
          ".codex/config.toml: multi_agent_v2 must remain enabled until removal is proven, " <>
            "found #{inspect(other)}"
        ]
    end
  end

  # Concept: the contract loads before the context map, in every adapter file.
  # Technical depth: order is compared by first occurrence, which is what a reader
  # of the file encounters; a later mention does not restore the ordering.
  defp pointer_reasons(text, label) do
    contract = index_of(text, @contract_pointer)
    context = index_of(text, @context_pointer)
    normalised = normalise(text)

    Enum.reject(
      [
        if(contract == nil or context == nil, do: "#{label}: missing a canonical pointer"),
        if(contract != nil and context != nil and contract >= context,
          do: "#{label}: must route #{@contract_pointer} before #{@context_pointer}"
        ),
        unless(String.contains?(normalised, @routing_guidance),
          do: "#{label}: missing the canonical routing guidance"
        ),
        stale_reason(normalised, label)
      ],
      &is_nil/1
    )
  end

  defp stale_reason(normalised, label) do
    case Enum.find(@stale_routing, &String.contains?(normalised, &1)) do
      nil -> nil
      stale -> "#{label}: carries stale status-routing guidance #{inspect(stale)}"
    end
  end

  defp role_reasons(root, config) do
    roles = Map.get(config, "agents", %{})

    case MapSet.new(Map.keys(roles)) == MapSet.new(Map.keys(@expected_sandboxes)) do
      false ->
        [".codex/config.toml: unexpected Codex roles #{inspect(Enum.sort(Map.keys(roles)))}"]

      true ->
        Enum.flat_map(Enum.sort(roles), fn {key, entry} ->
          role_profile_reasons(root, key, entry)
        end)
    end
  end

  defp role_profile_reasons(root, key, entry) do
    relative = Path.join(".codex", Map.get(entry, "config_file", ""))

    with {:ok, text} <- read(root, relative),
         {:ok, profile} <- decode_toml(text, relative) do
      instructions = profile |> Map.get("developer_instructions", "") |> String.trim()

      Enum.reject(
        [
          unless(Map.get(profile, "name") == key,
            do: "#{relative}: declares name #{inspect(Map.get(profile, "name"))}, expected #{key}"
          ),
          unless(Map.get(profile, "description") == Map.get(entry, "description"),
            do: "#{relative}: description drifts from the registry entry"
          ),
          if(instructions == "", do: "#{relative}: has no developer instructions"),
          unless(
            instructions == "" or
              String.starts_with?(normalise_spaces(instructions), @role_prologue),
            do: "#{relative}: canonical context prologue is missing or out of order"
          ),
          unless(Map.get(profile, "sandbox_mode") == Map.fetch!(@expected_sandboxes, key),
            do: "#{relative}: sandbox drift, found #{inspect(Map.get(profile, "sandbox_mode"))}"
          ),
          unless(MapSet.new(Map.keys(profile)) == @allowed_role_keys,
            do:
              "#{relative}: unexpected role configuration #{inspect(Enum.sort(Map.keys(profile)))}"
          ),
          if(Map.has_key?(profile, "model"), do: "#{relative}: carries a project-local model pin")
        ],
        &is_nil/1
      )
    else
      {:error, reason} -> [reason]
    end
  end

  defp claude_reasons(root) do
    settings_reasons(root) ++ claude_agent_reasons(root)
  end

  # Concept: path deny rules exist only where the client consults them.
  # Technical depth: Claude Code consults path rules for Read and Edit only — Read
  # rules cover Grep and Glob reads, Edit rules cover every file-editing tool. A
  # path rule on another tool is accepted, never consulted, and warns at startup,
  # so its presence is a defect rather than extra protection.
  defp settings_reasons(root) do
    with {:ok, text} <- read(root, ".claude/settings.json"),
         {:ok, settings} <- decode_json(text, ".claude/settings.json") do
      denies =
        settings |> Map.get("permissions", %{}) |> Map.get("deny", []) |> MapSet.new()

      required =
        Enum.reject(@deny_path_tools, &MapSet.member?(denies, "#{&1}(~/.loopex/**)"))

      inert = Enum.filter(@inert_path_tools, &MapSet.member?(denies, "#{&1}(~/.loopex/**)"))

      Enum.map(required, &".claude/settings.json: missing the real-home deny rule for #{&1}") ++
        Enum.map(
          inert,
          &".claude/settings.json: #{&1}(~/.loopex/**) is an inert path rule; use Read or Edit"
        )
    else
      {:error, reason} -> [reason]
    end
  end

  defp claude_agent_reasons(root) do
    found = tracked(root, ".claude/agents") |> Enum.filter(&String.ends_with?(&1, ".md"))

    case Enum.sort(found) == @expected_claude_agents do
      false ->
        [".claude/agents: unexpected Claude agents #{inspect(Enum.sort(found))}"]

      true ->
        Enum.flat_map(found, &claude_agent_file_reasons(root, &1))
    end
  end

  defp claude_agent_file_reasons(root, relative) do
    with {:ok, text} <- read(root, relative),
         {:ok, fields, body} <- frontmatter(text, relative) do
      pointer_reasons(body, relative) ++
        Enum.reject(
          [
            unless(Map.get(fields, "model", "inherit") == "inherit",
              do: "#{relative}: carries a project-local model pin"
            ),
            reviewer_reason(relative, fields)
          ],
          &is_nil/1
        )
    else
      {:error, reason} -> [reason]
    end
  end

  defp reviewer_reason(relative, fields) do
    case Path.basename(relative) do
      "reviewer.md" ->
        tools = fields |> Map.get("tools", "") |> String.split(",") |> Enum.map(&String.trim/1)

        cond do
          tools != ["Read", "Grep", "Glob"] -> "#{relative}: reviewer tools #{inspect(tools)}"
          Map.get(fields, "permissionMode") != "plan" -> "#{relative}: reviewer permissionMode"
          true -> nil
        end

      _other ->
        nil
    end
  end

  defp skill_reasons(root) do
    root
    |> tracked(".agents/skills")
    |> Enum.filter(&String.ends_with?(&1, "/SKILL.md"))
    |> Enum.sort()
    |> Enum.flat_map(&skill_file_reasons(root, &1))
  end

  defp skill_file_reasons(root, relative) do
    with {:ok, text} <- read(root, relative),
         {:ok, fields, body} <- frontmatter(text, relative) do
      name = relative |> Path.dirname() |> Path.basename()

      pointer_reasons(body, relative) ++
        case name in @protected_skills do
          true -> protected_skill_reasons(root, relative, fields)
          false -> unprotected_skill_reasons(relative, fields)
        end
    else
      {:error, reason} -> [reason]
    end
  end

  defp unprotected_skill_reasons(relative, fields) do
    case Map.has_key?(fields, "disable-model-invocation") do
      true -> ["#{relative}: unexpected client invocation extension"]
      false -> []
    end
  end

  # Concept: a protected workflow runs only when a person asks for it by name.
  # Technical depth: both clients must agree. Claude reads a frontmatter field;
  # Codex reads a nested policy mapping, and the nesting is checked because a
  # top-level key with the same name would be inert.
  defp protected_skill_reasons(root, relative, fields) do
    claude =
      case Map.get(fields, "disable-model-invocation") do
        "true" -> []
        _other -> ["#{relative}: protected workflow must require explicit invocation"]
      end

    metadata_path = Path.join(Path.dirname(relative), "agents/openai.yaml")

    codex =
      case read(root, metadata_path) do
        {:error, reason} ->
          [reason]

        {:ok, metadata} ->
          lines = String.split(metadata, "\n")
          policy_index = Enum.find_index(lines, &(&1 == "policy:"))
          invocation = Enum.filter(lines, &String.contains?(&1, "allow_implicit_invocation:"))

          Enum.reject(
            [
              unless(Enum.count(lines, &(&1 == "policy:")) == 1,
                do: "#{metadata_path}: must contain exactly one policy mapping"
              ),
              unless(invocation == ["  allow_implicit_invocation: false"],
                do: "#{metadata_path}: protected workflow must require explicit invocation"
              ),
              unless(
                policy_index != nil and invocation != [] and
                  Enum.at(lines, policy_index + 1) == hd(invocation),
                do: "#{metadata_path}: invocation policy must be nested under policy"
              )
            ],
            &is_nil/1
          )
      end

    claude ++ codex
  end

  # Concept: the hosted wrapper invokes the repository command and does nothing
  # else.
  # Technical depth: compared as an exact structural line list with comments and
  # blank lines removed, so a step that added a policy, a cache, or a second
  # command cannot slip in while the wrapper still looks thin.
  defp workflow_reasons(root) do
    path = Path.join(root, @workflow)

    cond do
      not File.regular?(path) or symlink?(path) ->
        ["#{@workflow}: missing required regular-file hosted bootstrap wrapper"]

      true ->
        text = File.read!(path)

        cond do
          not String.valid?(text) or Enum.any?(@noncanonical, &String.contains?(text, &1)) ->
            ["#{@workflow}: hosted bootstrap wrapper must use canonical UTF-8/LF bytes"]

          true ->
            structure =
              text
              |> String.split("\n")
              |> Enum.reject(
                &(String.trim(&1) == "" or String.starts_with?(String.trim_leading(&1), "#"))
              )
              |> Enum.map(&String.trim_trailing/1)

            case structure == @workflow_structure do
              true ->
                []

              false ->
                ["#{@workflow}: must remain the exact thin wrapper, found #{inspect(structure)}"]
            end
        end
    end
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  @doc """
  ## Concept

  Reads a Markdown file's frontmatter fields and the body that follows it.

  ## Technical depth

  The fence must open on the first line and close on a later one; a duplicate key
  fails, because a client that read the second value would behave differently from
  a check that read the first.
  """
  @spec frontmatter(String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}, String.t()} | {:error, String.t()}
  def frontmatter(text, relative) do
    lines = String.split(text, "\n")

    with ["---" | rest] <- lines,
         end_index when is_integer(end_index) <- Enum.find_index(rest, &(&1 == "---")) do
      fields =
        rest
        |> Enum.take(end_index)
        |> Enum.filter(&String.contains?(&1, ":"))
        |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
          [key, value] = String.split(line, ":", parts: 2)
          key = String.trim(key)

          case Map.has_key?(acc, key) do
            true -> {:halt, {:error, "#{relative}: duplicate frontmatter key #{inspect(key)}"}}
            false -> {:cont, {:ok, Map.put(acc, key, String.trim(value))}}
          end
        end)

      case fields do
        {:ok, parsed} ->
          {:ok, parsed, rest |> Enum.drop(end_index + 1) |> Enum.join("\n")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, "#{relative}: unterminated frontmatter"}
      _other -> {:error, "#{relative}: missing frontmatter"}
    end
  end

  # Concept: enumeration reads the index, never a directory walk.
  # Technical depth: a Git worktree under a scanned directory is a second copy of
  # the repository, and a walk would read it as project content.
  defp tracked(root, prefix) do
    case System.cmd("git", ["ls-files", "-z", "--cached", "--", prefix], cd: root) do
      {output, 0} -> output |> String.split(<<0>>, trim: true)
      _other -> []
    end
  end

  defp read(root, relative) do
    case File.read(Path.join(root, relative)) do
      {:ok, text} -> {:ok, text}
      {:error, posix} -> {:error, "#{relative}: cannot be read (#{:file.format_error(posix)})"}
    end
  end

  defp decode_toml(text, label) do
    case Toml.decode(text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, "#{label}: is not readable TOML (#{reason})"}
    end
  end

  defp decode_json(text, label) do
    case Json.decode(text) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, "#{label}: top level must be an object"}
      {:error, reason} -> {:error, "#{label}: is not valid JSON (#{reason})"}
    end
  end

  defp index_of(text, needle) do
    case String.split(text, needle, parts: 2) do
      [before, _rest] -> byte_size(before)
      _other -> nil
    end
  end

  defp normalise(text), do: text |> normalise_spaces() |> String.downcase()

  defp normalise_spaces(text), do: text |> String.split() |> Enum.join(" ")
end
