#!/usr/bin/env bash
# m31-review-mutations.sh — do the 45 assertions M31's REVIEW added see what they were written for?
#
#   scratchpad/campaign/m31-review-mutations.sh [ARM …]      # default: all
#
# The review added assertions in three places and every one of them has to be shown capable of
# failing, for the reason the standing brief gives at length: an assertion written beside a true
# statement reads as its proof.
#
#   R1  the procedure map IS re-keyed (i.e. upstream closes SOURCE-MAPPING §2.4 hole 1)
#   R2  the page reports a module digest that is not the module's
#   R3a the publication predicate always answers 0            (the pin reads as unpublished)
#   R3b the publication predicate always answers 1            (the CONTROL stops controlling)
#   R4  the two builds are read from ONE lock                 (the difference disappears)
#   R5  the shim asks for the wasm_js backend                 (the refusal becomes a value)
#   R6  the procedure-map census is fed an empty corpus       (non-emptiness, the vacuity guard)
#
# Same discipline as `m31-mutations.sh`: restore by CONTENT then `touch`, verify the restore
# against a copy taken here, assert AFTER the run that the mutation is still there, and record the
# failing assertion TEXT rather than only the count.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${M31_REVIEW_MUT_WORK:-$HOME/.cache/m31-review/revmut}"
SAVE="$WORK/save"
mkdir -p "$SAVE" || { echo "could not create $SAVE" >&2; exit 2; }
ARMS_WORK="${M31_WORK:-$HOME/.cache/aztec-m31-arms}"

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'm31-review-mutations: %s\n' "$*" >&2; exit 2; }

FILES=()
save_file() {
  local f="$1" key
  key="$(printf '%s' "$f" | tr '/' '_')"
  [ -f "$f" ] || die "cannot save $f: it does not exist"
  cp "$f" "$SAVE/$key" || die "could not save $f"
  FILES+=("$f")
}
restore_all() {
  local f key rc=0
  for f in "${FILES[@]}"; do
    key="$(printf '%s' "$f" | tr '/' '_')"
    cp "$SAVE/$key" "$f" || rc=1
    touch "$f"
    if [ "$(sha256sum <"$f" | cut -d' ' -f1)" != "$(sha256sum <"$SAVE/$key" | cut -d' ' -f1)" ]; then
      printf 'restore: %s does NOT match its pre-mutation copy\n' "$f" >&2; rc=1
    fi
  done
  [ "$rc" = 0 ] && printf 'restore: every file is byte-identical to its pre-mutation copy\n'
  return "$rc"
}
verify_restore_control() {
  printf 'a\n' >"$WORK/.a"; printf 'b\n' >"$WORK/.b"
  [ "$(sha256sum <"$WORK/.a")" != "$(sha256sum <"$WORK/.b")" ] \
    || die "the restore checker cannot tell two different files apart"
  printf 'restore-control: a one-character corruption IS reported\n'
  rm -f "$WORK/.a" "$WORK/.b"
}
run_check() {
  local check="$1" label="$2"
  local log="$WORK/$label.$check.log"
  ( cd "$REPO" && direnv exec . "verification/$check.sh" ) >"$log" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E "^$check: [0-9]+ assertion" "$log" | tail -1)"
  printf '  %-58s rc=%s  %s\n' "$check" "$rc" "${summary:-<NO SUMMARY LINE>}"
  grep '^  FAIL' "$log" | sed 's/^/      /' | head -10
  return "$rc"
}
refresh_arms() { rm -f "$ARMS_WORK/transpiler.json"; }
still_mutated() {
  grep -q -- "$2" "$1" || die "ARM ABORTED: the mutation in $1 is NO LONGER THERE after the run."
}

ARMS=("$@")
[ "${#ARMS[@]}" -gt 0 ] || ARMS=(R1 R2 R3a R3b R4 R5 R6)
in_arms() { local a; for a in "${ARMS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }

verify_restore_control

ARMS_MJS="$REPO/tools/run_transpiler_arms.mjs"
PAGE="$REPO/verification/m31/page/transpile_page.mjs"
IDENT="$REPO/verification/verify_transpiler_wasm_output_identical_to_native.sh"
NEUTRAL="$REPO/verification/verify_transpiler_native_build_unaffected.sh"
RUNG="$REPO/verification/verify_transpiler_rung1_mapping_survives.sh"
SHIM_CFG="$REPO/avm-transpiler-wasm/.cargo/config.toml"

# --------------------------------------------------------------------------------------------
# R1 — the procedure map IS re-keyed. §4b asserts it is NOT; the day upstream closes hole 1 this
# must go red rather than sit green over a document that says the hole is open.
# --------------------------------------------------------------------------------------------
if in_arms R1; then
  say "R1 — brillig_procedure_locs is re-keyed after all"
  save_file "$ARMS_MJS"
  python3 - "$ARMS_MJS" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        procedureLocs: JSON.stringify(debugInfo.brillig_procedure_locs ?? {}),"
new = ("        // MUTATION R1: pretend upstream re-keyed it\n"
       "        procedureLocs: JSON.stringify(Object.fromEntries(Object.entries("
       "debugInfo.brillig_procedure_locs ?? {}).map(([k, m]) => [k, Object.fromEntries("
       "Object.entries(m).map(([kk, v]) => [String(Number(kk) + 64), v]))]))),")
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check verify_transpiler_rung1_mapping_survives R1
  still_mutated "$ARMS_MJS" "MUTATION R1"
  restore_all; refresh_arms
fi

# --------------------------------------------------------------------------------------------
# R2 — the page reports a digest that is not the module's. The old check never compared the
# page's module digest against the file at all; this is the assertion that closes that.
# --------------------------------------------------------------------------------------------
if in_arms R2; then
  say "R2 — the page reports a module digest that is not the module's"
  save_file "$PAGE"
  python3 - "$PAGE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  const moduleSha = await sha256Hex(moduleBytes);"
new = ("  // MUTATION R2: hash something else\n"
       "  const moduleSha = await sha256Hex(new Uint8Array([1, 2, 3]));")
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check verify_transpiler_wasm_output_identical_to_native R2
  still_mutated "$PAGE" "MUTATION R2"
  restore_all; refresh_arms
fi

# --------------------------------------------------------------------------------------------
# R3a / R3b — the publication predicate, in BOTH directions. M26's review found a control that
# agreed with the thing it was controlling because the predicate short-circuited to 0 for both.
# --------------------------------------------------------------------------------------------
if in_arms R3a; then
  say "R3a — the publication predicate always answers 0"
  save_file "$IDENT"
  python3 - "$IDENT" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "m31_refcount() { # <repo> <rev>\n"
new = "m31_refcount() { # <repo> <rev>\n  printf '0\\n'; return 0  # MUTATION R3a\n"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  run_check verify_transpiler_wasm_output_identical_to_native R3a
  still_mutated "$IDENT" "MUTATION R3a"
  restore_all
fi

if in_arms R3b; then
  say "R3b — the publication predicate always answers 1 (the control stops controlling)"
  save_file "$IDENT"
  python3 - "$IDENT" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "m31_refcount() { # <repo> <rev>\n"
new = "m31_refcount() { # <repo> <rev>\n  printf '1\\n'; return 0  # MUTATION R3b\n"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  run_check verify_transpiler_wasm_output_identical_to_native R3b
  still_mutated "$IDENT" "MUTATION R3b"
  restore_all
fi

# --------------------------------------------------------------------------------------------
# R4 — both resolutions read from ONE lock, so the difference §6 measures disappears. This is the
# state the old comment asserted ("the two builds differ in target and in nothing else").
# --------------------------------------------------------------------------------------------
if in_arms R4; then
  say "R4 — both dependency resolutions are read from the native lock"
  save_file "$NEUTRAL"
  python3 - "$NEUTRAL" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '  WV="$(lockver "$WASM_LOCK" "$crate")"'
new = '  WV="$(lockver "$NATIVE_LOCK" "$crate")"  # MUTATION R4'
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  run_check verify_transpiler_native_build_unaffected R4
  still_mutated "$NEUTRAL" "MUTATION R4"
  restore_all
fi

# --------------------------------------------------------------------------------------------
# R5 — the shim asks for `wasm_js`, i.e. the refusal becomes a plausible value. RI-79's whole
# decision is that it does not.
# --------------------------------------------------------------------------------------------
if in_arms R5; then
  say "R5 — wasm_js reaches the rustflags line"
  save_file "$SHIM_CFG"
  # ITS FIRST FORM CRASHED AND THAT IS RECORDED RATHER THAN QUIETLY REPLACED. Swapping the value
  # outright to `getrandom_backend="wasm_js"` gives **0 assertion(s), 1 failure(s)**: the config is
  # inside the build script's content stamp, so the module rebuilds, and getrandom 0.4 has no
  # `wasm_js` arm in its dispatch (M31's own M9 arm measured that), so the build fails and
  # `m31_require_build` dies at the precondition. The check never reached §6. That is M24's review's
  # rule exactly — "the check failed" and "the check saw what I broke" are different statements —
  # so the arm now adds `wasm_js` to the line while LEAVING the backend selection valid, which
  # builds and reddens the assertion this arm exists for.
  python3 - "$SHIM_CFG" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """rustflags = ['--cfg', 'getrandom_backend="unsupported"']"""
new = """rustflags = ['--cfg', 'getrandom_backend="unsupported"', '--cfg', 'wasm_js_mutation_r5']  # MUTATION R5"""
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  run_check verify_transpiler_native_build_unaffected R5
  still_mutated "$SHIM_CFG" "MUTATION R5"
  restore_all
fi

# --------------------------------------------------------------------------------------------
# R6 — the non-emptiness guard. If every row's procedure map were `{}`, "comes through UNCHANGED"
# would be seven comparisons of `{}` with `{}` — vacuity by DATA, which is the family the standing
# brief records for a deviation field that was zero on every row of the arm it was asserted over.
# --------------------------------------------------------------------------------------------
if in_arms R6; then
  say "R6 — every procedure map is reported empty (the vacuity guard)"
  save_file "$ARMS_MJS"
  python3 - "$ARMS_MJS" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        procedureLocs: JSON.stringify(debugInfo.brillig_procedure_locs ?? {}),"
new = "        procedureLocs: JSON.stringify({}), // MUTATION R6"
assert old in s
s = s.replace(old, new)
old2 = "      inputProcedureLocs[fn.name] = JSON.stringify(di.brillig_procedure_locs ?? {});"
new2 = "      inputProcedureLocs[fn.name] = JSON.stringify({}); // MUTATION R6"
assert old2 in s
open(p, 'w').write(s.replace(old2, new2))
PY
  refresh_arms
  run_check verify_transpiler_rung1_mapping_survives R6
  still_mutated "$ARMS_MJS" "MUTATION R6"
  restore_all; refresh_arms
fi

say "done"
restore_all
