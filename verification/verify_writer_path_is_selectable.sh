#!/usr/bin/env bash
# verify_writer_path_is_selectable
#
# M41 verification: BOTH writers are selectable, and `ct_writer_kind()` reports which one produced
# each container.
#
# WHY THIS IS M41'S FIRST CHECK. Until M41 there was no seam at all — no `[features]` block, no
# `cfg`, and `CtfsTraceWriter` named at the type level in two places. "Path A" and "Path B" were a
# decision recorded in prose about code that could express only one of them. Every other M41 check
# compares two modules; if two modules cannot be built, none of them means anything, and this is
# the cheapest place to find that out.
#
# THE CONTROL IS THE OTHER MODULE, WHICH IS THE STRONGEST CONTROL AVAILABLE HERE. `ct_writer_kind()`
# returning 1 is evidence of nothing on its own: a literal `1` in a function body would satisfy it
# forever. What cannot be satisfied by a literal is TWO modules, built from one source tree,
# DISAGREEING — so the assertion is that they disagree, and the value each reports is checked
# against the constant its own backend declares.
#
# AND THE TWO WAYS A CHECK DIES SILENTLY ARE BOTH DEMONSTRATED HERE, deliberately, because they are
# different failures and a check that showed one would be claiming the other:
#
#   * a HANG — no exit, so no trap, so no summary, and the sweep blocks behind it. `m41_bounded`
#     turns it into a named death, and the arm below runs a real `sleep` against a one-second bound
#     to show the mechanism fires.
#   * a DEATH BEFORE THE SUMMARY — an exit the trap does see, whose summary line must still be
#     printed. The arm below runs a subshell check that dies mid-way and asserts its output carries
#     the summary, so "the check printed nothing" cannot be mistaken for "the check passed".
#
# Run: just verify-writer-path-selectable

TEST_NAME="verify_writer_path_is_selectable"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ---------------------------------------------------------------------------
# 1. The seam exists in the manifest, not only in a comment.
# ---------------------------------------------------------------------------
MANIFEST="$M41_CRATE/Cargo.toml"
assert_file "ct-writer has a manifest" "$MANIFEST"
assert_true "the manifest declares a [features] section" \
  grep -qx '\[features\]' "$MANIFEST"
assert_true "and declares path-a" grep -qE '^path-a *=' "$MANIFEST"
assert_true "and declares path-b" grep -qE '^path-b *=' "$MANIFEST"
assert_true "with path-a as the default, so the shipped configuration is unchanged" \
  grep -qE '^default *= *\["path-a"\]' "$MANIFEST"

# ---------------------------------------------------------------------------
# 2. Both modules build, and they are different artefacts.
# ---------------------------------------------------------------------------
m41_require_path_a
m41_require_path_b
assert_file "the Path A module was built" "$M41_PATH_A"
assert_file "the Path B module was built" "$M41_PATH_B"

SUM_A="$(sha256sum "$M41_PATH_A" | cut -d' ' -f1)"
SUM_B="$(sha256sum "$M41_PATH_B" | cut -d' ' -f1)"
assert_false "the two modules are not the same bytes under two names" \
  test "$SUM_A" = "$SUM_B"

BYTES_A="$(wc -c <"$M41_PATH_A")"
BYTES_B="$(wc -c <"$M41_PATH_B")"
m41_say "Path A: $BYTES_A bytes  ${SUM_A:0:16}"
m41_say "Path B: $BYTES_B bytes  ${SUM_B:0:16}"
assert_ge "the Path A module is not empty" 100000 "$BYTES_A"
assert_ge "the Path B module is not empty" 100000 "$BYTES_B"

# ---------------------------------------------------------------------------
# 3. Each reports its OWN kind, and they disagree.
# ---------------------------------------------------------------------------
m41_drive "$M41_PATH_A" path-a
m41_drive "$M41_PATH_B" path-b

KIND_A="$(m41_report path-a writerKind)"
KIND_B="$(m41_report path-b writerKind)"
assert_eq "the Path A module reports DD-7's Path A" "1" "$KIND_A"
assert_eq "the Path B module reports DD-7's Path B" "2" "$KIND_B"
assert_false "and the two disagree, so the field is measured rather than constant" \
  test "$KIND_A" = "$KIND_B"

# The constants are read out of the SOURCE too, so a module reporting 2 while the code calls 2
# something else would be caught. A check that compared the module against a number typed into
# this file would be comparing two copies of a guess.
BACKEND="$M41_CRATE/src/backend.rs"
assert_true "the source declares Path A's kind as the module reports it" \
  grep -qE "CT_WRITER_KIND_PATH_A_PURE_RUST: u32 = $KIND_A;" "$BACKEND"
assert_true "the source declares Path B's kind as the module reports it" \
  grep -qE "CT_WRITER_KIND_PATH_B_NIM: u32 = $KIND_B;" "$BACKEND"

# ---------------------------------------------------------------------------
# 4. Both produced a real container, so "selectable" means "usable".
# ---------------------------------------------------------------------------
CONT_A="$(m41_report path-a containerBytes)"
CONT_B="$(m41_report path-b containerBytes)"
assert_ge "the Path A container is not empty" 1024 "$CONT_A"
assert_ge "the Path B container is not empty" 1024 "$CONT_B"
m41_say "containers: Path A $CONT_A bytes, Path B $CONT_B bytes"

for f in path-a path-b; do
  MAGIC="$(python3 -c "
import sys
d = open('$M41_WORK/$f/container.ct','rb').read(5)
print(' '.join('%02x' % b for b in d))
")"
  assert_eq "the $f container carries the CTFS magic" "c0 de 72 ac e2" "$MAGIC"
done

# ---------------------------------------------------------------------------
# 5. THE HANG ARM. A bound that never fires has never been shown to fire.
# ---------------------------------------------------------------------------
HANG_RC=0
m41_run_unbounded_probe() {
  timeout --signal=TERM --kill-after=5 1 sleep 30
}
m41_run_unbounded_probe || HANG_RC=$?
assert_eq "a process that outlives its bound is killed with 124, not waited on" "124" "$HANG_RC"

# ---------------------------------------------------------------------------
# 6. THE DIE-BEFORE-SUMMARY ARM. The trap must print the summary on an abnormal exit, or a check
#    that died reads as a smaller milestone rather than a red one.
# ---------------------------------------------------------------------------
DEATH_PROBE="$M41_WORK/death-probe.sh"
mkdir -p "$M41_WORK"
cat >"$DEATH_PROBE" <<'PROBE'
#!/usr/bin/env bash
TEST_NAME="verify_writer_path_is_selectable_death_probe"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit
assert_eq "one assertion runs before the death, so the summary has something to count" "1" "1"
die "this probe dies on purpose, before finish, so the trap has something to do"
PROBE
chmod +x "$DEATH_PROBE"
cp "$DEATH_PROBE" "$REPO_ROOT/verification/.m41-death-probe.sh"
DEATH_OUT="$(bash "$REPO_ROOT/verification/.m41-death-probe.sh" 2>&1 || true)"
rm -f "$REPO_ROOT/verification/.m41-death-probe.sh"
assert_contains "a check that dies before finish still prints its own name" \
  "verify_writer_path_is_selectable_death_probe" "$DEATH_OUT"
assert_contains "and still prints the reason it died" "dies on purpose" "$DEATH_OUT"
assert_contains "and still prints a summary line, so silence cannot be read as success" \
  "assertion" "$DEATH_OUT"

finish
