#!/usr/bin/env bash
# test_single_trace_types_instantiation
#
# M24 verification: the build graph resolves `codetracer_trace_types`, `codetracer_trace_writer`
# and `codetracer_ctfs` to ONE instantiation each.
#
# WHY THIS IS A CHECK AND NOT A CONVENTION. Two copies of the trace types on different paths are
# two DISTINCT TYPES: `ValueRecord` from one is not `ValueRecord` from the other, they do not
# unify, and the error surfaces far from its cause. `noir-wt4-webpage/Cargo.toml:175` records
# hitting it and records that `[patch.crates-io]` cannot express the constraint either. RI-42
# names it as one of two consequences to be recorded rather than discovered.
#
# IT IS MEASURED THREE WAYS, AND THEN THE FAILURE IS REPRODUCED.
#
#   1. The LOCK FILE — one `[[package]]` entry per crate name. This is the artefact cargo actually
#      resolved to, not a reading of the manifests.
#   2. `cargo tree --duplicates`, which is cargo's own answer to the same question.
#   3. The MANIFEST is read too, but for a different claim: that `codetracer_ctfs` is NOT named
#      there. It reaches the graph as the writer's own dependency, and naming it again is the
#      cheapest way to introduce a second path to it.
#
# AND THEN TWO NEGATIVE CONTROLS THAT BUILD, because a duplicate detector that has never seen a
# duplicate is indistinguishable from one that cannot see one. Both use a real second copy of
# `codetracer_trace_types` — which is standalone: every one of its dependencies is a crates.io
# package, so a copy of that one directory compiles on its own.
#
#   A. SAME VERSION, TWO PATHS. Cargo refuses the lockfile outright:
#      "package collision in the lockfile ... are different, but only one can be written
#      unambiguously". The failure is at RESOLUTION, before any code is compiled.
#   B. DIFFERENT VERSIONS, TWO PATHS. Cargo accepts two entries, and then the compiler produces
#      exactly the error RI-42 warns about — E0308, with "there are multiple different versions of
#      crate `codetracer_trace_types` in the dependency graph" and the two `ValueRecord`
#      definitions pointed at as "expected" and "found".
#
# Control B is what makes this milestone's claim concrete: the trap is not hypothetical, it is
# reproduced here from the same crates the shipped module is built from.
#
# Run: just verify-ct-single-instantiation

TEST_NAME="test_single_trace_types_instantiation"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m24_ct_writer.sh"
m24_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v nix >/dev/null 2>&1 || die "nix is required (the rust toolchain is not in either dev shell)"

# The module must have been built, or there is no lock file to read — and a lock file this check
# generated itself would be a check depending on state it did not produce, which is precisely how
# four checks once passed against an empty build directory.
m24_require_module
MODULE="$M24_MODULE"
assert_file "the module was built, so its lock file describes a graph that compiled" "$MODULE"

LOCK="$M24_CRATE/Cargo.lock"
assert_file "the crate has a lock file" "$LOCK"

# ---------------------------------------------------------------------------
# 1. The lock file.
# ---------------------------------------------------------------------------
LOCKINFO="$(python3 - "$LOCK" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
pkgs = re.findall(r'^\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', text, re.M)
counts = {}
for name, ver in pkgs:
    counts.setdefault(name, []).append(ver)
print("TOTAL\t%d" % len(pkgs))
for name in sorted(counts):
    print("PKG\t%s\t%d\t%s" % (name, len(counts[name]), ",".join(sorted(counts[name]))))
dups = [n for n, v in counts.items() if len(v) > 1]
print("DUPLICATES\t%d\t%s" % (len(dups), ",".join(sorted(dups))))
ct = [n for n in dups if n.startswith("codetracer")]
print("CODETRACER_DUPLICATES\t%d\t%s" % (len(ct), ",".join(sorted(ct))))
PY
)" || die "the lock file could not be parsed"
[ -n "$LOCKINFO" ] || die "the lock parser printed nothing"

TAB=$'\t'
assert_ge "the lock file describes a real dependency graph (the scan is not vacuous)" "50" \
  "$(printf '%s\n' "$LOCKINFO" | sed -n 's/^TOTAL\t//p')"

for crate in codetracer_trace_types codetracer_trace_writer codetracer_ctfs; do
  n="$(printf '%s\n' "$LOCKINFO" | awk -F'\t' -v c="$crate" '$1=="PKG" && $2==c {print $3}')"
  assert_eq "$crate resolves to exactly ONE instantiation" "1" "${n:-MISSING}"
done
# The two the writer pulls in for itself. Not required by RI-42, asserted because a second copy of
# either would be the same class of defect and costs one line to rule out.
for crate in codetracer_trace_format_capnp codetracer_trace_format_cbor_zstd; do
  n="$(printf '%s\n' "$LOCKINFO" | awk -F'\t' -v c="$crate" '$1=="PKG" && $2==c {print $3}')"
  assert_eq "$crate resolves to exactly ONE instantiation too" "1" "${n:-MISSING}"
done
# THE LOCK DOES CONTAIN DUPLICATES, AND THAT IS NOT A DEFECT — the first draft asserted
# `DUPLICATES 0` and went red on `syn`, `schemars`, `hashbrown` and `indexmap`, which carry two
# major versions each because a proc-macro half of the graph is on the older one. RI-42's
# constraint is about the TRACE crates, and widening it to "no crate anywhere is duplicated" would
# be a claim nothing in this milestone needs and that no real Rust graph satisfies. The filtered
# count is the assertion; the unfiltered one is reported beside it so the filter is visible.
note "every duplicated crate in the lock: $(printf '%s\n' "$LOCKINFO" | sed -n 's/^DUPLICATES\t//p')"
assert_true "no codetracer crate appears twice in the lock" \
  str_has_line_re "$LOCKINFO" "^CODETRACER_DUPLICATES${TAB}0${TAB}\$"
assert_true "and the unfiltered count is NON-zero, so the filter is doing work rather than \
matching an empty list" \
  str_has_line_re "$LOCKINFO" "^DUPLICATES${TAB}[1-9][0-9]*${TAB}"

# ---------------------------------------------------------------------------
# 2. Cargo's own answer.
# ---------------------------------------------------------------------------
TREE="$(m24_require_bounded 900 "cargo tree --duplicates" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
set -uo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
cd "$M24_CRATE" || exit 1
cargo tree --duplicates --target wasm32-unknown-unknown 2>&1
echo "TREE_EXIT $?"
' )" || true
assert_true "cargo tree ran" str_has_sub "$TREE" 'TREE_EXIT'
assert_true "and exited 0" str_has_line_re "$TREE" '^TREE_EXIT 0$'
# `cargo tree --duplicates` prints one SUBTREE per duplicated crate, and the roots are the lines
# at column 0. A codetracer crate appears deeper in those subtrees as a PARENT of `syn` and
# `schemars`, so a substring search for `codetracer` over the whole output is not the question —
# the first draft of this assertion asked it and went red on a graph with no trace-crate duplicate
# in it. The roots are what `--duplicates` is reporting.
TREE_ROOTS="$(printf '%s\n' "$TREE" | grep -E '^[a-zA-Z0-9_-]+ v[0-9]' || true)"
assert_ge "cargo tree --duplicates found some duplicated crates to report (not a vacuous scan)" \
  "1" "$(printf '%s\n' "$TREE_ROOTS" | grep -c . || true)"
note "cargo tree --duplicates roots: $(printf '%s\n' "$TREE_ROOTS" | tr '\n' ' ')"
assert_eq "and NONE of them is a codetracer crate" "0" \
  "$(printf '%s\n' "$TREE_ROOTS" | grep -c '^codetracer' || true)"

# ---------------------------------------------------------------------------
# 3. The manifest names TWO paths, deliberately, and not three.
# ---------------------------------------------------------------------------
MANIFEST="$(cat "$M24_CRATE/Cargo.toml")"
assert_eq "the manifest declares codetracer_trace_types exactly once" "1" \
  "$(printf '%s\n' "$MANIFEST" | grep -c '^codetracer_trace_types = ' || true)"
assert_eq "and codetracer_trace_writer exactly once" "1" \
  "$(printf '%s\n' "$MANIFEST" | grep -c '^codetracer_trace_writer = ' || true)"
assert_eq "and does NOT declare codetracer_ctfs at all — it arrives as the writer's own dependency" "0" \
  "$(printf '%s\n' "$MANIFEST" | grep -c '^codetracer_ctfs = ' || true)"
assert_eq "both declared paths point into the SAME materialised checkout" "2" \
  "$(printf '%s\n' "$MANIFEST" | grep -c 'path = "build-wasm-deps/ctf/' || true)"
# And the writer's own manifest is where ctfs comes from, read rather than assumed.
assert_true "the writer's own manifest is what names codetracer_ctfs" \
  str_has_sub "$(cat "$M24_CRATE/build-wasm-deps/ctf/codetracer_trace_writer/Cargo.toml")" \
  'codetracer_ctfs = { path = "../codetracer_ctfs" }'

# ---------------------------------------------------------------------------
# THE TWO NEGATIVE CONTROLS.
# ---------------------------------------------------------------------------
DUP_WORK="${M24_DUP_WORK:-$HOME/.cache/aztec-m24-dup}"
CTF="$M24_CRATE/build-wasm-deps/ctf"
rm -rf "$DUP_WORK" || die "could not clear $DUP_WORK"
mkdir -p "$DUP_WORK/probe/src" "$DUP_WORK/copy" || die "could not create $DUP_WORK"
cp -r "$CTF/codetracer_trace_types" "$DUP_WORK/copy/codetracer_trace_types" \
  || die "could not copy codetracer_trace_types"
assert_dir "a second copy of codetracer_trace_types was made" "$DUP_WORK/copy/codetracer_trace_types"

cat > "$DUP_WORK/probe/src/lib.rs" <<'RS'
// Hand a `ValueRecord` from one copy to a function expecting the other's. If the two copies
// unified, this would compile — which is the point.
use codetracer_trace_types::ValueRecord as A;
use ctt_copy::ValueRecord as B;
pub fn takes_a(_v: A) {}
pub fn hand_over(b: B) { takes_a(b); }
RS

write_probe_manifest() { # <version-clause>
  cat > "$DUP_WORK/probe/Cargo.toml" <<EOF
[package]
name = "dup-probe"
version = "0.0.0"
edition = "2021"

[dependencies]
codetracer_trace_types = { path = "$CTF/codetracer_trace_types" }
ctt_copy = { package = "codetracer_trace_types", $1 path = "$DUP_WORK/copy/codetracer_trace_types" }

[workspace]
EOF
}

run_probe() {
  ( cd "$DUP_WORK/probe" && rm -f Cargo.lock
    m24_run_bounded 900 "the duplicate probe" \
      nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
set -uo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
cargo build --offline 2>&1
echo "PROBE_EXIT $?"
' )
}

# ---- CONTROL A: same version, two paths. Cargo refuses to resolve at all. -----
write_probe_manifest ""
A_OUT="$(run_probe)"
assert_true "CONTROL A ran" str_has_sub "$A_OUT" 'PROBE_EXIT'
assert_false "CONTROL A did NOT succeed" str_has_line_re "$A_OUT" '^PROBE_EXIT 0$'
assert_true "CONTROL A: cargo REFUSES a lockfile with two copies of the same crate at the same version" \
  str_has_sub "$A_OUT" 'package collision in the lockfile'
assert_true "and names codetracer_trace_types as the colliding package" \
  str_has_sub "$A_OUT" 'packages codetracer_trace_types'
assert_false "so no lock file was written for CONTROL A" test -f "$DUP_WORK/probe/Cargo.lock"

# ---- CONTROL B: different versions. Two entries resolve, and the types do not unify. ----
sed -i 's/^version = "0.19.0"$/version = "0.19.1"/' "$DUP_WORK/copy/codetracer_trace_types/Cargo.toml" \
  || die "could not bump the copy's version"
assert_true "the copy now declares a different version" \
  str_has_sub "$(cat "$DUP_WORK/copy/codetracer_trace_types/Cargo.toml")" 'version = "0.19.1"'
write_probe_manifest 'version = "0.19.1",'
B_OUT="$(run_probe)"
assert_true "CONTROL B ran" str_has_sub "$B_OUT" 'PROBE_EXIT'
assert_false "CONTROL B did NOT succeed either" str_has_line_re "$B_OUT" '^PROBE_EXIT 0$'
assert_file "CONTROL B resolved far enough to write a lock file" "$DUP_WORK/probe/Cargo.lock"
assert_eq "CONTROL B's lock carries TWO codetracer_trace_types entries" "2" \
  "$(grep -c 'name = "codetracer_trace_types"' "$DUP_WORK/probe/Cargo.lock" || true)"
# THE SAME PARSER that reported 0 duplicates over the real lock must report 1 over this one.
# Without this, "0 duplicates" is satisfied by a parser that cannot count.
DUPINFO="$(python3 - "$DUP_WORK/probe/Cargo.lock" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
pkgs = re.findall(r'^\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', text, re.M)
counts = {}
for name, ver in pkgs:
    counts.setdefault(name, []).append(ver)
dups = [n for n, v in counts.items() if len(v) > 1]
ct = [n for n in dups if n.startswith("codetracer")]
print("DUPLICATES\t%d\t%s" % (len(dups), ",".join(sorted(dups))))
print("CODETRACER_DUPLICATES\t%d\t%s" % (len(ct), ",".join(sorted(ct))))
PY
)"
assert_true "and the SAME parser reports it as a codetracer duplicate, so 0 above is a measurement" \
  str_has_line_re "$DUPINFO" "^CODETRACER_DUPLICATES${TAB}1${TAB}codetracer_trace_types\$"
# THE TRAP ITSELF, reproduced. This is the error RI-42 exists to prevent.
assert_true "CONTROL B: the compiler reports multiple versions in the dependency graph" \
  str_has_sub "$B_OUT" 'there are multiple different versions of crate `codetracer_trace_types` in the dependency graph'
assert_true "and it is a type mismatch, E0308" str_has_sub "$B_OUT" 'E0308'
assert_true "with one ValueRecord as the expected type" str_has_sub "$B_OUT" 'this is the expected type'
assert_true "and the other as the found type — two distinct types, exactly as RI-42 says" \
  str_has_sub "$B_OUT" 'this is the found type'

# ---- THE CONTROL FOR THE CONTROLS: one copy compiles. ------------------------
# Without this, both controls above are satisfied by a probe that cannot compile for any reason —
# a syntax error, a missing crate, an offline registry.
cat > "$DUP_WORK/probe/Cargo.toml" <<EOF
[package]
name = "dup-probe"
version = "0.0.0"
edition = "2021"

[dependencies]
codetracer_trace_types = { path = "$CTF/codetracer_trace_types" }

[workspace]
EOF
cat > "$DUP_WORK/probe/src/lib.rs" <<'RS'
use codetracer_trace_types::ValueRecord as A;
pub fn takes_a(_v: A) {}
pub fn hand_over(b: A) { takes_a(b); }
RS
C_OUT="$(run_probe)"
assert_true "THE CONTROL FOR THE CONTROLS: with ONE copy, the same probe compiles" \
  str_has_line_re "$C_OUT" '^PROBE_EXIT 0$'
assert_false "and reports no version-multiplicity note" \
  str_has_sub "$C_OUT" 'multiple different versions'

m24_finish
