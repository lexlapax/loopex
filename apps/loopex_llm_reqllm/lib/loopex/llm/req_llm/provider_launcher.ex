defmodule Loopex.LLM.ReqLLM.ProviderLauncher do
  @moduledoc false

  @excluded ~w(LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
    GOOGLE_API_KEY GEMINI_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN AZURE_OPENAI_API_KEY LD_PRELOAD LD_LIBRARY_PATH
    LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE LD_ORIGIN_PATH GLIBC_TUNABLES
    GCONV_PATH LOCPATH NLSPATH SSLKEYLOGFILE
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_ROOT_PATH
    DYLD_IMAGE_SUFFIX DYLD_SHARED_REGION
    DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH BASH_ENV ENV
    ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ERL_LIBS ERL_INETRC ERL_EPMD_PORT ERL_EPMD_ADDRESS
    ESCRIPT_EMULATOR EMU ROOTDIR BINDIR PROGNAME ELIXIR_ERL_OPTIONS
    ELIXIR_CLI_DRY_RUN MIX_ENV MIX_TARGET MIX_HOME HEX_HOME REBAR_CONFIG
    TIDEWAVE_REPL DOTENV_CONFIG_PATH HOME PATH CDPATH IFS SHELLOPTS BASHOPTS ZDOTDIR)

  # Concept: the first OS image receives no ambient credential or loader input.
  # Technical depth: env -i constrains only its subsequent exec. Port removals
  # therefore cover the host's name snapshot and unconditional known names.
  # As ADR 0019 states, the trusted host must not concurrently introduce other
  # environment names while this snapshot is being used.
  @doc false
  def spawn_environment do
    (Map.keys(System.get_env()) ++ @excluded)
    |> Enum.uniq()
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  @doc false
  def prepare do
    namespace = "/tmp/lxp-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    socket_path = namespace <> "/data"

    case File.mkdir(namespace) do
      :ok -> prepare_owned(namespace, socket_path)
      _refused -> {:error, :provider_launch_unavailable}
    end
  rescue
    _error -> {:error, :provider_launch_unavailable}
  end

  defp prepare_owned(namespace, socket_path) do
    with :ok <- File.chmod(namespace, 0o700),
         {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             {:ip, {:local, socket_path}},
             {:active, false},
             {:packet, :raw},
             {:backlog, 1}
           ]) do
      case File.chmod(socket_path, 0o600) do
        :ok ->
          {:ok, %{namespace: namespace, socket_path: socket_path, listener: listener}}

        _refused ->
          :gen_tcp.close(listener)
          abandon(namespace)
          {:error, :provider_launch_unavailable}
      end
    else
      _refused ->
        abandon(namespace)
        {:error, :provider_launch_unavailable}
    end
  end

  # Concept: namespace deletion is confined to this invocation's two names.
  # Technical depth: only the pre-launch caller or the live OS guard may remove
  # these entries. This function never recursively removes a pathname.
  @doc false
  def abandon(namespace) do
    _ = File.rm(namespace <> "/data")
    _ = File.rmdir(namespace)
    :ok
  end

  @doc false
  def start(namespace, configuration, nonce, cleanup_grace_ms, deadline) do
    {program, arguments} = vector(namespace, configuration, nonce, cleanup_grace_ms, deadline)

    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        {:args, arguments},
        {:env, spawn_environment()},
        {:line, 1_024},
        {:busy_limits_msgq, {4_096, 8_192}}
      ])

    # Once Port birth has happened, even bootstrap failure must retain that
    # exact handle. It cannot be relabelled a pre-launch namespace abandonment.
    carrier =
      case Port.info(port, :os_pid) do
        {:os_pid, carrier} when carrier > 1 -> carrier
        _unavailable -> nil
      end

    _sent =
      try do
        Port.command(port, "bootstrap:#{nonce}:#{cleanup_grace_ms}\n")
      catch
        _kind, _reason -> false
      end

    {:ok, %{port: port, carrier: carrier}}
  rescue
    _error -> {:error, :provider_launch_unavailable}
  end

  @doc false
  def vector(namespace, configuration, nonce, cleanup_grace_ms, deadline) do
    {"/usr/bin/env",
     [
       "-i",
       "PATH=/usr/bin:/bin",
       "LANG=C",
       "LC_ALL=C",
       "ERL_CRASH_DUMP=/dev/null",
       "ERL_CRASH_DUMP_SECONDS=0",
       "/bin/sh",
       "-c",
       carrier_program(),
       "loopex-provider-carrier",
       guard_program(),
       namespace.namespace,
       nonce,
       Integer.to_string(cleanup_grace_ms),
       configuration.interpreter_path,
       configuration.worker_path,
       namespace.socket_path,
       configuration.build_manifest_sha256,
       Integer.to_string(deadline)
     ]}
  end

  # Concept: destroying the direct Port image must leave a cleanup owner alive.
  # Technical depth: the disposable carrier and its independent guard remain in
  # the group created at Port birth. The carrier closes its control descriptors
  # immediately after the fork. Only the guard can consume control or answer it.
  # Group signals use the shell builtin's explicit `-s SIGNAL -- -PGID` form:
  # dash rejects `-SIGNAL --`, while omitting `--` misparses the negative PGID.
  # Keeping actuation in the live shell preserves its birth-group authority.
  # Wait retries use that shell's trapped-interruption flag: dash loses its job
  # table in command substitutions. A final status <=128 wins over a concurrent
  # trap; an untrapped signal exit remains final instead of being retried.
  defp carrier_program do
    ~S"""
    exec </dev/null >/dev/null 2>&1
    guard_program=$1
    shift
    trap 'wait_interrupted=1' TERM USR1
    /bin/sh -c "$guard_program" loopex-provider-guard "$$" "$@" 3<&3 4>&4 &
    guard_pid=$!
    exec 3<&- 4>&-
    while :; do
      wait_interrupted=0
      wait "$guard_pid"
      status=$?
      if [ "$status" -le 128 ] || [ "$wait_interrupted" -eq 0 ]; then
        break
      fi
    done
    [ "$status" -eq 0 ] && exit 0
    trap '' TERM
    kill -s TERM -- -"$$" 2>/dev/null
    kill -s KILL -- -"$$" 2>/dev/null
    exit 125
    """
  end

  # Concept: cleanup confirmation belongs to the live owner of the birth group.
  # Technical depth: a complete witnessed process table must show that only
  # the carrier, guard and known cleanup timer remain. The timer reaps its own
  # sleep before the guard acknowledges. Every inspection and namespace helper
  # runs under that one timer. An expired timer kills its still-anchored group;
  # because that also destroys the guard it can never produce a cleanup ACK.
  # Only a quiescence-authorized USR1 cancels the timer; generic termination
  # cannot disarm it. Its sole first external child is sleep, forked after trap
  # installation: observing that live child proves cancellation is armed. All
  # signals retain the live birth-group authority. Namespace failure always
  # exits unproved, even if a signal interrupts its timer wait.
  # Ignore generic termination before forking the timer, not in the newborn
  # timer: caught traps reset on fork, leaving a default-disposition window.
  # The timer and its sleeper retain these ignored dispositions; the guard
  # restores its own interruption traps after capturing the timer identity.
  defp guard_program do
    ~S"""
    group=$1 namespace=$2 nonce=$3 grace=$4
    shift 4
    interpreter=$1 worker=$2 socket=$3 manifest=$4 deadline=$5
    exec </dev/null >/dev/null 2>&1

    cleanup() {
      remaining=$1 stop_id=$2
      trap 'wait_interrupted=1' TERM HUP INT PIPE USR1
      kill -s TERM -- -"$group" 2>/dev/null
      if [ "${#remaining}" -gt 3 ]; then
        seconds=${remaining%???}
        millis=${remaining#"$seconds"}
        delay="$seconds.$millis"
      else
        delay=$(printf '0.%03d' "$remaining")
      fi
      trap '' TERM HUP INT PIPE
      (
        stopping=0
        trap 'stopping=1; wait_interrupted=1' USR1
        [ "$stopping" -eq 1 ] && exit 0
        /bin/sleep "$delay" &
        sleeper=$!
        if [ "$stopping" -eq 1 ]; then
          kill -s USR1 -- -"$group" 2>/dev/null
        fi
        while :; do
          wait_interrupted=0
          wait "$sleeper"
          sleeper_status=$?
          if [ "$sleeper_status" -le 128 ] || [ "$wait_interrupted" -eq 0 ]; then
            break
          fi
        done
        [ "$stopping" -eq 1 ] && exit 0
        kill -s KILL -- -"$group" 2>/dev/null
        exit 125
      ) 3<&- 4>&- &
      timer=$!
      trap 'wait_interrupted=1' TERM HUP INT PIPE USR1
      if /bin/rm -f "$socket" && /bin/rmdir "$namespace"; then
        :
      else
        while :; do
          wait_interrupted=0
          wait "$timer"
          timer_status=$?
          if [ "$timer_status" -le 128 ] || [ "$wait_interrupted" -eq 0 ]; then
            break
          fi
        done
        exit 125
      fi
      while :; do
        table=$(/bin/sh -c 'printf "%s\n" "$$"; exec /bin/ps -ax -o pid= -o ppid= -o pgid= -o stat=')
        status=$?
        if [ "$status" -eq 0 ] && printf '%s\n' "$table" | /usr/bin/awk \
          -v group="$group" -v guard="$$" -v carrier="$group" -v timer="$timer" '
          NR == 1 { if ($0 !~ /^[0-9]+$/) exit 2; witness=$0; next }
          NF != 4 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad=1; next }
          { parent[$1]=$2; groups[$1]=$3; states[$1]=$4 }
          END {
            if (bad || groups[witness] != group || groups[guard] != group || groups[timer] != group) exit 2
            for (pid in parent) if (parent[pid] == timer && groups[pid] == group && states[pid] !~ /^Z/) timer_started=1
            if (!timer_started) exit 1
            allowed[guard]=1; allowed[carrier]=1; allowed[witness]=1; timer_tree[timer]=1
            cursor=witness
            while (cursor != guard) {
              if (!parent[cursor] || seen[cursor]++ || groups[cursor] != group) exit 2
              allowed[cursor]=1; cursor=parent[cursor]
            }
            do { changed=0; for (pid in parent) if (timer_tree[parent[pid]] && !timer_tree[pid]) { timer_tree[pid]=1; changed=1 } } while (changed)
            for (pid in groups) if (groups[pid] == group && !allowed[pid] && !timer_tree[pid] && states[pid] !~ /^Z/) exit 1
            exit 0
          }'; then
          kill -s USR1 -- -"$group" 2>/dev/null
          while :; do
            wait_interrupted=0
            wait "$timer"
            timer_status=$?
            if [ "$timer_status" -le 128 ] || [ "$wait_interrupted" -eq 0 ]; then
              break
            fi
          done
          [ "$timer_status" -eq 0 ] || exit 125
          if [ -n "$stop_id" ]; then
            printf 'cleanup_complete:%s:%s\n' "$nonce" "$stop_id" >&4 || exit 125
          fi
          exit 0
        fi
        /bin/sleep 0.01
      done
    }

    lost_parent() { cleanup "$grace" ''; }
    stop_control() {
      rest=${control#"stop:$nonce:"}
      stop_id=${rest%%:*}
      remaining=${rest#*:}
      case "$stop_id" in ''|*[!0-9a-f]*) lost_parent ;; esac
      [ "${#stop_id}" -eq 32 ] || lost_parent
      case "$remaining" in ''|*[!0-9]*) lost_parent ;; esac
      [ "${#remaining}" -le 20 ] || lost_parent
      cleanup "$remaining" "$stop_id"
    }
    trap 'lost_parent' HUP INT PIPE TERM
    ulimit -c 0 || lost_parent
    IFS= read -r bootstrap <&3 || lost_parent
    [ "$bootstrap" = "bootstrap:$nonce:$grace" ] || lost_parent
    printf 'ready:%s:%s:%s:%s\n' "$nonce" "$group" "$$" "$namespace" >&4 || lost_parent
    IFS= read -r control <&3 || lost_parent
    case "$control" in
      "run:$nonce") ;;
      "stop:$nonce:"*) stop_control ;;
      *) lost_parent ;;
    esac
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
      "$interpreter" "$worker" "$socket" "$nonce" "$manifest" "$deadline" \
      3<&- 4>&- </dev/null >/dev/null 2>&1 &
    while IFS= read -r control <&3; do
      case "$control" in
        "stop:$nonce:"*)
          stop_control
          ;;
        *) lost_parent ;;
      esac
    done
    lost_parent
    """
  end
end
