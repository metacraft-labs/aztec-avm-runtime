#!/usr/bin/env bash
# verify_node_client_surface_narrow — L0 (Aztec-Live-Chain-Replay).
#
# "Permitted methods reach through; every other AztecNode method throws on read AND on `in`.
#  Control: the raw client answers for all of them, so the guard is measured rather than an
#  absence."
#
# THE CONTROL IS THE POINT, and the milestone says so in as many words. This campaign has twice
# shipped an absence asked of a tree that excluded its subject by construction — "no published
# @aztec package ships a ForkCheckpoint", measured against a node_modules from which the package
# was deliberately missing, and then the same defect again on a containment claim, in a check whose
# own header cited the first. "The guard refuses `sendTx`" is worth nothing unless something in the
# same run demonstrates that `sendTx` was there to be refused. So every refusal below is paired
# with the SAME NAME read off `createUnguardedNodeClientForControls`, which is upstream's own
# client over the whole fifty-five-method schema, pointed at the SAME fake node, in the SAME
# process.
#
# WHY A RUNTIME GUARD AND NOT A NARROW TYPE. A narrow type is erased. `client as any`,
# `Reflect.get(client, 'sendTx')`, and — the one that matters — a duck-typed helper that PROBES for
# a method before calling it all walk straight past it. The probe case is the dangerous one because
# it fails SILENTLY in the safe-looking direction: `'sendTx' in client` answering `false` makes the
# caller take another path, and nothing anywhere records that it asked. So `has` is trapped as well
# as `get`, and this check exercises both, over every one of the forty-one.
#
# THE UNIVERSE IS RE-DERIVED FROM UPSTREAM AT THE PINNED ANCHOR, TWICE, ON EVERY RUN, and the
# refusal set the guard is tested against is COMPUTED FROM IT — upstream's fifty-five minus our
# fourteen — rather than read out of `replay/src`. A check that compared our list against our list
# is the tautology family this campaign has met more often than any other.
#
# Run: just verify-l0-surface

set -uo pipefail
TEST_NAME="verify_node_client_surface_narrow"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l0_node_client.sh"

echo "== $TEST_NAME"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -d "$FORK_ROOT" ] || die "the upstream fork is not at $FORK_ROOT.
     Every enumeration here is re-derived from the pinned anchor's object store, so this check
     cannot run without it. Only \`git show <anchor>:<path>\` is used, so a bare or partial clone
     is enough — no working tree has to be checked out at the anchor."
l0_prepare

CPP="$(l0_cpp_anchor)"
assert_ge "the cpp anchor was read from pins.json" 40 "${#CPP}"

IFACE_SRC="$(l0_at_anchor "$L0_NODE_IFACE_PATH")"
assert_ge "AztecNode's own declaration was read at the anchor" 700 \
  "$(printf '%s\n' "$IFACE_SRC" | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 1. the universe, re-derived from the anchor twice and compared as a set"
#
# When the derivation IS the number, run the derivation twice, differently, before believing it.
# M25's import-closure walker returned 47 files against a true 65 and was caught only because two
# independent walks disagreed; that is the instrument being copied here.
# ---------------------------------------------------------------------------
IFACE_SCAN="$(l0_anchor_node_members "$IFACE_SRC")"
SCHEMA_SCAN="$(l0_anchor_schema_keys "$IFACE_SRC")"

IFACE_N="$(printf '%s\n' "$IFACE_SCAN" | sed -n 's/^COUNT //p')"
SCHEMA_N="$(printf '%s\n' "$SCHEMA_SCAN" | sed -n 's/^COUNT //p')"
IFACE_SET="$(l0_members_of "$IFACE_SCAN")"
SCHEMA_SET="$(l0_members_of "$SCHEMA_SCAN")"

note "AztecNode at $CPP: interface $IFACE_N member(s), schema $SCHEMA_N key(s)"

# THE MILESTONE FILE SAYS FIFTY-ONE. IT IS FIFTY-FIVE, and this assertion is the correction.
# The campaign file states "fifty-one methods" twice and nothing had ever re-derived it — the
# "a figure nobody re-derives rots" family. The number is asserted exactly rather than as a range,
# so an upstream addition reddens here and somebody has to classify it in section 3.
assert_eq "AztecNode declares fifty-five methods at the anchor, not the fifty-one the milestone says" \
  "55" "$IFACE_N"
assert_eq "…and its JSON-RPC schema has one key per method" "$IFACE_N" "$SCHEMA_N"
assert_eq "…and the two derivations agree as a SET, not merely in size" "$IFACE_SET" "$SCHEMA_SET"

# THE SCANNERS PRINT THEIR RESIDUE, and the residue is asserted to be what it should be rather than
# to be empty. A class that is too narrow is a silent undercount; a scanner that reports what it
# cannot place turns that into a red line. Both residues here are the `): Promise<…>;` and `}),`
# continuation lines of multi-line declarations, so their COUNT is asserted non-zero — an empty
# residue would mean the scanner had swallowed the continuations too, and the member count could
# then be wrong in the other direction with nothing saying so.
IFACE_RESIDUE="$(printf '%s\n' "$IFACE_SCAN" | sed -n 's/^RESIDUE //p')"
SCHEMA_RESIDUE="$(printf '%s\n' "$SCHEMA_SCAN" | sed -n 's/^RESIDUE //p')"
note "residues: interface $IFACE_RESIDUE line(s), schema $SCHEMA_RESIDUE line(s)"
assert_ge "the interface scanner reports its residue, and it is not empty" 10 "$IFACE_RESIDUE"
assert_ge "the schema scanner reports its residue, and it is not empty" 10 "$SCHEMA_RESIDUE"
UNPLACED_NOT_CONT="$(printf '%s\n' "$IFACE_SCAN" "$SCHEMA_SCAN" | sed -n 's/^UNPLACED //p' \
  | grep -cvE '^(\): |\}\),$)' || true)"
assert_eq "…and every unplaced line is a multi-line declaration's continuation, not a missed member" \
  "0" "$UNPLACED_NOT_CONT"

# THE SCANNER CAN FIND THINGS, AND CAN FAIL TO. Two controls, because a scanner that returned the
# same list whatever it was given would satisfy everything above.
PLANTED="$(printf '%s\n' "$IFACE_SRC" \
  | awk '/^export interface AztecNode/ { print; print "  aFabricatedMethodName(x: number): Promise<void>;"; next } { print }')"
PLANTED_N="$(l0_anchor_node_members "$PLANTED" | sed -n 's/^COUNT //p')"
assert_eq "with one planted member the same scanner reports fifty-six" "56" "$PLANTED_N"
EMPTY_N="$(l0_anchor_node_members "$(printf 'export interface SomethingElse {\n  a(): void;\n}\n')" \
  | sed -n 's/^COUNT //p')"
assert_eq "…and a source with no AztecNode in it yields nothing rather than a stale answer" "0" \
  "$EMPTY_N"

# ---------------------------------------------------------------------------
echo "== 2. the two disputed classifications, decided from the AVM's own opcode set"
#
# `node_surface.ts` refuses `getBlockHashMembershipWitness` though L2's route-1 list names it, and
# permits `getL1ToL2MessageMembershipWitness` though that list does not. Both rest on which
# world-state READS the AVM can perform, and both are asserted from that source here rather than
# from the prose that describes it.
# ---------------------------------------------------------------------------
OPCODES="$(l0_at_anchor 'barretenberg/cpp/src/barretenberg/vm2/common/opcodes.hpp')"
assert_ge "the AVM's opcode enum was read at the anchor" 100 \
  "$(printf '%s\n' "$OPCODES" | grep -c . || true)"
assert_true "L1TOL2MSGEXISTS is an AVM opcode, so the L1-to-L2 message tree IS read" \
  str_has_word "$OPCODES" "L1TOL2MSGEXISTS"
for op in SLOAD NOTEHASHEXISTS NULLIFIEREXISTS GETCONTRACTINSTANCE; do
  assert_true "…and so is $op" str_has_word "$OPCODES" "$op"
done
# The other direction, so "is an opcode" is a discriminating test rather than one that says yes to
# anything: the archive read that would justify getBlockHashMembershipWitness is NOT there.
for absent in BLOCKHASH ARCHIVEEXISTS GETBLOCKHASH; do
  if str_has_word "$OPCODES" "$absent"; then found=yes; else found=no; fi
  assert_eq "…while $absent is not an opcode, which is why the archive witness has no reader" \
    "no" "$found"
done

# ---------------------------------------------------------------------------
echo "== 3. the probe: the declaration, the partition, and the guard"
#
# ONE probe, so the classification and the behaviour are measured over the same loaded module.
# The universe it is given is the ANCHOR's, injected by this check; everything the probe reports
# about our own declaration is compared against that.
#
# THE MECHANISM THAT MAKES THIS LAST: upstream adding a fifty-sixth method leaves it unclassified,
# and `partition.unclassified` names it and this check goes red. An unclassified method is a
# failure, not a default — which is the difference between an enumeration and a snapshot.
# ---------------------------------------------------------------------------
ANCHOR_JS="$(printf '%s\n' "$IFACE_SET" | sed "s/^/  '/; s/$/',/")"

PROBE="$(l0_imports)
$(cat <<EOS

// UPSTREAM'S FIFTY-FIVE, derived from the pinned anchor by the check that wrote this probe.
const ANCHOR_METHODS = [
$ANCHOR_JS
];
EOS
)
$(cat <<'EOS'

import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecNodeApiSchema } from '@aztec/stdlib/interfaces/client';

const anchor = new Set(ANCHOR_METHODS);
const permitted = [...REPLAY_NODE_SURFACE];
const refusedDeclared = [...REFUSED_METHODS];

// ---- 1. the declaration, and how it partitions upstream's set --------------
line('declared.permitted', permitted.length);
line('declared.refused', refusedDeclared.length);
line('declared.groups', REFUSAL_GROUPS.length);
line('declared.sum', permitted.length + refusedDeclared.length);
line('declared.count', AZTEC_NODE_METHOD_COUNT);
line('declared.duplicateRefusals', refusedDeclared.length - new Set(refusedDeclared).size);
line('declared.overlap', permitted.filter((m) => refusedDeclared.includes(m)).length);
line('declared.groupsWithoutReason',
     REFUSAL_GROUPS.filter((g) => !g.reason || g.reason.length < 80).length);
line('declared.smallestGroup', Math.min(...REFUSAL_GROUPS.map((g) => g.methods.length)));
line('declared.continuousFollowing',
     (REFUSAL_GROUPS.find((g) => g.id === 'CONTINUOUS_FOLLOWING')?.methods.length) ?? 0);

const classified = new Set([...permitted, ...refusedDeclared]);
const unclassified = ANCHOR_METHODS.filter((m) => !classified.has(m));
const invented = [...classified].filter((m) => !anchor.has(m));
line('partition.unclassified', unclassified.join(',') || 'none');
line('partition.unclassifiedCount', unclassified.length);
line('partition.invented', invented.join(',') || 'none');
line('partition.inventedCount', invented.length);

// The two disputed names, by name, so reversing either is a red line and not an edit.
line('disputed.l1ToL2Permitted', permitted.includes('getL1ToL2MessageMembershipWitness') ? 'yes' : 'no');
line('disputed.archiveRefused', refusedDeclared.includes('getBlockHashMembershipWitness') ? 'yes' : 'no');
for (const streaming of ['getBlocks', 'getCheckpoints', 'getChainTips', 'getWorldStateSyncStatus']) {
  line(`streaming.${streaming}`, refusedDeclared.includes(streaming) ? 'refused' : 'PERMITTED');
}

// THE REFUSAL SET THE GUARD IS TESTED AGAINST IS UPSTREAM'S MINUS OURS, not ours.
const REFUSED_AT_ANCHOR = ANCHOR_METHODS.filter((m) => !permitted.includes(m));

const node = await startFakeNode({ versions: PINNED_PROTOCOL_VERSION });
const guarded = createReplayNodeClient({ url: node.url });
// THE CONTROL OBJECT. Upstream's own client over the whole schema, same url, same process.
const raw = createUnguardedNodeClientForControls(node.url);

// ---- 2. permitted members reach through, and reach the NODE ----------------
// "Reached through" is asserted from the NODE's own record of what it was asked, not from the
// client's account of what it sent — the client is the thing under test.
const hash = TxHash.fromField(new Fr(42n));
const reached = [];
for (const [name, call] of [
  ['getBlockNumber', () => guarded.getBlockNumber()],
  ['getNodeInfo', () => guarded.getNodeInfo()],
  ['getTxByHash', () => guarded.getTxByHash(hash)],
  ['getTxsByHash', () => guarded.getTxsByHash([hash])],
  ['getTxEffect', () => guarded.getTxEffect(hash)],
  ['getBlockData', () => guarded.getBlockData(1)],
]) {
  try {
    const answer = await call();
    if (answer !== undefined && answer !== null) { reached.push(name); }
  } catch (e) {
    line('permitted.unexpectedThrow', `${name}: ${e.message}`);
  }
}
line('permitted.called', reached.length);
line('permitted.reachedNode', node.calls.length);
line('permitted.nodeSawAll', reached.every((n) => node.calls.includes(n)) ? 'yes' : 'no');

// Every permitted name is readable and is a function, so "the guard lets fourteen through" is
// measured over all fourteen rather than over the six that have fixtures.
let permittedThrew = 0, permittedNotFunction = 0;
for (const name of permitted) {
  try { if (typeof guarded[name] !== 'function') { permittedNotFunction += 1; } }
  catch { permittedThrew += 1; }
}
line('permitted.count', permitted.length);
line('permitted.threw', permittedThrew);
line('permitted.notFunction', permittedNotFunction);

// The adapter's own members are readable too, or the guard would be refusing its own object.
let ownThrew = 0;
for (const name of REPLAY_CLIENT_OWN_MEMBERS) {
  try { void guarded[name]; } catch { ownThrew += 1; }
}
line('own.count', REPLAY_CLIENT_OWN_MEMBERS.length);
line('own.threw', ownThrew);

// ---- 3. every OTHER AztecNode method throws on a plain read ----------------
let getThrew = 0, getWrongError = 0, getSilent = 0;
for (const name of REFUSED_AT_ANCHOR) {
  try { void guarded[name]; getSilent += 1; }
  catch (e) {
    if (e instanceof ReplayNodeSurfaceExceeded && e.property === name) { getThrew += 1; }
    else { getWrongError += 1; }
  }
}
line('get.outsideCount', REFUSED_AT_ANCHOR.length);
line('get.threw', getThrew);
line('get.wrongError', getWrongError);
line('get.answeredSilently', getSilent);

// ---- 4. …and on `in`, which is how a duck-typed probe asks ----------------
let hasThrew = 0, hasAnswered = 0;
for (const name of REFUSED_AT_ANCHOR) {
  try { if (name in guarded) { hasAnswered += 1; } else { hasAnswered += 1; } }
  catch (e) { if (e instanceof ReplayNodeSurfaceExceeded) { hasThrew += 1; } }
}
line('has.threw', hasThrew);
line('has.answeredSilently', hasAnswered);

// ---- 5. THE CONTROL: the raw client answers for all of them ----------------
// Upstream's client is an object with one key per SCHEMA method, so a name the installed package's
// schema carries reads as a function and `in` is true. The anchor's set and the package's set
// differ by exactly one name (declared in node_surface.ts), so the control is taken over the
// intersection and the one exception is measured rather than skipped.
const schemaKeys = new Set(Object.keys(AztecNodeApiSchema));
const controllable = REFUSED_AT_ANCHOR.filter((n) => schemaKeys.has(n));
const notInPackage = REFUSED_AT_ANCHOR.filter((n) => !schemaKeys.has(n));
let rawAnswered = 0, rawThrew = 0, rawIn = 0;
for (const name of controllable) {
  try {
    if (typeof raw[name] === 'function') { rawAnswered += 1; }
    if (name in raw) { rawIn += 1; }
  } catch { rawThrew += 1; }
}
line('control.controllable', controllable.length);
line('control.rawAnswered', rawAnswered);
line('control.rawIn', rawIn);
line('control.rawThrew', rawThrew);
line('control.notInPackage', notInPackage.join(',') || 'none');
line('control.notInPackageCount', notInPackage.length);

// And the control object is not "an object that answers for anything": a fabricated name is
// absent from it. Without this, `control.rawAnswered` would be satisfied by a Proxy that says yes
// to everything, and the control would control nothing.
let rawFabricated = 'answered';
try { rawFabricated = typeof raw['aFabricatedMethodName'] === 'function' ? 'answered' : 'absent'; }
catch { rawFabricated = 'threw'; }
line('control.rawFabricated', rawFabricated);

// ---- 6. ownKeys is deliberately NOT trapped, and that is a decision --------
let inspectable = 'no';
try {
  const util = await import('node:util');
  inspectable = util.inspect(guarded).length > 0 ? 'yes' : 'empty';
} catch { inspectable = 'threw'; }
line('inspect.works', inspectable);
let keysThrew = 'no';
let keyCount = -1;
try { keyCount = Object.keys(guarded).length; } catch { keysThrew = 'yes'; }
line('ownKeys.threw', keysThrew);
line('ownKeys.count', keyCount);

// ---- 7. the guard is the object's, not the class's ------------------------
// `Reflect.get` and a cast both go through the same trap, which is the whole reason the guard is a
// proxy and not a type.
let reflectThrew = 'no';
try { Reflect.get(guarded, 'sendTx'); } catch (e) { reflectThrew = e.kind ?? 'wrong-type'; }
line('reflect.get', reflectThrew);

// ---- 8. `strictSurface` is not "throws at everything" ---------------------
// A guard that refused every name would satisfy sections 3 and 4 and be useless. Exercised on a
// throwaway object with a list this check owns, so the property is measured independently of the
// client's own allow-list.
const toy = strictSurface({ a: 1, b: 2 }, ['a']);
let toyA = 'threw', toyB = 'answered';
try { toyA = String(toy.a); } catch { toyA = 'threw'; }
try { void toy.b; toyB = 'answered'; } catch (e) { toyB = e.kind ?? 'wrong-type'; }
line('guard.permittedValue', toyA);
line('guard.refusedValue', toyB);

await node.close();
line('l0.done', 1);
EOS
)"

OUT="$L0_WORK/probes/surface.out"
l0_run_probe surface "$PROBE" "$OUT"
f() { l0_field "$OUT" "$1"; }

echo "== 4. the partition: fourteen permitted, forty-one refused, nothing unclassified"
note "permitted $(f declared.permitted), refused $(f declared.refused), in $(f declared.groups) group(s)"
assert_eq "the permitted surface is fourteen of the fifty-five" "14" "$(f declared.permitted)"
assert_eq "…and the refused set is forty-one" "41" "$(f declared.refused)"
assert_eq "…and 14 + 41 is the number upstream declares at the anchor" "$IFACE_N" "$(f declared.sum)"
assert_eq "…which is also the constant node_surface.ts publishes" "$IFACE_N" "$(f declared.count)"
assert_ge "…across several refusal groups" 5 "$(f declared.groups)"
assert_eq "…every one of which states a substantive reason" "0" "$(f declared.groupsWithoutReason)"
assert_ge "…and none of which is a group of one dressed up as a category" 2 \
  "$(f declared.smallestGroup)"
assert_eq "no method is in two refusal groups" "0" "$(f declared.duplicateRefusals)"
assert_eq "no method is both permitted and refused" "0" "$(f declared.overlap)"
assert_eq "every AztecNode method at the anchor is classified — nothing is left over" "none" \
  "$(f partition.unclassified)"
assert_eq "…and nothing is classified that AztecNode does not declare" "none" \
  "$(f partition.invented)"

assert_eq "getL1ToL2MessageMembershipWitness is PERMITTED, because L1TOL2MSGEXISTS exists" "yes" \
  "$(f disputed.l1ToL2Permitted)"
assert_eq "getBlockHashMembershipWitness is REFUSED, because the AVM never reads the archive" "yes" \
  "$(f disputed.archiveRefused)"
assert_ge "the continuous-following refusal group is a real set, not a token" 8 \
  "$(f declared.continuousFollowing)"
for streaming in getBlocks getCheckpoints getChainTips getWorldStateSyncStatus; do
  assert_eq "$streaming is refused: an ingestion pipeline is a different milestone" "refused" \
    "$(f "streaming.$streaming")"
done

echo "== 5. permitted methods reach through, and reach the node"
assert_eq "six permitted methods were called and every one of them answered" "6" "$(f permitted.called)"
assert_ge "…and the node recorded being asked" 6 "$(f permitted.reachedNode)"
assert_eq "…for exactly those methods, so the answers came over the wire" "yes" "$(f permitted.nodeSawAll)"
assert_eq "all fourteen permitted names are readable through the guard" "14" "$(f permitted.count)"
assert_eq "…and not one of them threw" "0" "$(f permitted.threw)"
assert_eq "…and every one of them is a function" "0" "$(f permitted.notFunction)"
assert_ge "the adapter's own members are declared" 6 "$(f own.count)"
assert_eq "…and the guard does not refuse its own object" "0" "$(f own.threw)"

echo "== 6. every other AztecNode method throws, on read"
assert_eq "the refused set the guard was tested against is upstream's forty-one" "41" \
  "$(f get.outsideCount)"
assert_eq "…and every one of them threw" "$(f get.outsideCount)" "$(f get.threw)"
assert_eq "…with the adapter's own error type and the property named" "0" "$(f get.wrongError)"
assert_eq "…and not one was answered" "0" "$(f get.answeredSilently)"

echo "== 7. …and on 'in', which is the dangerous direction"
assert_eq "every 'in' probe threw too" "$(f get.outsideCount)" "$(f has.threw)"
assert_eq "…and not one of them was answered silently" "0" "$(f has.answeredSilently)"

echo "== 8. THE CONTROL: the raw client answers for all of them"
assert_ge "the control set is nearly the whole refused set" 40 "$(f control.controllable)"
assert_eq "…and upstream's own client answers for every one of them" "$(f control.controllable)" \
  "$(f control.rawAnswered)"
assert_eq "…including on 'in', so section 7 measures a guard and not an absence" \
  "$(f control.controllable)" "$(f control.rawIn)"
assert_eq "…and the raw client threw for none of them" "0" "$(f control.rawThrew)"
assert_eq "…while a fabricated method name is ABSENT from the raw client" "absent" \
  "$(f control.rawFabricated)"
assert_eq "exactly one refused name is at the anchor and not in the installed package" "1" \
  "$(f control.notInPackageCount)"
assert_eq "…and it is the one node_surface.ts declares" "getL1ToL2MessageIndex" \
  "$(f control.notInPackage)"

echo "== 9. the guard is not simply 'throws at everything'"
assert_eq "a permitted member of a throwaway guarded object reads its value" "1" \
  "$(f guard.permittedValue)"
assert_eq "…and a refused one throws" "replay-node-surface-exceeded" "$(f guard.refusedValue)"

echo "== 10. ownKeys is deliberately open, and that is a decision"
assert_eq "util.inspect of the client still works" "yes" "$(f inspect.works)"
assert_eq "…and Object.keys does not throw" "no" "$(f ownKeys.threw)"
assert_ge "…and reports the object's own fields, so a debugging aid stays possible" 14 \
  "$(f ownKeys.count)"

echo "== 11. the guard is on the object, so a cast cannot get past it"
assert_eq "Reflect.get of a refused name throws the adapter's own refusal" \
  "replay-node-surface-exceeded" "$(f reflect.get)"

finish
