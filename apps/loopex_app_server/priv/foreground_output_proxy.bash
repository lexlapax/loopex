#!/bin/bash
# Concept: one trusted worker writes one already encoded LF record to inherited
# stdout. Control never enters that output and frame bytes never become code.
# Technical depth: Bash 3.2-compatible reads, disabled job control and exact
# child wait preserve a live leader as the authority for terminating its group.
exec 0<&- 2>/dev/null
set +m
nonce=$1
authorized=0
abort_group() {
  trap '' HUP INT PIPE TERM
  if [ "$authorized" = 1 ]; then
    kill -s KILL -- -"$$"
  fi
  exit 125
}
trap abort_group HUP INT PIPE TERM
case "$nonce" in ''|*[!0-9a-f]*) exit 125 ;; esac
[ "${#nonce}" = 32 ] || exit 125
printf 'READY %s %s\n' "$nonce" "$$" >&4 || exit 125
IFS= read -r -t 5 -u 3 control || exit 125
[ "$control" = "ALLOW $nonce" ] || exit 125
authorized=1
IFS= read -r -t 5 -u 3 header || abort_group
[ "${#header}" -le 80 ] || abort_group
case "$header" in "FRAME $nonce "*) size=${header#"FRAME $nonce "} ;; *) abort_group ;; esac
case "$size" in ''|0*|*[!0-9]*) abort_group ;; esac
[ "${#size}" -le 7 ] && [ "$size" -le 2097152 ] || abort_group
IFS= read -r -t 5 -u 3 payload || abort_group
[ "$(( ${#payload} + 1 ))" = "$size" ] || abort_group
frame=$payload$'\n'
unset payload
(
  exec 3<&-
  printf '%s' "$frame" || exit 125
  printf 'WRITTEN %s\n' "$nonce" >&4 || exit 125
) &
worker=$!
unset frame
printf 'STARTED %s %s\n' "$nonce" "$worker" >&4 || abort_group
IFS= read -r -t 5 -u 3 control || abort_group
[ "$control" = "CONTINUE $nonce" ] || abort_group
wait "$worker" || abort_group
printf 'JOINED %s %s\n' "$nonce" "$worker" >&4 || abort_group
IFS= read -r -t 5 -u 3 control || abort_group
[ "$control" = "STOP $nonce" ] || abort_group
abort_group
