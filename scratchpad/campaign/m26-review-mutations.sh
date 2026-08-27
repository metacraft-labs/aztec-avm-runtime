#!/usr/bin/env bash
# M26's REVIEW mutations — one arm per assertion the review ADDED.
#
#   direnv exec <repo> bash scratchpad/campaign/m26-review-mutations.sh [<arm> ...]
#
# An added assertion is worth exactly what a mutation says it is worth. Each arm below corrupts the
# thing its assertion is about, and the arm is only satisfied if the NAMED assertion goes red —
# "the check failed" and "the check saw what I broke" are different statements.
#
# Same discipline as `m26-mutations.sh`: one at a time, backup + sha256, restore + verify restored,
# and a refusal to start beside a sweep.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"
OUT="${M26_MUT_OUT:-$HOME/.cache/aztec-m26-revmut}"
mkdir -p "$OUT" || exit 1

if pgrep -f 'just verify-m[0-9]' >/dev/null 2>&1 || pgrep -f 'm2[0-9]-sweep' >/dev/null 2>&1; then
  echo "REFUSING: a verification sweep looks like it is running; two writers over one working copy" >&2
  exit 2
fi

BACKUPS=()
restore_all() {
  local b f
  for b in "${BACKUPS[@]:-}"; do
    [ -n "$b" ] || continue
    f="${b#*::}"
    cp "$OUT/${b%%::*}" "$f" || echo "RESTORE-FAILED $f" >&2
    touch "$f"
  done
  BACKUPS=()
}
trap 'restore_all' EXIT INT TERM

backup() {
  local key
  key="$(printf '%s' "$1" | tr '/.' '__')"
  cp "$1" "$OUT/$key" || exit 1
  sha256sum "$1" | cut -d' ' -f1 > "$OUT/$key.sha"
  BACKUPS+=("$key::$1")
}

verify_restored() {
  local key want got
  key="$(printf '%s' "$1" | tr '/.' '__')"
  want="$(cat "$OUT/$key.sha")"
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    echo "!! NOT RESTORED: $1" >&2
    exit 3
  fi
  printf '   restored-and-verified %s\n' "$1"
}

run_check() {
  local arm="$1" check="$2" log="$OUT/$1.log"
  timeout --signal=TERM --kill-after=30 "${M26_MUT_TIMEOUT:-1800}" \
    "verification/$check.sh" > "$log" 2>&1
  local rc=$?
  printf '== %s  check=%s  rc=%s\n' "$arm" "$check" "$rc"
  printf '   summary: %s\n' "$(grep -E '^[A-Za-z_0-9 .-]+: [0-9]+ assertion' "$log" | tail -1)"
  printf '   red assertions:\n'
  grep '^  FAIL' "$log" | sed 's/^/     /' | head -8
  return 0
}

want="${*:-J K L}"

# ---------------------------------------------------------------------------
# J — DUPLICATION. A retained line repeated. Membership calls it retained every
#     time; measured before the fix, this passed EVERY assertion in the check.
#     Only the pinned content-line count can see it.
# ---------------------------------------------------------------------------
if [[ " $want " == *" J "* ]]; then
  F="$REPO/orchestration/src/vendor/simple_contract_data_source.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
i = next(j for j, ln in enumerate(lines)
         if ln.strip().startswith("this.contractInstances.set("))
lines = lines[: i + 1] + [lines[i]] * 3 + lines[i + 1 :]
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  run_check J verify_tx_builder_vendored_not_reimplemented
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# K — REORDERING. Two adjacent retained lines swapped, which is a statement moved
#     from one place to another. Every count is byte-identical and the residue is
#     empty; only the in-order walk can see it.
# ---------------------------------------------------------------------------
if [[ " $want " == *" K "* ]]; then
  F="$REPO/orchestration/src/vendor/simple_contract_data_source.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
idx = [j for j, ln in enumerate(lines)
       if ln.strip() != "" and not ln.lstrip().startswith("//")]
a = b = None
for j in range(len(idx) - 1):
    if idx[j + 1] == idx[j] + 1 and lines[idx[j]] != lines[idx[j + 1]]:
        a, b = idx[j], idx[j + 1]
        break
assert a is not None
lines[a], lines[b] = lines[b], lines[a]
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  run_check K verify_tx_builder_vendored_not_reimplemented
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# L — THE TRIPWIRE WIRED TO NOTHING. The builder is handed a plain `{}` instead
#     of the throwing proxy. The transaction still builds, the observation list is
#     still empty, and RI-72's load-bearing sentence is now supported by NOTHING.
#     Before the review's control this passed the whole check.
# ---------------------------------------------------------------------------
if [[ " $want " == *" L "* ]]; then
  F="$REPO/orchestration/src/join_e2e_driver.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "  const tester = new PublicTxSimulationTester(merkleTripwire as never, dataSource);"
new = "  const tester = new PublicTxSimulationTester({} as never, dataSource);"
assert old in s
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  run_check L verify_tx_builder_vendored_not_reimplemented
  restore_all; verify_restored "$F"
fi

restore_all
echo "all arms done"
