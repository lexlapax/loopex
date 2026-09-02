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
  @max_host_label_bytes 1_024
  @unsafe_host_label_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @decision_keys [
    :decision_source,
    :expires_at,
    :issued_at,
    :manifest_digest,
    :revocation_state,
    :trust_scope,
    :workspace_ref
  ]
  @decision_sources ["interactive_operator", "host_supplied"]

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
          required(:issued_at) => binary(),
          required(:expires_at) => binary() | nil,
          required(:revocation_state) => binary()
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

  Validation is the same ordered first-match table `resolve/2` applies, so a
  manifest that fails here fails there for the same named reason.
  """
  @spec digest(term()) :: {:ok, binary(), [map()]} | {:error, atom(), map()}
  def digest(manifest) do
    with {:ok, entries, workspace} <- admit_manifest(manifest),
         {:ok, ordered} <- admit_entries(entries, workspace) do
      {:ok, manifest_digest(ordered, workspace), ordered}
    end
  end

  @doc """
  ## Concept

  Decides what this run stages, and why.

  ## Technical depth

  Resolution is one deterministic first-match table, not a set of independent
  predicates. When more than one condition is false, the order alone chooses the
  receipt:

  | Step | Failure |
  | --- | --- |
  | no manifest supplied | `declined(no_manifest)` |
  | outer manifest shell and exact member set | `manifest_rejected/invalid_manifest` |
  | zero-or-one entries, counted by cons cell | `invalid_manifest` or `too_many_entries` |
  | workspace shell and bounded members | `manifest_rejected/invalid_workspace` |
  | entry shell and bounded label | `entry_not_bounded_plain_data` |
  | permitted label, containment, declared size | the matching reason with its label |
  | per-resource byte ceiling | `over_limit` |
  | declared content digest | `declared_digest_mismatch` |
  | decision absent | `declined(no_decision)` |
  | decision shape, `revocation_state`, `expires_at` | `binding_changed/invalid_decision` |
  | manifest digest, then workspace | `digest_mismatch` then `workspace_mismatch` |

  Every shape check uses `map_size/1` and fixed `Map.fetch/2` calls. No step
  enumerates, sorts, or allocates a key list, so an enormous outer manifest,
  workspace, entry, or decision is refused without being traversed. The entries
  member is classified without `is_list/1` or `length/1`: only `[]` and a
  one-cons list ending in `[]` are admitted, observing a second cons yields
  `too_many_entries` immediately without visiting that entry or any later tail,
  and an improper tail is `invalid_manifest`.

  Byte limits use `byte_size/1` and are applied before any content is hashed, so
  an oversized body is never traversed merely to prove the digest it already
  cannot admit.

  M2's decision domain has no clock in it. `revocation_state` must be exactly
  `"active"` and `expires_at` must be exactly `nil`; every other value is an
  invalid decision rather than a separate revoked or expired disposition,
  because a decision whose own record says it is not good is one this stage
  cannot interpret rather than one it can date.
  """
  @spec resolve(term(), term()) ::
          {:staged, [binary()], map()} | {:declined, atom(), map()}
  def resolve(nil, _decision), do: {:declined, :no_manifest, %{}}

  def resolve(manifest, decision) do
    with {:ok, entries, workspace} <- admit_manifest(manifest),
         {:ok, ordered} <- admit_entries(entries, workspace) do
      resolve_decision(
        decision,
        manifest_digest(ordered, workspace),
        Map.fetch!(workspace, :workspace_ref),
        ordered
      )
    else
      {:error, reason, detail} -> {:declined, reason, detail}
    end
  end

  @doc """
  ## Concept

  The receipt journaled for whatever this run staged or declined.

  ## Technical depth

  A declined class is recorded as explicitly as an admitted one. An operator
  asking why the model ignored their `AGENTS.md` gets a reason from the journal
  rather than an absence they have to interpret. The revision distinguishes this
  exact closed disposition and detail set from ADR 0010's earlier open map.
  """
  @spec receipt(atom(), map()) :: map()
  def receipt(disposition, detail) do
    %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => Atom.to_string(disposition),
      "detail" => detail
    }
  end

  # Concept: the outer shell is judged before anything inside it.
  #
  # Technical depth: `map_size/1` plus two fixed fetches, so a manifest carrying
  # thousands of unexpected members is refused without allocating or sorting its
  # keys. Failure names the manifest itself and carries no label, because no
  # entry has been looked at.
  defp admit_manifest(manifest) when is_map(manifest) and not is_struct(manifest) do
    with 2 <- map_size(manifest),
         {:ok, entries} <- Map.fetch(manifest, :entries),
         {:ok, workspace} <- Map.fetch(manifest, :workspace) do
      {:ok, entries, workspace}
    else
      _rejected -> manifest_rejected("invalid_manifest")
    end
  end

  defp admit_manifest(_manifest), do: manifest_rejected("invalid_manifest")

  # Concept: M2 admits zero or one project resource, and says so before it looks
  # at either the workspace or the entry.
  #
  # Technical depth: this is the allocation-safe boundary. `is_list/1` and
  # `length/1` both walk the whole spine, so an enormous or improper supplied
  # list would be traversed just to learn it is too long. Matching one cons cell
  # at a time stops at the second, which is refused without that entry or any
  # later tail being inspected at all.
  defp admit_entries([], workspace) do
    with :ok <- admit_workspace(workspace), do: {:ok, []}
  end

  defp admit_entries([entry | tail], workspace) do
    case tail do
      [] -> with :ok <- admit_workspace(workspace), do: admit_entry(entry)
      [_second | _rest] -> manifest_rejected("too_many_entries")
      _improper -> manifest_rejected("invalid_manifest")
    end
  end

  defp admit_entries(_entries, _workspace), do: manifest_rejected("invalid_manifest")

  defp admit_workspace(workspace) do
    if valid_workspace?(workspace), do: :ok, else: manifest_rejected("invalid_workspace")
  end

  # Concept: the one admitted entry, checked in the order an operator would
  # want it explained.
  #
  # Technical depth: shell and label bounding come first and carry no label,
  # because there is not yet a trustworthy label to name. Every later failure
  # retains the actual bounded label. The byte ceiling is an O(1) `byte_size/1`
  # test applied before the content digest, so an oversized body is refused
  # without being hashed.
  defp admit_entry(entry) do
    with true <- is_map(entry) and not is_struct(entry) and map_size(entry) == 5,
         {:ok, label} <- Map.fetch(entry, :label),
         true <- valid_host_label?(label),
         {:ok, content} <- Map.fetch(entry, :content),
         {:ok, declared_size} <- Map.fetch(entry, :byte_size),
         {:ok, declared_digest} <- Map.fetch(entry, :content_digest),
         {:ok, contained} <- Map.fetch(entry, :contained),
         true <- is_binary(content) and is_integer(declared_size) and is_binary(declared_digest) do
      admit_entry_content(label, content, declared_size, declared_digest, contained)
    else
      _rejected -> manifest_rejected("entry_not_bounded_plain_data")
    end
  end

  defp admit_entry_content(label, content, declared_size, declared_digest, contained) do
    observed = byte_size(content)

    cond do
      label not in @permitted_labels ->
        manifest_rejected("unpermitted_label", label)

      contained != true ->
        manifest_rejected("entry_not_reported_contained", label)

      declared_size != observed ->
        manifest_rejected("declared_size_mismatch", label)

      observed > @per_resource_bytes ->
        {:error, :over_limit,
         %{
           "dimension" => "project_resource_bytes",
           "observed" => observed,
           "limit" => @per_resource_bytes,
           "label" => label
         }}

      declared_digest != Canonical.digest_bytes(content) ->
        manifest_rejected("declared_digest_mismatch", label)

      true ->
        {:ok,
         [
           %{
             label: label,
             content: content,
             byte_size: observed,
             content_digest: declared_digest,
             contained: true
           }
         ]}
    end
  end

  defp manifest_rejected(reason, label \\ nil),
    do: {:error, :manifest_rejected, %{"reason" => reason, "label" => label}}

  # Concept: the digest a decision binds names the workspace and the exact
  # resolved set.
  #
  # Technical depth: entries are canonicalized in label order, so the digest
  # does not depend on the order a host walked them in. Content bytes are not in
  # the preimage; their verified digests are, which is what makes an edited
  # resource produce a different manifest digest.
  defp manifest_digest(ordered, workspace) do
    Canonical.digest(%{
      "entries" =>
        Enum.map(ordered, fn entry ->
          %{
            "relative_label" => entry.label,
            "byte_size" => entry.byte_size,
            "content_digest" => entry.content_digest,
            "contained" => true
          }
        end),
      "workspace" => %{
        "workspace_ref" => Map.fetch!(workspace, :workspace_ref),
        "repository_origin" => Map.get(workspace, :repository_origin),
        "revision" => Map.get(workspace, :revision)
      }
    })
  end

  defp resolve_decision(nil, manifest_digest, _workspace_ref, _ordered),
    do: {:declined, :no_decision, %{"manifest_digest" => manifest_digest}}

  # Concept: an invalid decision, a decision for another manifest, and a
  # decision for another workspace are three different answers.
  #
  # Technical depth: the decision's own digest is retained only when it is
  # independently a valid SHA-256 value, so a malformed decision cannot smuggle
  # arbitrary bytes into the receipt. Digest mismatch is decided before
  # workspace mismatch, so a decision that differs in both is reported as
  # binding to a different manifest rather than to a different workspace.
  defp resolve_decision(decision, manifest_digest, workspace_ref, ordered) do
    decision_digest = decision_manifest_digest(decision)

    cond do
      not valid_decision?(decision) ->
        binding_changed("invalid_decision", manifest_digest, decision_digest)

      decision_digest != manifest_digest ->
        binding_changed("digest_mismatch", manifest_digest, decision_digest)

      Map.fetch!(decision, :workspace_ref) != workspace_ref ->
        binding_changed("workspace_mismatch", manifest_digest, decision_digest)

      true ->
        {:staged, Enum.map(ordered, &block/1),
         %{
           "manifest_digest" => manifest_digest,
           "decision_source" => Map.fetch!(decision, :decision_source),
           "workspace_ref" => Map.fetch!(decision, :workspace_ref),
           "entries" => Enum.map(ordered, &source_entry/1)
         }}
    end
  end

  defp binding_changed(reason, manifest_digest, decision_digest) do
    {:declined, :binding_changed,
     %{
       "reason" => reason,
       "expected_manifest_digest" => manifest_digest,
       "decision_manifest_digest" => decision_digest
     }}
  end

  defp decision_manifest_digest(decision) when is_map(decision) and not is_struct(decision) do
    case Map.fetch(decision, :manifest_digest) do
      {:ok, digest} -> if valid_digest?(digest), do: digest, else: nil
      :error -> nil
    end
  end

  defp decision_manifest_digest(_decision), do: nil

  # Technical depth: `map_size/1` and fixed fetches again, so an enormous
  # decision map is refused without its keys being enumerated. `revocation_state`
  # and `expires_at` are required members, so a host is entitled to have each
  # value mean something; M2 mints exactly `"active"` and `nil` and treats every
  # other value as a decision this stage cannot interpret.
  defp valid_decision?(decision) when is_map(decision) and not is_struct(decision) do
    map_size(decision) == length(@decision_keys) and
      Enum.all?(@decision_keys, &Map.has_key?(decision, &1)) and
      valid_digest?(Map.fetch!(decision, :manifest_digest)) and
      valid_host_label?(Map.fetch!(decision, :workspace_ref)) and
      Map.fetch!(decision, :trust_scope) == "project_resource" and
      Map.fetch!(decision, :decision_source) in @decision_sources and
      Map.fetch!(decision, :revocation_state) == "active" and
      Map.fetch!(decision, :expires_at) == nil and
      valid_issued_at?(Map.fetch!(decision, :issued_at))
  end

  defp valid_decision?(_decision), do: false

  defp valid_issued_at?(issued_at) do
    valid_host_label?(issued_at, 64) and
      match?({:ok, _instant, _offset}, DateTime.from_iso8601(issued_at))
  end

  # Concept: the workspace identity the digest binds.
  #
  # Technical depth: checked after the zero-or-one entries boundary, so a
  # manifest that is already refused for its entry shape is never reported as a
  # workspace failure.
  defp valid_workspace?(workspace) when is_map(workspace) and not is_struct(workspace) do
    map_size(workspace) == 3 and
      Map.has_key?(workspace, :workspace_ref) and
      Map.has_key?(workspace, :repository_origin) and
      Map.has_key?(workspace, :revision) and
      valid_host_label?(Map.fetch!(workspace, :workspace_ref)) and
      valid_optional_host_label?(Map.fetch!(workspace, :repository_origin)) and
      valid_optional_host_label?(Map.fetch!(workspace, :revision))
  end

  defp valid_workspace?(_workspace), do: false

  defp valid_digest?(value) when is_binary(value),
    do: String.match?(value, ~r/^[0-9a-f]{64}$/)

  defp valid_digest?(_value), do: false

  defp valid_optional_host_label?(nil), do: true
  defp valid_optional_host_label?(value), do: valid_host_label?(value)

  defp valid_host_label?(value, ceiling \\ @max_host_label_bytes)

  defp valid_host_label?(value, ceiling) when is_binary(value) do
    byte_size(value) in 1..ceiling and String.valid?(value) and
      not Regex.match?(@unsafe_host_label_codepoints, value)
  end

  defp valid_host_label?(_value, _ceiling), do: false

  # Concept: typed delimiters are input structure, not an authority boundary.
  #
  # Technical depth: an admitted block changes no tool set, no policy decision,
  # no bound, and no grant. It is text the model reads, marked so the model can
  # tell it from the operator's own words, and nothing about being inside these
  # delimiters grants anything.
  defp block(entry) do
    "<project_resource label=\"#{entry.label}\">\n#{entry.content}\n</project_resource>"
  end

  defp source_entry(entry) do
    %{
      "relative_label" => entry.label,
      "content_digest" => entry.content_digest,
      "byte_size" => entry.byte_size
    }
  end
end
