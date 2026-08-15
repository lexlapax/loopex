#!/usr/bin/env bash
# Provider-neutral seed-bootstrap entrypoint. Hosted CI may mirror this exact
# repository-owned command, but local execution requires no hosted service.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
bash scripts/check-agent-bootstrap.sh
bash scripts/check-gitignore.sh
bash scripts/check-commit-messages.sh
bash scripts/check-repo-hygiene.sh
