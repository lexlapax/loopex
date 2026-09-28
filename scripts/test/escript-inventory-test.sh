#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/loopex-escript-inventory.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

python3 - "$fixture" <<'PY'
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
entries = [
    "logger/ebin/logger.app",
    "logger/ebin/Elixir.Logger.beam",
    "req_llm/ebin/req_llm.app",
    "req/ebin/req.app",
    "finch/ebin/finch.app",
]
for name, omitted in (("good", None), ("missing", "logger/ebin/logger.app")):
    with zipfile.ZipFile(root / name, "w") as archive:
        for entry in entries:
            if entry != omitted:
                archive.writestr(entry, b"fixture")
PY

python3 scripts/escript-inventory.py "$fixture/good" "$fixture/good" \
  >"$fixture/positive.log"
grep -q 'escript-inventory: PASS good' "$fixture/positive.log"
if python3 scripts/escript-inventory.py "$fixture/good" "$fixture/missing" \
  >"$fixture/negative.log" 2>&1; then
  echo 'escript-inventory-test: missing logger.app was accepted' >&2
  exit 1
fi
grep -q 'missing required applications' "$fixture/negative.log"
printf 'escript-inventory-test: PASS positive and missing-app controls\n'
