#!/usr/bin/env bash
# verify_aztec_ts_anchor_current
#
# M37 verification: how current the TypeScript anchor can be, measured live rather
# than quoted — and the answer is not the one the milestone was written expecting.
#
# WHAT M37 ASKED FOR. "`pins.json`'s ts anchor is an ancestor of upstream's tip and
# within a declared distance of it." The plan's own table put the `ts` anchor 2,007
# commits behind `origin/next` at `651bda5d5f1` (2026-08-20) and asked for it to be
# advanced.
#
# WHAT IS ACTUALLY THERE. On **2026-08-27**, `703d896149`
# (*chore!: delete the in-tree labs components*) removed `yarn-project/` from
# `aztec-packages` — 3,328 files, in a commit touching 10,825 paths — and rebuilt it
# from a `labs` SUBMODULE pointing at a different repository. So "advance the `ts`
# anchor to current" has no referent inside this repository any more: at
# `upstream/next` there is no TypeScript to anchor to, and EVERY upstream path
# `PROVENANCE.md` vendors resolves to nothing.
#
# WHAT THIS CHECK THEREFORE MEASURES, and every part of it is a live `git` question
# against the fork rather than a sentence:
#
#   1. the `ts` anchor is still an ancestor of the tip, and its distance;
#   2. `yarn-project/` is ABSENT at the tip and PRESENT one commit before the
#      deletion — both directions, because an absence measured against a tree that
#      never had the subject is this campaign's most-repeated defect;
#   3. the CEILING — the last commit at which the TypeScript exists in-tree — is
#      `703d896149^`, and the `cpp` anchor is within a declared distance of it;
#   4. **every upstream path this repository vendors is byte-identical at the `cpp`
#      anchor and at that ceiling**, which is what makes the residual staleness
#      `ts -> cpp` rather than `ts -> tip`, and it is the measurement that decides
#      how much re-vendoring M37 actually owes;
#   5. the residue: which vendored paths DIFFER between `ts` and `cpp`, named
#      rather than counted, so a bump cannot silently change the population.
#
# THE CONTROL FOR (4) IS (5). A byte-identity comparison that has never been seen to
# report a difference proves nothing, so the same comparison is run over the
# `ts -> cpp` pairs, where it must report a NON-EMPTY set naming specific files.
#
# Run: just verify-m37-anchor

TEST_NAME="verify_aztec_ts_anchor_current"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m37.sh"
m37_summary_on_abnormal_exit

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
[ -f "$REPO_ROOT/pins.json" ] || die "pins.json does not exist"

pin() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["anchors"][sys.argv[2]]["commit"])' "$REPO_ROOT/pins.json" "$1"; }
TS="$(pin ts)"
CPP="$(pin cpp)"
DELETION="703d89614927720d3a2c9dd9c6609c014625e9bd"   # chore!: delete the in-tree labs components

printf '\n=== %s\n' "$TEST_NAME"

# The tip is READ, not fetched: `verify_carry_set_applies_to_upstream_head` fetches
# and records what it replayed against, and two checks fetching the same remote in
# one sweep is two different tips in one measurement.
TIP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tip"]["commit"])' "$REPO_ROOT/carry/rebase.json" 2>/dev/null || true)"
[ -n "$TIP" ] || TIP="$(git -C "$FORK_ROOT" rev-parse upstream/next 2>/dev/null || true)"
[ -n "$TIP" ] || die "could not determine upstream's tip from carry/rebase.json or upstream/next"
note "tip: $TIP"
note "cpp: $CPP    ts: $TS"

for c in "$TS" "$CPP" "$TIP" "$DELETION"; do
  assert_eq "the fork carries ${c:0:10}" "commit" \
    "$(git -C "$FORK_ROOT" cat-file -t "$c" 2>/dev/null || echo missing)"
done

# --- §1 the anchors' distances, live ----------------------------------------
assert_true "the ts anchor is an ancestor of upstream's tip" \
  git -C "$FORK_ROOT" merge-base --is-ancestor "$TS" "$TIP"
assert_true "the cpp anchor is an ancestor of upstream's tip" \
  git -C "$FORK_ROOT" merge-base --is-ancestor "$CPP" "$TIP"

D_TS="$(git -C "$FORK_ROOT" rev-list --count "$TS..$TIP")"
D_CPP="$(git -C "$FORK_ROOT" rev-list --count "$CPP..$TIP")"
note "ts is $D_TS commit(s) behind the tip; cpp is $D_CPP"
assert_ge "the ts anchor is more than a thousand commits behind, which is the fact M37 opens with" \
  1000 "$D_TS"
# The `cpp` half is the one M37 records as fine, and "fine" is a bound, not a word.
if [ "$D_CPP" -le 40 ]; then
  pass "the cpp anchor is within the declared distance of the tip  [$D_CPP <= 40]"
else
  fail "the cpp anchor is $D_CPP commits behind the tip, past the declared 40"
fi

# --- §2 the TypeScript is GONE, and the absence is measured both ways --------
lstree() { git -C "$FORK_ROOT" ls-tree "$1" "$2" 2>/dev/null | grep -c . || true; }
assert_eq "yarn-project/ is ABSENT at upstream's tip" "0" "$(lstree "$TIP" yarn-project)"
assert_eq "…and PRESENT one commit before the deletion, so that zero is a fact about the tree and not about the predicate" \
  "1" "$(lstree "${DELETION}^" yarn-project)"
assert_eq "…and PRESENT at the ts anchor itself" "1" "$(lstree "$TS" yarn-project)"
assert_eq "…and PRESENT at the cpp anchor" "1" "$(lstree "$CPP" yarn-project)"

N_DELETED="$(git -C "$FORK_ROOT" diff --diff-filter=D --name-only "${DELETION}^" "$DELETION" -- yarn-project | grep -c . || true)"
assert_ge "the deletion removed the whole TypeScript tree, not a file or two" 3000 "$N_DELETED"
note "the deletion removed $N_DELETED path(s) under yarn-project/"

# It went to a SUBMODULE, and that is what says the code still exists somewhere.
GITMODULES="$(git -C "$FORK_ROOT" show "$TIP:.gitmodules" 2>/dev/null)"
assert_true "…and the tip declares a labs submodule in its place" \
  str_has_sub "$GITMODULES" 'path = labs'
assert_true "…pointing at a different repository" \
  str_has_sub "$GITMODULES" 'aztec-node.git'
assert_false "…which the cpp anchor's .gitmodules does NOT declare, so the submodule is the move" \
  str_has_sub "$(git -C "$FORK_ROOT" show "$CPP:.gitmodules" 2>/dev/null)" 'path = labs'

# --- §3 the ceiling ----------------------------------------------------------
CEIL="$(git -C "$FORK_ROOT" rev-parse "${DELETION}^")"
note "ceiling (last in-tree TypeScript): ${CEIL:0:10}"
assert_true "the cpp anchor is at or before the ceiling" \
  git -C "$FORK_ROOT" merge-base --is-ancestor "$CPP" "$CEIL"
D_CEIL="$(git -C "$FORK_ROOT" rev-list --count "$CPP..$CEIL")"
if [ "$D_CEIL" -le 40 ]; then
  pass "the cpp anchor is within the declared distance of the ceiling  [$D_CEIL <= 40]"
else
  fail "the cpp anchor is $D_CEIL commits behind the ceiling, past the declared 40"
fi

# --- §4/§5 every vendored path, at three revisions ---------------------------
#
# The population is DERIVED from PROVENANCE.md rather than typed here, so a row
# added later joins this comparison automatically. `tools/provenance.py map` emits
# <local> <upstream> <commit> <anchor> <licence> <inventory> …, tab-separated —
# field 4 is the anchor NAME and field 3 is the resolved commit, and reading the
# wrong one is how this section reported zero on its first run.
PROV="$REPO_ROOT/tools/provenance.py"
[ -f "$PROV" ] || die "the provenance tool is missing at $PROV"
MAP="$(python3 "$PROV" map)" || die "provenance.py map failed"

TS_PATHS="$(printf '%s\n' "$MAP" | awk -F'\t' '$4=="ts" && $2!="" {print $2}' | LC_ALL=C sort -u)"
N_TS_PATHS="$(printf '%s\n' "$TS_PATHS" | grep -c . || true)"
assert_ge "PROVENANCE.md declares ts-anchored upstream paths to compare" 100 "$N_TS_PATHS"

# The single-file rows under `yarn-project/` are the population: they are the
# TypeScript this repository vendors, and the question this section asks — how
# current can that TypeScript be — is a question about the PATHS, not about which
# anchor a row happens to name today. The whole-tree rows (spike/, diffsim/,
# drift/) are deletion-era EVIDENCE by construction and are reported separately
# rather than folded in.
#
# THE DERIVATION USED TO BE `cells[3] == "ts"`, AND THAT MADE THE POPULATION A
# PROPERTY OF A DECISION RATHER THAN OF THE SUBJECT. A parallel M37 commit
# (`8cf321b`) re-anchored every single-file row from `ts` to `cpp` — which is the
# move this very section sizes — and the population went to ZERO. Three
# assertions then compared empty sets and the check's own "so that emptiness is
# not the emptiness of the loop" guards fired, which is the guard working; but the
# repair is not a bigger guard, it is a derivation that survives the move. Anchored
# to `yarn-project/` it is the same eighteen rows before and after.
SINGLE="$(python3 - "$REPO_ROOT/PROVENANCE.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
block = text.split("<!-- BEGIN:files -->")[1].split("<!-- END:files -->")[0]
for line in block.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 6 or not re.match(r"^F\d+$", cells[0]):
        continue
    if not cells[2].startswith("yarn-project/"):
        continue
    print(cells[2])
PY
)"
N_SINGLE="$(printf '%s\n' "$SINGLE" | grep -c . || true)"
assert_ge "…of which the single-file rows are the population M37's re-vendoring is about" 10 "$N_SINGLE"
note "$N_SINGLE ts-anchored single-file rows with an upstream counterpart"

blob() { git -C "$FORK_ROOT" rev-parse --verify -q "$1:$2" 2>/dev/null || true; }

SAME_CEIL=0; DIFF_CEIL=""; ABSENT_CPP=""; ABSENT_TS=""; DIFF_TS_CPP=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  b_ts="$(blob "$TS" "$p")"; b_cpp="$(blob "$CPP" "$p")"; b_ceil="$(blob "$CEIL" "$p")"
  if [ -z "$b_cpp" ]; then ABSENT_CPP="$ABSENT_CPP $p"; continue; fi
  if [ "$b_cpp" = "$b_ceil" ]; then SAME_CEIL=$((SAME_CEIL + 1)); else DIFF_CEIL="$DIFF_CEIL $p"; fi
  # An ABSENCE at `ts` is not a DIFFERENCE — folding the two together would let a
  # path that exists at only one end satisfy the residue control, which is the
  # control that says the byte-identity above can answer the other way.
  if [ -z "$b_ts" ]; then ABSENT_TS="$ABSENT_TS $p"
  elif [ "$b_ts" != "$b_cpp" ]; then DIFF_TS_CPP="$DIFF_TS_CPP $p"; fi
done <<EOF
$SINGLE
EOF

# (4) The measurement that decides the size of the job.
assert_eq "every vendored path present at the cpp anchor is BYTE-IDENTICAL at the ceiling — so the reachable TypeScript is the one already pinned" \
  "" "${DIFF_CEIL# }"
assert_ge "…over a non-empty population, so that emptiness is not the emptiness of the loop" 10 "$SAME_CEIL"
note "$SAME_CEIL vendored path(s) identical at cpp and at the ceiling"

# (5) THE CONTROL, and it is the residue that also happens to be the deliverable's
# real work list. The same comparison, over the same files, between `ts` and `cpp`
# must report a NON-EMPTY set — otherwise the identity above is a comparator that
# cannot report a difference.
N_DIFF_TS_CPP="$(printf '%s\n' ${DIFF_TS_CPP} | grep -c . || true)"
assert_ge "the same comparison DOES report differences between ts and cpp, so it can answer both ways" \
  1 "$N_DIFF_TS_CPP"
note "vendored paths that differ between the ts and cpp anchors ($N_DIFF_TS_CPP):"
for p in $DIFF_TS_CPP; do note "    $p"; done

# THE ONE ROW WHOSE UPSTREAM PATH IS ABSENT AT `cpp` — AND IT MOVED RATHER THAN
# DYING, WHICH IS A DIFFERENT FACT AND THE ONE THAT DECIDES WHAT TO DO ABOUT IT.
#
# The first version of this section said the file was "one of the ~16k lines
# `4377ddf64c` removed" and that the row therefore "cannot move at all". Measured:
# `4377ddf64c` (*refactor: remove the TS AVM simulator*) RENAMED
# `avm/fixtures/utils.ts` to `avm/testing/utils.ts` and shrank it 154 -> 115 lines,
# and `simple_contract_data_source.ts`'s own import moves with it in the same
# commit. So there IS a successor, F22 CAN be re-anchored, and the sentence that
# said otherwise was *"a limitation stated with a false reason"* — which this
# campaign records as worse than one stated with none, because the false reason
# closes the search. The successor is asserted PRESENT here so the absence above is
# a move rather than a loss, and the assertion is anchored to the successor's path
# so a real deletion would still fail.
# READ FROM THE `ts` END NOW, BECAUSE THE ROWS MOVED. Until `8cf321b` the rows
# named the `ts`-era path `avm/fixtures/utils.ts`, which is absent at `cpp`, and
# this section asserted that absence. The rows now name the successor, so the same
# rename is visible from the other side and the assertions say so: every row's
# upstream path exists at `cpp` (which is what the re-anchoring bought, and a row
# pointing at a path its own anchor does not have is the defect this catches), and
# exactly one of them is absent at `ts`, which is the renamed file.
assert_eq "every vendored upstream path exists at the cpp anchor the rows name" "0" \
  "$(printf '%s\n' ${ABSENT_CPP} | grep -c . || true)"
assert_eq "…and exactly one is ABSENT at the ts anchor, which is the rename seen from the other end" "1" \
  "$(printf '%s\n' ${ABSENT_TS} | grep -c . || true)"
assert_contains "…and it is the AVM fixtures helper, whose path the TS-AVM removal changed" \
  "avm/testing/utils.ts" "$ABSENT_TS"
assert_eq "…and it MOVED rather than dying: the successor is present at the cpp anchor" "blob" \
  "$(git -C "$FORK_ROOT" cat-file -t "$CPP:yarn-project/simulator/src/public/avm/testing/utils.ts" 2>/dev/null || echo missing)"
assert_eq "…and the successor did NOT exist at the ts anchor, so the move is between the two" "missing" \
  "$(git -C "$FORK_ROOT" cat-file -t "$TS:yarn-project/simulator/src/public/avm/testing/utils.ts" 2>/dev/null || echo missing)"
# A rename is a claim about ONE commit, so name it and require it to be the commit
# the `ts` anchor is defined as the parent of — otherwise "it moved" is a story
# about an unnamed change.
assert_eq "…and the commit that moved it is the one the ts anchor is the parent of" \
  "$(git -C "$FORK_ROOT" rev-parse 4377ddf64c 2>/dev/null)" \
  "$(git -C "$FORK_ROOT" log --format='%H' --diff-filter=A "$TS..$CPP" \
       -- yarn-project/simulator/src/public/avm/testing/utils.ts | tail -1)"

m37_finish
