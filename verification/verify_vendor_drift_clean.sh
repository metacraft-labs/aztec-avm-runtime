#!/usr/bin/env bash
# verify_vendor_drift_clean
#
# M1 verification: `just check-drift` reports only the edits enumerated in
# PROVENANCE.md and fails on any other divergence.
#
# Two halves, and the second is what gives the first its meaning:
#
#   1. `check-drift` exits 0 over the real tree — 742 vendored files against
#      three anchors — having made real assertions, with no SKIP line anywhere.
#   2. FOUR NEGATIVE CONTROLS. Each builds a scratch copy of the real repository,
#      mutates it, and requires check-drift to FAIL there:
#        a. an unrecorded content edit to a vendored file;
#        b. an unrecorded deletion of a vendored file;
#        c. a recorded edit removed from PROVENANCE.md's ledger while the edit
#           itself stays in the file — the direction a laxer check would miss;
#        d. a change to a derived tree that the recorded transformation does not
#           produce.
#      A drift check never observed to fail is indistinguishable from one that
#      cannot fail.
#
# The scratch copy is built from `git ls-files` plus the M1 tools, so it is small
# (no node_modules) and nothing here can write to the tree it is checking. Each
# copy gets its own parent directory with an `aztec-packages` symlink beside it,
# because check_drift.sh resolves the fork as a workspace-root sibling.
#
# Run: just verify-vendor-drift

TEST_NAME="verify_vendor_drift_clean"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -x "$VERIFY_DIR/check_drift.sh" ] || die "verification/check_drift.sh is missing or not executable"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"

# ---- 1. the real tree ------------------------------------------------------
out="$("$VERIFY_DIR/check_drift.sh" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "just check-drift exits 0 over the real tree"
  note "$(printf '%s\n' "$out" | tail -1)"
else
  fail "just check-drift exits $rc over the real tree"
  printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ' || true)"
assert_ge "check-drift made a meaningful number of assertions" 15 "$n_ok"
assert_not_contains "check-drift printed no SKIP line" "SKIP" "$out"

# ---- 2. negative controls --------------------------------------------------
# NOT `mktemp -d`, which lands in $TMPDIR. On this host $TMPDIR is a quota-limited tmpfs where
# `df` reports gigabytes free and a write fails anyway with EDQUOT — the campaign brief has said
# so since M3, and this check is the heaviest offender because it stages the whole tracked tree
# (1,427 files) once as a template and again per negative control. Measured by M21's review: with
# another agent's build occupying /tmp, `verify_vendor_drift_clean` died mid-copy with
# `cp: error copying …: Disk quota exceeded`, emitted NO summary line at all, and took M1 from 151
# to 141 with no failure printed — a red that says nothing about vendor drift. The same run with
# TMPDIR under ~/.cache is 10 assertions, 0 failures. A work directory this check owns is the fix.
M1_WORK="${M1_WORK:-$HOME/.cache/aztec-m1-vendor-drift}"
mkdir -p "$M1_WORK" || die "could not create the work directory $M1_WORK"
SANDBOX_BASE="$(mktemp -d "$M1_WORK/sandbox.XXXXXX")" \
  || die "could not create a sandbox under $M1_WORK"
trap 'rm -rf "$SANDBOX_BASE"' EXIT

# A pristine template, copied per control. Tracked files + the M1 additions.
TEMPLATE="$SANDBOX_BASE/template"
staged="$(python3 - "$REPO_ROOT" "$TEMPLATE" <<'PY'
import os, shutil, subprocess, sys
src, dst = sys.argv[1], sys.argv[2]
files = subprocess.run(["git", "-C", src, "ls-files", "-z"],
                       capture_output=True, check=True).stdout.decode().split("\0")
extra = ["PROVENANCE.md", "pins.json", "REUSE-INVENTORY.md", "DRIFT.md", "PINS.md"]
extra += ["tools/" + f for f in os.listdir(os.path.join(src, "tools"))] if os.path.isdir(os.path.join(src, "tools")) else []
extra += ["verification/" + f for f in os.listdir(os.path.join(src, "verification"))]
n = 0
for rel in [f for f in files if f] + extra:
    s = os.path.join(src, rel)
    if os.path.isdir(s) and not os.path.islink(s):
        continue  # e.g. tools/__pycache__
    if not os.path.exists(s) and not os.path.islink(s):
        continue
    d = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    if os.path.islink(s):
        if os.path.lexists(d):
            os.unlink(d)
        os.symlink(os.readlink(s), d)
    else:
        shutil.copy2(s, d)
    n += 1
if n < 500:
    raise SystemExit("staged only %d files; the sandbox would not be representative" % n)
print(n)
PY
)" || die "could not stage the scratch template"
note "scratch template staged $staged files"

assert_file "the scratch template has PROVENANCE.md" "$TEMPLATE/PROVENANCE.md"

# Give the template its own index so `git ls-files` works inside it. This is a
# throwaway repository under $TMPDIR, not the working copy.
( cd "$TEMPLATE" && git init -q . && git add -- . >/dev/null 2>&1 ) \
  || die "could not initialise the scratch index"

make_sandbox() { # -> prints the sandbox repo path
  local parent
  parent="$(mktemp -d -p "$SANDBOX_BASE")"
  ln -s "$FORK_ROOT" "$parent/aztec-packages"
  cp -a "$TEMPLATE" "$parent/aztec-avm-runtime"
  printf '%s' "$parent/aztec-avm-runtime"
}

sandbox_check() { ( cd "$1" && "$1/verification/check_drift.sh" >/dev/null 2>&1 ); }

# The unmutated sandbox must be GREEN, or every control below "fails" for the
# wrong reason and proves nothing.
clean_sandbox="$(make_sandbox)"
if sandbox_check "$clean_sandbox"; then
  pass "the unmutated scratch copy passes check-drift (the controls start from green)"
else
  fail "the unmutated scratch copy already fails check-drift; the controls would be meaningless"
  ( cd "$clean_sandbox" && ./verification/check_drift.sh 2>&1 | grep -E '^  FAIL|cannot run' | head -5 | sed 's/^/      /' ) >&2
  finish
fi

control() { # <description> <shell-body-run-inside-the-sandbox>
  local desc="$1" body="$2" dir
  dir="$(make_sandbox)"
  if ! ( cd "$dir" && eval "$body" ); then
    fail "$desc — the mutation itself failed to apply"
    return
  fi
  if sandbox_check "$dir"; then
    fail "$desc — check-drift still PASSED; it is too weak"
  else
    pass "$desc — check-drift failed, as it must"
  fi
}

VICTIM="reference/vm2-common/gas.hpp"
assert_file "the control's victim file exists" "$REPO_ROOT/$VICTIM"

control "an unrecorded content edit to a vendored file" \
  "printf '\n// unrecorded edit\n' >> '$VICTIM'"

control "an unrecorded deletion of a vendored file" \
  "rm -f '$VICTIM' && git rm -q --cached '$VICTIM'"

control "a recorded edit dropped from the PROVENANCE.md ledger while the edit remains" \
  "grep -q 'spike/src/public/fixtures/public_tx_simulation_tester.ts | spike-pure-ts' PROVENANCE.md && \
   sed -i '/^| spike\\/src\\/public\\/fixtures\\/public_tx_simulation_tester.ts | spike-pure-ts/d' PROVENANCE.md"

control "a change to the derived tree the recorded transformation does not produce" \
  "printf '\n// not produced by the rename\n' >> drift/src/public/avm/avm_simulator.ts"

finish
