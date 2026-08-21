#!/usr/bin/env bash
# just check-drift
#
# Diff the vendored tree against its recorded commit. Intentional edits stay
# visible; unintentional ones fail.
#
# Every vendored file is mapped by PROVENANCE.md to an upstream path and an
# anchor in pins.json, and compared against `git show <anchor>:<path>` in the
# sibling fork — with the provenance header stripped first, so a header can
# never mask a content change, and with symlinks compared as links rather than
# through to their targets.
#
# The comparison is two-directional, which is what stops it passing vacuously:
#
#   1. Every file PROVENANCE.md says is unmodified must be byte-identical, every
#      file it says is modified must actually differ, and every file it says was
#      added must have no upstream counterpart. A recorded edit that is no
#      longer there fails just as loudly as an unrecorded one.
#   2. Every vendored tree's tracked-file count must equal the count PROVENANCE.md
#      declares, so a vendored file cannot be deleted without this noticing, and
#      no tracked file inside a vendored prefix can escape the mapping.
#
# Derived trees (drift/src) are checked differently and more strongly: they are
# REGENERATED from their source tree by the recorded transformation and required
# to match byte for byte. That is what makes the re-pin transformation
# reproducible rather than a one-off sed nobody can re-derive.
#
# Run: just check-drift

TEST_NAME="just check-drift"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
[ -f "$REPO_ROOT/PROVENANCE.md" ] || die "PROVENANCE.md does not exist"
[ -f "$REPO_ROOT/pins.json" ] || die "pins.json does not exist"

PROV="$REPO_ROOT/tools/provenance.py"
[ -f "$PROV" ] || die "the provenance tool is missing at $PROV"

# ---- the mapping itself must be non-empty and internally consistent ---------
counts="$(python3 "$PROV" counts)" || die "provenance.py counts failed"
[ -n "$counts" ] || die "provenance.py produced no tree counts"

while IFS=$'\t' read -r tid local declared actual; do
  [ -n "$tid" ] || continue
  assert_eq "$tid $local: tracked file count matches PROVENANCE.md" "$declared" "$actual"
done <<EOF
$counts
EOF

map="$(python3 "$PROV" map)" || die "provenance.py map failed"
mapped="$(printf '%s\n' "$map" | grep -c . || true)"
assert_ge "the mapping covers a meaningful number of files" 500 "$mapped"

# Every anchor commit named by the mapping must exist in the fork. A mapping
# against a commit we do not have is not a check, it is a wish.
anchors="$(printf '%s\n' "$map" | cut -f3 | sort -u)"
n_anchors=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  n_anchors=$((n_anchors + 1))
  assert_eq "anchor ${c:0:10} is a commit in the fork" "commit" \
    "$(git -C "$FORK_ROOT" cat-file -t "$c" 2>/dev/null || echo missing)"
done <<EOF
$anchors
EOF
assert_ge "the mapping spans at least two distinct anchors" 2 "$n_anchors"


# ---- the file-by-file comparison -------------------------------------------
drift="$(python3 "$PROV" drift)" || die "provenance.py drift failed"
rows="$(printf '%s\n' "$drift" | grep -c . || true)"
assert_eq "every mapped file was compared" "$mapped" "$rows"

bad="$(printf '%s\n' "$drift" | grep '^BAD' || true)"
if [ -z "$bad" ]; then
  pass "every vendored file agrees with PROVENANCE.md ($rows compared)"
else
  while IFS= read -r b; do
    [ -n "$b" ] && fail "unrecorded divergence: $b"
  done <<EOF
$bad
EOF
fi

# The recorded-edit set must be exercised, in both directions. If PROVENANCE.md
# enumerated edits that no longer exist, the rows above would already be BAD;
# this asserts the enumeration is not empty and that the comparison genuinely
# found identical files too, so neither half of the ledger is vacuous.
n_identical="$(printf '%s\n' "$drift" | awk -F'\t' '$1=="OK" && $2=="identical"' | grep -c . || true)"
n_differs="$(printf '%s\n' "$drift"   | awk -F'\t' '$1=="OK" && $2=="differs"'   | grep -c . || true)"
n_derived="$(printf '%s\n' "$drift"   | awk -F'\t' '$1=="OK" && $2=="derived"'   | grep -c . || true)"
assert_ge "vendored files were found byte-identical to upstream" 400 "$n_identical"
assert_ge "the recorded local edits were found to be real edits" 10 "$n_differs"
assert_ge "a derived tree was covered" 100 "$n_derived"

# ---- headers ---------------------------------------------------------------
hdr="$(python3 "$PROV" headers --check 2>&1)"
if [ -z "$hdr" ]; then
  pass "every vendored file's provenance header matches its mapping"
else
  while IFS= read -r h; do
    [ -n "$h" ] && fail "provenance header wrong or missing: $h"
  done <<EOF
$hdr
EOF
fi

# ---- derived trees: regenerate and require byte equality -------------------
scratch="$(mktemp -d)"
derived_out="$(python3 "$PROV" derived "$scratch" 2>&1)"
derived_rc=$?
rm -rf "$scratch"
if [ "$derived_rc" -eq 0 ] && [ -z "$derived_out" ]; then
  pass "every derived tree regenerates byte-identically from its recorded transformation"
else
  while IFS= read -r d; do
    [ -n "$d" ] && fail "derived tree does not reproduce: $d"
  done <<EOF
$derived_out
EOF
fi

# ---- every edit class is used, and every used class is defined -------------
classes="$(python3 "$PROV" classes | cut -f1 | sort)"
used="$(printf '%s\n' "$map" | cut -f8 | grep -v '^none$' | grep -v '^derived$' | sort -u)"
assert_eq "every defined edit class is used by at least one file, and vice versa" \
  "$(printf '%s' "$classes" | tr '\n' ' ')" "$(printf '%s' "$used" | tr '\n' ' ')"

finish
