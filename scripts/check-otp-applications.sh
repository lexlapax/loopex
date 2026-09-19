#!/usr/bin/env bash
# Every application that calls an OTP application declares it. Mix prunes
# undeclared OTP applications from the code path, which the floor toolchain
# pair enforces and the current pair does not, so an undeclared call passes
# every current-pair run and fails on the floor. Reads the tree only.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

status=0
for app in apps/*/; do
  app=${app%/}
  [ -d "$app/lib" ] || continue
  declared=$(sed -n 's/.*extra_applications: \[\([^]]*\)\].*/\1/p' "$app/mix.exs" | tr -d ' ')
  for otp in crypto ssl public_key; do
    if grep -rqE ":${otp}\." "$app/lib"; then
      case ",$declared," in
        *",:$otp,"*) ;;
        *)
          echo "$app: calls :$otp but does not declare it in extra_applications" >&2
          status=1
          ;;
      esac
    fi
  done
done

[ "$status" -eq 0 ] && echo "otp applications check passed"
exit "$status"
