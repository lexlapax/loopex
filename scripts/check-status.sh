#!/usr/bin/env bash
# Structural status validation on the accepted Elixir/OTP toolchain.
#
# Shell is not retired: the enduring development baseline is Git, shell and POSIX
# tools, and the accepted Elixir/OTP toolchain, so this stays a shell entrypoint
# that calls repository-owned Mix commands.
#
# Two commands, for the two things this check has to do. The adversarial suite
# proves the checks reject the mutations they exist to reject; the validation
# command applies them to this checkout. Running only the second would leave a
# check that passes because it inspects nothing.
#
# Both commands read the current tree only and take seconds; neither walks Git
# history. Expect no silence longer than a minute.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mix test apps/loopex/test/status_check_test.exs
exec mix loopex.status
