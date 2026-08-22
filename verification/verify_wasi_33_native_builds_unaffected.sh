#!/usr/bin/env bash
# verify_wasi_33_native_builds_unaffected
#
# M4 verification. "Native builds are unaffected" is a claim with a check behind
# it, not a sentence. Four independent ways of establishing it, from cheapest and
# most structural to most empirical:
#
#   1. THE DIFF. The file list is re-derived from the two worktrees with
#      `git diff --name-only`, not read out of PR.md, and asserted to be exactly
#      the five expected paths. No .cpp/.hpp/.tcc/.c/.h/.cc is touched — asserted
#      by extension over the derived list, so a sixth file of any kind fails here.
#
#   2. THE PRESETS. `CMakePresets.json` IS read by native builds, so "it is only
#      the wasm preset" has to be shown. Every configurePreset and buildPreset is
#      compared before/after by name and by content; exactly one may differ, it
#      must be `wasm`, and the difference must be confined to
#      environment.WASI_SDK_PREFIX.
#
#   3. THE CMAKE MODULE. `cmake/threading.cmake` is included unconditionally, so
#      the changed lines have to be shown to be inside `if(WASM)`. Every changed
#      line number from the diff is checked against the parsed block structure.
#
#   4. THE COMPILE LINES. Both trees are natively configured through
#      barretenberg's own `default` preset and their compile_commands.json are
#      compared after normalising the tree path away: same TU set, and every
#      command byte-identical. This is the assertion the other three exist to
#      explain — if the patch could reach a native build, it would show up here.
#
# The check asserts cmake's EXIT STATUS for each configure separately from
# anything parsed out of the result: a stale compile_commands.json from an earlier
# run would otherwise compare equal to itself while the configure was failing.
#
# Run: just verify-wasi33-native-neutral

TEST_NAME="verify_wasi_33_native_builds_unaffected"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_wasi33.sh"

require_nix
m4_prepare_trees
note "work directory: $M4_WORK"

BASE="$M4_WORK/base"
PATCHED="$M4_WORK/patched"

# ---------------------------------------------------------------------------
# 1. The diff, re-derived from the trees.
# ---------------------------------------------------------------------------
CHANGED="$(git -C "$PATCHED" diff --name-only "$M4_BASE_REV" HEAD | sort)"
EXPECTED="$(printf '%s\n' $M4_TOUCHED_FILES | sort)"
assert_eq "the patch touches exactly the five recorded files" "$EXPECTED" "$CHANGED"
assert_eq "and no more than five" "5" "$(printf '%s\n' "$CHANGED" | grep -c .)"

SOURCEY="$(printf '%s\n' "$CHANGED" | grep -E '\.(c|cc|cpp|cxx|h|hpp|hxx|tcc|inl)$' || true)"
assert_eq "no C or C++ source or header is touched" "" "$SOURCEY"

# A patch that touched nothing would satisfy every assertion above. Assert it is
# a real change.
STAT="$(git -C "$PATCHED" diff --shortstat "$M4_BASE_REV" HEAD)"
assert_contains "the patch is not empty" "5 files changed" "$STAT"
note "shortstat: $STAT"

# ---------------------------------------------------------------------------
# 1b. AND THAT IT IS *THIS* PATCH. Everything above is satisfied by any patch
#     confined to the same five files — including one that pins 34.0, or 28.0,
#     or leaves 27.0 in one of the three installers. That was demonstrated: a
#     patched tree amended to `expected_abs_wasi_version=34.0` passed this whole
#     check. So the version the patch actually moves the pin TO is asserted here,
#     in every file that carries it, and the old version is asserted GONE.
# ---------------------------------------------------------------------------
version_lines() { git -C "$PATCHED" show HEAD:"$1"; }

BOOT="$(version_lines bootstrap.sh)"
assert_contains "bootstrap.sh pins wasi-sdk 33.0 after the patch" \
  "expected_abs_wasi_version=33.0" "$BOOT"
assert_not_contains "and no longer pins 27.0" "expected_abs_wasi_version=27.0" "$BOOT"

DOCKER="$(version_lines build-images/src/Dockerfile)"
assert_contains "the build image downloads wasi-sdk 33" "wasi-sdk-33.0-" "$DOCKER"
assert_not_contains "and no longer downloads 27" "wasi-sdk-27" "$DOCKER"

SETUPC="$(version_lines scripts/setup-container.sh)"
assert_contains "setup-container.sh installs wasi-sdk 33" "wasi-sdk-33.0-" "$SETUPC"
assert_not_contains "and no longer installs 27" "wasi-sdk-27" "$SETUPC"

# The three installers must agree with each other; a bump that moves two of three
# is the failure mode `bootstrap.sh`'s own version gate exists to catch, and it
# would only show up in CI.
for f in bootstrap.sh build-images/src/Dockerfile scripts/setup-container.sh; do
  assert_eq "no wasi-sdk version other than 33 survives in $f" "" \
    "$(version_lines "$f" | grep -oE 'wasi-sdk-[0-9]+|wasi_version=[0-9.]+' \
       | grep -vE 'wasi-sdk-33|wasi_version=33\.0' | sort -u | tr '\n' ' ')"
done

# ---------------------------------------------------------------------------
# 2. The presets: only `wasm` may move, and only in one key.
# ---------------------------------------------------------------------------
PRESET_DIFF="$(python3 - "$BASE" "$PATCHED" <<'PY'
import json, sys
b, p = sys.argv[1], sys.argv[2]
def load(root):
    with open(f"{root}/barretenberg/cpp/CMakePresets.json") as f:
        d = json.load(f)
    out = {}
    for kind in ("configurePresets", "buildPresets", "testPresets", "packagePresets"):
        for e in d.get(kind, []):
            out[f"{kind}/{e['name']}"] = json.dumps(e, sort_keys=True)
    return out
B, P = load(b), load(p)
if set(B) != set(P):
    print("PRESET-SET-CHANGED", sorted(set(B) ^ set(P)))
for k in sorted(B):
    if k in P and B[k] != P[k]:
        print(k)
PY
)"
assert_eq "exactly one preset changes, and it is the wasm configure preset" \
  "configurePresets/wasm" "$PRESET_DIFF"

WASM_KEY_DIFF="$(python3 - "$BASE" "$PATCHED" <<'PY'
import json, sys
def wasm(root):
    with open(f"{root}/barretenberg/cpp/CMakePresets.json") as f:
        d = json.load(f)
    return next(e for e in d["configurePresets"] if e["name"] == "wasm")
b, p = wasm(sys.argv[1]), wasm(sys.argv[2])
keys = set(b) | set(p)
for k in sorted(keys):
    if b.get(k) != p.get(k):
        if k == "environment":
            for ek in sorted(set(b[k]) | set(p[k])):
                if b[k].get(ek) != p[k].get(ek):
                    print(f"environment.{ek}: {b[k].get(ek)!r} -> {p[k].get(ek)!r}")
        else:
            print(f"{k}: {b.get(k)!r} -> {p.get(k)!r}")
PY
)"
assert_eq "and the only key that moves is WASI_SDK_PREFIX" \
  "environment.WASI_SDK_PREFIX: '/opt/wasi-sdk' -> '\$penv{WASI_SDK_PREFIX}'" "$WASM_KEY_DIFF"

# ---------------------------------------------------------------------------
# 3. threading.cmake: the changed lines are inside if(WASM).
# ---------------------------------------------------------------------------
INSIDE="$(python3 - "$PATCHED" <<'PY'
import re, subprocess, sys
tree = sys.argv[1]
path = "barretenberg/cpp/cmake/threading.cmake"
diff = subprocess.run(["git", "-C", tree, "diff", "-U0", "233d8e0993", "HEAD", "--", path],
                      capture_output=True, text=True).stdout
# The new-file line numbers of every added line in the hunk.
changed = []
for h in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff, re.M):
    start, count = int(h.group(1)), int(h.group(2) or 1)
    changed += list(range(start, start + count))
lines = open(f"{tree}/{path}").read().splitlines()
# Track the innermost if() condition per line.
stack, cond = [], {}
for i, line in enumerate(lines, 1):
    s = line.strip()
    m = re.match(r"if\s*\((.*)\)", s)
    if m:
        stack.append(m.group(1).strip())
    cond[i] = list(stack)
    if re.match(r"endif\s*\(", s) and stack:
        stack.pop()
outside = [n for n in changed if "WASM" not in cond.get(n, [])]
print("CHANGED=%d" % len(changed))
print("OUTSIDE=%s" % (",".join(map(str, outside)) or "none"))
PY
)"
assert_contains "threading.cmake really does change lines" "CHANGED=" "$INSIDE"
assert_not_contains "threading.cmake changes more than 0 lines (else this is vacuous)" "CHANGED=0" "$INSIDE"
assert_contains "every changed threading.cmake line is inside if(WASM)" "OUTSIDE=none" "$INSIDE"
note "$(printf '%s' "$INSIDE" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4. The compile lines. The assertion the rest exists to explain.
# ---------------------------------------------------------------------------
m4_native_configure "$BASE";    RC_BASE=$?
m4_native_configure "$PATCHED"; RC_PATCHED=$?
assert_eq "the base tree configures natively" "0" "$RC_BASE"
assert_eq "the patched tree configures natively" "0" "$RC_PATCHED"
[ "$RC_BASE" -eq 0 ] && [ "$RC_PATCHED" -eq 0 ] \
  || die "a native configure failed — see $BASE/m4-native-configure.log and $PATCHED/m4-native-configure.log"

CC_BASE="$BASE/barretenberg/cpp/build/compile_commands.json"
CC_PATCHED="$PATCHED/barretenberg/cpp/build/compile_commands.json"
assert_file "the base tree produced compile_commands.json" "$CC_BASE"
assert_file "the patched tree produced compile_commands.json" "$CC_PATCHED"

normalise() { # <file> <tree> -> "<relative file>\t<normalised command>" per line
  python3 - "$1" "$2" <<'PY'
import json, sys
path, tree = sys.argv[1], sys.argv[2]
for e in sorted(json.load(open(path)), key=lambda e: e["file"]):
    f = e["file"].replace(tree, "<TREE>")
    c = (e.get("command") or " ".join(e.get("arguments", []))).replace(tree, "<TREE>")
    print(f"{f}\t{c}")
PY
}
normalise "$CC_BASE" "$BASE" > "$M4_WORK/cc.base"
normalise "$CC_PATCHED" "$PATCHED" > "$M4_WORK/cc.patched"

N_BASE=$(wc -l < "$M4_WORK/cc.base")
N_PATCHED=$(wc -l < "$M4_WORK/cc.patched")
# Pinned, not merely "a real number": the write-up quotes 1,009 and 959, so those
# are the numbers that must not drift away from the artefacts.
assert_eq "the native configure covers the recorded 1,009 translation units" "1009" "$N_BASE"
assert_eq "the same number of native translation units before and after" "$N_BASE" "$N_PATCHED"

if diff -q "$M4_WORK/cc.base" "$M4_WORK/cc.patched" >/dev/null; then
  pass "every native compile command is byte-identical before and after  [$N_BASE TUs]"
else
  fail "native compile commands differ: $(diff "$M4_WORK/cc.base" "$M4_WORK/cc.patched" | head -4 | tr '\n' ' ')"
fi

# The comparison would also be satisfied by two files that were both empty of the
# thing at issue. Assert the native lines really are native and really do go
# through the threading module's other branch.
assert_not_contains "no native compile line carries a wasm triple" \
  "--target=wasm32" "$(cat "$M4_WORK/cc.base")"
assert_eq "and the recorded 959 of them are barretenberg's own sources" "959" \
  "$(grep -c 'barretenberg/cpp/src/barretenberg' "$M4_WORK/cc.base")"

finish
