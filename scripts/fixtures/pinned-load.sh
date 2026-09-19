#!/usr/bin/env bash
# Runs ExUnit cases under the contention a small hosted runner has: the test
# VM and eight busy-loop hogs pinned to four cores, one process fsyncing 8 MiB
# in a loop, the cases in a loop, counting failures and any run past its run
# deadline as a hang. This is how the launch-guard frame split was reproduced
# (2 in 34) and its fix confirmed (0 in 30); a change to the executor's OS
# boundary is run through it on a Linux host before merge. It is a
# developer tool, not a repository check: it needs taskset and a compiled
# test build in the current tree.
#
#   bash scripts/fixtures/pinned-load.sh apps/loopex_executor_local \
#     test/coding_tools_test.exs:4302 test/post_closure_hotfix_test.exs:786
#
# ITER (default 30), CPUS (default 0-3) and HOGS (default 8) are environment
# variables. Prints one line per run and a final count.
set -u
[ $# -ge 2 ] || { echo "usage: pinned-load.sh <app dir> <test spec>..." >&2; exit 2; }
command -v taskset >/dev/null || { echo "pinned-load.sh: taskset is required (Linux)" >&2; exit 2; }
app=$1
shift
ITER=${ITER:-30}
CPUS=${CPUS:-0-3}
HOGS=${HOGS:-8}
fsync_file=$(mktemp "${TMPDIR:-/tmp}/loopex-pinned-load.XXXXXX")
hogs=()
for _ in $(seq 1 "$HOGS"); do
  taskset -c "$CPUS" bash -c 'while :; do :; done' &
  hogs+=($!)
done
taskset -c "$CPUS" bash -c "while :; do dd if=/dev/zero of='$fsync_file' bs=1M count=8 oflag=dsync 2>/dev/null; done" &
hogs+=($!)
trap 'kill ${hogs[*]} 2>/dev/null; rm -f "$fsync_file"' EXIT
echo "pinned-load: cpus=$CPUS hogs=$HOGS iterations=$ITER specs=$*"
fails=0
hangs=0
for i in $(seq 1 "$ITER"); do
  start=$(date +%s)
  out=$(cd "$app" && taskset -c "$CPUS" mix test --no-compile "$@" 2>&1)
  dur=$(( $(date +%s) - start ))
  echo "run $i ${dur}s :: $(echo "$out" | grep -aE '^Result:|tests?, [0-9]+ failure' | tail -n 1)"
  if ! echo "$out" | grep -qaE '^Result: [0-9]+ passed|tests?, 0 failures'; then
    fails=$((fails + 1))
    echo "$out" | grep -aE '^\s+[0-9]+\) test|code:|left:|right:|TimeoutError' | head -8
  fi
  [ "$dur" -ge 60 ] && hangs=$((hangs + 1))
done
echo "pinned-load: fails=$fails hangs=$hangs of $ITER"
[ "$fails" -eq 0 ] && [ "$hangs" -eq 0 ]
