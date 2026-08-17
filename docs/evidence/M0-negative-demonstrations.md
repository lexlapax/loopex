# M0 Negative Demonstrations

A test that still passes when the behavior it covers is removed proved nothing,
and no locked name or minimum count detects that. For each constitutional
outcome this records the mechanism disabled, the resulting failure, and the
commit at which it was demonstrated.

Populated as outcomes 4, 5, and 6 are proved.

## Outcome 4 — journal replay

- mechanism disabled: —
- observed failure: —
- demonstrated at: —

## Outcome 5 — fencing and reconciliation

- mechanism disabled: —
- observed failure: —
- demonstrated at: —

## Outcome 6 — isolated VM load and rollback

- mechanism disabled: `load_generation/2` loaded the generation into the test VM as well as the isolated VM, which is the same-VM reload the gate names as the rejected anti-pattern
- observed failure: `apps/loopex/test/vm_code_spike_test.exs:18` — `Expected false or nil, got {:file, ~c"nofile"}`, code `refute :code.is_loaded(module)`
- demonstrated at: `7d54e8e`, reverted before commit and confirmed byte-identical by SHA-256 rather than by inspection

Three further variants were demonstrated at the same revision and are recorded
here because each fails a different assertion, which is what shows the test is
not passing for one incidental reason: loading into the manager VM instead of the
isolated VM failed `assert VmGeneration.loaded?(vm, module)`; making
`unload_generation/2` a no-op failed `refute VmGeneration.loaded?(vm, module)`;
and ignoring the generation number in `build_generation/2` failed the rollback
equality assertion with `left: 1, right: 2`.
