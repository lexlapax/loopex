#!/usr/bin/env bash
# Temporary Python bridge for structural status validation. M0 migrates this
# lane to the accepted Elixir/OTP toolchain and removes the Python prerequisite.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
python3 -B scripts/test_check_status.py --quiet
exec python3 -B scripts/check_status.py --root .
