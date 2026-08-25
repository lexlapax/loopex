import Config

# Concept: per-runtime state never lives in application environment, so this
# file stays empty of runtime configuration on purpose. See the core-only lane
# in docs/plans/M0-gate.md, which fails if core reads runtime state from here.

# Concept: the built `loopex` command has to work when it is the only file an
# operator has.
#
# Technical depth: `llm_db` resolves a model specification from a snapshot it
# reads out of its own `priv` directory at runtime. An escript is a single
# archive, so that directory is not a path anything can read, and every real
# provider call from the built command failed with `:enotdir` while every test
# passed -- the tests run from a checkout where the directory exists. Setting
# the dependency's compile-time embedding puts the snapshot in the beam instead,
# which is what makes the packaged command resolve the same model identity the
# test lanes seal. It costs about five megabytes of escript.
#
# This is third-party build configuration and not Loopex runtime state. No
# Loopex application reads it, and the core-only lane still holds: per-runtime
# state never lives in application environment. See the core-only lane in
# docs/plans/M0-gate.md, which fails if core reads runtime state from here.
config :llm_db, compile_embed: true
