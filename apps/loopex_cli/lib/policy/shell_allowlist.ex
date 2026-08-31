defmodule LoopexCli.Policy.ShellAllowlist do
  @moduledoc """
  ## Concept

  A host that lets a session read and change files, and lets it run only the
  shell commands the operator named in advance.

  This is a **scope** policy, not a sandbox. It answers "which commands did I
  agree to?" and nothing else. It is not a containment mechanism and must not be
  relied on as one: the leading word of a command is what it matches, so a
  compound command, a shell function, an alias, or an interpreter invoked with a
  script all reach past it trivially. Containment is the executor's boundary and
  the isolation the host places around it; this is the operator saying which
  work they meant.

  It exists because `allow-all` and a blanket refusal are the two stances that
  demonstrate nothing. A refusal is only meaningful where something else was
  permitted, and a task only continues truthfully after a refusal if the run was
  going somewhere in the first place.

  ## Technical depth

  Every non-shell tool is allowed. A `loopex.bash` call is allowed when the
  first whitespace-separated word of its command is in `permitted_commands/0`,
  and denied `:policy_denied` otherwise. A call carrying no readable
  command is denied rather than allowed, because a decision this policy cannot
  make is a decision it must not make in the model's favour.

  The list is fixed here rather than read from a flag or the environment.
  Authority that a run can widen is not authority, and a command line long
  enough to carry a policy is a command line an operator stops reading.

  Like every policy this command ships, it announces itself once so the stance
  a run is under is visible in the transcript rather than inferred from what
  happened to be refused.
  """

  @behaviour Loopex.Policy

  alias LoopexCli.Policy.Notice

  @permitted ["cat", "ls", "pwd", "echo", "git", "grep", "head", "tail", "wc"]
  @notice_key {__MODULE__, :notice}

  @doc """
  ## Concept

  The shell commands this stance permits.

  ## Technical depth

  Exposed so a caller reporting the stance enumerates it from here rather than
  restating it, and so the demonstration's transcript can name the exact list
  the run was decided against.
  """
  @spec permitted_commands() :: [binary()]
  def permitted_commands, do: @permitted

  @impl Loopex.Policy
  # Concept: a refusal names a category the port publishes, not one this stance
  # invented.
  #
  # Technical depth: this returned `:command_not_permitted` and
  # `:command_not_readable`, which read well and are in no published enumeration.
  # `Loopex.Policy` documents a closed set precisely so an operator reading a
  # denial gets a category they can act on rather than free text that varies by
  # host, and it now admits only that set -- so an invented category reaches the
  # operator as `:policy_unavailable`, which says the policy is broken when it
  # worked exactly as intended. `:policy_denied` is the true statement the
  # published set can carry: this stance refused it. The command itself is
  # already in the transcript, so the detail the old atom carried is not lost,
  # only moved to where it was always visible.
  def decide(%{generation: {"loopex.bash", _version, _digest}} = request) do
    notice()

    case leading_word(request) do
      {:ok, command} when command in @permitted -> {:allow, nil}
      {:ok, _other} -> {:deny, :policy_denied}
      :error -> {:deny, :policy_denied}
    end
  end

  def decide(_request) do
    notice()
    {:allow, nil}
  end

  defp leading_word(%{arguments: %{"command" => command}}) when is_binary(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      [first | _rest] -> {:ok, first}
      [] -> :error
    end
  end

  defp leading_word(_request), do: :error

  # Technical depth: once per operating-system process, so a run under this
  # stance says so without a line per tool call. The shared notice helper makes
  # that promise atomic across concurrent decisions.
  defp notice do
    Notice.once(@notice_key, fn ->
      IO.puts(
        :stderr,
        "loopex: the shell-allowlist host policy is active. Files may be read and " <>
          "changed, and only these shell commands are permitted: " <>
          Enum.join(@permitted, ", ") <>
          ". This is scope, not containment: it matches the leading word of a " <>
          "command and a compound command defeats it."
      )
    end)
  end
end
