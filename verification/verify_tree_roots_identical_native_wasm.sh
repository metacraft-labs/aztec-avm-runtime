#!/usr/bin/env bash
# verify_tree_roots_identical_native_wasm — M8.
#
# THE COMPARISON THE SPIKE'S TRANSCRIPTS IMPLIED BUT DID NOT MAKE.
#
# The vm2-wasm spike matched 105 transcript lines native versus wasm: revert codes, gas, fees,
# nullifiers, note hashes, data writes, public logs, call frames and instruction counts. Nullifier
# insertion and data writes exercise the trees, so correct values strongly IMPLY correct trees.
# Implication is not comparison. This check makes the comparison, on M6's real module split and
# M7's overlay rather than on the spike's hacked tree.
#
# It is also the check that BUILDS, so it writes $M8_WORK/measured.env and every other M8 check
# reads it. Nothing here is inferred from a previous run: cmake's exit status and ninja's are
# asserted separately from anything parsed out of either, and every artefact is asserted present
# before any predicate reads it.
#
# COVERAGE. The tree half of this differential is one scripted sequence and seven corpus programs.
# It is an integration check across two targets. Breadth is M7's 391 upstream tests; semantics is
# M19's oracle. Neither number may be quoted as this one.

TEST_NAME="verify_tree_roots_identical_native_wasm"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
require_nix

mkdir -p "$M8_WORK"

# ---------------------------------------------------------------------------
echo "== 1. the tree: 233d8e0993 + six patches, applied in order"
# ---------------------------------------------------------------------------
assert_file "M7's AVM_SIM_TESTS overlay is present" "$M7_PATCH_5"
assert_file "M8's AVM_DIFFERENTIAL overlay is present" "$M8_PATCH_6"
M8_TREE="$(m8_tree)"
m6_tree_or_die M8_TREE
assert_eq "the tree is the base plus exactly six commits" "6" \
  "$(git -C "$M8_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_eq "the sixth commit is M8's overlay" \
  "test(vm2): AVM_DIFFERENTIAL, a native-versus-wasm differential driver" \
  "$(git -C "$M8_TREE" log -1 --format=%s)"
assert_eq "nothing under barretenberg/ differs from the prepared HEAD" "" "$(m8_tree_dirty)"

# The overlay adds exactly one source file, and the milestone's "built from identical sources"
# claim is about THAT file. Read out of the patch itself rather than off the disk.
NEW_FILES="$(grep -c '^new file mode' "$M8_PATCH_6" || true)"
assert_eq "M8's overlay creates exactly one file" "1" "$NEW_FILES"
assert_true "and it is the differential driver" \
  grep -q '^+++ b/barretenberg/cpp/src/barretenberg/vm2/differential/avm_differential.cpp$' "$M8_PATCH_6"
assert_true "the overlay adds no test source" \
  bash -c "! grep -qE '^\+\+\+ b/.*\.(test|bench|fuzzer)\.cpp\$' '$M8_PATCH_6'"

DRIVER_SRC="$M8_TREE/barretenberg/cpp/src/barretenberg/vm2/differential/avm_differential.cpp"
assert_file "the driver source is in the prepared tree" "$DRIVER_SRC"
DRIVER_SHA="$(sha256sum "$DRIVER_SRC" | cut -d' ' -f1)"
note "driver source sha256: $DRIVER_SHA"

# ---------------------------------------------------------------------------
echo "== 2. additive: with the option at its default, no target moves"
# ---------------------------------------------------------------------------
# The default is read from the patch's OWN added option() line, not from a cache a preset could
# have set — M7's precedent, and the reason is that a preset setting it ON would make every
# "additive" claim below true for the wrong reason.
OPTION_LINE="$(grep -E '^\+option\(AVM_DIFFERENTIAL ' "$M8_PATCH_6" | head -1)"
assert_contains "the option is declared by the patch" "option(AVM_DIFFERENTIAL" "$OPTION_LINE"
case "$OPTION_LINE" in
  *" OFF)") pass "the declared default is OFF  [$OPTION_LINE]" ;;
  *)        fail "the declared default is not OFF: [$OPTION_LINE]" ;;
esac

m6_configure "$M8_TREE" wasm-avm "build-wasm-avm-off"
OFF_RC=$?
assert_eq "a wasm configure with the option left at its default succeeds" "0" "$OFF_RC"
if [ "$OFF_RC" -eq 0 ]; then
  # Written to a file rather than held in a variable: the list is ~3,500 entries and passing it as
  # one argv element is E2BIG, which `assert_true` would have reported as a failed assertion about
  # the target list rather than as a broken check.
  OFF_TARGETS="$M8_WORK/off-targets.txt"
  m6_ninja_targets "$M8_TREE" "build-wasm-avm-off" >"$OFF_TARGETS"
  assert_ge "the OFF configure declares a real target list" 100 "$(grep -c . "$OFF_TARGETS" || true)"
  assert_eq "…and it declares no avm_differential target" "0" \
    "$(grep -cE '(^|/)avm_differential$' "$OFF_TARGETS" || true)"
  assert_ge "…while it does declare libvm2_sim.a, so the absence above is not vacuous" 1 \
    "$(grep -c 'libvm2_sim\.a$' "$OFF_TARGETS" || true)"
fi

# ---------------------------------------------------------------------------
echo "== 3. the two builds"
# ---------------------------------------------------------------------------
m8_build_wasm
WASM_RC=$?
assert_eq "the wasm configure exits 0" "0" "${M8_WASM_CONFIGURE_RC:-99}"
assert_eq "the wasm build exits 0" "0" "${M8_WASM_BUILD_RC:-99}"
assert_eq "the wasm side as a whole exits 0" "0" "$WASM_RC"
if [ "$WASM_RC" -ne 0 ]; then
  m6_build_log "$M8_TREE" "$M8_WASM_BUILD" | tail -30 >&2
  finish
fi

m8_build_native
NATIVE_RC=$?
assert_eq "the native configure exits 0" "0" "${M8_NATIVE_CONFIGURE_RC:-99}"
assert_eq "the native build exits 0" "0" "${M8_NATIVE_BUILD_RC:-99}"
assert_eq "the native side as a whole exits 0" "0" "$NATIVE_RC"
if [ "$NATIVE_RC" -ne 0 ]; then
  m6_build_log "$M8_TREE" "$M8_NATIVE_BUILD" | tail -30 >&2
  finish
fi

# `-Wfatal-errors` means a plain `' error: '` grep counts ZERO on a failing build here, and
# `' error: '` is a SUBSTRING of `fatal error:` so it counts non-zero on a passing one. Both
# hazards are M7's, and the discriminator for a clean build is the ninja status above plus the
# absence of `fatal error:`.
assert_eq "no translation unit failed in the wasm build" "0" \
  "$(m6_build_log "$M8_TREE" "$M8_WASM_BUILD" | grep -c 'fatal error:' || true)"
assert_eq "no translation unit failed in the native build" "0" \
  "$(m6_build_log "$M8_TREE" "$M8_NATIVE_BUILD" | grep -c 'fatal error:' || true)"

WASM_BIN="$(m8_wasm_bin avm_differential)"
NATIVE_BIN="$(m8_native_bin avm_differential)"
m8_require_artifacts "$WASM_BIN" "$NATIVE_BIN"
assert_eq "the wasm artefact carries the WebAssembly magic number" "0061736d" \
  "$(head -c 4 "$WASM_BIN" | od -An -tx1 | tr -d ' \n')"
assert_eq "the native artefact is an ELF executable" "7f454c46" \
  "$(head -c 4 "$NATIVE_BIN" | od -An -tx1 | tr -d ' \n')"

# The ON side declares the target the OFF side does not, so the two configures really differ by
# this option and the absence measured above is not a statement about both of them. Asserted here
# rather than beside the OFF check because the ON build directory does not exist until now.
ON_TARGETS="$M8_WORK/on-targets.txt"
m6_ninja_targets "$M8_TREE" "$M8_WASM_BUILD" >"$ON_TARGETS"
assert_ge "the ON configure declares an avm_differential target" 1 \
  "$(grep -cE '(^|/)avm_differential$' "$ON_TARGETS" || true)"
assert_ge "…and the two target lists are otherwise the same size to within a few entries" 1 \
  "$(python3 -c "
a=len(open('$M8_WORK/off-targets.txt').read().split(chr(10)))
b=len(open('$ON_TARGETS').read().split(chr(10)))
print(1 if abs(a-b) < 40 else 0)")"

# ---------------------------------------------------------------------------
echo "== 4. identical sources, two targets"
# ---------------------------------------------------------------------------
# "Built from identical sources" is asserted from the two compile databases rather than asserted in
# prose: the same absolute path, compiled once on each side, out of one worktree.
SRC_REPORT="$(python3 - "$(m6_compile_db "$M8_TREE" "$M8_WASM_BUILD")" \
                        "$(m6_compile_db "$M8_TREE" "$M8_NATIVE_BUILD")" \
                        "$DRIVER_SRC" <<'PY'
import json, sys

wasm_db, native_db, driver = sys.argv[1], sys.argv[2], sys.argv[3]
out = []


def entries(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


w = entries(wasm_db)
n = entries(native_db)
wd = [e for e in w if e["file"] == driver]
nd = [e for e in n if e["file"] == driver]
out.append(("the wasm build compiles the driver exactly once", len(wd) == 1, str(len(wd))))
out.append(("the native build compiles the driver exactly once", len(nd) == 1, str(len(nd))))
if wd and nd:
    out.append(("both compile the same absolute path", wd[0]["file"] == nd[0]["file"], wd[0]["file"]))
    wc, nc = wd[0]["command"], nd[0]["command"]
    out.append(("the wasm side targets wasm32 through the wasi sysroot", "wasi-sysroot" in wc, ""))
    out.append(("the native side does not", "wasi-sysroot" not in nc, ""))
    # The flags this milestone's fifth deliverable is about, read off the driver's own command line.
    for flag in ("-Werror", "-Wconversion", "-Wsign-conversion", "-fwasm-exceptions"):
        out.append((f"the wasm driver is compiled with {flag}", flag in wc, ""))
    out.append(("the wasm driver is NOT compiled with -Wno-error", "-Wno-error" not in wc, ""))
    out.append(("the wasm driver is NOT compiled with -fno-exceptions", "-fno-exceptions" not in wc, ""))

# The support translation units must be the same set on both sides, or "identical sources" is a
# statement about one file in a program built from six. Counted as DISTINCT paths: a native
# AVM=ON configure legitimately compiles vm2/testing/*.cpp a second time into the `vm2` module,
# and comparing the raw lists would report a difference that is not one.
def support(db):
    return sorted({e["file"] for e in db
                   if "/vm2/testing/" in e["file"] and e["file"].endswith(".cpp")
                   and not e["file"].endswith((".test.cpp", ".bench.cpp", ".fuzzer.cpp"))})


ws, ns = support(w), support(n)
out.append(("both builds see the same five vm2/testing support units", ws == ns,
            ";".join(x.split("/")[-1] for x in ws)))
out.append(("and there are five of them", len(ws) == 5, str(len(ws))))

for name, ok, detail in out:
    print(("PASS" if ok else "FAIL") + "\t" + name + "\t" + detail)
PY
)"
printf '%s\n' "$SRC_REPORT" >"$M8_WORK/sources.report"
m8_report "$M8_WORK/sources.report"

# And the decisive form of it: the OBJECT list of the `avm_differential` target itself, on each
# side. This is the program's own input set rather than the build's, so it cannot be satisfied by
# a file that happens to be compiled somewhere else in the tree.
for side in wasm native; do
  case $side in
    wasm)   d="$M8_TREE/barretenberg/cpp/$M8_WASM_BUILD" ;;
    native) d="$M8_TREE/barretenberg/cpp/$M8_NATIVE_BUILD" ;;
  esac
  od="$d/src/barretenberg/vm2/CMakeFiles/avm_differential.dir"
  assert_dir "the $side avm_differential object directory exists" "$od"
  find "$od" \( -name '*.o' -o -name '*.obj' \) -printf '%P\n' 2>/dev/null \
    | sed -e 's/\.obj$//' -e 's/\.o$//' | LC_ALL=C sort >"$M8_WORK/objects.$side"
done
assert_eq "the wasm avm_differential is built from six translation units" "6" \
  "$(grep -c . "$M8_WORK/objects.wasm" || true)"
assert_true "the two targets are built from exactly the same translation units" \
  cmp -s "$M8_WORK/objects.wasm" "$M8_WORK/objects.native"
assert_true "…including the driver itself" \
  grep -q '^differential/avm_differential\.cpp$' "$M8_WORK/objects.wasm"

# ---------------------------------------------------------------------------
echo "== 5. -Wshift-count-overflow and -Wshorten-64-to-32 are errors on the wasm build"
# ---------------------------------------------------------------------------
# The milestone asks for these to be "promoted to errors on the wasm build". Measured, they already
# are: `-Werror` makes the default-on `-Wshift-count-overflow` fatal, and `-Wconversion` supplies
# `-Wshorten-64-to-32`, both of which M6's AVM_WASM patch already puts on every one of
# barretenberg's own wasm translation units. So what M8 adds is not a flag, it is the ASSERTION —
# and it is a measurement rather than a reading of the flag list, because a flag that is present
# and inert is exactly the shape a flag list cannot distinguish.
#
# Three controls, because "the probe failed" is not by itself attributable:
#   * with -Wno-error appended, each probe must COMPILE (so the probe is valid and the promotion is
#     what stopped it);
#   * with -Wconversion removed, the narrowing probe must COMPILE (so -Wconversion is the flag that
#     supplies -Wshorten-64-to-32, rather than it being on by default);
#   * with -Werror removed, the shift probe must COMPILE (so -Werror is what promotes it).
PROBE_DIR="$M8_WORK/warning-probes"
mkdir -p "$PROBE_DIR"
cat >"$PROBE_DIR/shift.cpp" <<'EOF'
#include <cstdint>
uint32_t f() { uint32_t x = 1; return x << 32; }
EOF
cat >"$PROBE_DIR/narrow.cpp" <<'EOF'
#include <cstdint>
int32_t g(int64_t v) { int32_t out = v; return out; }
EOF

WASM_DRIVER_FLAGS="$(python3 - "$(m6_compile_db "$M8_TREE" "$M8_WASM_BUILD")" "$DRIVER_SRC" <<'PY'
import json, shlex, sys
db = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in db if x["file"] == sys.argv[2]]
if not e:
    sys.exit(1)
# The warning flags the build really uses, taken off the driver's own command line rather than
# restated here. Everything else (PCH, includes, output paths) is dropped: the probes are
# standalone.
keep = [t for t in shlex.split(e[0]["command"])
        if t.startswith("-W") or t == "--target=wasm32-wasip1" or t.startswith("--sysroot=")]
print(" ".join(keep))
PY
)"
[ -n "$WASM_DRIVER_FLAGS" ] || die "could not read the driver's own warning flags from the wasm compile database"
note "wasm driver warning flags: $WASM_DRIVER_FLAGS"
assert_contains "the flags taken from the build include -Werror" "-Werror" "$WASM_DRIVER_FLAGS"
assert_contains "…and -Wconversion" "-Wconversion" "$WASM_DRIVER_FLAGS"

WASI_SDK="$(m6_sdk 33)"
m8_probe() { # <extra-flags> <file> -> writes $M8_WORK/probe.out, returns clang's status
  local extra="$1" file="$2"
  m6_in_devshell '
    sdk="$1"; extra="$2"; flags="$3"; file="$4"
    "$sdk/bin/clang++" --target=wasm32-wasip1 --sysroot="$sdk/share/wasi-sysroot" \
      $flags $extra -fsyntax-only "$file" 2>&1
  ' "$WASI_SDK" "$extra" "$WASM_DRIVER_FLAGS" "$file" >"$M8_WORK/probe.out" 2>&1
}

m8_probe "" "$PROBE_DIR/shift.cpp"; RC=$?; OUT="$(cat "$M8_WORK/probe.out")"
assert_true "a shift past the width of the type FAILS the wasm build's own flags" test "$RC" -ne 0
assert_contains "…and it fails naming -Wshift-count-overflow" "-Wshift-count-overflow" "$OUT"

m8_probe "" "$PROBE_DIR/narrow.cpp"; RC=$?; OUT="$(cat "$M8_WORK/probe.out")"
assert_true "a 64-to-32 narrowing FAILS the wasm build's own flags" test "$RC" -ne 0
assert_contains "…and it fails naming -Wshorten-64-to-32" "-Wshorten-64-to-32" "$OUT"

m8_probe "-Wno-error" "$PROBE_DIR/shift.cpp"; RC=$?
assert_eq "control: with -Wno-error the shift probe compiles, so the probe is valid" "0" "$RC"
m8_probe "-Wno-error" "$PROBE_DIR/narrow.cpp"; RC=$?
assert_eq "control: with -Wno-error the narrowing probe compiles, so the probe is valid" "0" "$RC"
m8_probe "-Wno-conversion" "$PROBE_DIR/narrow.cpp"; RC=$?
assert_eq "control: -Wconversion is the flag that supplies -Wshorten-64-to-32" "0" "$RC"
m8_probe "-Wno-error=shift-count-overflow" "$PROBE_DIR/shift.cpp"; RC=$?
assert_eq "control: -Werror is what promotes -Wshift-count-overflow" "0" "$RC"

# And it is not only the driver: every one of barretenberg's own wasm translation units carries the
# two flags, so the promotion is a property of the build rather than of one target.
OWN_TUS="$(m6_own_tu_count "$M8_TREE" "$M8_WASM_BUILD")"
WERROR_TUS="$(m6_flag_tu_count "$M8_TREE" "$M8_WASM_BUILD" "-Werror")"
WCONV_TUS="$(m6_flag_tu_count "$M8_TREE" "$M8_WASM_BUILD" "-Wconversion")"
assert_ge "the wasm build has barretenberg translation units to speak of" 200 "$OWN_TUS"
assert_eq "every one of them carries -Werror" "$OWN_TUS" "$WERROR_TUS"
assert_eq "every one of them carries -Wconversion" "$OWN_TUS" "$WCONV_TUS"

# ---------------------------------------------------------------------------
echo "== 6. run both, and compare the ROOT lines per line"
# ---------------------------------------------------------------------------
NATIVE_T="$(m8_native_transcript)"
V8_T="$(m8_v8_transcript)"
# The transcript is STDOUT, exactly. The AVM logs its own progress on fd 2 and the hosts do not
# interleave the two streams the same way, so merging them would make this a comparison of host
# buffering rather than of the AVM. The stderr is kept, not discarded — check 5 reads it.
m8_run_native "$NATIVE_BIN" "$NATIVE_T" "$(m8_native_stderr)"
assert_eq "the native driver exits 0" "0" "$?"
m8_run_v8 "$WASM_BIN" "$V8_T" "$(m8_v8_stderr)"
assert_eq "the wasm driver exits 0 on V8, running the SHIPPED binary unmodified" "0" "$?"
m8_require_artifacts "$NATIVE_T" "$V8_T" "$(m8_native_stderr)" "$(m8_v8_stderr)"
assert_eq "no AVM log line leaked into the native transcript" "0" \
  "$(grep -c '(mem: N/A)' "$NATIVE_T" || true)"
assert_eq "no AVM log line leaked into the wasm transcript" "0" \
  "$(grep -c '(mem: N/A)' "$V8_T" || true)"
assert_ge "…and the AVM really did log, so the separation is not a statement about silence" 20 \
  "$(grep -c '(mem: N/A)' "$(m8_v8_stderr)" || true)"
assert_eq "the two transcripts carry the same number of non-diagnostic lines" \
  "$(m8_ordinary "$NATIVE_T" | grep -c . || true)" "$(m8_ordinary "$V8_T" | grep -c . || true)"
assert_eq "…and it is the number this milestone records" "$M8_EXPECTED_ORDINARY_LINES" \
  "$(m8_ordinary "$NATIVE_T" | grep -c . || true)"

assert_eq "the native transcript ran to completion" "avmDifferential.done 1" "$(tail -1 "$NATIVE_T")"
assert_eq "the wasm transcript ran to completion" "avmDifferential.done 1" "$(tail -1 "$V8_T")"

N_ROOTS="$M8_WORK/native.roots"; W_ROOTS="$M8_WORK/wasm.roots"
m8_root_lines "$NATIVE_T" >"$N_ROOTS"
m8_root_lines "$V8_T" >"$W_ROOTS"
assert_eq "the native transcript carries the expected number of root+size lines" \
  "$M8_EXPECTED_ROOT_LINES" "$(grep -c . "$N_ROOTS" || true)"
assert_eq "the wasm transcript carries the expected number of root+size lines" \
  "$M8_EXPECTED_ROOT_LINES" "$(grep -c . "$W_ROOTS" || true)"
# Per line, in order, never by count: equal counts survive a swap, a rename or a drop plus an
# addition. A root set does not.
if cmp -s "$N_ROOTS" "$W_ROOTS"; then
  pass "every root and size is identical native versus wasm  [$M8_EXPECTED_ROOT_LINES lines]"
else
  fail "the root lines differ: $(diff "$N_ROOTS" "$W_ROOTS" | head -6 | tr '\n' ' ')"
fi

# A comparison of constants is not a comparison. The roots must move.
DISTINCT="$(grep -oE '0x[0-9a-f]{64}' "$N_ROOTS" | LC_ALL=C sort -u | grep -c . || true)"
assert_ge "the roots move across the transcript rather than being one constant" 30 "$DISTINCT"

# And each of the seven programs must have contributed a start AND an end snapshot for all four
# trees, so "200 root lines" cannot be 200 lines from one program.
for prog in add revert loop sha256 poseidon2 storage burn; do
  assert_eq "program $prog reports four start and four end tree snapshots" "8" \
    "$(grep -cE "^program\.$prog\.(start|end)\." "$N_ROOTS" || true)"
done
assert_eq "the corpus is the seven programs the coverage statement names" "$M8_EXPECTED_PROGRAMS" \
  "$(sed -n 's/^programs\.count //p' "$NATIVE_T")"

# The tree half: genesis, the eight Tier D steps, the checkpoint cycle and the padding sequence.
assert_eq "the genesis state reports all four trees" "4" "$(grep -cE '^genesis\.[A-Z]' "$N_ROOTS" || true)"
assert_eq "the Tier D replay reports four trees at each of eight steps" "32" \
  "$(grep -cE '^tierD\.step[0-9]+\.' "$N_ROOTS" || true)"
assert_eq "the checkpoint cycle reports four trees at each of three phases" "12" \
  "$(grep -cE '^tierD\.checkpoint\.(before|inside|afterRevert)\.' "$N_ROOTS" || true)"
assert_eq "the sibling-path fields are identical native versus wasm" "0" \
  "$(diff <(grep -E '^(genesis|samples)\.siblingPath\.' "$NATIVE_T") \
          <(grep -E '^(genesis|samples)\.siblingPath\.' "$V8_T") | grep -c . || true)"
assert_eq "the transcript carries the expected number of sibling-path fields" \
  "$M8_EXPECTED_SIBLING_FIELDS" \
  "$(grep -cE '^(genesis|samples)\.siblingPath\.[A-Z_]+\.[0-9]+\.[0-9]+ ' "$NATIVE_T" || true)"
assert_eq "the transcript carries the expected number of genesis prefill preimages" \
  "$M8_EXPECTED_PREFILL_LINES" "$(grep -cE '^genesis\.prefill\.' "$NATIVE_T" || true)"

# ---------------------------------------------------------------------------
echo "== 7. negative controls"
# ---------------------------------------------------------------------------
# (1) A single perturbed root must be caught, by the root comparison and not by a line count.
PERT="$M8_WORK/wasm.roots.perturbed"
python3 - "$W_ROOTS" "$PERT" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, ln in enumerate(lines):
    m = re.search(r"0x([0-9a-f]{64})", ln)
    if m and "tierD.step4" in ln:
        d = m.group(1)
        lines[i] = ln.replace("0x" + d, "0x" + d[:-1] + ("0" if d[-1] != "0" else "1"))
        break
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
assert_eq "control: the perturbed copy still has the same number of lines" \
  "$(grep -c . "$W_ROOTS" || true)" "$(grep -c . "$PERT" || true)"
assert_false "control: a single flipped root is rejected" cmp -s "$N_ROOTS" "$PERT"

# (2) A transcript that stops early has an identical PREFIX. Truncation must be caught, and it is
#     caught by the completion assertion rather than by the comparison.
TRUNC="$M8_WORK/wasm.truncated"
head -n 200 "$V8_T" >"$TRUNC"
m8_root_lines "$TRUNC" >"$M8_WORK/wasm.truncated.roots"
TRUNC_ROOTS="$(grep -c . "$M8_WORK/wasm.truncated.roots" || true)"
assert_true "control: a truncated transcript yields FEWER root lines" \
  test "$TRUNC_ROOTS" -lt "$M8_EXPECTED_ROOT_LINES"
head -n "$TRUNC_ROOTS" "$N_ROOTS" >"$M8_WORK/native.roots.prefix"
assert_true "control: and those it does yield are an identical PREFIX, which is why a count is not enough" \
  cmp -s "$M8_WORK/native.roots.prefix" "$M8_WORK/wasm.truncated.roots"
assert_true "control: the truncated transcript does not carry the completion marker" \
  bash -c "! grep -q '^avmDifferential.done 1\$' \"\$1\"" bash "$TRUNC"

# (3) The same transcript handed in on both sides. This is M5's lesson: comparing an artefact with
#     itself reports IDENTICAL, which is true and worthless. The discriminator is the pointer width,
#     which the two targets cannot share.
assert_eq "control: the native transcript reports a 64-bit target" "diag target.pointerBits 64" \
  "$(grep '^diag target.pointerBits' "$NATIVE_T")"
assert_eq "control: the wasm transcript reports a 32-bit target" "diag target.pointerBits 32" \
  "$(grep '^diag target.pointerBits' "$V8_T")"

# ---------------------------------------------------------------------------
# The record every other M8 check reads.
# ---------------------------------------------------------------------------
# The build logs are PRESERVED under their own names first. Later M8 checks — and
# `just avm-differential`, which `verify_avm_differential_exit_status` runs eight times — build in
# the same directories and overwrite `m6-<build-dir>-build.log`, so after a green run the only
# record of what this check built would otherwise be gone. M7's review found exactly that shape and
# recorded it as an outstanding task; it is fixed here rather than inherited.
for bdir in "$M8_WASM_BUILD" "$M8_NATIVE_BUILD"; do
  cp "$M8_TREE/m6-$bdir.log"       "$M8_WORK/check1-$bdir-configure.log" 2>/dev/null || true
  cp "$M8_TREE/m6-$bdir-build.log" "$M8_WORK/check1-$bdir-build.log"     2>/dev/null || true
done
assert_file "this check's wasm build log is preserved" "$M8_WORK/check1-$M8_WASM_BUILD-build.log"
assert_file "this check's native build log is preserved" "$M8_WORK/check1-$M8_NATIVE_BUILD-build.log"
assert_ge "…and the preserved wasm log records real work" 100 \
  "$(grep -c '^\[' "$M8_WORK/check1-$M8_WASM_BUILD-build.log" || true)"
assert_ge "…as does the native one" 100 \
  "$(grep -c '^\[' "$M8_WORK/check1-$M8_NATIVE_BUILD-build.log" || true)"

{
  printf 'M8_TREE=%s\n' "$M8_TREE"
  printf 'M8_WASM_BUILD=%s\n' "$M8_WASM_BUILD"
  printf 'M8_NATIVE_BUILD=%s\n' "$M8_NATIVE_BUILD"
  printf 'M8_DRIVER_SHA=%s\n' "$DRIVER_SHA"
  printf 'M8_ROOT_LINES=%s\n' "$(grep -c . "$N_ROOTS" || true)"
} >"$M8_WORK/measured.env"
note "measurement recorded at $M8_WORK/measured.env"

finish
