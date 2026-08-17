defmodule Loopex.VmGeneration do
  @moduledoc """
  ## Concept

  M0's feasibility spike for VM-global trusted-code evolution. It answers one
  question and claims nothing else: can a *code generation* — one compiled
  version of a module, produced and retained as an artifact — be loaded into a
  BEAM instance separate from the one coordinating the change, exercised there,
  and then rolled back, without the coordinating instance ever loading it?

  Loading code is VM-global. Two conflicting generations of the same module name
  cannot both be current in one BEAM instance, so the runtime that manages
  generations cannot also host the ones it is comparing or replacing. This module
  keeps those roles apart. The caller — the *manager* — builds artifacts and
  owns *isolated VMs*; only an isolated VM ever loads.

  Rollback has two senses here and both are demonstrated. Reloading a retained
  earlier artifact restores the earlier behavior, and withdrawing a generation
  removes it outright.

  An isolated VM is a **trust-neutral** boundary. It separates code generations;
  it is not a sandbox and constrains nothing the loaded code may do. Less-trusted
  code belongs behind the executor protocol in OS isolation instead.

  This is disposable experimental code under the accepted M0 plan. It is not an
  extension system, and it claims nothing about quiescent activation, atomic
  module-set loading, or exact rollback as governed capabilities; those need
  their own milestone and their own evidence.

  ## Technical depth

  An isolated VM is a separate `erl` OS process started through `:peer` (OTP 25+;
  the deprecated `:slave` is not used). Its control channel is the peer's
  standard input and output, so **distribution is deliberately not started**:
  no `epmd`, no `net_kernel`, no cookie, no hostname resolution, and no node
  name. Two consequences matter. Nothing is registered under a global name, so
  the handle returned by `start_isolated_vm/0` is the only reference to that VM,
  which is the explicit-runtime-reference invariant rather than a convention. And
  the isolation being claimed is OS-process separation of the BEAM instance,
  which `call/4` can prove directly by comparing `:os.getpid/0` across the
  boundary.

  The peer inherits no code path from the manager, so a generated module is
  unreachable there until it is loaded and unreachable again once withdrawn.

  `build_generation/2` compiles Erlang abstract forms with `:compile.forms/2`,
  which returns a BEAM binary and loads nothing. That is the property the whole
  approach rests on: `Code.compile_string/1` and friends load into the calling
  VM as a side effect, so using them would put the generation into the manager
  and destroy the claim before any peer was involved. The artifact is plain
  serializable data — a module name and a binary — which is also what makes
  "retain the prior generation and reload it" a real rollback rather than a
  recompilation.

  The handle holds the peer's control process pid. It is an in-memory runtime
  reference for this spike, not durable state and not boundary data, so the
  plain-data rule for journals and public contracts does not reach it.

  The isolated VM is started unlinked, so exactly one thing tears it down:
  `stop_isolated_vm/1`. A single owner is the point. Linking it to the starting
  process instead gives two teardown paths that race — an explicit stop issued
  while the link is already shutting the VM down fails on a VM that is going away
  correctly — and the failure lands in cleanup, after the assertions, where it
  reads as a defect in the mechanism rather than in the teardown.

  Being unlinked does not risk a stray VM. The control channel is a pipe from the
  manager process, so if the manager exits without stopping the VM the peer reads
  end-of-file on its standard input and halts itself. The guarantee holds even
  when the manager is killed outright and no cleanup runs at all.
  """

  @enforce_keys [:peer]
  defstruct [:peer]

  @typedoc """
  ## Concept

  A handle to one isolated VM. Holding it is the only way to reach that VM.

  ## Technical depth

  Wraps the `:peer` control process pid. There is no registered or global name to
  look the VM up by, so losing the handle strands the VM until the process that
  started it exits.
  """
  @type t :: %__MODULE__{peer: pid()}

  @typedoc """
  ## Concept

  One built code generation, retained so it can be loaded — or reloaded, which is
  how rollback to an earlier generation works.

  ## Technical depth

  Plain serializable data: the module name the generation defines, the generation
  number its `generation/0` function returns, and the compiled BEAM binary. It is
  inert; nothing is loaded until `load_generation/2` is called.
  """
  @type artifact :: %{module: module(), generation: integer(), binary: binary()}

  # Technical depth: an explicit bound rather than `:peer.call/4`'s `:infinity`.
  # An isolated VM that stops answering must fail the caller, because a hang here
  # would surface as a suite-level timeout with no indication of which call stuck.
  @call_timeout_ms 30_000

  @doc """
  ## Concept

  Starts an isolated VM and returns the handle that reaches it.

  ## Technical depth

  Starts a separate `erl` OS process via `:peer` with a standard-io control
  channel, so no distribution, node name, or `epmd` registration is involved.
  The VM is unlinked, so the caller must stop it with `stop_isolated_vm/1`;
  should the caller die without doing so, the VM halts on its own when the
  control pipe closes.
  """
  @spec start_isolated_vm() :: {:ok, t()} | {:error, term()}
  def start_isolated_vm do
    case :peer.start(%{connection: :standard_io}) do
      {:ok, peer, _node} -> {:ok, %__MODULE__{peer: peer}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Stops an isolated VM. Safe to call when it has already stopped.

  ## Technical depth

  `:peer.stop/1` exits with `:noproc` against a control process that is already
  gone. That happens when the VM died on its own — it crashed, or it halted
  because the control pipe closed — and the caller's goal is already met, so it
  is reported as success. Only `:noproc` is absorbed: any other exit means the
  stop itself went wrong and is left to propagate.
  """
  @spec stop_isolated_vm(t()) :: :ok
  def stop_isolated_vm(%__MODULE__{peer: peer}) do
    :peer.stop(peer)
  catch
    :exit, :noproc -> :ok
  end

  @doc """
  ## Concept

  Builds one code generation as a retained artifact, loading it nowhere.

  ## Technical depth

  Compiles the Erlang equivalent of

      -module(Module).
      -export([generation/0]).
      generation() -> Generation.

  from abstract forms. `:compile.forms/2` returns a binary without touching any
  code server, so calling this leaves the manager VM — and every isolated VM —
  without the module. Building the same module name at two different generations
  is the point: those artifacts conflict, and only separate VMs can hold them at
  once.
  """
  @spec build_generation(module(), integer()) :: {:ok, artifact()} | {:error, term()}
  def build_generation(module, generation) when is_atom(module) and is_integer(generation) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 2, :export, [{:generation, 0}]},
      {:function, 3, :generation, 0, [{:clause, 3, [], [], [{:integer, 3, generation}]}]}
    ]

    case :compile.forms(forms, [:return_errors]) do
      {:ok, ^module, binary} ->
        {:ok, %{module: module, generation: generation, binary: binary}}

      {:ok, ^module, binary, _warnings} ->
        {:ok, %{module: module, generation: generation, binary: binary}}

      {:error, errors, _warnings} ->
        {:error, errors}

      :error ->
        {:error, :compile_failed}
    end
  end

  @doc """
  ## Concept

  Loads a generation into one isolated VM, and only there. Loading a retained
  earlier artifact is how a rollback to that generation is performed.

  ## Technical depth

  Runs `:code.load_binary/3` inside the isolated VM, which makes the generation
  current there and demotes any generation already loaded to old code. Because
  the binary arrives as data and the code server that acts on it belongs to the
  peer, the manager VM is unaffected. The recorded filename is `nofile`: the
  artifact never existed on disk, and claiming a path would misreport where the
  code came from.
  """
  @spec load_generation(t(), artifact()) :: :ok | {:error, term()}
  def load_generation(%__MODULE__{} = vm, %{module: module, binary: binary}) do
    case call(vm, :code, :load_binary, [module, ~c"nofile", binary]) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Withdraws a generation from an isolated VM entirely, leaving the module
  unreachable there again.

  ## Technical depth

  Three steps, because BEAM keeps two generations per module. The first purge
  removes any old generation still lingering, `:code.delete/1` demotes the
  current generation to old and unbinds the name, and the second purge removes
  that. Each step's return says whether a process was killed or a module was
  present, which is history rather than the property being established; the
  property is that the module is no longer loaded, and the caller checks it with
  `loaded?/2`.
  """
  @spec unload_generation(t(), module()) :: :ok
  def unload_generation(%__MODULE__{} = vm, module) when is_atom(module) do
    _ = call(vm, :code, :purge, [module])
    _ = call(vm, :code, :delete, [module])
    _ = call(vm, :code, :purge, [module])
    :ok
  end

  @doc """
  ## Concept

  Whether a module is currently loaded in the given isolated VM.

  ## Technical depth

  Asks the isolated VM's own code server via `:code.is_loaded/1`, so the answer
  is about that VM and never about the caller's. The manager checks itself by
  calling `:code.is_loaded/1` directly, which is what keeps the two questions
  visibly distinct at the call site.
  """
  @spec loaded?(t(), module()) :: boolean()
  def loaded?(%__MODULE__{} = vm, module) when is_atom(module) do
    case call(vm, :code, :is_loaded, [module]) do
      {:file, _filename} -> true
      false -> false
    end
  end

  @doc """
  ## Concept

  Calls a function inside an isolated VM and returns its result.

  ## Technical depth

  Errors raised in the isolated VM are re-raised in the caller, so an
  `:undef` from a withdrawn generation surfaces as a caught error rather than a
  return value. The call is bounded by an explicit timeout instead of `:peer`'s
  default `:infinity`.
  """
  @spec call(t(), module(), atom(), [term()]) :: term()
  def call(%__MODULE__{peer: peer}, module, function, args)
      when is_atom(module) and is_atom(function) and is_list(args) do
    :peer.call(peer, module, function, args, @call_timeout_ms)
  end
end
