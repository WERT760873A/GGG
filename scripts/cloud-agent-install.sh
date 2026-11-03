#!/usr/bin/env bash
# Idempotent bootstrap for Cloud Agent builds: tools + repo sanity checks.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
fi

required=(
  AGENTS.md
  README.md
  docs/persona-full.md
  .cursor/rules/00-identity.mdc
  .cursor/rules/03-workflow.mdc
  tests/fixtures/session.json
)

for path in "${required[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "missing required file: $path" >&2
    exit 1
  fi
done

# Fixture must parse and include the identity receipt used in AGENTS.md verification.
jq -e '.turns | type == "array" and length > 0' tests/fixtures/session.json >/dev/null
expected_receipt="海鸥在线，你要整点薯条吗？"
actual_receipt="$(jq -r '.turns[] | select(.role == "assistant") | .content' tests/fixtures/session.json | head -n1)"
if [[ "$actual_receipt" != "$expected_receipt" ]]; then
  echo "session fixture receipt mismatch: got ${actual_receipt@Q}" >&2
  exit 1
fi

echo "GGG cloud-agent install: ok"
