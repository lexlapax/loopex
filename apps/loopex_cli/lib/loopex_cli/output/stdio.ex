defmodule LoopexCli.Output.Stdio do
  @moduledoc """
  ## Concept

  The inherited-terminal output target. One fixed Bash writer per command
  copies exact rendered bytes to the command's own standard output or standard
  error, so a blocked or broken terminal stays inside a process this command
  owns and can retire.

  ## Technical depth

  Accepted ADR 0068 selects executable `/bin/bash` with Bash 3.2-compatible
  fixed script text, an explicit credential-free environment and the actual
  inherited fd 1 and fd 2. The port uses private fd 3 for control and payload
  and fd 4 for acknowledgements. A write is one header line naming the nonce,
  sequence, destination descriptor and byte count, followed by exactly that
  many raw bytes; POSIX `dd` reads them in one-byte input blocks into a copier
  that writes the whole record, so NUL, LF and invalid UTF-8 reach the
  destination unchanged and Bash never holds payload in a variable. `WRITTEN`
  follows the copier's write. The writer leads its own process group; loss of
  its owner or of its leader kills that group from inside, and retirement
  kills that group and proves it absent through a bounded process-table read.
  Output never supplies shell syntax, paths, environment or descriptors.
  """

  # Concept: the writer accepts only its own nonce and two fixed descriptors,
  # and its whole group dies with its owner or its leader, even mid-write.
  # Technical depth: `read -r -u 3` consumes a pipe byte by byte, so the header
  # never over-reads payload; `dd ibs=1 count=N` reads exactly N bytes into a
  # copier whose `obs=262144` holds the whole bounded record before its one
  # physical write. The leader is never blocked by the destination and is back
  # on control while the copier writes, so owner loss (control EOF) kills the
  # group. A watcher holds the only read end of fd 5, whose write end only the
  # leader keeps; the leader's death, however it happens, gives the watcher EOF
  # and it kills the group. The copier sends `WRITTEN`. Any malformed control,
  # failed copy or failed acknowledgement kills the group.
  @script ~S"""
  exec 0<&-
  set +m
  nonce=$1
  abort_group() {
    trap '' HUP INT PIPE TERM
    kill -s KILL -- -"$$"
    exit 125
  }
  copy() {
    exec 3<&- 5>&-
    dd ibs=65536 obs=262144 >&"$2" 2>/dev/null || abort_group
    printf 'WRITTEN %s %s\n' "$nonce" "$1" >&4 || abort_group
  }
  trap abort_group HUP INT PIPE TERM
  case "$nonce" in ''|*[!0-9a-f]*) exit 125 ;; esac
  [ "${#nonce}" = 32 ] || exit 125
  exec 5> >(exec 3<&- 4>&-; read -r _; kill -s KILL -- -"$$") || exit 125
  printf 'READY %s %s\n' "$nonce" "$$" >&4 || exit 125
  while IFS= read -r -u 3 header; do
    case "$header" in
      "STOP $nonce") exit 0 ;;
      "WRITE $nonce "*) rest=${header#"WRITE $nonce "} ;;
      *) abort_group ;;
    esac
    sequence=${rest%% *}
    rest=${rest#* }
    target=${rest%% *}
    size=${rest#* }
    case "$sequence" in ''|*[!0-9]*) abort_group ;; esac
    case "$size" in ''|0*|*[!0-9]*) abort_group ;; esac
    [ "${#sequence}" -le 12 ] && [ "${#size}" -le 6 ] && [ "$size" -le 262144 ] || abort_group
    case "$target" in 1|2) ;; *) abort_group ;; esac
    dd ibs=1 obs=65536 count="$size" > >(copy "$sequence" "$target") <&3 4>&- 5>&- 2>/dev/null ||
      abort_group
  done
  abort_group
  """

  @control_bytes 512

  @doc false
  def control_bytes, do: @control_bytes

  @doc false
  @spec launch(binary()) :: {:ok, port(), pos_integer()} | :error
  def launch(nonce) do
    if File.regular?("/bin/bash") do
      port =
        Port.open({:spawn_executable, ~c"/bin/bash"}, [
          :binary,
          :exit_status,
          :nouse_stdio,
          :hide,
          {:busy_limits_port, :disabled},
          {:args,
           [~c"--noprofile", ~c"--norc", ~c"-c", String.to_charlist(@script), ~c"loopex-output"] ++
             [String.to_charlist(nonce)]},
          {:env, environment()}
        ])

      case Port.info(port, :os_pid) do
        {:os_pid, leader} when is_integer(leader) and leader > 0 -> {:ok, port, leader}
        _ -> close(port)
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  @doc false
  def write(port, nonce, sequence, destination, bytes) do
    fd = if destination == :stderr, do: "2", else: "1"

    command(port, [
      "WRITE ",
      nonce,
      " ",
      Integer.to_string(sequence),
      " ",
      fd,
      " ",
      Integer.to_string(byte_size(bytes)),
      "\n",
      bytes
    ])
  end

  @doc false
  def stop(port, nonce), do: command(port, ["STOP ", nonce, "\n"])

  @doc false
  def command(port, iodata) do
    Port.command(port, iodata)
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  def close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :error
  end

  # Concept: retirement removes every process that could still emit output.
  # Technical depth: the leader's actual PID is also its process-group ID; the
  # kill names that group, never a recycled bare PID.
  @doc false
  def kill_group(leader) when is_integer(leader) and leader > 0 do
    port =
      Port.open({:spawn_executable, ~c"/bin/kill"}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, [~c"-KILL", ~c"--", String.to_charlist("-#{leader}")]},
        {:env, environment()}
      ])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      1_000 -> close(port)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Concept: absence is observed, not assumed from a port closing.
  # Technical depth: one bounded `ps` read must list processes and show no
  # member of the writer's group before the supplied cutoff.
  @doc false
  def group_absent?(leader, cutoff) when is_integer(leader) and leader > 0 do
    remaining = cutoff - System.monotonic_time(:millisecond)

    if remaining > 2 do
      port =
        Port.open({:spawn_executable, ~c"/bin/ps"}, [
          :binary,
          :exit_status,
          :hide,
          {:args, [~c"-e", ~c"-o", ~c"pgid="]},
          {:env, environment()}
        ])

      case collect(port, [], System.monotonic_time(:millisecond) + min(1_000, remaining)) do
        {:ok, output} ->
          groups = String.split(output, ~r/\s+/, trim: true)
          groups != [] and Integer.to_string(leader) not in groups

        :error ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp collect(port, acc, deadline) do
    receive do
      {^port, {:data, bytes}} -> collect(port, [acc, bytes], deadline)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, _}} -> :error
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> close(port)
    end
  end

  @doc false
  def environment do
    clear = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}
    clear ++ [{~c"PATH", ~c"/usr/bin:/bin"}, {~c"LC_ALL", ~c"C"}]
  end
end
