#!/usr/bin/env bash
# e2e_chain_snapshot_export_import_roundtrip — export, reload, and be the same chain.
#
# The verification entry: "A chain exported after several blocks reloads into a fresh runtime with
# identical state, block number and archive."
#
# THE SECOND RUNTIME SHARES NOTHING WITH THE FIRST. Both hold their own module handles, so the
# reloaded chain's trees start at genesis and everything it reaches is produced by the replay. A
# roundtrip through one world state would be a test of a serialiser and nothing else.
#
# "IDENTICAL" IS THREE THINGS AND THEY FAIL INDEPENDENTLY: the block number, the four-tree state
# reference, and the ARCHIVE ROOT. The third is the strongest: it is a hash over every header, and
# a header carries its block number, its timestamp and its state reference — so a replay that got
# any of those wrong produces a different archive even when the trees agree. The first version of
# this arm proved that twice, and both failures are recorded below because both are shapes a future
# change could reintroduce.
#
# THE SNAPSHOT IS A REPLAY LOG AND THE DECISION IS RECORDED. `world_state_reference`'s
# `get_snapshot()` is a summary — `{root, next_available_leaf_index}` — and upstream's only
# whole-state carrier is `NativeWorldStateService.backupTo()`, which copies LMDB files behind
# `@aztec/native`. So the export carries what PRODUCED the state, in upstream's own serialisation
# (`Tx.toBuffer()`), and the import re-derives it. RI-71 and `CHAIN-LOOP.md` section 5.
#
# Run: just verify-chain-snapshot

TEST_NAME="e2e_chain_snapshot_export_import_roundtrip"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_arms

# ---------------------------------------------------------------------------
# PART 1 — the source chain is worth exporting
# ---------------------------------------------------------------------------
echo "== the exported chain has blocks, a transaction and a message in it"

SRC_BLOCKS="$(m23_arm snapshotRoundtrip source.blocks)"
SRC_ARCHIVE="$(m23_arm snapshotRoundtrip source.archive)"
SRC_STATE="$(m23_arm snapshotRoundtrip source.stateReference)"

assert_eq "the source chain reached block 3" "3" "$SRC_BLOCKS"
assert_true "…its archive root is a field element rather than MISSING" test "${#SRC_ARCHIVE}" -eq 66
assert_ge "…and its state reference is a full four-tree encoding" 288 "${#SRC_STATE}"

# A CHAIN OF EMPTY BLOCKS WOULD BE A WEAKER TEST, so the snapshot is required to carry both a
# transaction and an L1-to-L2 message. Without this, "identical" is a claim about three headers.
SNAP="$(python3 - "$M23_ARMS" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["arms"]["snapshotRoundtrip"]["snapshot"]
txs = sum(len(b["txs"]) for b in s["blocks"])
msgs = sum(len(b["l1ToL2Messages"]) for b in s["blocks"])
print("format %s version %s blocks %d txs %d msgs %d funding %d"
      % (s["format"], s["version"], len(s["blocks"]), txs, msgs, len(s["funding"])))
PY
)"
assert_eq "the snapshot is three blocks carrying one transaction, one message and one funding" \
  "format avm-runtime-replay-log version 1 blocks 3 txs 1 msgs 1 funding 1" "$SNAP"

# THE TRANSACTION IS UPSTREAM'S OWN SERIALISATION, not a format of ours: a `Tx.toBuffer()` hex
# string that `Tx.fromBuffer` reads back to the same hash.
ROUNDTRIP="$(cd "$ORCH_DIR" && node --input-type=module -e '
import fs from "node:fs";
import { Tx } from "@aztec/stdlib/tx";
const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const hex = doc.arms.snapshotRoundtrip.snapshot.blocks.flatMap(b => b.txs)[0];
const tx = await Tx.fromBuffer(Buffer.from(hex, "hex"));
const again = Buffer.from(tx.toBuffer()).toString("hex");
console.log(hex === again ? "STABLE" : "UNSTABLE");
console.log(tx.getTxHash().toString());
' "$M23_ARMS" 2>&1 | tail -2)"
assert_eq "the recorded transaction is decodable by upstream's own Tx.fromBuffer" "STABLE" \
  "$(printf '%s\n' "$ROUNDTRIP" | sed -n 1p)"
TXHASH="$(printf '%s\n' "$ROUNDTRIP" | sed -n 2p)"
assert_true "…and yields a transaction hash" test "${#TXHASH}" -eq 66

# ---------------------------------------------------------------------------
# PART 2 — the reloaded chain is the same chain
# ---------------------------------------------------------------------------
echo "== a fresh runtime reloaded from it reaches the same state"

RE_BLOCKS="$(m23_arm snapshotRoundtrip reloaded.blocks)"
RE_ARCHIVE="$(m23_arm snapshotRoundtrip reloaded.archive)"
RE_STATE="$(m23_arm snapshotRoundtrip reloaded.stateReference)"

assert_eq "the same block number" "$SRC_BLOCKS" "$RE_BLOCKS"
assert_eq "the same four-tree state reference" "$SRC_STATE" "$RE_STATE"
assert_eq "the same ARCHIVE ROOT, which commits to every header" "$SRC_ARCHIVE" "$RE_ARCHIVE"
assert_eq "and the arm agrees the two are identical" "true" "$(m23_arm snapshotRoundtrip identical)"

echo "== and the timestamps were REPRODUCED rather than recomputed"
SRC_TS="$(m23_arm snapshotRoundtrip source.timestamps)"
RE_TS="$(m23_arm snapshotRoundtrip reloaded.timestamps)"
assert_eq "the reloaded chain's timestamps are the source's" "$SRC_TS" "$RE_TS"
# NOT A TAUTOLOGY: the source's timestamps are not what a fresh chain would compute from a fresh
# `ManualDateProvider(0)` with a one-second spacing, which is 1,2,3. They start at 2 because the
# source advanced its clock before the first block. So "the reloaded timestamps equal the source's"
# is a claim about the replay path and not about two identical defaults.
assert_true "…and they are NOT the 1,2,3 a fresh clock would produce" \
  test "$SRC_TS" != '["1","2","3"]'

# ---------------------------------------------------------------------------
# PART 3 — the two defects this arm has already had, pinned so they cannot come back
# ---------------------------------------------------------------------------
echo "== the two recorded failure modes are pinned"

# (1) A replay that recomputed timestamps produced different headers and therefore a different
#     archive. So `importSnapshot` must pass the recorded timestamp, and `produceBlock` must
#     accept and ENFORCE one.
RUNTIME="$(cat "$ORCH_SRC/avm_runtime.ts")"
CHAIN="$(cat "$ORCH_SRC/chain.ts")"
assert_true "importSnapshot replays at the recorded timestamp" \
  str_has_sub "$RUNTIME" "await this.chain.produceBlock({ timestamp: BigInt(b.timestamp) });"
assert_true "…and produceBlock takes an override" \
  str_has_sub "$CHAIN" "const timestamp = options.timestamp ??"
assert_true "…which is still required to advance the chain" \
  str_has_sub "$CHAIN" "if (timestamp <= this.lastTimestamp && this.produced.length > 0) {"

# THAT ENFORCEMENT IS RUN, AND THE FIRST VERSION OF THIS BLOCK ONLY SAID SO.
#
# It ran ONE case — a FIRST block, where the guard (`this.produced.length > 0`) does not apply —
# and asserted that it was ACCEPTED. That is the opposite case. The refusal itself was read as a
# source string above and never executed, while M23's Implementation Details said "that refusal is
# exercised rather than read". M23's review measured the gap and closed it: BOTH branches of the
# guard are run here now, against the same chain, so the assertion is about behaviour.
#
# `lastTimestamp` and `produced` are TypeScript-private, which is a compile-time annotation that
# Node's type stripping erases — the same erasure that made the §8.4 disclosure reachable around
# `create()`. A probe may therefore stand the guard up without a module underneath it, which is
# what makes the refusal exercisable at all without a whole block.
BACKWARDS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmChain } from "./src/chain.ts";
import { ManualDateProvider } from "./src/chain_clock.ts";
// A chain with a stub world below it. Reaching the processor is the marker for "the timestamp was
// ACCEPTED", because the timestamp is checked before anything else happens.
const mk = () => new AvmChain({
  merkleDb: { archiveSnapshot: () => ({ root: { toString: () => "0x0" }, nextAvailableLeafIndex: 1 }) },
  contractsDb: {},
  makeProcessor: () => { throw new Error("REACHED-PROCESSOR"); },
  clock: new ManualDateProvider(0),
}, { intervalMs: 0 });
const outcome = async (chain, ts) => {
  try { await chain.produceBlock({ timestamp: ts }); return "NO-THROW"; }
  catch (e) { return e.message.includes("REACHED-PROCESSOR") ? "ACCEPTED" : "REFUSED: " + e.message; }
};
// (1) the first block: the guard does not apply, so any timestamp is accepted.
console.log("FIRST " + await outcome(mk(), 5n));
// (2) a chain that HAS produced a block, at timestamp 5. Both fields are erased-private.
const chain = mk();
chain.produced.push({ number: 1, timestamp: 5n });
chain.lastTimestamp = 5n;
console.log("BACKWARDS " + await outcome(chain, 4n));
console.log("EQUAL " + await outcome(chain, 5n));
console.log("FORWARD " + await outcome(chain, 6n));
' 2>&1 | tail -4)"
assert_eq "the first block accepts any timestamp and reaches the processor" \
  "FIRST ACCEPTED" "$(printf '%s\n' "$BACKWARDS" | sed -n 1p)"
# THE REFUSAL, RUN. A replay timestamp that goes BACKWARDS is refused, by the chain's own message.
assert_prefix "…and once a block exists, a timestamp that goes backwards is REFUSED" \
  "BACKWARDS REFUSED: block 2 would have timestamp 4," "$(printf '%s\n' "$BACKWARDS" | sed -n 2p)"
# AND EQUALITY IS REFUSED TOO, which is what makes it "advance" rather than "not regress".
assert_prefix "…and one that merely repeats the last is refused as well" \
  "EQUAL REFUSED: block 2 would have timestamp 5," "$(printf '%s\n' "$BACKWARDS" | sed -n 3p)"
# THE CONTROL: the same chain, one second later, is ACCEPTED — so the refusals above are about the
# ordering and not about a chain that refuses every override.
assert_eq "…while a timestamp that DOES advance is accepted by the same chain" \
  "FORWARD ACCEPTED" "$(printf '%s\n' "$BACKWARDS" | sed -n 4p)"

# (2) Funding applied behind the facade's back was left out of the snapshot, so the replayed
#     transaction was thrown out for an insufficient balance. `fundFeeJuice` must record.
assert_true "AvmRuntime.fundFeeJuice records the funding for the snapshot" \
  str_has_sub "$RUNTIME" "this.funding.push({ feePayer: feePayer.toString(), amount: amount.toString() });"
assert_true "…and importSnapshot replays it before the blocks" \
  str_has_sub "$RUNTIME" "for (const f of snapshot.funding) {"

echo "== a replay onto a chain that already has blocks is refused"
assert_true "importSnapshot requires a fresh chain" \
  str_has_sub "$RUNTIME" "if (this.chain.blockNumber !== 0) {"
assert_true "…and refuses an unrecognised format" \
  str_has_sub "$RUNTIME" "throw new Error(\`unrecognised chain snapshot:"

# ---------------------------------------------------------------------------
# PART 4 — no parallel state format was invented
# ---------------------------------------------------------------------------
echo "== the snapshot reuses upstream's serialisation and declares no tree format"

assert_true "the snapshot's transactions are Tx.toBuffer() hex" \
  str_has_sub "$RUNTIME" "b.txs.map(t => Buffer.from(t.toBuffer()).toString('hex'))"
# NOTHING OF OURS SERIALISES A TREE. The needles are the shapes a home-made tree format would take.
for needle in "serializeTree" "toTreeBuffer" "leavesToBuffer" "serialiseLeaves"; do
  HITS="$(grep -rl "$needle" "$ORCH_SRC" --include='*.ts' || true)"
  assert_eq "no file of ours declares $needle" "" "$HITS"
done
# THE CONTROL for those four absences: a needle that IS present is found by the same scan.
assert_true "…and the same scan does find exportSnapshot, so it is not scanning nothing" \
  test -n "$(grep -rl 'exportSnapshot' "$ORCH_SRC" --include='*.ts' || true)"

m23_finish
