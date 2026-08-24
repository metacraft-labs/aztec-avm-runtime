#!/usr/bin/env bash
# test_large_assignment_survives_an_exported_name — M17, carried from M11.
#
# A CHECK THAT ASSIGNS A LARGE VALUE TO AN AMBIENTLY-EXPORTED NAME MUST STILL BE ABLE TO EXEC.
#
# THE DEFECT. A bash assignment to a name that is ALREADY EXPORTED keeps the export attribute. This
# workstation's environment exports `out` — direnv leaks a nix build environment, and `declare -p
# out` reads `declare -x out=...`. `verify_submission_is_a_manual_step` then does
# `out="$(… --dry-run 2>&1)"`, 738 KB of report, which therefore went into the ENVIRONMENT, past
# Linux's `MAX_ARG_STRLEN` of 128 KB per string, and every subsequent `exec` in that shell failed
# with E2BIG. The check scored 35 assertions instead of 95; its only diagnostic was
# `python3: Argument list too long`, which names neither the variable nor the cause; and two sibling
# checks failed downstream of it and were written up as network or upstream problems.
#
# THE FIX IS IN lib.sh AND IT IS GENERAL: every ambient ALL-LOWERCASE exported name is de-exported
# at source time. POSIX reserves lowercase names for applications, every environment variable these
# checks legitimately read is upper-case, and lowercase is exactly the namespace the check scripts
# use for their own variables. Measured in this environment, `out`, `outputs`, `name`, `patches`,
# `phases`, `shell`, `stdenv` and `builder` are all exported, and at least four of those are
# plausible names for a shell script's own variable.
#
# THIS CHECK IS THE REGRESSION, AND IT RUNS BOTH DIRECTIONS. A guard whose absence was never
# demonstrated is a guard nobody can tell is working — and the first draft of it did not work at
# all, because it enumerated exported names with `compgen -e`, which the dev shells' bash reports as
# `command not found`. It silently did nothing and both arms failed identically. That is why the
# NEGATIVE arm is here and is asserted to fail: without it this check would have passed over a
# no-op.
#
# It builds nothing and takes no work directory.
#
# Run: just verify-exported-name-guard

TEST_NAME="test_large_assignment_survives_an_exported_name"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

# Comfortably over MAX_ARG_STRLEN (128 KB) and comparable to the 738 KB that caused it.
BIG=756000
PROBE="$SCRATCH/probe.sh"
cat >"$PROBE" <<'SH'
#!/usr/bin/env bash
# <guard|noguard> <bytes> <exec-stderr-path> — assign that many bytes to `out`, then exec.
set -uo pipefail
if [ "$1" = "guard" ]; then
  TEST_NAME=probe . "$LIB_SH"
fi
out="$(python3 -c "import sys; sys.stdout.write('x' * $2)")"
printf 'len=%s\n' "${#out}"
# `${out@a}` is a bash parameter transformation giving the variable's attribute letters — `x` for
# exported. It is used INSTEAD of `declare -p out | grep` because in the arm this check exists to
# reproduce, the grep itself cannot be exec'd: the defect breaks its own measurement.
printf 'attrs=[%s]\n' "${out@a}"
if /usr/bin/env true 2>"$3"; then printf 'exec=ok\n'; else printf 'exec=failed:%s\n' "$?"; fi
SH
chmod +x "$PROBE"
export LIB_SH="$VERIFY_DIR/lib.sh"

# `out` is exported for BOTH arms, because that is the environment the defect happens in. If this
# shell's own environment did not already have it, the arms would differ for the wrong reason.
# The fallback is a placeholder for a machine whose environment does not already carry `out`; its
# CONTENT is irrelevant — what matters is only that the name is exported in both arms — so it is a
# literal rather than a path off this workstation.
export out="${out:-nix-build-output-placeholder}"

# ---------------------------------------------------------------------------
echo "== 1. the environment the defect needs, established rather than assumed"
# ---------------------------------------------------------------------------
assert_ge "the probe's payload is over MAX_ARG_STRLEN's 128 KB" 131072 "$BIG"
ARG_MAX="$(getconf ARG_MAX 2>/dev/null || echo 0)"
note "ARG_MAX on this host: $ARG_MAX; MAX_ARG_STRLEN is 128 KB per string regardless"
assert_ge "the payload is smaller than ARG_MAX, so the failure is the per-STRING limit" \
  "$BIG" "$ARG_MAX"

# ---------------------------------------------------------------------------
echo "== 2. WITHOUT the guard: the exec fails, and it fails for the right reason"
# ---------------------------------------------------------------------------
NG="$SCRATCH/noguard.txt"
env out="$out" bash "$PROBE" noguard "$BIG" "$SCRATCH/noguard.exec.err" >"$NG" 2>"$SCRATCH/noguard.err"
NG_TXT="$(cat "$NG")"
assert_contains "the value is there in full" "len=$BIG" "$NG_TXT"
assert_contains "…and it is EXPORTED, because the ambient name already was" "attrs=[x]" "$NG_TXT"
assert_contains "…so the exec fails" "exec=failed" "$NG_TXT"
# The specific failure mode, not merely a non-zero status: 126 is what bash reports for an exec that
# could not be performed, and the message names the limit.
assert_contains "…with the status bash gives an exec it could not perform" "exec=failed:126" "$NG_TXT"
assert_contains "…and the kernel's own reason, captured from the failing exec itself" \
  "Argument list too long" "$(cat "$SCRATCH/noguard.exec.err")"

# ---------------------------------------------------------------------------
echo "== 3. WITH the guard: the exec succeeds and the value is not lost"
# ---------------------------------------------------------------------------
G="$SCRATCH/guard.txt"
env out="$out" bash "$PROBE" guard "$BIG" "$SCRATCH/guard.exec.err" >"$G" 2>"$SCRATCH/guard.err"
G_TXT="$(cat "$G")"
assert_contains "the exec succeeds" "exec=ok" "$G_TXT"
assert_contains "…and the value is still there in full, because the name was DE-exported, not unset" \
  "len=$BIG" "$G_TXT"
assert_contains "…and it is no longer exported" "attrs=[]" "$G_TXT"
assert_eq "…and the same exec writes nothing to stderr under the guard" "" "$(cat "$SCRATCH/guard.exec.err")"

# The two arms differ, or one of them measured the other.
assert_true "the two arms genuinely differ" test "$G_TXT" != "$NG_TXT"

# ---------------------------------------------------------------------------
echo "== 4. the guard does what it says: de-export, not unset, and only lowercase"
# ---------------------------------------------------------------------------
LIB="$(cat "$VERIFY_DIR/lib.sh")"
assert_contains "lib.sh de-exports rather than unsets" 'export -n "$n"' "$LIB"
assert_not_contains "…and never unsets an ambient name" 'unset -v "$n"' "$LIB"
assert_contains "…and enumerates with declare -x, because compgen is not available here" \
  'declare -x | sed -n' "$LIB"
# An upper-case exported name must survive: HOME, PATH, LD_LIBRARY_PATH and the milestones' own
# <M>_WORK variables are all read from the environment by these checks.
SURVIVE="$SCRATCH/survive.txt"
env FOO_UPPER=kept lower_kept=alsokept bash -c '
  TEST_NAME=probe . "$1"
  printf "upper=[%s]\n" "${FOO_UPPER@a}"
  printf "lower=[%s]\n" "${lower_kept@a}"
  printf "lower_value=%s\n" "$lower_kept"
' bash "$VERIFY_DIR/lib.sh" >"$SURVIVE" 2>/dev/null
SURVIVE_TXT="$(cat "$SURVIVE")"
assert_contains "an UPPER-case exported variable keeps its export attribute" "upper=[x]" "$SURVIVE_TXT"
assert_contains "…a lower-case one loses it" "lower=[]" "$SURVIVE_TXT"
assert_contains "…and keeps its value" "lower_value=alsokept" "$SURVIVE_TXT"

# ---------------------------------------------------------------------------
echo "== 5. the check that was bitten no longer names a variable the environment exports"
# ---------------------------------------------------------------------------
CARRY="$VERIFY_DIR/verify_accepted_patches_dropped_from_carry.sh"
assert_file "the check that produced the 738 KB assignment exists" "$CARRY"
assert_eq "…and it no longer assigns to the bare name 'out'" "0" \
  "$(grep -cE '^[[:space:]]*out=' "$CARRY" || true)"
assert_ge "…having renamed it to something the environment does not export" 1 \
  "$(grep -cE '^[[:space:]]*harness_out=' "$CARRY" || true)"
# …and that new name is not one this environment carries at all, which is the property that made
# `out` dangerous. `${x+set}` rather than `${x@a}` because the latter needs the variable to exist
# and `set -u` is on.
assert_eq "harness_out is not a name this environment already has" "" "${harness_out+set}"

finish
