defmodule Loopex.VmCodeSpikeTest do
  use ExUnit.Case, async: true

  alias Loopex.VmGeneration

  # Concept: outcome 6 is only satisfied if the generation stays out of the VM
  # running the test. A same-VM reload is the named anti-pattern, and it is
  # indistinguishable from the real thing unless something asserts the negative,
  # so every step that loads or rolls back is followed by this check.
  #
  # Technical depth: two independent questions. `:code.is_loaded/1` asks this VM's
  # code server whether the module is bound, and the apply asks whether the module
  # is *reachable* — the error handler searches this VM's code path, which a
  # generation compiled to a binary and never written to disk cannot be on. A
  # same-VM load fails the first; a stray compiled artifact on the path fails the
  # second.
  defp refute_reachable_here(module) do
    refute :code.is_loaded(module)

    assert_raise UndefinedFunctionError, fn -> apply(module, :generation, []) end
  end

  # Concept: each test names its own module, so "not loaded in the test VM" can
  # never be satisfied by accident or defeated by another test's load.
  #
  # Technical depth: the atom is constructed in trusted test code from a counter,
  # never from external input, so this is not the untrusted-atom case the
  # development contract forbids at boundaries.
  defp probe_module do
    :"loopex_generation_probe_#{System.unique_integer([:positive])}"
  end

  # Concept: an isolated VM is a real OS process, so every test that starts one
  # must stop it whether it passes, fails, or raises.
  #
  # Technical depth: `on_exit/1` runs in all three cases, and the VM is unlinked
  # so this callback is its only teardown path — nothing else can be mid-shutdown
  # when the stop is issued. If the whole test VM were killed before any callback
  # ran, the isolated VM would still halt on its own when the control pipe closed.
  defp isolated_vm do
    {:ok, vm} = VmGeneration.start_isolated_vm()
    on_exit(fn -> VmGeneration.stop_isolated_vm(vm) end)
    vm
  end

  test "a trusted generation loads and rolls back in an isolated VM" do
    module = probe_module()
    vm = isolated_vm()

    {:ok, generation_one} = VmGeneration.build_generation(module, 1)
    {:ok, generation_two} = VmGeneration.build_generation(module, 2)

    # Two conflicting generations of one module name now exist as artifacts and
    # neither is loaded anywhere. That is what makes them retainable.
    refute_reachable_here(module)
    refute VmGeneration.loaded?(vm, module)

    # The isolated VM is a separate BEAM OS process. Code loading is VM-global,
    # so this separation is the entire reason the rest of the test can hold.
    assert VmGeneration.call(vm, :os, :getpid, []) != :os.getpid()

    assert :ok = VmGeneration.load_generation(vm, generation_one)
    assert VmGeneration.loaded?(vm, module)
    assert VmGeneration.call(vm, module, :generation, []) == 1
    refute_reachable_here(module)

    # Replacing it with the conflicting generation changes behavior in the
    # isolated VM only.
    assert :ok = VmGeneration.load_generation(vm, generation_two)
    assert VmGeneration.call(vm, module, :generation, []) == 2
    refute_reachable_here(module)

    # Rollback, first sense: reload the retained earlier artifact and the earlier
    # behavior is observable again.
    assert :ok = VmGeneration.load_generation(vm, generation_one)
    assert VmGeneration.call(vm, module, :generation, []) == 1
    refute_reachable_here(module)

    # Rollback, second sense: withdraw the generation, and the isolated VM can no
    # longer reach the module at all.
    assert :ok = VmGeneration.unload_generation(vm, module)
    refute VmGeneration.loaded?(vm, module)
    assert catch_error(VmGeneration.call(vm, module, :generation, [])) == :undef

    refute_reachable_here(module)
  end

  test "conflicting generations of one module are current in separate isolated VMs" do
    module = probe_module()
    first_vm = isolated_vm()
    second_vm = isolated_vm()

    {:ok, generation_one} = VmGeneration.build_generation(module, 1)
    {:ok, generation_two} = VmGeneration.build_generation(module, 2)

    assert :ok = VmGeneration.load_generation(first_vm, generation_one)
    assert :ok = VmGeneration.load_generation(second_vm, generation_two)

    # One module name, two current generations, at the same time. No single BEAM
    # instance can do this, which is why conflicting generations need separate VMs.
    assert VmGeneration.call(first_vm, module, :generation, []) == 1
    assert VmGeneration.call(second_vm, module, :generation, []) == 2

    assert VmGeneration.call(first_vm, :os, :getpid, []) !=
             VmGeneration.call(second_vm, :os, :getpid, [])

    refute_reachable_here(module)
  end

  test "a built generation is inert until an isolated VM loads it" do
    module = probe_module()
    vm = isolated_vm()

    {:ok, artifact} = VmGeneration.build_generation(module, 1)

    assert artifact.module == module
    assert is_binary(artifact.binary)

    # Building is compilation, not loading. If this were untrue the manager VM
    # would hold every generation it ever built and the outcome would be
    # unprovable regardless of what the isolated VM did.
    refute_reachable_here(module)
    refute VmGeneration.loaded?(vm, module)
  end
end
