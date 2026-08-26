#!/usr/bin/env bash
# m23-mutations.sh — break what each M23 check claims to detect, and confirm it goes red.
#
# NOT A VERIFICATION CHECK. It lives in scratchpad/ and is run by hand; its output is the mutation
# matrix reported with the milestone. M22 declared complete and its review then found a mutation
# that passed the WHOLE milestone green — 247 assertions, 4 of 4, exit 0, over a corrupted vendored
# constructor — because two of three classifier shapes were unpinned. This exists so that shape is
# not handed to M23's reviewer.
#
# Each mutation targets the CENTRAL claim of one check. It is applied, the check is run, the
# assertion and failure counts are recorded, and the file is restored from a copy this script took
# itself — never from `git checkout`, because a path that is not tracked yet restores to nothing
# and `git status --porcelain` on it prints nothing whatever happened, which is a defect this
# campaign has on record.
#
# Usage: scratchpad/campaign/m23-mutations.sh [check-name...]

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 90

BACKUP="$HOME/.cache/aztec-m23-mutations"
rm -rf "$BACKUP"; mkdir -p "$BACKUP" || exit 90

save() { # <path>
  local dst="$BACKUP/$(printf '%s' "$1" | tr '/' '_')"
  cp "$REPO/$1" "$dst" || exit 90
}
restore() { # <path>
  local dst="$BACKUP/$(printf '%s' "$1" | tr '/' '_')"
  cp "$dst" "$REPO/$1" || exit 90
}

# The counts a check reported, from its own summary line.
run_check() { # <check> -> "<assertions> <failures> <rc>"
  local out rc
  out="$(verification/"$1".sh 2>&1)"; rc=$?
  local line
  line="$(printf '%s\n' "$out" | grep -E "^$1: [0-9]+ assertion\(s\), [0-9]+ failure\(s\)$" | tail -1)"
  if [ -z "$line" ]; then
    printf 'NO-SUMMARY NO-SUMMARY %d\n' "$rc"
    return
  fi
  printf '%s %s %d\n' \
    "$(printf '%s' "$line" | sed -E 's/.*: ([0-9]+) assertion.*/\1/')" \
    "$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failure.*/\1/')" \
    "$rc"
}

ROWS=""
mutation() { # <check> <description> <file> <python-mutator>
  local check="$1" desc="$2" file="$3" mutator="$4"
  save "$file"
  python3 - "$REPO/$file" <<PY
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
$mutator
p.write_text(s)
PY
  local rc_mut=$?
  if [ "$rc_mut" -ne 0 ]; then
    printf '!! %s: the mutation itself did not apply — the check was NOT exercised\n' "$check" >&2
    restore "$file"
    ROWS="$ROWS
$check|$desc|MUTATION-DID-NOT-APPLY"
    return
  fi
  local result
  result="$(run_check "$check")"
  restore "$file"
  ROWS="$ROWS
$check|$desc|$result"
  printf '  %-52s %s\n' "$check" "$result"
}

echo "== baseline (unmutated)"
BASE=""
for c in verify_sequencer_reuse_enumeration_recorded verify_txe_reuse_verdict_recorded \
         verify_facade_surface_compared_against_txe test_tree_snapshot_vocabulary_reused_not_redefined \
         verify_kv_store_browser_exports_recorded test_empty_block_advances_number_and_archive \
         test_block_seal_updates_archive test_timestamps_strictly_monotonic_subsecond \
         test_fake_clock_hundred_blocks e2e_automine_seals_on_submission \
         test_receipt_declares_no_proving test_no_ambient_clock_or_timer \
         e2e_l1_to_l2_message_injection e2e_chain_snapshot_export_import_roundtrip
do
  r="$(run_check "$c")"
  printf '  %-52s %s\n' "$c" "$r"
  BASE="$BASE
$c|baseline|$r"
done

echo
echo "== mutations"

mutation verify_sequencer_reuse_enumeration_recorded \
  "RI-41's decision reverted to 'open'" \
  REUSE-INVENTORY.md \
  's = s.replace("### RI-41 — Chain loop, timer, and the `AvmRuntime` facade\n- upstream:", "### RI-41 — Chain loop, timer, and the `AvmRuntime` facade\n- upstream:", 1)
i = s.index("### RI-41 — ")
j = s.index("- decision: build", i)
s = s[:j] + "- decision: open" + s[j + len("- decision: build"):]'

mutation verify_txe_reuse_verdict_recorded \
  "RI-39's rejection reason emptied of its call sites" \
  REUSE-INVENTORY.md \
  'i = s.index("### RI-39 — ")
j = s.index("- rejection-reason:", i)
k = s.index("\n", j)
s = s[:j] + "- rejection-reason: cannot-reach-target: it is a node component and cannot be used here, we looked" + s[k:]'

mutation verify_facade_surface_compared_against_txe \
  "one facade member dropped from the mapping table" \
  CHAIN-LOOP.md \
  'old = "| `injectL1ToL2Message` | `sendL1ToL2Message` | none |\n"
assert s.count(old) == 1
s = s.replace(old, "")'

mutation test_tree_snapshot_vocabulary_reused_not_redefined \
  "a parallel TreeSnapshot type declared in chain.ts" \
  orchestration/src/chain.ts \
  's = s.replace("export interface ChainBlock {",
                "export interface TreeSnapshot { readonly root: string; readonly size: number; }\n\nexport interface ChainBlock {", 1)'

mutation verify_kv_store_browser_exports_recorded \
  "the deletion-era row deleted from the kv-store table" \
  CHAIN-LOOP.md \
  'import re
lines = s.split("\n")
out = [l for l in lines if not (l.startswith("| `spike/`, `diffsim/`, `probe-mt/`"))]
assert len(out) == len(lines) - 1, "the row was not found"
s = "\n".join(out)'

mutation test_empty_block_advances_number_and_archive \
  "archiveBefore read AFTER the seal, so the chain stops chaining" \
  orchestration/src/chain.ts \
  'old = """    const archiveBefore = this.deps.merkleDb.archiveSnapshot();
    const outcome = await sealBlock(guarded, globals);"""
new = """    const outcome = await sealBlock(guarded, globals);
    const archiveBefore = this.deps.merkleDb.archiveSnapshot();"""
assert s.count(old) == 1
s = s.replace(old, new)'

mutation test_block_seal_updates_archive \
  "updateArchive passes the CURRENT trees instead of the header state" \
  orchestration/src/resident_merkle_operations.ts \
  'old = """          l1ToL2MessageTree: encodeSnapshot(state.l1ToL2MessageTree),
          noteHashTree: encodeSnapshot(state.partial.noteHashTree),
          nullifierTree: encodeSnapshot(state.partial.nullifierTree),
          publicDataTree: encodeSnapshot(state.partial.publicDataTree),"""
new = """          l1ToL2MessageTree: encodeSnapshot(this.treeRootsForMutation().l1ToL2MessageTree),
          noteHashTree: encodeSnapshot(this.treeRootsForMutation().noteHashTree),
          nullifierTree: encodeSnapshot(this.treeRootsForMutation().nullifierTree),
          publicDataTree: encodeSnapshot(this.treeRootsForMutation().publicDataTree),"""
assert s.count(old) == 1
s = s.replace(old, new)
s = s.replace("  archiveSnapshot(): AppendOnlyTreeSnapshot {",
              "  treeRootsForMutation() { return this.treeRoots(); }\n\n  archiveSnapshot(): AppendOnlyTreeSnapshot {", 1)'

mutation test_timestamps_strictly_monotonic_subsecond \
  "the timestamp rule takes the MINIMUM instead of the maximum" \
  orchestration/src/chain_clock.ts \
  'old = "  return wall > floor ? wall : floor;"
assert s.count(old) == 1
s = s.replace(old, "  return wall < floor ? wall : floor;")'

mutation test_fake_clock_hundred_blocks \
  "ManualTicker delivers each tick twice" \
  orchestration/src/chain_clock.ts \
  'old = """    this.counted += 1;
    await this.onTick();
  }

  /** Deliver `n` ticks, in order, each awaited before the next. */"""
new = """    this.counted += 1;
    await this.onTick();
    await this.onTick();
  }

  /** Deliver `n` ticks, in order, each awaited before the next. */"""
assert s.count(old) == 1
s = s.replace(old, new)'

mutation e2e_automine_seals_on_submission \
  "submit() seals whether or not automine is set" \
  orchestration/src/chain.ts \
  'old = """    if (this.config.automine) {
      await this.produceBlock();
    }"""
new = """    await this.produceBlock();"""
assert s.count(old) == 1
s = s.replace(old, new)'

mutation test_receipt_declares_no_proving \
  "create() stops writing the disclosure to the sink" \
  orchestration/src/avm_runtime.ts \
  'old = "    sink(line);"
assert s.count(old) == 1
s = s.replace(old, "    void sink;")'

mutation test_no_ambient_clock_or_timer \
  "a planted Date.now() in chain.ts" \
  orchestration/src/chain.ts \
  's = s.replace("  private requireRunning(): void {",
                "  private plantedForMutation(): number { return Date.now(); }\n\n  private requireRunning(): void {", 1)'

mutation e2e_l1_to_l2_message_injection \
  "injectL1ToL2Message appends immediately instead of at the boundary" \
  orchestration/src/chain.ts \
  'old = """    this.pendingMessages.push(leaf);"""
new = """    void this.deps.merkleDb.appendLeaves(MerkleTreeId.L1_TO_L2_MESSAGE_TREE, [leaf]);"""
assert s.count(old) == 1
s = s.replace(old, new)'

mutation e2e_chain_snapshot_export_import_roundtrip \
  "exportSnapshot omits the fee-juice funding" \
  orchestration/src/avm_runtime.ts \
  'old = "      funding: this.funding.map(f => ({ ...f })),"
assert s.count(old) == 1
s = s.replace(old, "      funding: [],")'

mutation test_block_seal_updates_archive \
  "one export line removed from M23 overlay patch" \
  verification/m23/0001-test-vm2-expose-the-archive-tree-through-the-reactor.patch \
  'old = "+            avm_merkle_db_get_archive_snapshot\n"
assert s.count(old) == 1
s = s.replace(old, "")'

echo
echo "== matrix"
printf '%s\n' "$BASE" | grep . | awk -F'|' '{printf "  %-52s %-22s %s\n", $1, $2, $3}'
printf '%s\n' "$ROWS" | grep . | awk -F'|' '{printf "  %-52s %-52s %s\n", $1, $2, $3}'
