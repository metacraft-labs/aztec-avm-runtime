#!/usr/bin/env bash
# test_provenance_not_consulted_during_execution — M20, and DD-1's actual deliverable.
#
# The deliverable: "SubmittedTx { tx, provenance: { kind: 'external' } } per DD-1. The boundary is
# Tx; provenance is metadata alongside it, never inside it, and is ASSERTED-UNUSED INSIDE
# EXECUTION so the engine cannot behave differently for transactions we originated."
#
# THE TYPE IS NOT THE DELIVERABLE AND THIS CHECK IS SHAPED AROUND THAT. A record with two fields
# proves nothing: a `provenance.kind === 'local'` branch could be added tomorrow and every type
# would still check. Four independent claims are asserted here, each capable of failing on its
# own, and the fourth is the one that would catch the branch.
#
#   1. STRUCTURAL — no executing export accepts a `SubmittedTx`. DD-1 as an export-surface
#      property: a consumer cannot hand provenance to the simulator because the simulator's
#      parameter is a `Tx`.
#   2. OBSERVATIONAL — the seal traps every way a plain object can be observed, not just `get`.
#      Five traps, five assertions, and each is proved by making an observation of that kind.
#   2b. THE UNTRAPPABLE CHANNEL — and five traps were NOT enough. Node's `util.inspect` (hence
#      `console.log`, `console.dir`, `%o`, the REPL) reads a proxy's TARGET through V8's debug
#      API, bypassing every handler. A seal built over the provenance object itself therefore
#      prints `{ kind: 'local' }` to `util.inspect` with `reads` still EMPTY — a working
#      provenance branch no trap can see, and no sixth trap would have closed it. The shipped seal
#      proxies an EMPTY target instead. Asserted with the naive shape built beside it as the
#      control, so the probe answers in both directions rather than only in the safe one.
#   3. BEHAVIOURAL, THROUGH THE REAL MODULE — the same transaction under `external` and under
#      `local` produces byte-identical reports, on all SEVEN arms, including the ones that revert
#      and the ones that are thrown out.
#   4. THE MUTATION CONTROL — a copy of `form_a.ts` with ONE line added to `runPublicHalf` that
#      reads the provenance. If the tripwire is real, that copy throws
#      `ProvenanceConsultedDuringExecution`; the unmutated copy does not. Without this arm the
#      tripwire would "pass" by never firing, which is the defect this campaign has now found
#      twenty times.
#
# THE MUTATION IS APPLIED TO A COPY, NOT TO THE TREE. `orchestration/src/form_a.ts` is never
# written to. The copy lands under $M20_WORK, is compared line by line against the original so
# that "one line added, nothing else changed" is measured rather than assumed, and is removed on
# exit. A check that edited the file it is asserting about would leave a mutated tree behind if it
# were interrupted — this campaign has had a mutated artefact outlive a restored source.
#
# Run: just verify-form-a-provenance

TEST_NAME="test_provenance_not_consulted_during_execution"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_packages
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/provenance.XXXXXX")" || die "no scratch under $M20_WORK"
# The probes live UNDER orchestration/src, dot-prefixed. They have to: a copy of `form_a.ts`
# imports `./submitted_tx.ts` relatively, so a copy anywhere else is `ERR_MODULE_NOT_FOUND` — which
# is how the first version of this check failed, and it failed LOUDLY rather than passing, which is
# the direction to fail in. The trap removes them on every exit path including an interrupt.
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.m20_"*' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — structural: no executing export accepts a SubmittedTx
# ---------------------------------------------------------------------------

assert_file "form_a.ts is present" "$ORCH_SRC/form_a.ts"
assert_file "submitted_tx.ts is present" "$ORCH_SRC/submitted_tx.ts"

# The simulator interface the execution path calls through takes a `Tx`.
assert_eq "PublicTxSimulatorLike.simulate takes a Tx, not a SubmittedTx" "1" \
  "$(grep -c 'simulate(tx: Tx): Promise<PublicTxResult>;' "$ORCH_SRC/form_a.ts")"
assert_eq "and upstream's own simulator, which we wrap, does too" "1" \
  "$(grep -c 'async simulate(tx: Tx): Promise<PublicTxResult>' "$ORCH_SRC/wasm_avm_public_tx_simulator.ts")"

# THE WORD `provenance` MEANS TWO DIFFERENT THINGS IN THIS REPOSITORY, and a bare `grep -w` for
# it cannot tell them apart. DD-1's is a transaction's origin. The OTHER one is the vendoring
# system — `PROVENANCE.md`, `tools/provenance.py`, `verify_provenance_complete` — and a comment
# citing that machinery is not a use of the first at all. This assertion went red the moment
# `tx_intake.ts` acquired a line reading "`PROVENANCE.md` + `tools/provenance.py`", which is
# exactly the kind of false positive that gets a real check deleted.
#
# So the needle is the IDENTIFIER, not the word: `.provenance`, `provenance:`, `provenance)`,
# `provenance,` or a declaration of it — the forms a TypeScript file uses to touch the field —
# and never a bare occurrence inside a path or a prose citation. The two controls below are what
# make that narrowing safe rather than a way of excusing hits.
provenance_uses() { # <file>
  grep -cE '(\.provenance\b|\bprovenance[:,)]|\bprovenance\s*=|\bprovenance\?)' "$1" || true
}

for forbidden in avm_inputs.ts wasm_avm_public_tx_simulator.ts resident_db.ts \
                 shipped_module_config.ts tx_intake.ts fee_juice.ts ; do
  assert_eq "$forbidden never USES provenance (the identifier, not the word)" "0" \
    "$(provenance_uses "$ORCH_SRC/$forbidden")"
done

# The control for that family of greps: a file that DOES mention it must be found by the same
# command, or the six above are six greps that cannot match anything.
# CONTROL 1 — the same needle over the file that is ABOUT the field must find it. A needle that
# cannot match anything is not an assertion.
assert_ge "and the same needle DOES find it where it belongs" 5 \
  "$(provenance_uses "$ORCH_SRC/submitted_tx.ts")"

# CONTROL 2 — the narrowing must not be a way of excusing a real use. A file that merely CITES the
# vendoring machinery scores zero; the same file with one added `submitted.provenance` read scores
# one. Both measured on a probe, so the discrimination is executed rather than argued.
cite_probe="$SCRATCH/cite_only.ts"
printf '// see PROVENANCE.md and tools/provenance.py for the vendoring rules\nexport const x = 1;\n' > "$cite_probe"
assert_eq "a comment citing PROVENANCE.md and tools/provenance.py is NOT a use" "0" \
  "$(provenance_uses "$cite_probe")"
assert_eq "and the old bare-word grep DID count it, which is why it was narrowed" "1" \
  "$(grep -cw 'provenance' "$cite_probe" || true)"
printf 'export const y = (s: { provenance: string }) => s.provenance;\n' >> "$cite_probe"
assert_ge "while one real read of the field IS counted" 1 "$(provenance_uses "$cite_probe")"

# ---------------------------------------------------------------------------
# PART 2 — observational: every trap fires, not just `get`
# ---------------------------------------------------------------------------

cat > "$SCRATCH/traps.mjs" <<'EOF'
import { externalTx, provenanceReadsDuring } from './index.ts';
const observations = {
  get:                      s => { void s.provenance.kind; },
  has:                      s => { void ('kind' in s.provenance); },
  ownKeys:                  s => { void Object.keys(s.provenance); },
  getOwnPropertyDescriptor: s => { void Object.getOwnPropertyDescriptor(s.provenance, 'kind'); },
  getPrototypeOf:           s => { void Object.getPrototypeOf(s.provenance); },
  spread:                   s => { void ({ ...s.provenance }); },
  stringify:                s => { void JSON.stringify(s.provenance); },
  none:                     s => { void s.tx; },
};
const out = {};
for (const [name, body] of Object.entries(observations)) {
  out[name] = provenanceReadsDuring(externalTx({ marker: 1 }), body);
}
console.log(JSON.stringify(out));
EOF
cp "$SCRATCH/traps.mjs" "$ORCH_SRC/.m20_traps.mjs"
TRAPS="$(cd "$ORCH_SRC" && node .m20_traps.mjs 2>&1)" || die "the trap probe failed: $TRAPS"
rm -f "$ORCH_SRC/.m20_traps.mjs"
printf '%s\n' "$TRAPS" | sed 's/^/      /'

trap_fired() { # <observation-name> <trap-name>
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
reads = d.get(sys.argv[2])
print("MISSING" if reads is None else ("yes" if any(r.split(":")[0] == sys.argv[3] for r in reads) else "no"))' \
    "$TRAPS" "$1" "$2"
}

assert_eq "reading a property fires the get trap" "yes" "$(trap_fired get get)"
assert_eq "an 'in' test fires the has trap" "yes" "$(trap_fired has has)"
assert_eq "Object.keys fires the ownKeys trap" "yes" "$(trap_fired ownKeys ownKeys)"
assert_eq "getOwnPropertyDescriptor fires its own trap" "yes" \
  "$(trap_fired getOwnPropertyDescriptor getOwnPropertyDescriptor)"
assert_eq "Object.getPrototypeOf fires the getPrototypeOf trap" "yes" \
  "$(trap_fired getPrototypeOf getPrototypeOf)"
assert_eq "a spread is caught (it is ownKeys plus a descriptor walk)" "yes" \
  "$(trap_fired spread ownKeys)"
assert_eq "JSON.stringify is caught" "yes" "$(trap_fired stringify get)"

# THE NEGATIVE CASE. Touching only `.tx` records nothing at all — without this, "the reads list
# was non-empty" would be true of a seal that fired on everything including nothing.
assert_eq "reading only .tx records no observation whatever" "[]" \
  "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["none"]))' "$TRAPS")"

# ---------------------------------------------------------------------------
# PART 2b — the channel NO proxy can trap, and the shape that closes it
# ---------------------------------------------------------------------------
#
# The five traps above are the complete set for ECMASCRIPT, and they are not sufficient on their
# own. Node's `util.inspect` — hence `console.log`, `console.dir`, `util.format('%o')` and the
# REPL — reads a proxy's TARGET through V8's debug API, which bypasses every handler. Sealing the
# provenance object ITSELF therefore leaves `util.inspect(sealed)` printing `{ kind: 'local' }`
# with `reads` still empty, which is a working provenance branch the tripwire cannot see. The
# shipped seal proxies an EMPTY target and serves reads from a closure, so there is nothing in the
# target to disclose.
#
# THE CONTROL IS THE OLD SHAPE, BUILT HERE. Asserting only "the shipped seal discloses nothing"
# would pass against a Node that had stopped disclosing anything, or against a probe that had
# failed to inspect at all. So the probe builds the naive proxy beside it and the check asserts
# that THAT one DOES disclose the kind. One tree, both answers.

cat > "$SCRATCH/inspect.mjs" <<'EOF'
import util from 'node:util';
import { sealProvenance, externalTx, locallyOriginatedTx } from './submitted_tx.ts';

// The naive shape this file used to have: every trap installed, but over the real object.
function naiveSeal(provenance) {
  const reads = [];
  const observe = t => reads.push(t);
  return {
    sealed: new Proxy(provenance, {
      get(t, p, r) { observe('get'); return Reflect.get(t, p, r); },
      has(t, p) { observe('has'); return Reflect.has(t, p); },
      ownKeys(t) { observe('ownKeys'); return Reflect.ownKeys(t); },
      getOwnPropertyDescriptor(t, p) { observe('gOPD'); return Reflect.getOwnPropertyDescriptor(t, p); },
      getPrototypeOf(t) { observe('getPrototypeOf'); return Reflect.getPrototypeOf(t); },
    }),
    reads,
  };
}

const out = {};
for (const [name, provenance] of [['external', externalTx(0).provenance], ['local', locallyOriginatedTx(0).provenance]]) {
  const shipped = sealProvenance(provenance, () => { throw new Error('the shipped seal fired'); });
  const naive = naiveSeal(provenance);
  out[name] = {
    shippedInspect: util.inspect(shipped.sealed),
    shippedReads: shipped.reads.length,
    naiveInspect: util.inspect(naive.sealed),
    naiveReads: naive.reads.length,
  };
  // The values must still be right, or "it discloses nothing" would be true of a broken seal.
  const seen = sealProvenance(provenance, () => {});
  out[name].kind = seen.sealed.kind;
  out[name].keys = Object.keys(seen.sealed).join(',');
  out[name].spread = JSON.stringify({ ...seen.sealed });
  out[name].descriptorConfigurable = Object.getOwnPropertyDescriptor(seen.sealed, 'kind')?.configurable ?? null;
  out[name].readsAfter = seen.reads.length;
}
console.log(JSON.stringify(out));
EOF
cp "$SCRATCH/inspect.mjs" "$ORCH_SRC/.m20_inspect.mjs"
INSPECT="$(cd "$ORCH_SRC" && node .m20_inspect.mjs 2>&1 | tail -1)" || die "the inspect probe failed: $INSPECT"
rm -f "$ORCH_SRC/.m20_inspect.mjs"
printf '%s\n' "$INSPECT" | sed 's/^/      /'

ins() { python3 -c '
import json, sys
d = json.loads(sys.argv[1]).get(sys.argv[2])
if d is None:
    print("MISSING"); raise SystemExit
v = d.get(sys.argv[3], "MISSING")
print("MISSING" if v is None else str(v))' "$INSPECT" "$1" "$2"; }

# THE CONTROL FIRST: the naive shape leaks, so the assertions below are asking a question this
# probe can answer in the other direction.
assert_eq "the NAIVE seal — every trap, but over the real object — discloses the kind to util.inspect" \
  "{ kind: 'local' }" "$(ins local naiveInspect)"
assert_eq "and it does so without firing a single trap, which is why no sixth trap would have helped" \
  "0" "$(ins local naiveReads)"

assert_eq "the SHIPPED seal discloses nothing at all under util.inspect, for local" "{}" \
  "$(ins local shippedInspect)"
assert_eq "and for external" "{}" "$(ins external shippedInspect)"
assert_eq "so the two provenances are indistinguishable through that channel" \
  "$(ins external shippedInspect)" "$(ins local shippedInspect)"
assert_eq "and inspecting it fired no trap either, so the seal is not merely throwing instead" "0" \
  "$(ins local shippedReads)"

# Non-disclosure is worthless if the seal stopped working. Every value is still right.
assert_eq "the sealed provenance still reads its own kind" "local" "$(ins local kind)"
assert_eq "and external's" "external" "$(ins external kind)"
assert_eq "Object.keys still reports the key" "kind" "$(ins local keys)"
assert_eq "a spread still reproduces the object" '{"kind":"local"}' "$(ins local spread)"
assert_eq "the reported descriptor is configurable, which the empty target's invariants require" \
  "True" "$(ins local descriptorConfigurable)"
assert_ge "and all of that was recorded as observations rather than passing silently" 4 \
  "$(ins local readsAfter)"

# ---------------------------------------------------------------------------
# PART 3 — behavioural, through the real module: the two provenances agree
# ---------------------------------------------------------------------------

m20_require_arms

DISAGREE="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
bad = [a["arm"] for a in doc["arms"] if not a["provenanceAgnostic"]]
print(",".join(bad) if bad else "none")' "$M20_ARMS")"
assert_eq "every arm produced the same report under external and local provenance" "none" "$DISAGREE"

# And that claim is only worth having if the arms REACHED different outcomes — otherwise "they
# agree" is true of a suite in which nothing happened.
DISTINCT="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(len({json.dumps(a["external"], sort_keys=True) for a in doc["arms"]}))' "$M20_ARMS")"
assert_ge "and the arms reached at least four DIFFERENT outcomes, so agreement is not trivial" 4 \
  "$DISTINCT"

# ---------------------------------------------------------------------------
# PART 4 — the mutation control: a read inside the window must throw
# ---------------------------------------------------------------------------

PRISTINE="$SCRATCH/form_a.pristine.ts"
MUTATED="$SCRATCH/form_a.mutated.ts"
cp "$ORCH_SRC/form_a.ts" "$PRISTINE"

python3 - "$PRISTINE" "$MUTATED" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
needle = "  return await simulator.simulate(sealed.tx);"
hits = [i for i, l in enumerate(lines) if l == needle]
if len(hits) != 1:
    sys.stderr.write(f"expected exactly one execution-window line, found {len(hits)}\n")
    sys.exit(3)
i = hits[0]
lines.insert(i, "  void (sealed.provenance as { kind: string }).kind;")
open(dst, "w").write("\n".join(lines))
PY
[ -s "$MUTATED" ] || die "the mutation could not be applied; the execution-window line moved"

# "One line added, nothing else changed" — measured, because a mutation that also changed
# something else would make the throw prove the wrong thing.
assert_eq "the mutated copy is exactly one line longer" "1" \
  "$(python3 -c '
import sys
a = open(sys.argv[1]).read().split("\n"); b = open(sys.argv[2]).read().split("\n")
print(len(b) - len(a))' "$PRISTINE" "$MUTATED")"
assert_eq "and every original line survives, in order" "0" \
  "$(python3 -c '
import sys
a = open(sys.argv[1]).read().split("\n"); b = open(sys.argv[2]).read().split("\n")
it = iter(b); missing = 0
for line in a:
    for cand in it:
        if cand == line: break
    else:
        missing += 1
print(missing)' "$PRISTINE" "$MUTATED")"

run_arm() { # <form_a copy> -> verdict
  cp "$1" "$ORCH_SRC/.m20_form_a_under_test.ts"
  cat > "$ORCH_SRC/.m20_run.mjs" <<'EOF'
import { executeExternallySettledTx } from './.m20_form_a_under_test.ts';
import { externalTx } from './submitted_tx.ts';
const simulator = { async simulate() { return { revertCode: { getCode: () => 0, isOK: () => true } }; } };
try {
  const outcome = await executeExternallySettledTx(externalTx({ marker: 1 }), simulator);
  console.log('returned:' + outcome.kind);
} catch (error) {
  console.log((error?.kind ?? error?.name ?? 'unknown') + ':' + (error?.trap ?? '') + ':' + (error?.property ?? ''));
}
EOF
  ( cd "$ORCH_SRC" && node .m20_run.mjs 2>&1 | tail -1 ) || true
  rm -f "$ORCH_SRC/.m20_form_a_under_test.ts" "$ORCH_SRC/.m20_run.mjs"
}

PRISTINE_VERDICT="$(run_arm "$PRISTINE")"
MUTATED_VERDICT="$(run_arm "$MUTATED")"
note "pristine -> $PRISTINE_VERDICT"
note "mutated  -> $MUTATED_VERDICT"

assert_eq "the unmutated execution path lands without ever touching provenance" "returned:processed" \
  "$PRISTINE_VERDICT"
assert_eq "ONE added read inside the window trips the wire, naming the trap and the property" \
  "provenance-consulted-during-execution:get:kind" "$MUTATED_VERDICT"

assert_eq "and the tree's own form_a.ts was never written to" "0" \
  "$(cmp -s "$PRISTINE" "$ORCH_SRC/form_a.ts" && echo 0 || echo 1)"
assert_eq "the probe left nothing behind under orchestration/src" "0" \
  "$(find "$ORCH_SRC" -maxdepth 1 -name '.m20_*' | grep -c . || true)"

finish
