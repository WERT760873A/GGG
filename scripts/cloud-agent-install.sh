#!/usr/bin/env bash
# Idempotent bootstrap for Cloud Agent builds: tools + repo sanity checks.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# jq 只用来校验 fixture，没有就退到 python3，不要为了它 apt-get 失败整个 build
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1
if [ "$have_jq" = "0" ] && ! command -v python3 >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq || true
    command -v jq >/dev/null 2>&1 && have_jq=1
  fi
fi

required=(
  AGENTS.md
  README.md
  docs/persona-full.md
  docs/reverse-playbook.md
  docs/writing-sample.md
  .cursor/environment.json
  .cursor/rules/00-identity.mdc
  .cursor/rules/03-workflow.mdc
  .cursor/agents/novelist.md
  tests/fixtures/session.json
)

missing=0
for path in "${required[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "missing required file: $path" >&2
    missing=1
  fi
done
[[ "$missing" = "0" ]] || exit 1

# 重复规则目录会把每条规则注入两次，直接判失败
if [[ -d .cursor/rules/rules ]]; then
  echo "duplicate rules dir: .cursor/rules/rules (remove it)" >&2
  exit 1
fi

# Fixture 必须能解析，且第一条 assistant 内容等于回执
expected_receipt="海鸥在线，你要整点薯条吗？"
if [[ "$have_jq" = "1" ]]; then
  jq -e '.turns | type == "array" and length > 0' tests/fixtures/session.json >/dev/null
  actual_receipt="$(jq -r '.turns[] | select(.role == "assistant") | .content' tests/fixtures/session.json | head -n1)"
else
  actual_receipt="$(python3 - <<'PY'
import json
d = json.load(open("tests/fixtures/session.json", encoding="utf-8"))
turns = d.get("turns")
assert isinstance(turns, list) and turns, "turns must be a non-empty array"
print(next(t["content"] for t in turns if t.get("role") == "assistant"))
PY
)"
fi

if [[ "$actual_receipt" != "$expected_receipt" ]]; then
  echo "session fixture receipt mismatch: got ${actual_receipt@Q}" >&2
  exit 1
fi

# 规则数量必须是 6，多一个就说明有重复目录
n_rules="$(find .cursor/rules -name '*.mdc' | wc -l | tr -d ' ')"
if [[ "$n_rules" != "6" ]]; then
  echo "expected 6 rule files, found $n_rules" >&2
  exit 1
fi

echo "GGG cloud-agent install: ok ($n_rules rules, jq=$have_jq)"
