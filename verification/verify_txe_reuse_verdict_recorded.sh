#!/usr/bin/env bash
# verify_txe_reuse_verdict_recorded — TXE cannot be declined by omission.
#
# The verification entry: "The enumeration covers TXE specifically — its oracle surface, its
# state_machine substitutions and its native dependencies — and records a verdict of reuse or
# reference-implementation with the reason, so TXE cannot be declined by omission."
#
# THE ONE OUTCOME THE DELIVERABLE FORBIDS IS DECLINING WITHOUT LOOKING, so this check is built
# around measuring that somebody looked. Every figure is re-derived from the fork on every run — the
# file count, the line count, the presence of each named oracle method, the `state_machine/`
# inventory, and the four native dependencies BY IMPORT — and `CHAIN-LOOP.md` and RI-39 are then
# held to what was found.
#
# THE SURFACE IS CHECKED METHOD BY METHOD, not by a count. A count is satisfied by any fifteen
# methods; the claim is about these fifteen, and about one of them being PRIVATE, which the
# milestone's own table gets wrong.
#
# THE DEPENDENCY MEASUREMENT IS THE DECIDING ONE AND IT IS AN IMPORT SCAN, not a package.json read.
# A dependency listed in `package.json` and never imported is a different fact from one imported in
# two files, and the rejection reason names call sites.
#
# AND THE OTHER HALF OF THE DELIVERABLE — "let its API shape inform ours anyway" — IS CHECKED TOO.
# A `reference implementation` verdict that took nothing from the reference would be a decline with
# a nicer name.
#
# Run: just verify-chain-txe-verdict

TEST_NAME="verify_txe_reuse_verdict_recorded"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor

DOC="$(cat "$M23_DOC")"
INV="$REPO_ROOT/REUSE-INVENTORY.md"

# ---------------------------------------------------------------------------
# PART 1 — the size, re-derived
# ---------------------------------------------------------------------------
echo "== TXE's size, measured rather than quoted"

TXE_FILES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ | grep -c . || true)"
assert_eq "txe/src/ is 41 files at the cpp anchor" "41" "$TXE_FILES"

TXE_LINES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ \
  | while IFS= read -r f; do git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:$f" | wc -l; done \
  | awk '{s += $1} END {print s}')"
assert_eq "…and 7,376 lines" "7376" "$TXE_LINES"

# THE FIGURE IS A cpp-ANCHOR FACT, and the ts anchor is the control that it is not simply "the
# number of files TXE has".
TXE_TS_FILES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_TS_ANCHOR" -- yarn-project/txe/src/ | grep -c . || true)"
assert_true "…and the ts anchor has a DIFFERENT number, so the anchor matters" \
  test "$TXE_TS_FILES" -ne "$TXE_FILES"
# The needle is a FRAGMENT of one line rather than a sentence, because the document wraps and a
# needle that spans a line break silently stops matching the day somebody reflows a paragraph.
assert_true "CHAIN-LOOP.md says the figure is a cpp-anchor fact" \
  str_has_sub "$DOC" "-anchor fact"
assert_true "…and says how many files the ts anchor has instead" \
  str_has_sub "$DOC" "At the \`ts\` anchor it is $TXE_TS_FILES files"

# ---------------------------------------------------------------------------
# PART 2 — the oracle surface, method by method
# ---------------------------------------------------------------------------
echo "== the fifteen named oracle methods, each found in the source"

CTX_PATH="yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts"
CTX="$(m23_anchor_file "$CTX_PATH")"
assert_ge "the top-level context is a substantial file" 800 "$(printf '%s\n' "$CTX" | grep -c .)"
assert_true "…and declares the class the milestone names" \
  str_has_sub "$CTX" "class TXEOracleTopLevelContext"

for m in mineBlock advanceBlocksBy advanceTimestampBy sendL1ToL2Message deploy addAccount \
         createAccount registerContractAndAddAccount getNextBlockNumber getNextBlockTimestamp \
         getLastBlockTimestamp getLastTxEffects privateCallNewFlow publicCallNewFlow \
         addAuthWitness getRandomField
do
  assert_true "TXE declares $m" str_has_line_re "$CTX" "^  (private )?(async )?$m\("
done
# THE CONTROL: a method it does not have is not found by the same matcher.
assert_false "…and a method TXE does not have is not found" \
  str_has_line_re "$CTX" "^  (private )?(async )?mineEpoch\("

echo "== and one of them is PRIVATE, which the milestone's table does not say"
assert_true "registerContractAndAddAccount is private" \
  str_has_line_re "$CTX" "^  private async registerContractAndAddAccount\("
assert_false "…while deploy is not" str_has_line_re "$CTX" "^  private async deploy\("
assert_true "CHAIN-LOOP.md records that correction" \
  str_has_sub "$DOC" "**It is \`private\`**"

echo "== TXE's block time: seeded from the wall clock ONCE, then advanced only explicitly"
N_DATE="$(git -C "$FORK_ROOT" grep -c 'Date\.now(' "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ \
  | awk -F: '{s += $NF} END {print s + 0}')"
N_INTERVAL="$(git -C "$FORK_ROOT" grep -c 'setInterval(' "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ \
  | awk -F: '{s += $NF} END {print s + 0}')"
N_TIMEOUT="$(git -C "$FORK_ROOT" grep -c 'setTimeout(' "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ \
  | awk -F: '{s += $NF} END {print s + 0}')"
assert_eq "Date.now( appears four times in txe/src, all diagnostic" "4" "$N_DATE"
assert_eq "setInterval( appears once" "1" "$N_INTERVAL"
assert_eq "setTimeout( appears not at all" "0" "$N_TIMEOUT"
# THE POSITIVE HALF: the timestamp is a field the caller advances.
assert_true "advanceTimestampBy moves a plain bigint field" \
  str_has_sub "$CTX" "this.nextBlockTimestamp += duration"
assert_true "…and mineBlock stamps it without incrementing it" \
  str_has_sub "$CTX" "timestamp: this.nextBlockTimestamp"

# AND THE SPELLING THE THREE COUNTS ABOVE CANNOT SEE. This section said "TXE never reads a wall
# clock for block time" and rested it on those three greps — all of which are correct and none of
# which matches `new Date().getTime()`, which is the one TXE uses, in the one place that matters:
# SEEDING the session's block timestamp. M23's review found it. `Date.now(` is not the only way to
# read a clock, and this is the campaign's "needles come from the artefact" defect met in the
# section whose entire subject is wall-clock reads.
#
# So the fact is measured in the direction that makes it a finding rather than an absence: `new
# Date(` appears EXACTLY ONCE in `txe/src/`, and it is that line.
N_NEWDATE="$(git -C "$FORK_ROOT" grep -c 'new Date(' "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ \
  | awk -F: '{s += $NF} END {print s + 0}')"
assert_eq "new Date( appears exactly once in txe/src" "1" "$N_NEWDATE"
SESSION="$(m23_anchor_file yarn-project/txe/src/txe_session.ts)"
assert_true "…and it is the line that SEEDS the block timestamp from the host clock" \
  str_has_line "$SESSION" "    const nextBlockTimestamp = BigInt(Math.floor(new Date().getTime() / 1000));"
# THE DOCUMENT IS HELD TO THE CORRECTION IN BOTH DIRECTIONS, so it cannot drift back.
assert_true "CHAIN-LOOP.md records that TXE SEEDS block time from a wall clock" \
  str_has_sub "$DOC" "It SEEDS it from one"
assert_false "…and no longer claims TXE never reads one" \
  str_has_sub "$DOC" "TXE never reads a wall clock for block time"

# ---------------------------------------------------------------------------
# PART 3 — the state_machine substitutions
# ---------------------------------------------------------------------------
echo "== the state_machine substitutions, by file"

SM_FILES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" \
  -- yarn-project/txe/src/state_machine/ | grep -c . || true)"
assert_eq "state_machine/ has six files" "6" "$SM_FILES"
SM_LINES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" \
  -- yarn-project/txe/src/state_machine/ \
  | while IFS= read -r f; do git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:$f" | wc -l; done \
  | awk '{s += $1} END {print s}')"
assert_eq "…and 789 lines, the figure the milestone gives" "789" "$SM_LINES"

for f in archiver.ts global_variable_builder.ts synchronizer.ts dummy_p2p_client.ts mock_epoch_cache.ts; do
  assert_true "state_machine/$f exists at the anchor" \
    git -C "$FORK_ROOT" cat-file -e "$M23_CPP_ANCHOR:yarn-project/txe/src/state_machine/$f"
done
assert_false "…and a file it does not have is not found by the same lookup" \
  git -C "$FORK_ROOT" cat-file -e "$M23_CPP_ANCHOR:yarn-project/txe/src/state_machine/mock_prover.ts"

# THE POINT OF THAT INVENTORY: they are upstream substituting a node's components, which is the
# strongest argument FOR reuse and is recorded as such rather than skipped.
assert_true "CHAIN-LOOP.md says they are upstream's own substitutions" \
  str_has_sub "$DOC" "upstream itself substituting a node's"
assert_true "…and that this is the strongest argument for reuse" \
  str_has_sub "$DOC" "the strongest argument for reuse"

# ---------------------------------------------------------------------------
# PART 4 — the native dependencies, BY IMPORT
# ---------------------------------------------------------------------------
echo "== the four native dependencies, counted by import"

count_import() { # <package specifier>
  git -C "$FORK_ROOT" grep -c "from '$1'" "$M23_CPP_ANCHOR" -- yarn-project/txe/src/ 2>/dev/null \
    | awk -F: '{s += $NF} END {print s + 0}'
}
N_WS="$(count_import '@aztec/world-state/native')"
N_NODE="$(count_import '@aztec/aztec-node')"
N_ARCH="$(count_import '@aztec/archiver')"
N_BB="$(count_import '@aztec/bb-prover/test')"
N_KV="$(count_import '@aztec/kv-store/lmdb-v2')"

assert_eq "@aztec/world-state/native is imported twice" "2" "$N_WS"
assert_eq "@aztec/aztec-node once" "1" "$N_NODE"
assert_eq "@aztec/archiver once" "1" "$N_ARCH"
assert_eq "@aztec/bb-prover/test once" "1" "$N_BB"
# EXACTLY, like the other four. This was the one `assert_ge` in the block, and it is the one figure
# CHAIN-LOOP.md got wrong: it said SIX, which is the count of every `@aztec/kv-store*` import
# including three type-only ones, in a bullet headed "by import". A loose assertion beside four
# exact ones is where a number goes to drift.
assert_eq "@aztec/kv-store/lmdb-v2 exactly three times" "3" "$N_KV"
# THE CONTROL: a package TXE does not import is counted as zero by the same counter, so the numbers
# above are a measurement and not the counter returning whatever it is asked for.
assert_eq "…and a package it does not import counts zero" "0" "$(count_import '@aztec/avm-runtime')"

# `@aztec/native` is NOT imported directly, and that distinction is the one that matters: it
# arrives transitively, which is why a package.json read would have told a different story.
assert_eq "@aztec/native is not imported directly at all" "0" "$(count_import '@aztec/native')"
assert_true "…and CHAIN-LOOP.md says it arrives through @aztec/world-state" \
  str_has_sub "$DOC" "@aztec/native\` is never imported directly — it arrives through"

echo "== and TXE is driven over a protocol rather than as a library"
BIN="$(m23_anchor_file yarn-project/txe/src/bin/index.ts)"
assert_true "its entry point starts an HTTP RPC server" str_has_sub "$BIN" "startHttpRpcServer"
RPC="$(m23_anchor_file yarn-project/txe/src/rpc_server.ts)"
assert_true "…built by createTXERpcServer" str_has_sub "$RPC" "createTXERpcServer"
assert_true "…over a safe JSON-RPC server" str_has_sub "$RPC" "createSafeJsonRpcServer"

# ---------------------------------------------------------------------------
# PART 5 — the verdict, with its reason, in both places
# ---------------------------------------------------------------------------
echo "== the verdict is recorded, with a tagged rejection reason"

DEC="$(awk '
  /^### RI-39 — / {inside=1; next}
  inside && /^### RI-/ {inside=0}
  inside && /^- decision:/ {sub(/^- decision:[ ]*/,""); print; inside=0}
' "$INV")"
assert_eq "RI-39's decision is recorded and is not open" "replace" "$DEC"

RR="$(awk '
  /^### RI-39 — / {inside=1; next}
  inside && /^### RI-/ {inside=0}
  inside && /^- rejection-reason:/ {sub(/^- rejection-reason:[ ]*/,""); print; inside=0}
' "$INV")"
assert_prefix "…and its rejection reason carries one of the three admissible tags" \
  "cannot-reach-target:" "$RR"
assert_ge "…and is specific rather than a sentence" 400 "${#RR}"
assert_true "…naming the world-state import site" str_has_sub "$RR" "txe_oracle_top_level_context.ts:89"
assert_true "…and the second, independent blocker" str_has_sub "$RR" "driven over a PROTOCOL"

assert_true "CHAIN-LOOP.md states the verdict in terms" \
  str_has_sub "$DOC" "### DECISION: **reference implementation**, \`cannot-reach-target\`"

# ---------------------------------------------------------------------------
# PART 6 — the OTHER half: the shape was taken
# ---------------------------------------------------------------------------
echo "== and its API shape informs ours, which is the rest of the deliverable"

RUNTIME="$(cat "$ORCH_SRC/avm_runtime.ts")"
# Four of TXE's names are on our facade. Each is required BOTH upstream and here, so this is a
# correspondence rather than a coincidence of vocabulary.
for m in advanceBlocksBy getNextBlockNumber getNextBlockTimestamp getLastBlockTimestamp; do
  assert_true "TXE has $m" str_has_line_re "$CTX" "^  (private )?(async )?$m\("
done
assert_true "AvmRuntime.advanceBlocksBy carries TXE's name" \
  str_has_sub "$RUNTIME" "async advanceBlocksBy(n: number)"
assert_true "…and nextBlockNumber is documented as TXE's getNextBlockNumber" \
  str_has_sub "$RUNTIME" "TXE's \`getNextBlockNumber\`"
assert_true "…and nextBlockTimestamp as TXE's" str_has_sub "$RUNTIME" "TXE's \`getNextBlockTimestamp\`"
assert_true "…and lastBlockTimestamp as TXE's" str_has_sub "$RUNTIME" "TXE's \`getLastBlockTimestamp\`"

assert_true "the inventory's experiment line records what was taken" \
  str_has_sub "$(awk '/^### RI-39 — /,/^### RI-40 — /' "$INV")" "ITS API SHAPE INFORMS OURS"

m23_finish
