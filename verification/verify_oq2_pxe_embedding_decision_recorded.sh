#!/usr/bin/env bash
# verify_oq2_pxe_embedding_decision_recorded — M21, OQ-2.
#
# THE OPEN QUESTION, verbatim: "Embed `@aztec/pxe` (`client/lazy`) or reimplement a minimal store
# set for Form B? … Reimplementing means reinventing note discovery. **Experiment:** build a page
# that imports `@aztec/pxe/client/lazy` and executes one private function with no node attached, and
# measure both whether it works and what it costs in bundle size. **Recommendation: embed.** The
# burden of proof should be on reimplementation."
#
# THE DECIDING EVIDENCE IS NOT BUNDLE SIZE, AND THE ANSWER IS NEITHER HORN.
#
# `@aztec/pxe` hard-depends on `@aztec/simulator`, which hard-depends on `@aztec/native` (the NAPI
# AVM) and `@aztec/world-state` (the LMDB addon). DD-9 forbids the shipped package from reaching
# either, and `verify_differential_containment` asserts that against the MANIFEST, the `npm pack`
# output and the import graph. A lazily-loaded chunk is still a manifest dependency, so the page the
# experiment describes could not have answered the question that decides it — it would have measured
# kilobytes while the disqualifying fact was in `package.json`.
#
# So the burden of proof lands where the open question put it, and reimplementation still does not
# win it: the third route is VENDOR, which is what this repository already does to 742 files through
# `PROVENANCE.md` + `check_drift.sh`, and which RI-63 used for the phase splitter for exactly this
# reason. RI-64 records the simulator half (711 lines, all six files already vendored in three
# parallel subdirectories, one zero-dependency install missing); RI-65 records what is still open.
#
# THIS IS THE TRAP M20 HIT TWICE AND IT IS WHY THIS CHECK MEASURES RATHER THAN READS. M18 recorded,
# and M20 repeated, "upstream does not publish `@aztec/simulator`". It does. Being published is not
# the question; the dependency list is. So this check RESOLVES BOTH PACKAGES AND READS THEIR
# DEPENDENCY LISTS LIVE, and asserts in both directions: the forbidden pair IS there, and a package
# the decision relies on being clean (`@aztec/noir-acvm_js`) is measured to be clean rather than
# assumed to be.
#
# NO NETWORK IS A PRECONDITION FAILURE, NOT A SKIP. A check that reports success without having
# executed anything is worse than no check at all, and this campaign has closed a SKIPPED branch
# once already.

set -uo pipefail
TEST_NAME="verify_oq2_pxe_embedding_decision_recorded"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

PIN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["npm"]["deletion_era"]["version"])' \
       "$REPO_ROOT/pins.json")"
assert_true "the orchestration package's pin was read from pins.json rather than typed here" \
  str_has_re "$PIN" '^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}$'
CONSUMER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["npm_consumers"]["orchestration"])' \
            "$REPO_ROOT/pins.json")"
assert_eq "…and it is the line orchestration/ is declared to use" "deletion_era" "$CONSUMER"

# ONE REGISTRY DOCUMENT PER PACKAGE, and every field read out of it only after the document is shown
# to BE that package at this pin. `npm view <pkg> <field>` prints NOTHING both when the field is
# absent and when the lookup failed — a 404, a version that does not exist, a misspelled package or
# field, a dropped connection — so an assertion that a list is empty could not tell "declares none"
# from "asked nothing". Reading the whole document makes those two different answers: `none` needs a
# document whose name and version match; anything else is UNRESOLVED.
NPM_DOCS="$(mktemp -d)"
npm_doc_file() { printf '%s/%s.json' "$NPM_DOCS" "$(printf '%s' "$1" | tr '/@' '__')"; }
npm_q() { # <package> <resolved|dependencies|optionalDependencies|dependencies-json>
  local f; f="$(npm_doc_file "$1")"
  [ -s "$f" ] || ( cd "$REPO_ROOT/orchestration" && npm view "$1@$PIN" --json 2>/dev/null ) >"$f"
  python3 - "$f" "$1" "$PIN" "$2" <<'PYQ'
import json, sys
path, pkg, pin, field = sys.argv[1:]
try:
    d = json.load(open(path))
except Exception:
    print("UNRESOLVED"); sys.exit(0)
if isinstance(d, list):
    d = d[-1] if d else {}
if not isinstance(d, dict) or d.get("name") != pkg or d.get("version") != pin:
    print("UNRESOLVED"); sys.exit(0)
if field == "resolved":
    print(pkg + "@" + pin); sys.exit(0)
if field == "dependencies-json":
    print(json.dumps(d.get("dependencies") or {}, separators=(",", ":"))); sys.exit(0)
v = d.get(field) or {}
print(" ".join(sorted(v)) if v else "none")
PYQ
}
deps_of() { # <package> -> its `dependencies` object as one line, or empty when it did not resolve
  local r; r="$(npm_q "$1" dependencies-json)"
  [ "$r" = "UNRESOLVED" ] || printf '%s' "$r"
}

# ---------------------------------------------------------------------------
echo "== 1. the measurement, live, at this package's own pin"
# ---------------------------------------------------------------------------
PXE_DEPS="$(deps_of @aztec/pxe)"
[ -n "$PXE_DEPS" ] || die "npm could not resolve @aztec/pxe@$PIN.
     This check MEASURES dependency lists rather than quoting them, because M18 and M20 both
     recorded a package as unpublished when it was published. Without the registry it can conclude
     nothing, so it fails rather than passing on a recorded answer. Check the network and re-run."
SIM_DEPS="$(deps_of @aztec/simulator)"
[ -n "$SIM_DEPS" ] || die "npm could not resolve @aztec/simulator@$PIN — see above."

assert_true "@aztec/pxe IS published at this pin — 'it is unpublished' was the wrong reason twice" \
  str_has_sub "$PXE_DEPS" '@aztec/'
assert_true "…and it hard-depends on @aztec/simulator" str_has_sub "$PXE_DEPS" '"@aztec/simulator"'
assert_true "@aztec/simulator is published too" str_has_sub "$SIM_DEPS" '@aztec/'
assert_true "…and hard-depends on @aztec/native, the NAPI AVM" \
  str_has_sub "$SIM_DEPS" '"@aztec/native"'
assert_true "…and on @aztec/world-state, the LMDB addon" \
  str_has_sub "$SIM_DEPS" '"@aztec/world-state"'
# THE DIRECTION THAT MATTERS: these are `dependencies`, not `optionalDependencies` or `peer`. An
# optional dependency would be a different question and the answer might have been different.
assert_eq "@aztec/pxe declares no optionalDependencies, so its list is the whole list" "none" \
  "$(npm_q @aztec/pxe optionalDependencies)"
assert_eq "@aztec/simulator declares none either" "none" "$(npm_q @aztec/simulator optionalDependencies)"
# The reader's own control: a package that does not exist is UNRESOLVED, not "none".
assert_eq "a package the registry does not have reads UNRESOLVED rather than none" "UNRESOLVED" \
  "$(npm_q @aztec/no-such-package-m21 optionalDependencies)"

# THE CONTROL, in the other direction. If `str_has_sub` said yes to everything the five assertions
# above would be five assertions of nothing.
assert_false "a package name that is not in @aztec/simulator's list is not found" \
  str_has_sub "$SIM_DEPS" '"@aztec/no-such-package"'
assert_false "…and @aztec/native is NOT in @aztec/pxe's own direct list, so the reach is transitive" \
  str_has_sub "$PXE_DEPS" '"@aztec/native"'

# ---------------------------------------------------------------------------
echo "== 2. the packages the decision DOES rely on, measured clean rather than assumed"
# ---------------------------------------------------------------------------
assert_eq "@aztec/noir-acvm_js resolves at this pin" "@aztec/noir-acvm_js@$PIN" \
  "$(npm_q @aztec/noir-acvm_js resolved)"
assert_eq "…and declares NO dependencies at all, which is what makes RI-64 cheap" "none" \
  "$(npm_q @aztec/noir-acvm_js dependencies)"
ABI_DEPS="$(deps_of @aztec/noir-noirc_abi)"
assert_eq "@aztec/noir-noirc_abi declares exactly one, @aztec/noir-types" "@aztec/noir-types" \
  "$(npm_q @aztec/noir-noirc_abi dependencies)"
assert_false "…and it is not @aztec/native" str_has_sub "$ABI_DEPS" '"@aztec/native"'
assert_eq "@aztec/noir-types resolves at this pin, so its empty list is a list" "@aztec/noir-types@$PIN" \
  "$(npm_q @aztec/noir-types resolved)"
assert_eq "…whose own list is empty, so the closure ends there" "none" \
  "$(npm_q @aztec/noir-types dependencies)"

# ---------------------------------------------------------------------------
echo "== 3. NEITHER IS INSTALLED, and the manifest says so"
#
# The decision is worth nothing if the tree contradicts it. Asked of the manifest AND of the
# installed tree, because they are different questions and the campaign has confused them before.
# ---------------------------------------------------------------------------
MANIFEST="$(cat "$REPO_ROOT/orchestration/package.json")"
for forbidden in '@aztec/pxe' '@aztec/simulator' '@aztec/native' '@aztec/world-state'; do
  if str_has_sub "$MANIFEST" "\"$forbidden\":"; then declared=yes; else declared=no; fi
  assert_eq "orchestration/package.json does not declare $forbidden" "no" "$declared"
done
# …and the manifest DOES declare the four it depends on, so the four absences above are absences in
# a file that could have contained them.
for present in '@aztec/stdlib' '@aztec/foundation' '@aztec/constants' '@aztec/protocol-contracts'; do
  if str_has_sub "$MANIFEST" "\"$present\":"; then declared=yes; else declared=no; fi
  assert_eq "…while it does declare $present, so the absences are in a populated list" "yes" "$declared"
done
for forbidden in '@aztec/pxe' '@aztec/simulator' '@aztec/native' '@aztec/world-state'; do
  if [ -e "$REPO_ROOT/orchestration/node_modules/$forbidden" ]; then installed=yes; else installed=no; fi
  assert_eq "…and $forbidden is not installed either" "no" "$installed"
done

# ---------------------------------------------------------------------------
echo "== 4. the decision is RECORDED, with the measurement rather than the argument"
# ---------------------------------------------------------------------------
INV="$(cat "$REPO_ROOT/REUSE-INVENTORY.md")"
assert_true "RI-64 records the WASMSimulator vendoring decision" str_has_sub "$INV" "### RI-64"
assert_true "RI-65 records what OQ-2 actually decided" str_has_sub "$INV" "### RI-65"
assert_true "…naming the two hard dependencies that decide it" \
  str_has_sub "$INV" "the NAPI AVM and the LMDB world-state addon into the shipped tree"
assert_true "…and saying why the bundle-size experiment would have measured the wrong quantity" \
  str_has_sub "$INV" "a lazily-loaded chunk is still a manifest dependency"
assert_true "…and the 711-line closure, so 'vendor' is costed rather than asserted" \
  str_has_sub "$INV" "711 lines"
assert_true "…and the 68-entry oracle registry, which is the part that is still open" \
  str_has_sub "$INV" "68 entries"
assert_true "…and the parallel-subdirectory trap in the tsavm copy of it" \
  str_has_sub "$INV" "53 entries"
# RI-65's decision must be `open`, not `vendor`: the simulator half is decided, the oracle half is
# not, and recording one verdict for both would be the over-claim this file exists to prevent.
RI65="$(printf '%s\n' "$INV" | awk '/^### RI-65 /{ inside=1 } inside { print } inside && /^- confidence:/ { exit }')"
assert_true "RI-65's decision is 'open', because the oracle half is not decided" \
  str_has_line "$RI65" "- decision: open"
assert_true "…and RI-64's is 'vendor', because the simulator half is" \
  str_has_sub "$INV" "$(printf '### RI-64 — `WASMSimulator`: private execution under the ACVM, in wasm\n- upstream:')"

rm -rf "$NPM_DOCS"
finish
