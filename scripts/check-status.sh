#!/usr/bin/env bash
# Structural status validation on the accepted Elixir/OTP toolchain.
#
# Shell is not retired: the enduring development baseline is Git, shell and POSIX
# tools, and the accepted Elixir/OTP toolchain, so this stays a shell entrypoint
# that calls repository-owned Mix commands.
#
# Two commands, for the two things the retired bridge did. The adversarial suite
# proves the checks reject the mutations they exist to reject; the validation
# command applies them to this checkout and its reachable history. Running only
# the second would leave a check that passes because it inspects nothing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mix test apps/loopex/test/status_check_test.exs apps/loopex/test/history_anchoring_test.exs
exec mix loopex.status
