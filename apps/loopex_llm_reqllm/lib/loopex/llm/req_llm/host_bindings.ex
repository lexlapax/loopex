defmodule Loopex.LLM.ReqLLM.HostBindings do
  @moduledoc """
  ## Concept

  Validate host credential references for composition and per-invocation route
  selection without reading values or starting provider work.

  ## Technical depth

  Both boundaries share ADR 0048's closed binding grammar, compiled provider
  catalog and operational-name exclusions. Selection uses the committed exact
  model's provider and never adds an ambient fallback to a supplied map.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards

  # Concept: operational names cannot serve as credential slots.
  # Technical depth: ADR 0048 permits narrower adapter exclusions. LC_ALL is
  # also reserved because reference-host placement probes require LC_ALL=C;
  # admitting it would conflict with removing every credential name at launch.
  @reserved ~w(LC_ALL PATH HOME TMPDIR TMP TEMP SHELL USER LOGNAME PWD OLDPWD SHLVL IFS CDPATH ENV BASH_ENV ZDOTDIR)
  @prefixes ~w(LD_ DYLD_ ERL_ ELIXIR_ MIX_ RELEASE_ BASH_ LOOPEX_)
  @legacy "LOOPEX_PROVIDER_API_KEY"
  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

  @doc """
  ## Concept

  Admit the complete route map without resolving any credential.

  ## Technical depth

  The returned host-only map contains original binary-key bindings and the
  exclusion set. Errors expose only a stable class and the provider field's
  JSON pointer, never a selected environment name or credential value.
  Credential-free bindings are valid only where the compiled adapter admits
  that profile; durable constructors must separately refuse them.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def validate(bindings) when is_map(bindings) and map_size(bindings) in 1..16 do
    catalog = Guards.binding_catalog()

    result =
      bindings
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.reduce_while({:ok, [@legacy]}, fn {provider, binding}, {:ok, names} ->
        case validate_route(provider, binding, catalog) do
          {:ok, nil} -> {:cont, {:ok, names}}
          {:ok, name} -> {:cont, {:ok, [name | names]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, names} ->
        {:ok, %{bindings: bindings, excluded_env_names: names |> Enum.uniq() |> Enum.sort()}}

      {:error, _} = error ->
        error
    end
  end

  def validate(_), do: {:error, {:invalid_provider_bindings, "/providers"}}

  @doc """
  ## Concept

  Check a credential slot's syntax and operational exclusions without reading it.

  ## Technical depth

  Names use at most 128 ASCII bytes. The sole operational-prefix exception is
  the released legacy provider key; validation is case-sensitive like the host
  environment. No case conversion or substitution occurs.
  """
  @spec valid_env_name?(term()) :: boolean()
  def valid_env_name?(name) when is_binary(name) and byte_size(name) in 1..128 do
    String.valid?(name) and Regex.match?(@name, name) and name not in @reserved and
      (name == @legacy or not Enum.any?(@prefixes, &String.starts_with?(name, &1)))
  end

  def valid_env_name?(_), do: false

  defp validate_route(provider, binding, catalog) when is_binary(provider) do
    case Map.fetch(catalog, provider) do
      {:ok, profile} -> validate_binding(binding, profile, "/providers/" <> provider)
      :error -> {:error, {:unsupported_provider, "/providers"}}
    end
  end

  defp validate_route(_, _, _), do: {:error, {:invalid_provider_bindings, "/providers"}}

  defp validate_binding(%{"credential" => credential} = binding, profile, pointer)
       when map_size(binding) == 1 do
    case credential do
      %{"env" => name} when map_size(credential) == 1 ->
        if valid_env_name?(name),
          do: {:ok, name},
          else: {:error, {:invalid_credential_reference, pointer <> "/credential/env"}}

      %{"none" => true} when map_size(credential) == 1 ->
        if profile.credential_required,
          do: {:error, {:credential_required, pointer <> "/credential"}},
          else: {:ok, nil}

      _ ->
        {:error, {:invalid_credential_binding, pointer <> "/credential"}}
    end
  end

  defp validate_binding(_, _, pointer),
    do: {:error, {:invalid_credential_binding, pointer}}

  @doc """
  ## Concept

  Select only the credential reference admitted for this request's provider.

  ## Technical depth

  Validate the entire map first, including unused routes. Nil denotes an
  explicitly credential-free binding. A missing route refuses; no environment
  value is read, deleted or copied by this function.
  """
  @spec select(term(), term()) :: {:ok, binary() | nil} | {:error, term()}
  def select(model, bindings) do
    with {:ok, _} <- validate(bindings),
         {:ok, selected} <- Guards.model(model),
         {:ok, binding} <- Map.fetch(bindings, Atom.to_string(selected.provider)) do
      case binding["credential"] do
        %{"env" => name} -> {:ok, name}
        %{"none" => true} -> {:ok, nil}
      end
    else
      :error -> {:error, :provider_route_unavailable}
      {:error, _} = error -> error
    end
  end
end
