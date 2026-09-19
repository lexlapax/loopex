#!/usr/bin/env bash
# Structural status validation on the accepted Elixir/OTP toolchain.
#
# Shell is not retired: the enduring development baseline is Git, shell and POSIX
# tools, and the accepted Elixir/OTP toolchain, so this stays a shell entrypoint
# that calls repository-owned Mix commands.
#
# Applies the current-tree checks to this checkout. The adversarial suite that
# proves they reject what they must runs with the ordinary test suite, not
# here, so it is not executed twice per check. Reads the current tree only and
# takes seconds; expect no silence longer than a minute.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# A project-defined Mix task runs whatever beams _build holds; compile first so
# a stale beam of a removed module can never answer for the current source.
mix compile
exec mix loopex.status
