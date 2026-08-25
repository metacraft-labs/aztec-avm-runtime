#!/usr/bin/env bash
# test_aztec_node_adapter_surface_minimal — M21.
#
# "Calling any method outside the enumerated set throws, so the adapter cannot grow a dependency
# surface by accident."
#
# WHY A RUNTIME GUARD AND NOT A NARROW TYPE. A narrow type is erased. `node as any`,
# `Reflect.get(node, 'getBlockHeader')`, and — the one that matters — a duck-typed helper that
# PROBES for a method before calling it all walk straight past it, and each is how a "narrow
# adapter" grows a surface without anyone editing its declaration. The probe case is the dangerous
# one because it fails SILENTLY in the safe-looking direction: `'getBlockHeader' in node` answering
# `false` makes the caller take another path, and nothing anywhere records that it asked.
#
# So `has` is trapped as well as `get`, and this check exercises both. `ownKeys` is deliberately NOT
# trapped and that is asserted here rather than left to the source comment: enumerating an object is
# not reaching for a method, and `console.log`/`util.inspect` of the adapter must keep working. That
# is the OPPOSITE call from `submitted_tx.ts`'s provenance seal, and for the opposite reason —
# there, disclosure IS the hazard; here the adapter has nothing to disclose and a debugging aid that
# throws is worse than no guard.
#
# EVERY ARM IS EXECUTED. Nothing here is read out of the source.

set -uo pipefail
TEST_NAME="test_aztec_node_adapter_surface_minimal"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m21_form_b.sh"

echo "== $TEST_NAME"
m21_prepare

PROBE="$(m21_imports)
$(cat <<'EOS'

const line = (k, v) => console.log(`${k} ${v}`);

// A stand-in for the wasm boundary. This check is about the SURFACE, not about the world state, so
// the boundary is a recorder: it proves the guard does not stop a permitted call from reaching the
// module, and it makes the nullifier arm answerable without a build.
const calls = [];
const fakeModule = {
  callWithBlob(name, handle, blob) {
    calls.push({ name, handle, bytes: blob.length });
    return { is_already_present: true, index: 42 };
  },
};

const raw = new ResidentSettledReadSource(fakeModule, 7);
const guarded = strictSurface(raw);

// ---- 1. the permitted member works, and reaches the module -----------------
const nullifierTree = SETTLED_READ_TREES[1];
const { Fr } = await import('@aztec/foundation/curves/bn254');
const found = await guarded.findLeavesIndexes(null, nullifierTree, [new Fr(99n)]);
line('permitted.answer', found[0]);
line('permitted.reachedModule', calls.length);
line('permitted.exportName', calls[0]?.name ?? 'none');

// ---- 2. every member outside the set throws, on GET ------------------------
// The names are AztecNode's own, so this is the exact accident the deliverable names.
const outside = ['getBlockHeader', 'getContractClass', 'simulatePublicCalls', 'sendTx',
                 'getChainTips', 'getTxEffect', 'getPublicStorageAt', 'getLogsByTags'];
let threw = 0, wrongError = 0;
for (const name of outside) {
  try { void guarded[name]; }
  catch (e) {
    if (e instanceof SettledReadSourceSurfaceExceeded && e.property === name) threw += 1;
    else wrongError += 1;
  }
}
line('get.outsideCount', outside.length);
line('get.threw', threw);
line('get.wrongError', wrongError);

// ---- 3. …and on `in`, which is how a duck-typed probe asks ----------------
let probeThrew = 0, probeAnswered = 0;
for (const name of outside) {
  try { if (name in guarded) probeAnswered += 1; else probeAnswered += 1; }
  catch (e) { if (e instanceof SettledReadSourceSurfaceExceeded) probeThrew += 1; }
}
line('has.threw', probeThrew);
line('has.answeredSilently', probeAnswered);

// ---- 4. the guard is not "throws at everything" ---------------------------
let permittedThrew = 0;
for (const name of ALLOWED_SURFACE) {
  try { void guarded[name]; } catch { permittedThrew += 1; }
}
line('permitted.count', ALLOWED_SURFACE.length);
line('permitted.threw', permittedThrew);

// ---- 5. THE UNGUARDED CONTROL ---------------------------------------------
// The raw object must NOT throw for the same names, or section 2 would be measuring the absence of
// a property rather than the presence of a guard.
let rawThrew = 0;
for (const name of outside) {
  try { void raw[name]; } catch { rawThrew += 1; }
}
line('control.rawThrew', rawThrew);

// ---- 6. ownKeys is deliberately open, and that is a decision -------------
let inspectable = 'no';
try {
  const util = await import('node:util');
  const s = util.inspect(guarded);
  inspectable = s.length > 0 ? 'yes' : 'empty';
  line('inspect.mentionsNothingSecret', s.includes('findLeavesIndexes') ? 'names-method' : 'plain');
} catch { inspectable = 'threw'; }
line('inspect.works', inspectable);
line('ownKeys.count', Object.keys(guarded).length);

// ---- 7. a tree the adapter cannot search is REFUSED, not answered undefined
// `verifyReadRequests` reads an `undefined` as "this leaf has not settled" and rejects the
// transaction, so answering it for a tree we cannot search would report an adapter limitation as a
// bad transaction. The failure direction is the point.
let refusedUnknownTree = 'no';
try { await guarded.findLeavesIndexes(null, 99, [new Fr(1n)]); }
catch (e) { refusedUnknownTree = e instanceof SettledReadSourceSurfaceExceeded ? 'yes' : 'wrong-type'; }
line('unknownTree.refused', refusedUnknownTree);

// ---- 8. the note-hash arm answers from the index this runtime feeds -------
const h = new Fr(1234n);
line('noteHash.beforeFeed', (await guarded.findLeavesIndexes(null, SETTLED_READ_TREES[0], [h]))[0]);
line('noteHash.appendedBefore', guarded.noteHashesAppended);
guarded.noteHashAppended(h, 5n);
line('noteHash.afterFeed', (await guarded.findLeavesIndexes(null, SETTLED_READ_TREES[0], [h]))[0]);
line('noteHash.appendedAfter', guarded.noteHashesAppended);
line('noteHash.otherValue', (await guarded.findLeavesIndexes(null, SETTLED_READ_TREES[0], [new Fr(5678n)]))[0]);

line('formB.done', 1);
EOS
)"

OUT="$M21_WORK/probes/surface.out"
m21_probe surface "$PROBE" >"$OUT"
RC=$?
# EXIT STATUS FIRST, THEN COMPLETENESS, and the order is load-bearing. A probe that THROWS part way
# leaves a partial transcript that is indistinguishable from the V8/WASI truncation, and asking the
# completeness question first makes the refusal tell the reader about a flake when what happened was
# an exception with a stack trace sitting in stderr. Measured, on this check's own first run.
assert_eq "the surface probe exited 0" "0" "$RC"
[ "$RC" -eq 0 ] || die "the surface probe exited $RC. Its stderr, which is where the reason is:
$(head -12 "$(m21_probe_err surface)")"
require_complete_transcript "$OUT" formB.done "the surface probe's"
assert_eq "…and its transcript is complete rather than truncated" "complete" \
  "$(transcript_completeness "$OUT" formB.done)"

f() { m21_field "$OUT" "$1"; }

echo "== 1. the permitted member works and reaches the module"
assert_eq "the nullifier arm answers with the index the module reported" "42" "$(f permitted.answer)"
assert_eq "…having made exactly one boundary call" "1" "$(f permitted.reachedModule)"
assert_eq "…to the export REACTOR-ABI.md names for an indexed low-leaf lookup" \
  "avm_merkle_db_get_low_indexed_leaf" "$(f permitted.exportName)"

echo "== 2. every AztecNode method outside the set throws on a plain read"
assert_ge "the outside set is a real set, not one name" 8 "$(f get.outsideCount)"
assert_eq "…and every one of them threw" "$(f get.outsideCount)" "$(f get.threw)"
assert_eq "…with the adapter's own error type and the property named" "0" "$(f get.wrongError)"

echo "== 3. and on 'in', which is how a duck-typed probe asks"
assert_eq "every 'in' probe threw too" "$(f get.outsideCount)" "$(f has.threw)"
assert_eq "…and not one of them was answered silently, which is the dangerous direction" "0" \
  "$(f has.answeredSilently)"

echo "== 4. the guard is not simply 'throws at everything'"
assert_eq "the permitted surface is four names" "4" "$(f permitted.count)"
assert_eq "…and not one of them threw" "0" "$(f permitted.threw)"

echo "== 5. the unguarded control"
assert_eq "the RAW object does not throw for those names, so section 2 measures the guard" "0" \
  "$(f control.rawThrew)"

echo "== 6. ownKeys is deliberately not trapped, and that is a decision"
assert_eq "util.inspect of the adapter still works" "yes" "$(f inspect.works)"
# THREE, not zero: `Object.keys` walks the RAW object's own enumerable fields (`module`, `handle`,
# `noteHashIndex`), and the `ownKeys` trap is deliberately absent so it can. The number is asserted
# exactly rather than as "does not throw", because "does not throw" is also true of a trap that
# returns nothing and would make `console.log` print `{}` — which is the shape `submitted_tx.ts`'s
# seal WANTS and this adapter does not.
assert_eq "Object.keys walks the object's own fields and does not throw" "3" "$(f ownKeys.count)"
# `plain`: `util.inspect` shows the instance's own FIELDS, not its prototype methods, so
# `findLeavesIndexes` is not in the string. Measured rather than expected — the first draft of this
# assertion guessed `names-method` and was wrong, which is why it is here as a measurement.
assert_eq "…and util.inspect shows the object's fields rather than its prototype methods" "plain" \
  "$(f inspect.mentionsNothingSecret)"

echo "== 7. a tree it cannot search is REFUSED rather than answered 'not settled'"
assert_eq "an unknown tree id throws instead of returning undefined" "yes" "$(f unknownTree.refused)"

echo "== 8. the note-hash arm answers from the index this runtime feeds"
assert_eq "before the append is recorded, the hash is not found" "undefined" \
  "$(f noteHash.beforeFeed)"
assert_eq "…and the index says it has seen nothing, which is a fact rather than an absence" "0" \
  "$(f noteHash.appendedBefore)"
assert_eq "after the append is recorded, the hash resolves to its index" "5" "$(f noteHash.afterFeed)"
assert_eq "…and the index says so" "1" "$(f noteHash.appendedAfter)"
assert_eq "…while a DIFFERENT value is still not found, so it is a lookup and not a constant" \
  "undefined" "$(f noteHash.otherValue)"

finish
