#!/usr/bin/env bash
# verify_avm_wasm_module_split_patch_applies — M10
#
# The claim: the format-patch file applies cleanly to the stated base and both
# the native and the wasm presets build from the result.
#
# The artefact under test is the PATCH FILE, not the fork's branch, because the
# file is what would be filed upstream and what a reviewer would apply.
#
# "The stated base" is `233d8e0993` plus three patches, and the check does not
# take that on trust either. It measures which of the three the patch needs in
# order to APPLY and which it needs in order to BUILD, because `PR.md` and
# `SERIES.md` both say "will not apply or build without" all three and those are
# two different statements about three different patches:
#
#   * onto the bare base, `git am` must FAIL, and the rejected file is named.
#   * onto base + the merkle/LMDB split + the wasi-sdk bump, it must APPLY —
#     the widening fix touches a file this patch does not.
#   * and then that tree must FAIL TO BUILD, on exactly `contract_crypto.cpp`
#     under `-Wshift-count-overflow`, which is what "needs the widening fix"
#     means and is the only way to tell an apply dependency from a build one.
#
# Two mutation controls, on M3's lessons: a truncated hunk must be rejected by
# `git am`, and a patch altered so that it still applies but is no longer the
# reviewed change must be caught by the resulting TREE HASH, which is the only
# assertion that sees it.
#
# And the numbers. `PR.md` and the patch's own commit message are required to
# agree with each other and with the patch, because three patches in this series
# have shipped with a corrected `PR.md` beside a stale commit message.

TEST_NAME=verify_avm_wasm_module_split_patch_applies
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_avm_wasm.sh"
. "$(dirname "$0")/lib_m10_cmake_split.sh"

echo "== 0. the patch's own identity =="
assert_file "the prepared patch is where SERIES.md indexes it" "$M10_PATCH"
assert_file "PR.md beside it" "$M10_PR_MD"
assert_file "verify.sh beside it" "$M10_VERIFY_SH"
assert_true "PR.md, not ISSUE.md — this is a non-defect contribution" \
  bash -c '[ ! -e "$1/ISSUE.md" ]' _ "$M10_PATCH_DIR"
assert_true "verify.sh, not reproduce.sh" \
  bash -c '[ ! -e "$1/reproduce.sh" ]' _ "$M10_PATCH_DIR"

HDR="$(sed -n '1,/^---$/p' "$M10_PATCH")"
assert_prefix "the patch is a git format-patch file" "From " "$(head -1 "$M10_PATCH")"
assert_contains "with the upstream-facing subject SERIES.md and PR.md quote" \
  "build(wasm): optional AVM_WASM, and separate the AVM modules" "$HDR"
assert_not_contains "and no internal project name in it" "codetracer" "$(tr 'A-Z' 'a-z' <"$M10_PATCH")"
assert_not_contains "nor the campaign's" "aztec-avm-runtime" "$HDR"

# The stats, re-derived from the patch rather than read off its own diffstat, and
# then required to agree with the diffstat AND with PR.md. `git format-patch`
# ends with a `-- ` signature line, which is not a removal and is excluded.
STATS="$(python3 - "$M10_PATCH" <<'PY'
import sys
add = rem = 0
files = []
cur = None
for line in open(sys.argv[1]):
    if line.startswith('diff --git a/'):
        cur = line.split(' b/')[-1].strip(); files.append(cur)
    elif cur is None:
        continue
    elif line.startswith('+++') or line.startswith('---'):
        continue
    elif line.rstrip('\n') == '-- ':
        continue
    elif line.startswith('+'):
        add += 1
    elif line.startswith('-'):
        rem += 1
print(len(files), add, rem)
PY
)"
set -- $STATS
P_FILES="$1"; P_ADD="$2"; P_REM="$3"
assert_eq "the patch touches 8 files" "8" "$P_FILES"
assert_eq "its own diffstat agrees on the file count" "$P_FILES" \
  "$(grep -oE '^ [0-9]+ files? changed' "$M10_PATCH" | grep -oE '[0-9]+')"
assert_eq "and on the insertions" "$P_ADD" \
  "$(grep -oE '[0-9]+ insertions?\(\+\)' "$M10_PATCH" | grep -oE '^[0-9]+')"
assert_eq "and on the deletions" "$P_REM" \
  "$(grep -oE '[0-9]+ deletions?\(-\)' "$M10_PATCH" | grep -oE '^[0-9]+')"
assert_true "PR.md quotes the same three numbers" \
  bash -c 'grep -qF "$2 files" "$1" && grep -qF "+$3 / −$4" "$1"' \
  _ "$M10_PR_MD" "$P_FILES" "$P_ADD" "$P_REM"
note "the patch is $P_FILES files, +$P_ADD / −$P_REM"

# The downstream-carry size, measured and split the way a maintainer would read
# it: CMake versus C++. PR.md must state the measured figures.
CARRY="$(python3 - "$M10_PATCH" <<'PY'
import sys
cur = None; per = {}
for line in open(sys.argv[1]):
    if line.startswith('diff --git a/'):
        cur = line.split(' b/')[-1].strip(); per[cur] = [0, 0]
    elif cur is None or line.startswith('+++') or line.startswith('---'):
        continue
    elif line.rstrip('\n') == '-- ':
        continue
    elif line.startswith('+'):
        per[cur][0] += 1
    elif line.startswith('-'):
        per[cur][1] += 1
def is_cmake(p):
    return p.endswith('CMakeLists.txt') or p.endswith('.cmake') or p.endswith('CMakePresets.json')
ca = sum(v[0] for k, v in per.items() if is_cmake(k))
cr = sum(v[1] for k, v in per.items() if is_cmake(k))
sa = sum(v[0] for k, v in per.items() if not is_cmake(k))
sr = sum(v[1] for k, v in per.items() if not is_cmake(k))
print(sum(1 for k in per if is_cmake(k)), ca, cr, sum(1 for k in per if not is_cmake(k)), sa, sr)
PY
)"
set -- $CARRY
assert_eq "five of the eight files are CMake" "5" "$1"
assert_eq "and three are C++" "3" "$4"
note "downstream carry: CMake $1 files +$2/−$3; C++ $4 files +$5/−$6"
assert_true "PR.md states the measured carry rather than an estimate" \
  bash -c 'grep -qF "$2 files of CMake, +$3 / −$4" "$1"' _ "$M10_PR_MD" "$1" "$2" "$3"

# The $penv{} correction is NOT this patch's, and that is asserted from both
# patch files rather than restated. This patch adds no WASI_SDK_PREFIX line at
# all; the wasi-sdk bump is where the hardcode is replaced.
# It never SETS the variable — no `"WASI_SDK_PREFIX": …` preset key and no
# `WASI_SDK_PREFIX=` assignment, added or removed. It does MENTION the name once,
# in the gate's failure message ("Point WASI_SDK_PREFIX at wasi-sdk 33.0 or
# newer"), which is the message doing its job and is asserted rather than
# excluded by a looser pattern.
assert_eq "this patch adds no line that sets WASI_SDK_PREFIX" "0" \
  "$(m6_patch_added "$M10_PATCH" | grep -cE '"WASI_SDK_PREFIX"[[:space:]]*:|WASI_SDK_PREFIX=')"
assert_eq "and removes none" "0" \
  "$(m6_patch_removed "$M10_PATCH" | grep -cE '"WASI_SDK_PREFIX"[[:space:]]*:|WASI_SDK_PREFIX=')"
assert_eq "the only place it names the variable is the gate's failure message" "1" \
  "$(m6_patch_added "$M10_PATCH" | grep -c 'WASI_SDK_PREFIX')"
assert_eq "and that line tells the reader what to point it at" "1" \
  "$(m6_patch_added "$M10_PATCH" | grep -c 'Point WASI_SDK_PREFIX at wasi-sdk 33.0 or newer')"
assert_eq "the wasi-sdk patch is the one that introduces \$penv{WASI_SDK_PREFIX}" "1" \
  "$(m6_patch_added "$M6_PATCH_2" | grep -c '"WASI_SDK_PREFIX": "\$penv{WASI_SDK_PREFIX}"')"
assert_eq "by removing the hardcoded /opt/wasi-sdk from the same key" "1" \
  "$(m6_patch_removed "$M6_PATCH_2" | grep -c '"WASI_SDK_PREFIX": "/opt/wasi-sdk"')"
assert_eq "and the wasm-avm preset this patch adds declares no environment block" "0" \
  "$(m6_patch_added "$M10_PATCH" 'CMakePresets.json' | grep -c 'environment')"
assert_true "PR.md says whose correction it is" \
  grep -qF 'belongs to the wasi-sdk' "$M10_PR_MD"

echo
echo "== 1. it applies to the stated base, and the result is pinned by its tree hash =="
APPLY="$(m6_prepare_tree m10apply "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M10_PATCH")"
m10_tree_or_die_local() { [ -n "${1:-}" ] && [ -e "$1/.git" ] || die "the apply tree was not prepared"; }
m10_tree_or_die_local "$APPLY"
assert_dir "base + patches 1,2,3 + this one applies cleanly by git am" "$APPLY"
assert_eq "the result is base plus exactly four commits" "4" \
  "$(git -C "$APPLY" rev-list --count "$M6_BASE_REV..HEAD")"
# The Subject header is FOLDED across two lines in this patch, so it is unfolded
# by a real header parser rather than by `sed`, which would compare half of it.
PATCH_SUBJECT="$(python3 -c '
import email, sys
m = email.message_from_file(open(sys.argv[1]))
print(" ".join(m["Subject"].replace("[PATCH]", "", 1).split()))' "$M10_PATCH")"
assert_contains "the unfolded subject is the one SERIES.md and PR.md quote" \
  "build(wasm): optional AVM_WASM, and separate the AVM modules from the server modules" \
  "$PATCH_SUBJECT"
assert_eq "and the applied commit carries exactly it" "$PATCH_SUBJECT" \
  "$(git -C "$APPLY" log -1 --format=%s | head -1)"
m6_prepare_trees
assert_eq "and the tree it produces is bit-for-bit M6's, from the same four files" \
  "$(git -C "$M6_TREE_AVM" rev-parse HEAD^{tree})" "$(git -C "$APPLY" rev-parse HEAD^{tree})"
TREE_HASH="$(git -C "$APPLY" rev-parse HEAD^{tree})"
note "the reviewed tree is $TREE_HASH"

echo
echo "== 2. which prerequisites are APPLY prerequisites and which are BUILD ones =="

# A scratch worktree the apply experiments own, made and destroyed here.
m10_try_am() { # <name> <patch...> -> "0" if git am succeeded, "1" if it did not
  local name="$1"; shift
  local dir="$M10_WORK/$name"
  rm -rf "$dir"
  git -C "$FORK_ROOT" worktree prune >/dev/null 2>&1
  git -C "$FORK_ROOT" worktree add --detach "$dir" "$M6_BASE_REV" >/dev/null 2>&1 \
    || die "could not create the $name worktree"
  local p rc=0
  for p in "$@"; do
    if ! git -C "$dir" am "$p" >>"$M10_WORK/$name-am.log" 2>&1; then
      git -C "$dir" am --abort >/dev/null 2>&1 || true
      rc=1; break
    fi
  done
  printf '%s\n' "$rc"
}

rm -f "$M10_WORK"/am-*.log
assert_eq "onto the BARE base it does not apply — it is not standalone" "1" \
  "$(m10_try_am am-bare "$M10_PATCH")"
assert_contains "and git am names the file the merkle/LMDB split owns" \
  "crypto/CMakeLists.txt" "$(cat "$M10_WORK/am-bare-am.log" 2>/dev/null)"
assert_eq "onto base + the merkle/LMDB split alone it DOES apply" "0" \
  "$(m10_try_am am-p1 "$M6_PATCH_1" "$M10_PATCH")"
assert_eq "onto base + the merkle split + the wasi-sdk bump it applies too" "0" \
  "$(m10_try_am am-p12 "$M6_PATCH_1" "$M6_PATCH_2" "$M10_PATCH")"
note "so patch 1 is an APPLY prerequisite and patches 2 and 3 are BUILD prerequisites"

# The build prerequisite, measured. base+1+2+4 has no widening fix, so the wasm
# AVM build must fail on exactly contract_crypto.cpp. `ninja -k 0` so one run
# reports the whole failing set rather than the first member of it, and
# `-Wfatal-errors` means each failing unit emits one `fatal error:` line.
NO3="$M10_WORK/am-p12"
assert_dir "the no-widening-fix tree survives for the build experiment" "$NO3"
m6_configure "$NO3" wasm-avm build-m10-no3; rc=$?
assert_eq "it configures — the missing prerequisite is not a configure-time one" "0" "$rc"
m6_build "$NO3" build-m10-no3 vm2_sim; rc=$?
assert_true "and then FAILS to build vm2_sim" bash -c '[ "$1" -ne 0 ]' _ "$rc"
NO3LOG="$(m6_build_log "$NO3" build-m10-no3)"
FAILED_UNITS="$(printf '%s\n' "$NO3LOG" | grep -oE '[^ ]+\.(cpp|hpp):[0-9]+:[0-9]+: fatal error' \
                | sed 's/:[0-9]*:[0-9]*: fatal error//' | sed 's|.*/src/barretenberg/||' | sort -u)"
assert_eq "on exactly one translation unit" "1" "$(printf '%s\n' "$FAILED_UNITS" | grep -c .)"
assert_eq "and it is the one the widening fix owns" \
  "vm2/simulation/lib/contract_crypto.cpp" "$FAILED_UNITS"
assert_eq "under -Wshift-count-overflow, and nothing else failed for any other reason" "1" \
  "$(printf '%s\n' "$NO3LOG" | grep -c 'fatal error:.*shift-count-overflow')"
assert_eq "so exactly one fatal diagnostic in the whole run" "1" \
  "$(printf '%s\n' "$NO3LOG" | grep -c 'fatal error:')"

echo
echo "== 3. mutation controls =="
# A truncated hunk: git am must reject it.
TRUNC="$M10_WORK/truncated.patch"
head -n $(( $(wc -l <"$M10_PATCH") - 40 )) "$M10_PATCH" >"$TRUNC"
assert_true "the truncated patch is shorter than the real one" \
  bash -c '[ "$(wc -l <"$1")" -lt "$(wc -l <"$2")" ]' _ "$TRUNC" "$M10_PATCH"
assert_eq "and git am rejects it" "1" \
  "$(m10_try_am am-trunc "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$TRUNC")"

# A patch that still applies and is no longer the reviewed change. Only the tree
# hash sees this: the file count, the diffstat and `git am`'s exit status are all
# unmoved.
ALTERED="$M10_WORK/altered.patch"
sed 's/^+option(AVM_WASM "Build the AVM simulator (vm2_sim) for wasm\. Additive; implies real C++ exceptions\." OFF)$/+option(AVM_WASM "Build the AVM simulator (vm2_sim) for wasm. Additive; implies real C++ exceptions." ON)/' \
  "$M10_PATCH" >"$ALTERED"
assert_true "the altered patch flips the option's default and nothing else" \
  bash -c '[ "$(diff "$1" "$2" | grep -c "^[<>]")" -eq 2 ]' _ "$M10_PATCH" "$ALTERED"
assert_eq "it still applies cleanly, which is the point" "0" \
  "$(m10_try_am am-altered "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$ALTERED")"
assert_true "and only the tree hash catches it" \
  bash -c '[ "$(git -C "$1" rev-parse HEAD^{tree})" != "$2" ]' _ "$M10_WORK/am-altered" "$TREE_HASH"
assert_eq "the default really was OFF in the reviewed patch" "1" \
  "$(m6_patch_added "$M10_PATCH" 'cpp/CMakeLists.txt' | grep -c 'option(AVM_WASM .* OFF)')"

echo
echo "== 4. both presets build from the result =="
m6_configure "$APPLY" wasm-avm build-m10-apply-wasm; rc=$?
assert_eq "cmake --preset wasm-avm configures on the applied tree" "0" "$rc"
m6_build "$APPLY" build-m10-apply-wasm vm2_sim world_state_reference; rc=$?
assert_eq "ninja vm2_sim world_state_reference exits 0" "0" "$rc"
assert_eq "with no compiler diagnostic" "0" \
  "$(m6_build_log "$APPLY" build-m10-apply-wasm | grep -c 'error:')"
assert_eq "and the nine AVM archives are there" "$M6_EXPECTED_ARCHIVES" \
  "$(m6_archives "$APPLY" build-m10-apply-wasm)"

m10_native_preset_configure "$APPLY" default build-m10-apply-native; rc=$?
assert_eq "cmake --preset default configures on the applied tree" "0" "$rc"
m6_build "$APPLY" build-m10-apply-native vm2_sim world_state_reference; rc=$?
assert_eq "and ninja builds the same two targets natively" "0" "$rc"
assert_eq "with no compiler diagnostic" "0" \
  "$(m6_build_log "$APPLY" build-m10-apply-native | grep -c 'error:')"
assert_file "the native libvm2_sim.a exists" \
  "$APPLY/barretenberg/cpp/build-m10-apply-native/lib/libvm2_sim.a"
assert_eq "the native build is x86_64, not wasm32" "x86_64" \
  "$(m6_system_processor "$APPLY" build-m10-apply-native)"
assert_eq "and it has AVM_WASM off, which is the default the option declares" "OFF" \
  "$(m6_cache "$APPLY" build-m10-apply-native AVM_WASM)"

echo
echo "== 5. PR.md and the commit message say the same things =="
PR="$(cat "$M10_PR_MD")"
for claim in \
  "fe9ea3c16566fcd0" \
  "17,063,295" \
  "3,384" \
  "539" \
  "4,290" \
  "1,012" \
  "1,008"
do
  assert_contains "PR.md carries the figure $claim" "$claim" "$PR"
  assert_contains "and so does the commit message" "$claim" "$HDR"
done
# The transposition, which M6 found and which both documents must state rather
# than round to "identical".
assert_contains "PR.md says the command lines are NOT identical" "transposes" "$PR"
assert_contains "and the commit message says it too" "TRANSPOSES" "$HDR"
# The native test result this milestone adds, in both.
for claim in "vm2_tests" "world_state_tests"; do
  assert_contains "PR.md reports $claim" "$claim" "$PR"
  assert_contains "and so does the commit message" "$claim" "$HDR"
done
assert_true "PR.md no longer claims the AVM's own test suite was not run" \
  bash -c '! grep -qF "The AVM'"'"'s own test suite was not run in either configuration" "$1"' _ "$M10_PR_MD"
# The dependency statement, in both, and matching what part 2 measured. The needle
# is the SENTENCE that does the separating, not the word "apply": a bare "apply"
# occurs throughout a 350-line document, so an assertion on it passes on a PR.md
# with the separation deleted and is a statement about a letter sequence.
assert_contains "PR.md separates the apply prerequisite from the build ones" \
  "also an *apply* prerequisite" "$PR"
assert_contains "and the commit message names all three dependencies" \
  "wasi-sdk 33 bump" "$HDR"

# The tidying argument in its own section, placed BEFORE the disclosure. The
# deliverable's claim is that a reviewer can reject the flag and still take the two
# type corrections, which is a claim about the document's SHAPE, so it is asserted
# as one — including the ORDER, which is the whole point of the arrangement and
# which nothing asserted until now.
assert_contains "PR.md carries the tidying argument in its own section" \
  "## What this is worth on its own terms" "$PR"
assert_contains "and the disclosure in its own" "## Why we care" "$PR"
assert_true "with the tidying section placed BEFORE the disclosure" \
  bash -c '[ "$(grep -n "^## What this is worth on its own terms$" "$1" | cut -d: -f1)" -lt \
             "$(grep -n "^## Why we care" "$1" | cut -d: -f1)" ]' _ "$M10_PR_MD"
assert_contains "and it concedes that none of it is a reason on its own" \
  "reason on its own to take an" "$PR"
assert_contains "the commit message — which is the PR body — carries the same section" \
  "What this is worth without a wasm AVM" "$HDR"
assert_contains "and the same concession" "reason on its own to take an" "$HDR"

finish
