defmodule Loopex.Executor.Local.CodingTools do
  @moduledoc """
  ## Concept

  The four tools an operator actually needs: `read`, `write`, `edit`, and
  `bash`. They act on a real workspace, and the three that take a path are
  confined to it.

  `bash` is not, and the difference is worth stating plainly rather than
  rounding off. It takes a command, not a path; a command names its own files,
  in a shell, at a time this module cannot inspect, so there is nothing here to
  resolve and compare. A `bash` call reaches everything the operator running
  Loopex reaches. What governs it is the host policy that decided the call, not
  this module — and
  [the operator guidance](../../../../docs/operator/tools-and-policy.md) says so
  in the same words, because a moduledoc claiming a containment the code does
  not perform is worse than no claim at all.

  For the three that do take a path, containment is the load-bearing property
  and is deliberately checked against the resolved path rather than the
  requested one. A path that looks contained can leave the workspace through
  `..`, through an absolute path, or through a symlink that points elsewhere —
  and the last of those is invisible to any amount of string inspection.
  Resolving first and comparing afterwards is the only check that catches all
  three. Resolution and effect are not one kernel operation; the residual window
  is recorded at
  [`M2-recorded-limitations.md`](../../../../docs/evidence/M2-recorded-limitations.md).

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept).

  ## Technical depth

  `read` returns bounded content and says when it truncated. `write` creates or
  replaces a file beneath the root. `edit` replaces an exact match and, on a
  mismatch, says what it found instead of failing blankly — a diagnostic a model
  can act on is the difference between one retry and five.

  `bash` runs either an argv vector or an explicit raw shell string, and the two
  are different operations rather than one with a convenience. An argv vector is
  passed through without a shell, so no character in an argument is interpreted;
  a raw command asks for a shell and gets one. Collapsing them would mean a
  caller who supplied arguments safely could still be surprised by a `$` in a
  filename.

  Every child runs in its own process group, and termination signals the group
  rather than the leader. A leader that spawned children and exited would
  otherwise leave them running with nobody's name on them.
  """

  alias Loopex.ArtifactStore

  @read_bytes 65_536
  @output_bytes 65_536

  @definitions [
    %{
      "tool_id" => "loopex.read",
      "tool_version" => "1.0.0",
      "name" => "read",
      "description" =>
        "Read a UTF-8 text file beneath the workspace root. Returns bounded content and reports truncation.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the workspace root."}
        },
        "required" => ["path"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "File contents."},
      "effect_class" => "read_only",
      "idempotency_class" => "safe_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => @read_bytes,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.write",
      "tool_version" => "1.0.0",
      "name" => "write",
      "description" =>
        "Create or replace a file beneath the workspace root with the exact content given.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the workspace root."},
          "content" => %{"type" => "string", "description" => "Exact bytes to write."}
        },
        "required" => ["path", "content"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What was written."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "safe_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 4_096,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.edit",
      "tool_version" => "1.0.0",
      "name" => "edit",
      "description" =>
        "Replace one exact occurrence of a string in a file. Fails and reports what it found if the match is absent or ambiguous.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the workspace root."},
          "old" => %{"type" => "string", "description" => "Exact text to replace."},
          "new" => %{"type" => "string", "description" => "Replacement text."}
        },
        "required" => ["path", "old", "new"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What changed."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "never_blind_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 4_096,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.bash",
      "tool_version" => "1.0.0",
      "name" => "bash",
      "description" =>
        "Run a command in the workspace. Supply argv for no shell interpretation, or command for an explicit shell.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "argv" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Program and arguments, run without a shell."
          },
          "command" => %{
            "type" => "string",
            "description" => "A raw shell command, interpreted by the shell."
          }
        },
        "required" => []
      },
      "result_shape" => %{"content_type" => "text", "description" => "Combined output."},
      "effect_class" => "process",
      "idempotency_class" => "never_blind_retry",
      "budgets" => %{
        "wall_time_ms" => 120_000,
        "output_bytes" => @output_bytes,
        "artifact_bytes" => 8_388_608
      }
    }
  ]

  @doc """
  ## Concept

  The four shipped coding tool definitions.

  ## Technical depth

  Reference-distribution declarations in the reserved `loopex.` namespace. A
  host composes a runtime with these, or with its own; the registry admits a
  reserved identifier only through a runtime's configured tool set.
  """
  @spec definitions() :: [map()]
  def definitions, do: @definitions

  @doc """
  ## Concept

  Whether this tool identifier is one of the four.

  ## Technical depth

  Used by the executor to route a job, so an unknown identifier is refused
  rather than falling through to a default handler.
  """
  @spec known?(binary()) :: boolean()
  def known?(tool_id), do: Enum.any?(@definitions, &(&1["tool_id"] == tool_id))

  @doc """
  ## Concept

  Resolves a requested path inside the workspace, or refuses it.

  ## Technical depth

  The requested path is joined to the root and then *fully resolved*, following
  symlinks, before it is compared with the resolved root. A relative escape, an
  absolute path, and a symlink that points outside all fail the same comparison,
  which is why the check is one comparison rather than three string rules that
  each miss a case the others catch.

  A path that does not exist yet resolves its parent instead, so `write` can
  create a file while still being confined: the file is not there to resolve,
  but the directory it would live in is.
  """
  @spec resolve(binary(), term()) :: {:ok, binary()} | {:error, term()}
  def resolve(root, path) when is_binary(root) and is_binary(path) do
    with {:ok, resolved_root} <- real_path(root) do
      candidate = Path.expand(path, resolved_root)

      with {:ok, resolved} <- resolve_existing_prefix(candidate) do
        if contained?(resolved, resolved_root),
          do: {:ok, resolved},
          else: {:error, {:path_escapes_workspace, path}}
      end
    end
  end

  def resolve(_root, path), do: {:error, {:invalid_path, path}}

  # Concept: resolve as far as the filesystem actually goes, then keep the rest.
  #
  # Technical depth: `write` may create a file, and the directories above it, so
  # the path it names need not exist yet. Walking up to the deepest ancestor that
  # does exist and resolving *that* is what lets containment be checked on a path
  # that is partly hypothetical. `Path.expand/2` has already normalised away every
  # `..`, so the segments appended back are literal names and cannot reintroduce
  # an escape.
  defp resolve_existing_prefix(candidate) do
    case real_path(candidate) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, :enoent} ->
        parent = Path.dirname(candidate)

        if parent == candidate do
          {:error, :enoent}
        else
          case resolve_existing_prefix(parent) do
            {:ok, resolved_parent} ->
              {:ok, Path.join(resolved_parent, Path.basename(candidate))}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: containment is a path comparison, not a prefix comparison on text.
  #
  # Technical depth: comparing the resolved strings with a separator appended
  # stops `/work` from appearing to contain `/workspace-elsewhere`, which a bare
  # `String.starts_with?` would admit.
  defp contained?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp real_path(path), do: follow(path)

  # Concept: a symlink is resolved to what it points at, not merely noticed.
  #
  # Technical depth: this used to confirm the target existed and then resolve the
  # link's own parent plus its basename -- which is the link's location, not its
  # destination. A final-component symlink out of the workspace therefore
  # resolved to a contained path and passed the containment check, so
  # `read leak` returned an outside file and `write leak` overwrote one. Only a
  # symlinked *directory* was caught, because the parent walk happened to resolve
  # that one.
  #
  # The chain is followed to what actually exists, and the hop count is bounded
  # because a symlink loop is a filesystem an operator can create by accident and
  # must not hang a tool.
  @symlink_hops 32

  defp follow(path), do: follow(path, @symlink_hops)

  defp follow(_path, 0), do: {:error, :symlink_loop}

  defp follow(path, hops) do
    case :file.read_link_all(path) do
      {:ok, target} ->
        target
        |> List.to_string()
        |> resolve_target(path)
        |> follow(hops - 1)

      {:error, :einval} ->
        absolute_existing(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: a relative link is relative to the directory holding the link.
  defp resolve_target("/" <> _rest = absolute, _link), do: absolute
  defp resolve_target(relative, link), do: Path.join(Path.dirname(link), relative)

  # Concept: resolve what actually exists on disk, without moving the VM.
  #
  # Technical depth: `Path.expand/1` is textual and would happily normalise a
  # `..` that a symlink makes meaningless, so the walk below resolves each
  # component against the kernel instead. It used to reach that answer by
  # `File.cd!`-ing into the directory and reading the working directory back.
  # The working directory is global to the emulator, not local to a process, so
  # two runtimes resolving paths at the same time read each other's answer: a
  # write bound for one workspace landed in the other, the containment check
  # passed because it compared against the borrowed root, and a resolution racing
  # the restore could return the ambient directory and put the file outside every
  # workspace. Nothing here mutates process-global state now, so concurrent
  # resolution is simply concurrent.
  # Concept: the path the kernel would open, one component at a time.
  #
  # Technical depth: each component is checked for a symlink and replaced by its
  # target before the next is considered, because `..` after a symlink means the
  # parent of the link's target and not the parent of the link. The hop count
  # bounds a symlink cycle, which the filesystem permits and this walk would
  # otherwise follow forever.
  @symlink_hops 32

  defp walk_links([], resolved, _hops), do: {:ok, resolved}

  defp walk_links(_remaining, _resolved, hops) when hops > @symlink_hops,
    do: {:error, :symlink_hops_exhausted}

  defp walk_links(["/" | rest], resolved, hops), do: walk_links(rest, resolved, hops)
  defp walk_links(["." | rest], resolved, hops), do: walk_links(rest, resolved, hops)

  defp walk_links([".." | rest], resolved, hops),
    do: walk_links(rest, Path.dirname(resolved), hops)

  defp walk_links([segment | rest], resolved, hops) do
    candidate = Path.join(resolved, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        absolute =
          case Path.type(target) do
            :absolute -> target
            _relative -> Path.join(resolved, target)
          end

        walk_links(Path.split(absolute) ++ rest, "/", hops + 1)

      {:error, _not_a_symlink} ->
        walk_links(rest, candidate, hops)
    end
  end

  defp absolute_existing(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} ->
        walk_links(Path.split(expanded), "/", 0)

      {:ok, _stat} ->
        parent = Path.dirname(expanded)

        case absolute_existing(parent) do
          {:ok, resolved_parent} -> {:ok, Path.join(resolved_parent, Path.basename(expanded))}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Bounds a tool's output and says what it left out.

  ## Technical depth

  Returns the bounded content and, where it truncated, the complete bytes so a
  caller can spill them to the artifact store. Truncation is reported to the
  model rather than performed silently, because a model shown a partial result
  with no marker reasons about it as though it were whole.
  """
  @spec bound_output(binary(), pos_integer()) ::
          {:complete, binary()} | {:truncated, binary(), binary()}
  def bound_output(content, limit) when is_binary(content) and is_integer(limit) do
    if byte_size(content) <= limit do
      {:complete, content}
    else
      {:truncated, binary_part(content, 0, limit), content}
    end
  end

  @doc """
  ## Concept

  The model-facing result for a bounded read or run.

  ## Technical depth

  When output spilled, the notice names the total and the artifact reference.
  When it did not, the content stands alone, because a notice on complete output
  would be noise a model learns to skip.
  """
  @spec present(binary() | {:truncated, binary(), non_neg_integer(), map()}) :: binary()
  def present({:truncated, kept, total, reference}),
    do: ArtifactStore.truncation_notice(kept, total, reference)

  def present(content) when is_binary(content), do: content

  @doc """
  ## Concept

  The read ceiling and the run-output ceiling.

  ## Technical depth

  Exposed so a conformance case asserts against the declared value rather than a
  number transcribed into the test.
  """
  @spec limits() :: %{read_bytes: pos_integer(), output_bytes: pos_integer()}
  def limits, do: %{read_bytes: @read_bytes, output_bytes: @output_bytes}
end
