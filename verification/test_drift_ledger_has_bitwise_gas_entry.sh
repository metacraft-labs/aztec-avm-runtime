#!/usr/bin/env bash
# test_drift_ledger_has_bitwise_gas_entry
#
# M1 verification: the drift ledger contains the AND/OR/XOR dynamic-L2-gas entry
# with a recorded decision, so the archetype divergence is not resolved by
# accident.
#
# "Resolved by accident" is the specific failure this guards against. The
# divergence is silent — every test in the tree passes while the TypeScript gas
# table charges a cost upstream deleted — so the only thing keeping it visible
# is the entry. Three things are therefore asserted, not one:
#
#   1. The entry EXISTS and names the divergence concretely — the three opcodes,
#      the deleted constant, the design question, and a decision that is a real
#      decision rather than a placeholder.
#   2. The divergence is STILL REAL. Its content is re-verified against the
#      actual sources: `AVM_BITWISE_DYN_L2_GAS` must be absent from the pinned
#      protocol constants and present in the installed `@aztec/constants`, and
#      the vendored TypeScript gas table must still charge it. If upstream or the
#      npm line changes, this fails and the entry must be re-decided — which is
#      exactly "not resolved by accident".
#   3. The ledger as a whole is structurally sound: every entry has an id, a
#      status from a closed vocabulary, a decision and evidence, and the two
#      other M1 entries the milestone requires (the opcode-spam gas blindness,
#      and the disposition of the two surfaced divergences) are present.
#
#   4. EVERY entry is inside the parsed block. This is not a formality. The
#      structural parser only ever sees what lies between <!-- BEGIN:drift -->
#      and <!-- END:drift -->, and D8 was authored BELOW the END marker — so for
#      the whole of M4 it was never validated at all, while the check reported
#      green and printed a list of ids that silently omitted it. M5's review
#      confirmed the class was still open after D8 was moved: an entry with
#      `status: banana`, `decision: TBD` and three missing keys, planted one line
#      after the END marker, passed 31/31; the identical entry one line ABOVE it
#      produced six failures. A validator whose scope silently excludes part of
#      what it is believed to cover is worse than no validator, so the scope is
#      now asserted rather than assumed: the number of `## D<n> —` headings in
#      the file must equal the number the parser found.
#
# Run: just verify-drift-ledger

TEST_NAME="test_drift_ledger_has_bitwise_gas_entry"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
LEDGER="$REPO_ROOT/DRIFT.md"
[ -f "$LEDGER" ] || die "DRIFT.md does not exist"

doc="$(cat "$LEDGER")"

# ---- 1. the entry exists and is specific -----------------------------------
assert_contains "the ledger has a D1 entry" "- id: D1" "$doc"

d1="$(awk '/^## D1 —/{f=1} f&&/^## D2 —/{f=0} f' "$LEDGER")"
[ -n "$d1" ] || die "could not isolate the D1 entry"

for needle in "AND" "OR" "XOR" "AVM_BITWISE_DYN_L2_GAS" "OQ-13"; do
  assert_contains "D1 names $needle" "$needle" "$d1"
done
assert_contains "D1 names the dynamic L2 gas specifically" "dynamic L2 gas" "$d1"

d1_status="$(printf '%s\n' "$d1" | sed -n 's/^- status: //p')"
assert_contains "D1's status is from the ledger's vocabulary" "$d1_status" "open accepted withdrawn closed"

d1_decision="$(printf '%s\n' "$d1" | sed -n 's/^- decision: //p')"
assert_ge "D1 records a real decision, not a placeholder" 80 "${#d1_decision}"
case "$(printf '%s' "$d1_decision" | tr 'A-Z' 'a-z')" in
  n/a|none|tbd|-) fail "D1's decision is a placeholder: $d1_decision" ;;
  *)              pass "D1's decision is not a placeholder" ;;
esac
assert_contains "D1 names where it is resolved" "M19" "$d1"
assert_contains "D1 records evidence" "- evidence:" "$d1"

# ---- 2. the divergence is still real ---------------------------------------
# (a) the constant is gone from the pinned protocol constants
nr="$REPO_ROOT/reference/constants/constants.nr"
assert_file "the pinned protocol constants are vendored" "$nr"
if grep -q "AVM_BITWISE_DYN_L2_GAS" "$nr"; then
  fail "AVM_BITWISE_DYN_L2_GAS is present in the pinned constants.nr — D1's premise no longer holds; re-decide the entry"
else
  pass "AVM_BITWISE_DYN_L2_GAS is absent from the pinned protocol constants, as D1 says"
fi

# (b) the published npm constants still ship it
found_npm=0
for tree in drift diffsim spike; do
  gen="$REPO_ROOT/$tree/node_modules/@aztec/constants/dest/constants.gen.js"
  [ -f "$gen" ] || continue
  found_npm=1
  if grep -q "AVM_BITWISE_DYN_L2_GAS" "$gen"; then
    pass "the published @aztec/constants in $tree/ still ships AVM_BITWISE_DYN_L2_GAS, as D1 says"
  else
    fail "the published @aztec/constants in $tree/ no longer ships AVM_BITWISE_DYN_L2_GAS — D1's premise has changed; re-decide the entry"
  fi
done
assert_eq "at least one installed @aztec/constants was available to check" "1" "$found_npm"

# (c) the vendored TypeScript gas table still charges it
gas="$REPO_ROOT/spike/src/public/avm/avm_gas.ts"
assert_file "the vendored TS gas table is present" "$gas"
if grep -q "AVM_BITWISE_DYN_L2_GAS" "$gas"; then
  pass "the vendored TS gas table still charges the dynamic bitwise gas, as D1 says"
else
  fail "the vendored TS gas table no longer references AVM_BITWISE_DYN_L2_GAS — D1 has been resolved silently, which is the exact thing this check exists to prevent"
fi

# (d) upstream's C++ gas table, the authority, does not
spec="$REPO_ROOT/reference/vm2-common/instruction_spec.cpp"
assert_file "the pinned C++ instruction spec is vendored" "$spec"
if grep -qi "BITWISE_DYN_L2_GAS" "$spec"; then
  fail "the pinned C++ instruction spec references a bitwise dynamic L2 gas — D1's premise no longer holds"
else
  pass "the pinned C++ instruction spec charges no dynamic L2 gas for bitwise ops, as D1 says"
fi

# ---- 3. the ledger is structurally sound and carries M1's other entries -----
report="$(python3 - "$LEDGER" <<'PY'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"<!--\s*BEGIN:drift\s*-->(.*?)<!--\s*END:drift\s*-->", text, re.S)
if not block:
    print("PROBLEM DRIFT.md has no <!-- BEGIN:drift --> block")
    print("ENTRIES 0")
    raise SystemExit(0)

STATUSES = {"open", "accepted", "withdrawn", "closed"}
KEYS = ["id", "status", "opened", "milestone", "sides", "what", "decision"]
entries = []
for m in re.finditer(r"^## (D\d+) — (.+?)$\n(.*?)(?=^## D\d+ —|\Z)", block.group(1), re.M | re.S):
    did, title, body = m.group(1), m.group(2), m.group(3)
    fields, last = {}, None
    for line in body.splitlines():
        fm = re.match(r"^- ([a-z-]+):\s*(.*)$", line)
        if fm:
            last = fm.group(1)
            fields[last] = fm.group(2).strip()
        elif line.startswith("  ") and line.strip() and last:
            fields[last] = (fields[last] + " " + line.strip()).strip()
    entries.append((did, title, fields))

problems = []
for did, title, f in entries:
    for k in KEYS:
        if k not in f or not f[k]:
            problems.append("%s: missing key %r" % (did, k))
    if f.get("status") not in STATUSES:
        problems.append("%s: status %r is not in the vocabulary" % (did, f.get("status")))
    if len(f.get("what", "")) < 80:
        problems.append("%s: 'what' is too short to describe a divergence" % did)
    if f.get("decision", "").lower() in ("n/a", "none", "tbd", "-"):
        problems.append("%s: decision is a placeholder" % did)

ids = [e[0] for e in entries]
if len(ids) != len(set(ids)):
    problems.append("duplicate ids: %s" % sorted({i for i in ids if ids.count(i) > 1}))

# Scope. Everything above judged only what is INSIDE the block; an entry written
# outside it is invisible to every one of those rules. D8 was authored below the
# END marker and went unvalidated for a whole milestone while this check reported
# green, so the parser's reach is now compared against the document.
all_ids = re.findall(r"^## (D\d+) — ", text, re.M)
outside = [i for i in all_ids if i not in ids]
for i in outside:
    problems.append("%s: written OUTSIDE the <!-- BEGIN:drift --> block, so nothing validates it" % i)

print("ENTRIES %d" % len(entries))
print("HEADINGS %d" % len(all_ids))
print("IDS %s" % " ".join(ids))
for p in problems:
    print("PROBLEM %s" % p)
PY
)" || die "could not parse DRIFT.md"

n_entries="$(printf '%s\n' "$report" | sed -n 's/^ENTRIES //p')"
n_headings="$(printf '%s\n' "$report" | sed -n 's/^HEADINGS //p')"
ids="$(printf '%s\n' "$report" | sed -n 's/^IDS //p')"
problems="$(printf '%s\n' "$report" | sed -n 's/^PROBLEM //p')"

note "ledger entries: $ids"
assert_ge "the ledger carries several entries" 4 "$n_entries"
assert_contains "the ledger carries D1, the seeded bitwise-gas entry" "D1" "$ids"
# The scope assertion. Everything else here judges what the parser can see; this
# is what makes "what the parser can see" equal to "what the document contains".
assert_eq "every D-entry in DRIFT.md is inside the parsed block (D8 once was not)" \
  "$n_headings" "$n_entries"

if [ -z "$problems" ]; then
  pass "every ledger entry has an id, a status, a decision and evidence"
else
  while IFS= read -r p; do
    [ -n "$p" ] && fail "$p"
  done <<EOF
$problems
EOF
fi

# M1's other two required entries, by content rather than by id.
assert_contains "the ledger records that the opcode-spam arm is blind to gas divergence" \
  "blind to gas divergence" "$doc"
assert_contains "...and says so about the 74→216 expansion specifically" "74 to 216" "$doc"
assert_contains "...with the mutation evidence that establishes it" "+1 L2 gas" "$doc"
assert_contains "the ledger disposes of SENDL2TOL1MSG" "SENDL2TOL1MSG" "$doc"
assert_contains "the ledger disposes of REVERT_8" "REVERT_8" "$doc"

# ---- negative control -------------------------------------------------------
# The structural parser must reject a placeholder decision.
ctl="$(mktemp)"
sed 's|^- decision: Recorded, not resolved.*|- decision: TBD|' "$LEDGER" > "$ctl"
if cmp -s "$ctl" "$LEDGER"; then
  fail "the negative control changed nothing; it is vacuous"
else
  out="$(python3 - "$ctl" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"<!--\s*BEGIN:drift\s*-->(.*?)<!--\s*END:drift\s*-->", text, re.S)
bad = 0
for m in re.finditer(r"^## (D\d+) — .+?$\n(.*?)(?=^## D\d+ —|\Z)", block.group(1), re.M | re.S):
    for line in m.group(2).splitlines():
        fm = re.match(r"^- decision:\s*(.*)$", line)
        if fm and fm.group(1).strip().lower() in ("n/a", "none", "tbd", "-"):
            bad += 1
print(bad)
PY
)"
  if [ "$out" -ge 1 ]; then
    pass "a placeholder decision in the ledger is detected  [$out]"
  else
    fail "a placeholder decision was not detected; the ledger check is too weak"
  fi
fi
rm -f "$ctl"

# The scope negative control. The mutation that motivated the assertion above:
# a malformed entry planted one line BELOW the END marker used to pass 31/31,
# because the parser never saw it. It must now be counted and named.
scope_ctl="$(mktemp)"
python3 - "$LEDGER" "$scope_ctl" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
planted = "\n## D99 — planted outside the block\n\n- id: D99\n- status: banana\n- decision: TBD\n\n"
assert text.count("<!-- END:drift -->") == 1
open(sys.argv[2], "w", encoding="utf-8").write(
    text.replace("<!-- END:drift -->", "<!-- END:drift -->\n" + planted))
PY
scope_out="$(python3 - "$scope_ctl" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"<!--\s*BEGIN:drift\s*-->(.*?)<!--\s*END:drift\s*-->", text, re.S)
inside = re.findall(r"^## (D\d+) — ", block.group(1), re.M)
allids = re.findall(r"^## (D\d+) — ", text, re.M)
print(" ".join(i for i in allids if i not in inside))
PY
)"
# assert_contains, not assert_eq: if the ledger ITSELF has an out-of-scope entry
# the assertion above is what reports it, and this control should keep saying only
# whether the detector works.
assert_contains "an entry planted below the END marker is detected as out of scope" \
  "D99" "$scope_out"
rm -f "$scope_ctl"

finish
