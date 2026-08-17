import Config

# Concept: per-runtime state never lives in application environment, so this
# file stays empty of runtime configuration on purpose. See the core-only lane
# in docs/plans/M0-gate.md, which fails if core reads runtime state from here.
