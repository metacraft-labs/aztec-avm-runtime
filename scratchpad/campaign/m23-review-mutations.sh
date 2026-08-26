#!/usr/bin/env bash
# m23-review-mutations.sh — the REVIEW's mutations, beyond the implementation's fifteen.
#
# Two jobs.
#
#   1. REPLACE the two mutations that read `0 / 1 / 1`. Those kill the shared arm run, so the check
#      under test never reaches an assertion and the trap prints the summary. That proves the trap
#      works; it does not prove the check DISCRIMINATES. Each is replaced by a mutation of the same
#      subject that leaves the arm run alive.
#
#   2. Run mutations the implementation did not, especially against the archive and the chain loop,
#      and — unlike `m23-mutations.sh`, which runs only the target check — run the WHOLE milestone
#      for the dangerous ones, because M22's review found a mutation that passed a whole milestone
#      green while the single check it was aimed at was not the one that would have caught it.
#
# Restores from a copy this script takes itself, never `git checkout`: several of these paths are
# `git add -N` and would restore to nothing.
#
# Usage: scratchpad/campaign/m23-review-mutations.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 90

BACKUP="$HOME/.cache/aztec-m23rev-mutations2"
rm -rf "$BACKUP"; mkdir -p "$BACKUP" || exit 90

ALL_CHECKS="verify_sequencer_reuse_enumeration_recorded verify_txe_reuse_verdict_recorded
verify_facade_surface_compared_against_txe test_tree_snapshot_vocabulary_reused_not_redefined
verify_kv_store_browser_exports_recorded test_empty_block_advances_number_and_archive
test_block_seal_updates_archive test_timestamps_strictly_monotonic_subsecond
test_fake_clock_hundred_blocks e2e_automine_seals_on_submission
test_receipt_declares_no_proving test_no_ambient_clock_or_timer
e2e_l1_to_l2_message_injection e2e_chain_snapshot_export_import_roundtrip"

save()    { cp "$REPO/$1" "$BACKUP/$(printf '%s' "$1" | tr '/' '_')" || exit 90; }
restore() { cp "$BACKUP/$(printf '%s' "$1" | tr '/' '_')" "$REPO/$1" || exit 90; }

run_check() { # <check> -> "<assertions> <failures> <rc>"
  local out rc line
  out="$(verification/"$1".sh 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E "^$1: [0-9]+ assertion\(s\), [0-9]+ failure\(s\)$" | tail -1)"
  if [ -z "$line" ]; then printf 'NO-SUMMARY NO-SUMMARY %d\n' "$rc"; return; fi
  printf '%s %s %d\n' \
    "$(printf '%s' "$line" | sed -E 's/.*: ([0-9]+) assertion.*/\1/')" \
    "$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failure.*/\1/')" "$rc"
}

# The WHOLE milestone: total assertions, total failures, how many checks were red, and the names.
run_all() {
  local total=0 fails=0 red=0 rednames="" c r a f rc
  for c in $ALL_CHECKS; do
    r="$(run_check "$c")"
    a="${r%% *}"; rc="${r##* }"; f="$(printf '%s' "$r" | awk '{print $2}')"
    case "$a" in NO-SUMMARY) a=0 ;; esac
    case "$f" in NO-SUMMARY) f=1 ;; esac
    total=$((total + a)); fails=$((fails + f))
    if [ "$rc" -ne 0 ] || [ "$f" -ne 0 ]; then red=$((red + 1)); rednames="$rednames $c"; fi
  done
  printf '%d assertions, %d failing assertions, %d/14 checks RED%s\n' \
    "$total" "$fails" "$red" "${rednames:+ —$rednames}"
}

ROWS=""
mutate() { # <label> <scope: check name | ALL> <file> <python-mutator>
  local label="$1" scope="$2" file="$3" mutator="$4"
  save "$file"
  python3 - "$REPO/$file" <<PY
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
$mutator
p.write_text(s)
PY
  if [ $? -ne 0 ]; then
    restore "$file"
    printf '!! %s: MUTATION-DID-NOT-APPLY\n' "$label" >&2
    ROWS="$ROWS
$label|MUTATION-DID-NOT-APPLY"
    return
  fi
  local result
  if [ "$scope" = "ALL" ]; then result="$(run_all)"; else result="$(run_check "$scope")"; fi
  restore "$file"
  ROWS="$ROWS
$label|$result"
  printf '  %-60s %s\n' "$label" "$result"
}

# A4. The block number stops advancing: every block is number 1. The chain stops being a chain
# while every individual block is still sealed and appended.
mutate "A4 every block is numbered 1" test_empty_block_advances_number_and_archive \
  orchestration/src/chain.ts \
  'old = "    const number = this.nextBlockNumber;"
assert s.count(old) == 1
s = s.replace(old, "    const number = 1;")'

# A5. The declared wall-clock deviation lies. §-level honesty: a deviation field that lied would be
# worse than none, which the milestone says in terms.
mutate "A5 wallClockDeviationSeconds is always 0" ALL \
  orchestration/src/chain.ts \
  'old = "      wallClockDeviationSeconds: timestamp - wallClockSeconds,"
assert s.count(old) == 1
s = s.replace(old, "      wallClockDeviationSeconds: 0n,")'

# A6. The snapshot replay recomputes timestamps from the fresh clock instead of using the recorded
# ones — the defect the arm says is pinned so it cannot come back.
mutate "A6 importSnapshot ignores the recorded timestamps" ALL \
  orchestration/src/avm_runtime.ts \
  'old = "await this.chain.produceBlock({ timestamp: BigInt(b.timestamp) });"
assert s.count(old) == 1, s.count(old)
s = s.replace(old, "await this.chain.produceBlock();")'

# A7. The L1-to-L2 message is appended, but a DIFFERENT leaf. The tree grows by one and the root
# moves; only a read-back BY INDEX can tell.
mutate "A7 injectL1ToL2Message appends a different leaf" ALL \
  orchestration/src/chain.ts \
  'old = "    this.pendingMessages.push(leaf);"
assert s.count(old) == 1
s = s.replace(old, "    this.pendingMessages.push(leaf.add(new Fr(1n)));")'

# A8. `produceEmptyBlocks: false` is ignored — the timer produces a block whatever the flag says.
mutate "A8 produceEmptyBlocks is ignored" ALL \
  orchestration/src/chain.ts \
  'old = "    if (txs.length === 0 && !this.config.produceEmptyBlocks) {"
assert s.count(old) == 1
s = s.replace(old, "    if (false) {")'

# A9. The reactor reports a fabricated export list. The 51-export assertion reads the wasm binary,
# but the run report reads the reactor — do the two really cross-check?
mutate "A9 reactor.exportNames reports a fabricated list" ALL \
  node-host/src/reactor.ts \
  'import re
m = re.search(r"  get exportNames\(\): readonly string\[\] \{", s)
assert m, "exportNames getter not found"
s = s[:m.end()] + "\n    return [\"avm_simulate\"];" + s[m.end():]'

echo
echo "== matrix"
printf '%s\n' "$ROWS" | grep . | awk -F'|' '{printf "  %-60s %s\n", $1, $2}'
