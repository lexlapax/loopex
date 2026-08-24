defmodule Loopex.ProjectResource do
  @moduledoc """
  ## Concept

  Behaviour-shaping files from the operator's project reach the model only
  because the operator decided they should. Discovery is deliberately shallow
  and content-independent: the reference stage names exactly one resource,
  `AGENTS.md` at the root of the canonical workspace. There is no recursion, no
  globbing, no home-directory or history-derived resource, and no configured
  path list, so what can be admitted is knowable without reading anything.

  Content never extends the set either. An import, include, or link inside an
  admitted resource is inert text; a file cannot pull another file into the
  model's context by mentioning it.

  Failing closed here withholds *content*, never the runtime. A headless run with
  no matching decision stages the class empty, journals a declined receipt, and
  goes on to do the coding task. Refusing to start instead would make an absent
  decision look like a broken installation.

  Fixed by
  [ADR 0010](../../../../docs/adr/0010-provider-continuation-and-context-staging.md#concept).

  ## Technical depth

  Core never resolves, holds, or opens a filesystem path. The host or hand
  interprets `workspace_ref`, locates the root, resolves the resource, and
  enforces path containment; it hands core a manifest of supplied content. Core
  verifies that content against its declared digest and size, enforces the
  ceilings, orders the set, digests the manifest, and binds the trust decision.
  The relative label is a display string core never joins, resolves, or opens.

  Declared limits:

  | Limit | Value |
  | --- | --- |
  | `per_resource_bytes` | 64 KiB |
  | `class_total_bytes` | 64 KiB |

  An entry the supplier did not report as `contained` is refused rather than
  assumed contained, because containment is a fact only the side holding the
  path can establish.

  A decision binds one exact `manifest_digest`. A different workspace identity,
  a different revision where one is available, a resource added to or removed
  from the resolved set, or any changed content digest produces a different
  digest, so a decision bound to the old one admits nothing. That is the whole
  invalidation rule: there is no partial match and no staleness window.
  """

  alias LoopexProtocol.Canonical

  @permitted_labels ["AGENTS.md"]
  @per_resource_bytes 64 * 1024
  @class_total_bytes 64 * 1024

  @typedoc """
  ## Concept

  What a host supplies about the project resources it resolved.

  ## Technical depth

  Bounded plain data. `contained` is the supplier's own statement that the
  resolved path lies inside the workspace root; core cannot check it and refuses
  an entry that does not claim it.
  """
  @type manifest :: %{
          required(:entries) => [map()],
          required(:workspace) => map()
        }

  @typedoc """
  ## Concept

  The operator's decision about one exact manifest.

  ## Technical depth

  `expires_at` is null and `revocation_state` is `active` in M2; both exist so a
  later milestone can add expiry and revocation without changing the shape a
  decision is recorded in.
  """
  @type decision :: %{
          required(:manifest_digest) => binary(),
          required(:workspace_ref) => binary(),
          required(:trust_scope) => binary(),
          required(:decision_source) => binary(),
          optional(atom()) => term()
        }

  @doc """
  ## Concept

  The one resource label this stage will consider.

  ## Technical depth

  Exposed so a host and the conformance cases enumerate it from here rather than
  restating it. A manifest carrying any other label is refused whole rather than
  repaired, because a repaired manifest is one the operator never saw.
  """
  @spec permitted_labels() :: [binary()]
  def permitted_labels, do: @permitted_labels

  @doc """
  ## Concept

  The declared byte ceilings.

  ## Technical depth

  A resource above its ceiling, or a class total above its ceiling, fails closed
  with the observed sizes. Nothing is ever truncated into context: a partial
  instruction file is worse than none, because the model cannot tell it is
  reading half a sentence.
  """
  @spec limits() :: %{per_resource_bytes: pos_integer(), class_total_bytes: pos_integer()}
  def limits,
    do: %{per_resource_bytes: @per_resource_bytes, class_total_bytes: @class_total_bytes}

  @doc """
  ## Concept

  Validates a supplied manifest and computes the digest a decision binds.

  ## Technical depth

  Entries are ordered by their label so the digest does not depend on the order
  a host happened to walk them in. Every entry must carry a permitted label, a
  byte size matching its content, a content digest matching those exact bytes,
  and `contained: true`.
  """
  @spec digest(term()) :: {:ok, binary(), [map()]} | {:error, atom(), map()}
  def digest(%{entries: entries, workspace: %{workspace_ref: workspace_ref} = workspace})
      when is_list(entries) and is_binary(workspace_ref) do
    with :ok <- validate_entries(entries),
         :ok <- validate_sizes(entries) do
      ordered = Enum.sort_by(entries, & &1.label)

      manifest = %{
        "entries" =>
          Enum.map(ordered, fn entry ->
            %{
              "relative_label" => entry.label,
              "byte_size" => byte_size(entry.content),
              "content_digest" => Canonical.digest_bytes(entry.content),
              "contained" => true
            }
          end),
        "workspace" => %{
          "workspace_ref" => workspace_ref,
          "repository_origin" => Map.get(workspace, :repository_origin),
          "revision" => Map.get(workspace, :revision)
        }
      }

      {:ok, Canonical.digest(manifest), ordered}
    end
  end

  def digest(_manifest), do: {:error, :manifest_rejected, %{}}

  @doc """
  ## Concept

  Decides what this run stages, and why.

  ## Technical depth

  The resolution table is exhaustive and every outcome other than admission
  stages the class empty and journals a declined receipt naming its reason:

  | Observation | Resolution |
  | --- | --- |
  | Decision present and its digest matches | blocks staged |
  | No manifest supplied | `declined(no_manifest)` |
  | Manifest rejected | `declined(manifest_rejected)` |
  | Over a declared limit | `declined(over_limit)` with observed sizes |
  | No decision | `declined(no_decision)` |
  | Decision present, digest differs | `declined(binding_changed)` |

  A decision naming a different workspace is `binding_changed` too, since the
  workspace identity is inside the digested manifest.
  """
  @spec resolve(term(), term()) ::
          {:staged, [binary()], map()} | {:declined, atom(), map()}
  def resolve(nil, _decision), do: {:declined, :no_manifest, %{}}

  def resolve(manifest, decision) do
    case digest(manifest) do
      {:error, reason, detail} ->
        {:declined, reason, detail}

      {:ok, manifest_digest, ordered} ->
        case decision do
          %{manifest_digest: ^manifest_digest, trust_scope: "project_resource"} = admitted ->
            {:staged, Enum.map(ordered, &block/1),
             %{
               "manifest_digest" => manifest_digest,
               "decision_source" => Map.get(admitted, :decision_source, "host_supplied"),
               "labels" => Enum.map(ordered, & &1.label)
             }}

          %{manifest_digest: other} when is_binary(other) ->
            {:declined, :binding_changed, %{"expected" => manifest_digest, "decision" => other}}

          _absent ->
            {:declined, :no_decision, %{"manifest_digest" => manifest_digest}}
        end
    end
  end

  @doc """
  ## Concept

  The receipt journaled for whatever this run staged or declined.

  ## Technical depth

  A declined class is recorded as explicitly as an admitted one. An operator
  asking why the model ignored their `AGENTS.md` gets a reason from the journal
  rather than an absence they have to interpret.
  """
  @spec receipt(atom(), map()) :: map()
  def receipt(disposition, detail) do
    %{
      "class" => "project_resource",
      "disposition" => Atom.to_string(disposition),
      "detail" => detail
    }
  end

  # Concept: typed delimiters are input structure, not an authority boundary.
  #
  # Technical depth: an admitted block changes no tool set, no policy decision,
  # no bound, and no grant. It is text the model reads, marked so the model can
  # tell it from the operator's own words, and nothing about being inside these
  # delimiters grants anything.
  defp block(entry) do
    "<project_resource label=\"#{entry.label}\">\n#{entry.content}\n</project_resource>"
  end

  defp validate_entries([]), do: :ok

  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      cond do
        not (is_map(entry) and is_binary(Map.get(entry, :label)) and
                 is_binary(Map.get(entry, :content))) ->
          {:halt, {:error, :manifest_rejected, %{"reason" => "entry is not bounded plain data"}}}

        entry.label not in @permitted_labels ->
          {:halt,
           {:error, :manifest_rejected,
            %{"reason" => "unpermitted label", "label" => entry.label}}}

        Map.get(entry, :contained) != true ->
          {:halt,
           {:error, :manifest_rejected,
            %{"reason" => "entry was not reported contained", "label" => entry.label}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_sizes(entries) do
    total = Enum.reduce(entries, 0, &(byte_size(&1.content) + &2))

    oversized =
      Enum.find(entries, &(byte_size(&1.content) > @per_resource_bytes))

    cond do
      oversized ->
        {:error, :over_limit,
         %{
           "label" => oversized.label,
           "observed_bytes" => byte_size(oversized.content),
           "limit_bytes" => @per_resource_bytes
         }}

      total > @class_total_bytes ->
        {:error, :over_limit,
         %{"observed_total_bytes" => total, "limit_bytes" => @class_total_bytes}}

      true ->
        :ok
    end
  end
end
