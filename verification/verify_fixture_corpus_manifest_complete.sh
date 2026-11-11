#!/usr/bin/env bash
# verify_fixture_corpus_manifest_complete — M2.
#
# Every fixture family has a manifest entry naming its upstream source, its capture procedure, its
# licence, and what a skeptic should conclude from it passing.
#
# The check is `verification/_manifest_parser.py` plus a set of assertions this script makes
# directly, so that the two do not agree by construction; and five NEGATIVE CONTROLS that mutate a
# real copy of the manifest and require the same code path to reject it. A checker never observed
# to fail is indistinguishable from one that cannot fail.
#
# It fails, rather than skipping, if the manifest, the inventory or python3 are missing.

TEST_NAME="verify_fixture_corpus_manifest_complete"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$REPO_ROOT/fixtures/MANIFEST.md"
PARSER="$VERIFY_DIR/_manifest_parser.py"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
[ -f "$MANIFEST" ] || die "fixtures/MANIFEST.md does not exist"
[ -f "$PARSER" ] || die "verification/_manifest_parser.py does not exist"
[ -f "$REPO_ROOT/REUSE-INVENTORY.md" ] || die "REUSE-INVENTORY.md does not exist"

echo "== the manifest parses and every entry is complete"
REPORT="$(python3 "$PARSER" check --repo "$REPO_ROOT" --manifest "$MANIFEST" 2>&1)"
PARSER_RC=$?
if [ "$PARSER_RC" -ne 0 ]; then
  printf '%s\n' "$REPORT" >&2
fi
assert_eq "the manifest parser exits 0" "0" "$PARSER_RC"

ENTRIES="$(printf '%s' "$REPORT" | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["entries"])' 2>/dev/null)"
ASSERTS="$(printf '%s' "$REPORT" | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["assertions"])' 2>/dev/null)"
assert_ge "manifest entries" 20 "${ENTRIES:-0}"
assert_ge "parser-level sub-checks" 500 "${ASSERTS:-0}"

echo "== every tier the milestone names is populated, and Tier E is the smallest"
TIER_COUNTS="$(python3 "$PARSER" entries --manifest "$MANIFEST" | cut -f2 | sort | uniq -c | awk '{print $2"="$1}' | tr '\n' ' ')"
note "tier counts: $TIER_COUNTS"
for tier in A B C D E H; do
  n="$(python3 "$PARSER" entries --manifest "$MANIFEST" | cut -f2 | grep -c "^$tier$")"
  assert_ge "tier $tier has entries" 1 "$n"
done
E_COUNT="$(python3 "$PARSER" entries --manifest "$MANIFEST" | cut -f2 | grep -c '^E$')"
for tier in A B C D H; do
  n="$(python3 "$PARSER" entries --manifest "$MANIFEST" | cut -f2 | grep -c "^$tier$")"
  if [ "$E_COUNT" -lt "$n" ]; then
    pass "Tier E ($E_COUNT) is strictly smaller than tier $tier ($n)"
  else
    fail "Tier E ($E_COUNT) is not strictly smaller than tier $tier ($n)"
  fi
done

echo "== the four deliverables that are not fixture families are still covered"
# Each of these is a named M2 deliverable. Requiring the manifest to mention them by name is what
# stops the manifest from being complete-looking and silent about half the milestone.
assert_true "the manifest names PublicTxSimulationTester (the reused harness)" \
  grep -q "PublicTxSimulationTester" "$MANIFEST"
assert_true "the manifest names BytecodeBuilder and InstructionBuilder" \
  grep -q "InstructionBuilder" "$MANIFEST"
assert_true "the manifest names all seven corpus programs" \
  bash -c 'for p in add revert loop sha256 poseidon2 storage burn; do grep -q "\`$p\`" '"$MANIFEST"' || exit 1; done'
assert_true "the manifest names all six contract artifacts" \
  bash -c 'for c in Token AMM AvmTest AvmGadgetsTest StorageProofTest PublicFnsWithEmitRepro; do grep -q "$c" '"$MANIFEST"' || exit 1; done'

echo "== licensing is recorded per tier, and captures are distinguished from copies"
assert_true "the licence table names Apache-2.0 and its evidence" \
  grep -q "Apache-2.0" "$MANIFEST"
assert_true "MIT OR Apache-2.0 is recorded for avm-transpiler" \
  grep -q "MIT OR Apache-2.0" "$MANIFEST"
assert_true "the unlicensed upstream repos are named as not redistributed" \
  grep -q "protocol-specs-pdf" "$MANIFEST"
CAPTURE_LICENCES="$(grep -c 'licence: Apache-2.0 (output of Apache-2.0 code)' "$MANIFEST")"
assert_ge "entries that are captures of behaviour rather than copies of source" 5 "$CAPTURE_LICENCES"

echo "== the seven corpus programs each carry a recorded intent"
PROGRAMS_JSON="$REPO_ROOT/fixtures/avm-programs/programs.json"
assert_file "the assembled-program summary exists" "$PROGRAMS_JSON"
INTENT_REPORT="$(python3 - "$PROGRAMS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["programs"]
short = [k for k, v in d.items() if len(v.get("intent", "")) < 80]
print(len(d), len(short), ",".join(short))
PY
)"
assert_eq "seven programs with an intent each" "7 0 " "$INTENT_REPORT"

# ---------------------------------------------------------------------------
# Negative controls. Each mutates a real copy and requires the SAME parser to reject it.
# ---------------------------------------------------------------------------
echo "== negative controls"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$MANIFEST" "$SCRATCH/base.md"

# control <description> <rule-ERE> <mode: delete|set> <FX-id> <field> [value]
#
# The parser must reject the mutated copy WITH A FAIL LINE MATCHING <rule-ERE>: a mutation that
# happens to break some other rule would otherwise count as a caught control while the rule it is
# named for has been deleted.
#
# The mutation is addressed by ENTRY ID AND FIELD NAME, and the helper FAILS if that entry or that
# field is not found. That matters: an earlier revision of this script matched the first line of the
# right shape anywhere in the file and so silently mutated the "How to read an entry" documentation
# block instead of an entry — four controls "passed" without touching anything the parser judges.
# A control that mutates the wrong thing is worse than no control at all.
control() {
  local desc="$1" rule="$2" mode="$3" eid="$4" field="$5" value="${6:-}" out
  local rc
  python3 - "$SCRATCH/base.md" "$SCRATCH/mutated.md" "$mode" "$eid" "$field" "$value" <<'PY'
import sys
src, dst, mode, eid, field, value = sys.argv[1:7]
lines = open(src).read().splitlines()
start = None
for i, l in enumerate(lines):
    if l.startswith(f"### {eid} "):
        start = i
        break
if start is None:
    sys.stderr.write(f"control: entry {eid} not found\n")
    sys.exit(2)
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith("### ") or lines[j].startswith("<!-- END:manifest"):
        end = j
        break
target = None
for j in range(start, end):
    if lines[j].startswith(f"- {field}: "):
        target = j
        break
if target is None:
    sys.stderr.write(f"control: {eid} has no field {field}\n")
    sys.exit(2)
if mode == "delete":
    del lines[target]
elif mode == "set":
    lines[target] = f"- {field}: {value}"
else:
    sys.exit(2)
open(dst, "w").write("\n".join(lines) + "\n")
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "negative control could not be applied to $eid/$field: $desc"
    return
  fi
  if out="$(python3 "$PARSER" check --repo "$REPO_ROOT" --manifest "$SCRATCH/mutated.md" 2>&1)"; then
    fail "negative control NOT caught: $desc"
  elif str_has_line_re "$out" "^  FAIL $rule"; then
    pass "negative control caught: $desc"
  else
    fail "negative control: $desc — rejected, but not by the rule it is named for [$rule]: $(printf '%s\n' "$out" | grep '^  FAIL ' | head -3 | tr '\n' ' ')"
  fi
}

# The unmutated copy must be green first, or the controls prove nothing.
assert_true "the unmutated scratch copy is accepted" \
  python3 "$PARSER" check --repo "$REPO_ROOT" --manifest "$SCRATCH/base.md"

control "FX-01's skeptic-cannot-conclude field deleted" \
  'FX-01: missing or empty field `skeptic-cannot-conclude`' delete FX-01 skeptic-cannot-conclude
control "FX-01's skeptic-cannot-conclude reduced to a stub" \
  'FX-01: `skeptic-cannot-conclude` is [0-9]+ chars; 60 required' set FX-01 skeptic-cannot-conclude "not much."
control "FX-03's where: pointed at a path that does not exist" \
  'FX-03: `where` path does not exist: fixtures/no-such-file\.json' set FX-03 where "fixtures/no-such-file.json, tools/measure_differential.py"
# THE ABSENT ID IS DERIVED, NOT TYPED, AND THAT IS A DEFECT THIS CONTROL ALREADY SHIPPED.
#
# It planted `RI-99` as "an id that does not exist" — and M36 added RI-98 and RI-99 to
# `REUSE-INVENTORY.md`, so the id EXISTED and the control silently stopped controlling. Caught by
# the sweep, in a check M36 does not own and did not touch: **an inventory that grows makes a typed
# absent id into a present one**, which is this campaign's "an absence is only as wide as the
# spellings you enumerated" with the inventory moving instead of the needle.
#
# It is one past the highest id the file declares now, so it cannot go stale: adding an entry moves
# the needle with it.
ABSENT_RI="$(python3 -c 'import re,sys; ids=[int(m) for m in re.findall(r"^### RI-(\d+) ", open(sys.argv[1], encoding="utf-8").read(), re.M)]; print("RI-%02d" % (max(ids)+1) if ids else "RI-99")' "$REPO_ROOT/REUSE-INVENTORY.md")"
assert_false "the derived absent inventory id really is absent from REUSE-INVENTORY.md" \
  str_has_sub "$(cat "$REPO_ROOT/REUSE-INVENTORY.md")" "### $ABSENT_RI "
control "FX-23 citing an inventory id that does not exist ($ABSENT_RI)" \
  "FX-23: cites $ABSENT_RI, which is not an entry in REUSE-INVENTORY\\.md" set FX-23 inventory "$ABSENT_RI"
control "FX-20's no-upstream-equivalent reason emptied" \
  'FX-20: (missing or empty field `no-upstream-equivalent`|Tier E entry has no `no-upstream-equivalent` reason)' set FX-20 no-upstream-equivalent ""
control "FX-20's reason replaced by a tagged but content-free one" \
  'FX-20: `no-upstream-equivalent` names 0 upstream paths; at least 2 required' set FX-20 no-upstream-equivalent "does-not-cover: there is no upstream fixture for the timer-driven block loop, and the sequencer and the processor and the node and the txe were all considered and none of them has one, so it has to be written here instead, at sufficient length to clear the floor this checker imposes."
control "FX-20's reason padded to length but naming no upstream path" \
  'FX-20: `no-upstream-equivalent` names 0 upstream paths; at least 2 required' set FX-20 no-upstream-equivalent "does-not-cover: the upstream sequencer, the upstream processor, the upstream node facade and the upstream test environment were all read in full and none of them asserts a block per tick, a monotonic timestamp sequence, an empty block on idle, or a deadline that truncates a block, so all four have to be authored here under M23 with world-state roots asserted afterwards."
# Tier E stops being strictly the smallest by SHRINKING the smallest other tier to its size, not
# by moving an entry into E: an entry moved into E also breaks every Tier-E-only field rule, and
# the control would be caught by those with the size rule deleted. Two tier-B entries become tier
# A (B: 4 -> 2 = E), which breaks the size rule and nothing else.
python3 - "$SCRATCH/base.md" "$SCRATCH/mutated.md" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
cur, moved = None, []
for i, l in enumerate(lines):
    if l.startswith("### FX-"):
        cur = l.split()[1]
    if cur in ("FX-05", "FX-06") and l == "- tier: B":
        lines[i] = "- tier: A"
        moved.append(cur)
assert moved == ["FX-05", "FX-06"], moved
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY
TIER_OUT="$(python3 "$PARSER" check --repo "$REPO_ROOT" --manifest "$SCRATCH/mutated.md" 2>&1)"
if [ "$(printf '%s\n' "$TIER_OUT" | grep -c '^  FAIL ' || true)" = "1" ] &&
   str_has_line_re "$TIER_OUT" '^  FAIL manifest: Tier E has 2 entries, not strictly fewer than every other tier'; then
  pass "negative control caught: tier B shrunk to Tier E's size, so Tier E is no longer the smallest"
else
  fail "negative control: shrinking tier B to Tier E's size was not rejected by (only) the tier-size rule: $(printf '%s\n' "$TIER_OUT" | grep '^  FAIL ' | head -3 | tr '\n' ' ')"
fi
control "FX-01's licence set to one outside the vocabulary" \
  'FX-01: licence `WTFPL` is not one of' set FX-01 licence "WTFPL"
control "FX-01's measured field stripped of every number" \
  'FX-01: `measured` carries no number' set FX-01 measured "quite a lot of them, and all green"
control "FX-01 claiming no upstream source while not in Tier E" \
  "FX-01: a non-Tier-E entry claims no upstream source" set FX-01 upstream-source "none — authored here"
control "FX-05's capture field reduced to prose with no command" \
  'FX-05: `capture` names no command' set FX-05 capture "run the unit tests in the usual way and read the output"

finish
