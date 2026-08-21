defmodule Mix.Tasks.Loopex.M1Evidence do
  @shortdoc "Validates M1 negative-demonstration restoration evidence"

  @moduledoc """
  ## Concept

  Validates the retained negative demonstrations for M1. Each constitutional
  outcome names one disabled mechanism and observed failure, then binds that
  demonstration to a reachable committed artifact whose current bytes are the
  bytes restored after the mutation.

  This check proves structure and byte restoration. It cannot prove that the
  mutation was actually run or that the named failure was caused by it; closure
  review owns those truthfulness judgments.

  ## Technical depth

  The whole document is one fixed skeleton: one exact ATX title, then exact
  outcome 2, 3, 6, and 8 sections whose only content is one fenced, one-line JSON
  object. This leaves no Markdown interpretation surface in which another
  heading can render while escaping the inventory. The complete JSON reader
  rejects duplicate keys and malformed escapes, and the Git resolver requires
  the named candidate to be a reachable ancestor of `HEAD`.

  The five-key object binds a candidate, safe repository-relative artifact path,
  and SHA-256. Its review-facing descriptions use printable ASCII so a decoded
  control character cannot make the displayed claim disagree with the checked
  value. The candidate blob and current tracked regular-file bytes must both
  equal the recorded digest. A dirty or incorrectly restored artifact therefore
  fails instead of being certified by prose about a restoration.
  """

  use Mix.Task

  alias Loopex.Checks.Git
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Json
  alias Loopex.Checks.Markdown

  @evidence "docs/evidence/M1-negative-demonstrations.md"
  @outcomes [2, 3, 6, 8]
  @keys ~w(mechanism_disabled observed_failure candidate artifact restored_sha256)
  @sha ~r/\A[0-9a-f]{40}\z/u
  @digest ~r/\Asha256:([0-9a-f]{64})\z/u
  @safe_path ~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*\z/u

  @impl Mix.Task
  def run(args) do
    root = root(args)

    case check(root) do
      :ok -> Mix.shell().info("M1 negative evidence passed")
      {:error, reason} -> Mix.raise("M1 negative evidence failed: #{reason}")
    end
  end

  @doc """
  ## Concept

  Validates the canonical M1 negative-demonstration record in a checkout.

  ## Technical depth

  The working-tree reader additionally proves the artifact is tracked as an
  ordinary regular or executable file. Symlinks and untracked files are refused:
  their current bytes do not establish restoration of the committed artifact.
  """
  @spec check(Path.t()) :: :ok | {:error, String.t()}
  def check(root) do
    path = Path.join(root, @evidence)

    with {:ok, text} <- File.read(path) do
      validate(
        text,
        @evidence,
        Git.resolver(root),
        fn artifact -> current_blob(root, artifact) end
      )
    else
      {:error, posix} ->
        {:error, "#{@evidence}: #{:file.format_error(posix)}; evidence is unavailable"}
    end
  rescue
    error in Invalid -> {:error, Exception.message(error)}
  end

  @doc """
  ## Concept

  Validates one evidence document against supplied committed and current-byte
  readers.

  ## Technical depth

  Public for adversarial tests. The two readers keep Markdown/JSON structure
  independent from Git and filesystem setup, while `check/1` wires the same
  validator to the real repository boundaries.
  """
  @spec validate(
          binary(),
          String.t(),
          (String.t(), String.t() -> binary() | nil),
          (String.t() -> {:ok, binary()} | {:error, String.t()})
        ) :: :ok | {:error, String.t()}
  def validate(text, path, resolve_blob, read_current) do
    with :ok <- canonical_document(text, path),
         {:ok, records} <- evidence_records(text, path),
         :ok <- validate_outcomes(records, path, resolve_blob, read_current) do
      :ok
    end
  rescue
    error in Invalid -> {:error, Exception.message(error)}
  end

  defp root([]), do: repository_root()
  defp root(["--root", root]), do: root
  defp root(_args), do: Mix.raise("usage: mix loopex.m1_evidence [--root PATH]")

  defp repository_root do
    case Git.run(File.cwd!(), ["rev-parse", "--show-toplevel"]) do
      {output, 0} -> String.trim(output)
      _other -> File.cwd!()
    end
  end

  defp canonical_document(text, path) do
    if String.valid?(text) do
      Markdown.require_canonical!(text, path, "negative evidence")
    else
      raise Invalid, "#{path}: negative evidence must be UTF-8"
    end
  end

  defp evidence_records(text, path) do
    case Markdown.lines(text, path) do
      [
        "# M1 Negative Demonstrations",
        "",
        "## Outcome 2",
        "",
        "```json",
        outcome_2,
        "```",
        "",
        "## Outcome 3",
        "",
        "```json",
        outcome_3,
        "```",
        "",
        "## Outcome 6",
        "",
        "```json",
        outcome_6,
        "```",
        "",
        "## Outcome 8",
        "",
        "```json",
        outcome_8,
        "```",
        ""
      ] ->
        {:ok, Enum.zip(@outcomes, [outcome_2, outcome_3, outcome_6, outcome_8])}

      _other ->
        {:error,
         "#{path}: negative evidence must use the canonical fixed title-and-outcome skeleton"}
    end
  end

  defp validate_outcomes(records, path, resolve_blob, read_current) do
    Enum.reduce_while(records, :ok, fn {outcome, json}, :ok ->
      with {:ok, record} when is_map(record) <- Json.decode(json),
           :ok <- exact_keys(record, path, outcome),
           :ok <- validate_record(record, path, outcome, resolve_blob, read_current) do
        {:cont, :ok}
      else
        {:ok, _other} ->
          {:halt, {:error, "#{path}: outcome #{outcome} evidence must be one JSON object"}}

        {:error, reason} ->
          {:halt, {:error, "#{path}: outcome #{outcome} JSON or record is invalid: #{reason}"}}
      end
    end)
  end

  defp exact_keys(record, path, outcome) do
    case record |> Map.keys() |> Enum.sort() == Enum.sort(@keys) do
      true ->
        :ok

      false ->
        {:error, "#{path}: outcome #{outcome} must carry exactly #{Enum.join(@keys, ", ")}"}
    end
  end

  defp validate_record(record, path, outcome, resolve_blob, read_current) do
    mechanism = record["mechanism_disabled"]
    failure = record["observed_failure"]
    candidate = record["candidate"]
    artifact = record["artifact"]
    recorded = record["restored_sha256"]

    with :ok <- meaningful(mechanism, path, outcome, "mechanism_disabled"),
         :ok <- meaningful(failure, path, outcome, "observed_failure"),
         :ok <- valid_candidate(candidate, path, outcome),
         :ok <- safe_artifact(artifact, path, outcome),
         {:ok, digest} <- valid_digest(recorded, path, outcome),
         committed when is_binary(committed) <- resolve_blob.(candidate, artifact),
         :ok <- digest_matches(committed, digest, path, outcome, "candidate blob"),
         {:ok, current} <- read_current.(artifact),
         :ok <- digest_matches(current, digest, path, outcome, "current blob") do
      :ok
    else
      nil ->
        {:error, "#{path}: outcome #{outcome} candidate or artifact is not reachable from HEAD"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp meaningful(value, path, outcome, field) when is_binary(value) do
    normalised = value |> String.trim() |> String.downcase()

    cond do
      not printable_ascii?(value) ->
        {:error, "#{path}: outcome #{outcome} #{field} must use printable ASCII"}

      value != String.trim(value) ->
        {:error, "#{path}: outcome #{outcome} #{field} has surrounding whitespace"}

      normalised in ["", "-", "—", "tbd", "todo", "pending"] ->
        {:error, "#{path}: outcome #{outcome} #{field} is not populated"}

      not Regex.match?(~r/[[:alnum:]]/u, value) ->
        {:error, "#{path}: outcome #{outcome} #{field} is not populated"}

      true ->
        :ok
    end
  end

  defp meaningful(_value, path, outcome, field),
    do: {:error, "#{path}: outcome #{outcome} #{field} must be a string"}

  defp printable_ascii?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in 0x20..0x7E))
  end

  defp valid_candidate(value, path, outcome) when is_binary(value) do
    if Regex.match?(@sha, value),
      do: :ok,
      else: {:error, "#{path}: outcome #{outcome} candidate must be a full lowercase commit SHA"}
  end

  defp valid_candidate(_value, path, outcome),
    do: {:error, "#{path}: outcome #{outcome} candidate must be a string"}

  defp safe_artifact(value, path, outcome) when is_binary(value) do
    cond do
      not Regex.match?(@safe_path, value) ->
        {:error, "#{path}: outcome #{outcome} artifact is not a safe repository-relative path"}

      value in [".", ".."] or String.split(value, "/") |> Enum.any?(&(&1 in [".", ".."])) ->
        {:error, "#{path}: outcome #{outcome} artifact is not a safe repository-relative path"}

      ".git" in String.split(value, "/") ->
        {:error, "#{path}: outcome #{outcome} artifact may not name Git metadata"}

      true ->
        :ok
    end
  end

  defp safe_artifact(_value, path, outcome),
    do: {:error, "#{path}: outcome #{outcome} artifact must be a string"}

  defp valid_digest(value, path, outcome) when is_binary(value) do
    case Regex.run(@digest, value) do
      [_all, digest] -> {:ok, digest}
      nil -> {:error, "#{path}: outcome #{outcome} restored_sha256 is malformed"}
    end
  end

  defp valid_digest(_value, path, outcome),
    do: {:error, "#{path}: outcome #{outcome} restored_sha256 must be a string"}

  defp digest_matches(blob, digest, path, outcome, label) do
    case Markdown.digest(blob) == digest do
      true -> :ok
      false -> {:error, "#{path}: outcome #{outcome} #{label} does not match restored_sha256"}
    end
  end

  defp current_blob(root, artifact) do
    case Git.run(root, ["ls-files", "-s", "--error-unmatch", "--", artifact]) do
      {entry, 0} ->
        with [metadata, listed] <- String.split(String.trim_trailing(entry), "\t", parts: 2),
             [mode, _object, stage] <- String.split(metadata, " ", trim: true),
             true <- listed == artifact and stage == "0" and mode in ["100644", "100755"],
             {:ok, path} <- regular_path_without_symlink(root, artifact),
             {:ok, bytes} <- File.read(path) do
          {:ok, bytes}
        else
          _other -> {:error, "#{@evidence}: artifact #{artifact} is not a tracked regular file"}
        end

      {_output, _status} ->
        {:error, "#{@evidence}: artifact #{artifact} is not a tracked regular file"}
    end
  end

  defp regular_path_without_symlink(root, artifact) do
    walk_regular_path(root, String.split(artifact, "/"))
  end

  defp walk_regular_path(prefix, [name]) do
    path = Path.join(prefix, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _other -> :error
    end
  end

  defp walk_regular_path(prefix, [name | rest]) do
    path = Path.join(prefix, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk_regular_path(path, rest)
      _other -> :error
    end
  end
end
