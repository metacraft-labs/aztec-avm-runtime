#!/usr/bin/env bash
# verify_carry_set_applies_to_upstream_head
#
# The carry set is only carried if it still fits. This replays the whole ordered
# set onto a fresh fetch of upstream's own branch and requires every patch to
# apply, naming the conflicting files when one does not.
#
# It then answers the second half of the question — "and the result still builds"
# — WITHOUT a build, by an argument that is checked rather than assumed.
#
# THE ARGUMENT CHANGED, BECAUSE THE ONE IT REPLACES STOPPED BEING TRUE.
#
#   It used to be: the set of paths upstream changed since the base and the set of
#   paths the carry set changes must be DISJOINT, and then the two trees differ
#   only in files the carried build does not depend on being different.
#
#   Disjointness is SUFFICIENT and it is no longer available. Upstream's `next`
#   moved seven commits past the base and one of them deletes 198 lines from the
#   top-level `bootstrap.sh`, which patch 2 also modifies. The intersection is 1.
#
#   What replaces it is narrower, in three conjuncts, all computed in
#   verification/_carry_overlap.py:
#
#     1. Upstream changed NOTHING under the tree the evidence compiles. M6 and M10
#        both configure in `barretenberg/cpp`; if upstream has changed no path
#        under it, no translation unit, CMake input or test source either build
#        reads can differ. This conjunct cannot be waived: an overlap under the
#        build root is rejected before the acknowledgement file is consulted.
#     2. Every overlap OUTSIDE that tree is acknowledged in `carry/overlap.json`,
#        and each acknowledgement is pinned to upstream's exact change by the blob
#        ids of the path before and after. Upstream touching it again expires the
#        entry.
#     3. Upstream's changed line ranges and the carry set's changed line ranges,
#        both `-U0` and both relative to the base, are disjoint per path. That is
#        not about the build; it is what says the overlap is not even a rebase
#        hazard.
#
#   If any conjunct fails the verdict is `void`, which means what the old check
#   said it would: the transferred build evidence is no longer valid and M6 and
#   M10 have to be re-run against the rebased tree.
#
# That is a narrower claim than "we rebuilt everything at upstream HEAD", and it
# is stated as such rather than dressed up as one. The decision procedure is run
# against SIX synthetic inputs as well as the real one, each breaking exactly one
# rule, because a decision that has only ever been run on data that passes is the
# same failure as an intersection that can only return empty.

TEST_NAME="verify_carry_set_applies_to_upstream_head"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
EXPOSURE="$REPO_ROOT/carry/exposure.json"
ACK="$REPO_ROOT/carry/overlap.json"
REPORT="${CARRY_REBASE_REPORT:-$REPO_ROOT/carry/rebase.json}"
FETCH="${CARRY_FETCH:-1}"
DECIDE="$VERIFY_DIR/_carry_overlap.py"

assert_file "the carry set manifest exists" "$SERIES"
assert_file "the exposure measurement exists" "$EXPOSURE"
assert_file "the overlap acknowledgement file exists" "$ACK"
assert_file "the overlap decision procedure exists" "$DECIDE"
[ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"

SCRATCH="$(mktemp -d "${M11_WORK:-$HOME/.cache}/carry-overlap.XXXXXX")" \
  || die "could not create a scratch directory under ${M11_WORK:-$HOME/.cache}"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

fetch_flag=""
[ "$FETCH" = "1" ] || fetch_flag="--no-fetch"

out="$(python3 "$REPO_ROOT/tools/rebase_upstream_patches.py" $fetch_flag --json "$REPORT" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  |  /'

if [ "$rc" -eq 0 ]; then
  pass "every patch in the carry set applies to upstream HEAD"
else
  fail "the carry set does not fully apply to upstream HEAD (exit $rc)"
fi

assert_file "the replay wrote a machine-readable report" "$REPORT"
[ -f "$REPORT" ] || finish

# Counts and identities, not "it said applies somewhere".
n_patches="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$REPORT")"
n_declared="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$SERIES")"
assert_eq "the report covers every patch in the carry set" "$n_declared" "$n_patches"

n_applies="$(python3 -c 'import json,sys;print(sum(1 for r in json.load(open(sys.argv[1]))["patches"] if r["result"] in ("applies","already")))' "$REPORT")"
assert_eq "every patch either applies or is already upstream" "$n_declared" "$n_applies"

reported_ids="$(python3 -c 'import json,sys;print(" ".join(r["id"] for r in json.load(open(sys.argv[1]))["patches"]))' "$REPORT")"
declared_ids="$(python3 -c 'import json,sys;print(" ".join(p["id"] for p in sorted(json.load(open(sys.argv[1]))["patches"], key=lambda p: p["order"])))' "$SERIES")"
assert_eq "the report's patch identities are the carry set's, in order" \
  "$declared_ids" "$reported_ids"

# --- the transferability argument, checked ---------------------------------

base="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base"]["commit"])' "$SERIES")"
tip="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tip"])' "$REPORT")"

# The exposure measurement is the source of the carry side of every comparison
# below. If it was measured against a DIFFERENT upstream tip than the replay just
# used, its ranges and its per-path churn describe another moment — which is
# exactly the state M17 left this repository in, and it went unnoticed because
# nothing compared the two. Cheap to check, and it fails loudly.
exposure_tip="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["upstream_tip"])' "$EXPOSURE")"
assert_eq "the exposure measurement was taken against the tip the replay used" \
  "$tip" "$exposure_tip"

# Both lists go through the SAME collation before comm sees them. Python's
# `sorted` and the shell's `sort` disagree under a non-C locale, and comm given
# unsorted input silently reports a WRONG intersection rather than failing — which
# would turn this assertion into one that passes for the wrong reason.
upstream_paths="$(git -C "$FORK_ROOT" diff --name-only "$base" "$tip" | LC_ALL=C sort -u)"
n_upstream_paths="$(printf '%s\n' "$upstream_paths" | grep -c . || true)"

carry_paths="$(python3 -c '
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["modified_paths"]))' \
  "$EXPOSURE" | LC_ALL=C sort -u)"
n_carry_paths="$(printf '%s\n' "$carry_paths" | grep -c . || true)"
assert_ge "the exposure measurement names the modified paths" 1 "$n_carry_paths"

n_ranged="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
mod = set(d["modified_paths"])
rng = d.get("union_pre_ranges", {})
print(sum(1 for p in mod if rng.get(p)))' "$EXPOSURE")"
assert_eq "the exposure measurement names the changed line ranges of every modified path" \
  "$n_carry_paths" "$n_ranged"

overlap="$(LC_ALL=C comm -12 <(printf '%s\n' "$upstream_paths") <(printf '%s\n' "$carry_paths") 2>&1)"
n_overlap="$(printf '%s\n' "$overlap" | grep -c . || true)"

note "upstream changed $n_upstream_paths path(s) between $base and $tip"
note "the carry set modifies $n_carry_paths path(s) upstream also has"
note "the intersection is $n_overlap path(s)"
if [ "$n_overlap" -ne 0 ]; then
  printf '%s\n' "$overlap" | sed 's/^/      /'
fi

# Positive control for the intersection itself. An intersection test that returns
# "n" is worthless unless it can also return "n+1": one carried path that is NOT
# already in the intersection is spliced into the upstream list and the same
# comparison must find exactly the old intersection plus it.
#
# The previous version of this control expected the spliced result to equal the
# PROBE ALONE, which is only correct while the true intersection is empty — so the
# control broke on the same day the thing it was controlling did, and reported the
# real finding as a second failure with a confusing message. It is written against
# an intersection of any size now.
probe="$(LC_ALL=C comm -23 <(printf '%s\n' "$carry_paths") <(printf '%s\n' "$overlap") | head -1)"
assert_ge "a carried path outside the current intersection exists to probe with" \
  1 "$(printf '%s' "$probe" | grep -c . || true)"
expected_probe_overlap="$(printf '%s\n%s\n' "$overlap" "$probe" | grep . | LC_ALL=C sort -u)"
probe_overlap="$(LC_ALL=C comm -12 \
  <(printf '%s\n%s\n' "$upstream_paths" "$probe" | LC_ALL=C sort -u) \
  <(printf '%s\n' "$carry_paths"))"
assert_eq "the intersection test detects an overlap when one is spliced in" \
  "$expected_probe_overlap" "$probe_overlap"

# --- the build root, derived rather than typed ------------------------------
#
# The conjunct that carries the weight is "upstream changed nothing under the tree
# the evidence compiles", so which tree that is must not be a constant in this
# file. It is read out of the M6 and M10 libraries' own configure step — the
# directory they `cd` into before invoking cmake — and both must agree. If either
# build ever moves, this check goes red rather than quietly guarding the wrong
# subtree.
roots="$(sed -n 's|^ *cd "\$tree/\([a-z0-9/_-]*\)" .*|\1|p' \
  "$VERIFY_DIR/lib_avm_wasm.sh" "$VERIFY_DIR/lib_m10_cmake_split.sh" \
  | grep -v '\$' | LC_ALL=C sort -u)"
n_roots="$(printf '%s\n' "$roots" | grep -c . || true)"
assert_eq "M6's and M10's configure steps enter exactly one source directory" "1" "$n_roots"
BUILD_ROOT="$(printf '%s\n' "$roots" | head -1)"
assert_eq "and that directory is the tree this check guards" "barretenberg/cpp" "$BUILD_ROOT"

n_m6_roots="$(sed -n 's|^ *cd "\$tree/\([a-z0-9/_-]*\)" .*|\1|p' "$VERIFY_DIR/lib_avm_wasm.sh" \
  | grep -v '\$' | grep -c "^$BUILD_ROOT$" || true)"
n_m10_roots="$(sed -n 's|^ *cd "\$tree/\([a-z0-9/_-]*\)" .*|\1|p' "$VERIFY_DIR/lib_m10_cmake_split.sh" \
  | grep -v '\$' | grep -c "^$BUILD_ROOT$" || true)"
assert_ge "M6's library configures inside it" 1 "$n_m6_roots"
assert_ge "M10's library configures inside it" 1 "$n_m10_roots"

# The acknowledgement for `bootstrap.sh` rests on a sentence — "neither build executes it" —
# and a sentence in a JSON file is not evidence. This is the same sentence as a predicate.
# Scoped to EXECUTION: M3's checks read `barretenberg/cpp/bootstrap.sh` as text, which is a
# different file and a different act, so the pattern is an invocation and not a mention.
boot_re='(^|[^a-zA-Z0-9_/.-])(\./)?bootstrap\.sh([ 	"'"'"']|$)'
m6m10_boot="$(grep -nE "$boot_re" \
  "$VERIFY_DIR/lib_avm_wasm.sh" "$VERIFY_DIR/lib_m10_cmake_split.sh" \
  "$VERIFY_DIR/build_avm_wasm.sh" 2>/dev/null | grep -v '^\s*#' || true)"
assert_eq "neither M6's nor M10's build machinery invokes upstream's top-level bootstrap.sh" \
  "0" "$(printf '%s\n' "$m6m10_boot" | grep -c . || true)"

# …and the predicate can find one, which is what stops the assertion above from being a
# statement about a pattern that never matches anything.
cp "$VERIFY_DIR/lib_avm_wasm.sh" "$SCRATCH/lib_with_bootstrap.sh"
printf '  ./bootstrap.sh fast\n' >> "$SCRATCH/lib_with_bootstrap.sh"
assert_eq "the invocation predicate finds one when it is spliced in" "1" \
  "$(grep -cE "$boot_re" "$SCRATCH/lib_with_bootstrap.sh" || true)"

# --- the decision input, assembled from the tree ----------------------------

printf '%s\n' "$upstream_paths" | grep . > "$SCRATCH/upstream_paths.txt"
printf '%s\n' "$overlap"        | grep . > "$SCRATCH/overlap.txt" || true

SPECS="$WORKSPACE_ROOT/codetracer-specs"
assert_dir "the prepared patches' repository is a workspace sibling" "$SPECS/upstream-bugs"

python3 - "$FORK_ROOT" "$base" "$tip" "$EXPOSURE" "$ACK" "$BUILD_ROOT" \
         "$SCRATCH/upstream_paths.txt" "$SCRATCH/overlap.txt" \
         "$SPECS" "$SERIES" "$SCRATCH/input.json" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

(fork, base, tip, exposure_p, ack_p, build_root,
 up_paths_p, overlap_p, specs_p, series_p, out_p) = sys.argv[1:12]

def git(*a):
    return subprocess.run(["git", "-C", fork, *a], check=False, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout

def blob(rev, path):
    out = git("rev-parse", "--verify", "%s:%s" % (rev, path)).strip()
    return out or None

def ranges(path):
    out = []
    for line in git("diff", "-U0", base, tip, "--", path).splitlines():
        m = re.match(r"^@@ -(\d+)(?:,(\d+))? ", line)
        if not m:
            continue
        start = int(m.group(1))
        count = int(m.group(2) if m.group(2) is not None else 1)
        out.append([start, start + 1] if count == 0 else [start, start + count - 1])
    return out

overlap = [l for l in Path(overlap_p).read_text().split("\n") if l]
up_paths = [l for l in Path(up_paths_p).read_text().split("\n") if l]
exposure = json.loads(Path(exposure_p).read_text())
ack_doc = json.loads(Path(ack_p).read_text())
series = json.loads(Path(series_p).read_text())

# Which patch OWNS each overlapping path, read out of the patch files rather than
# out of the acknowledgement — so the acknowledgement's claim about ownership is
# compared against something, not merely recorded.
specs = Path(specs_p)
owners = {}
for p in series["patches"]:
    pf = specs / "upstream-bugs" / p["entry"] / p["patch"]
    for line in pf.read_text(errors="replace").splitlines():
        m = re.match(r"^diff --git a/(.+?) b/(.+)$", line)
        if m:
            owners.setdefault(m.group(2), []).append(p["id"])
for k in owners:
    owners[k] = sorted(set(owners[k]))

# ---------------------------------------------------------------------------
# THE BUILD-INPUT CLASSIFICATION, COMPUTED AT THE TIP AND FAIL-SAFE.
#
# Conjunct 1 used to be "upstream changed no path under the build root at all",
# which held for six upstream moves and stopped holding at `38fd5fc6e9`. What
# replaces it partitions the paths upstream changed under the build root into
# those that can reach a cmake build and those that cannot, and requires the first
# set to be EMPTY. Two rules, both narrow, and anything neither rule places is a
# build input — because an unrecognised file under the tree the evidence compiles
# is a reason to rebuild, not a reason to go looking for a declaration.
#
#   (a) `*.md` is documentation. CMake reads no markdown.
#   (b) `*.sh` is a NON-input only if its basename appears in NONE of the cmake
#       inputs under the build root AT THE TIP — every `CMakeLists.txt`, `*.cmake`
#       and `CMakePresets.json`, 128 files. A script an `add_custom_command`
#       invokes IS a build input and this finds it.
#
# Rule (b) is a search over the tip rather than a list in this file, so a script
# that becomes a build input tomorrow reclassifies itself. It is calibrated in the
# check: `avm_schema.json` is referenced from a `CMakeLists.txt` and must come back
# as referenced, which is what says the search can answer "yes".
cmake_inputs = [p for p in git("ls-tree", "-r", "--name-only", tip, build_root).splitlines()
                if p.endswith("/CMakeLists.txt") or p.endswith(".cmake")
                or p.endswith("/CMakePresets.json")]
cmake_text = ""
for p in cmake_inputs:
    cmake_text += git("show", "%s:%s" % (tip, p))

def referenced_by_cmake(path):
    return Path(path).name in cmake_text

def classify(paths):
    """THE classifier. One function, called for the real paths and for the probe
    below, because a control has to run THROUGH the instrument rather than beside
    it — and the two mutation arms that attack this conjunct inject into the
    decision procedure's JSON and therefore never reach this code at all."""
    bi, ni = [], []
    for p in paths:
        if p.endswith(".md"):
            ni.append(p)
        elif p.endswith(".sh") and not referenced_by_cmake(p):
            ni.append(p)
        else:
            bi.append(p)
    return bi, ni

in_tree = [p for p in up_paths
           if p == build_root or p.startswith(build_root.rstrip("/") + "/")]
build_inputs, non_inputs = classify(in_tree)

# THE CLASSIFIER'S OWN FAIL-SAFE BRANCH EXECUTES ZERO TIMES ON THE REAL DATA, because
# all five paths upstream changed under the build root are `.md` or `.sh`. So "anything
# the classifier cannot place is a build input" was, until this probe, a property of a
# branch nothing ran — and flipping `else: bi.append(p)` to `ni.append(p)` would have
# left every assertion in this check green. The probe runs the SAME function over
# synthetic paths and the shell asserts the partition, in both directions:
#   - a translation unit, a header and a CMake input must come back BUILD INPUTS;
#   - an extension no rule names must come back a BUILD INPUT (the fail-safe branch);
#   - a `.md` must come back a non-input;
#   - and `scripts/remake-constants.sh`, which IS named in a CMakeLists under the build
#     root, must come back a BUILD INPUT — which is rule (b) answering YES over a real
#     file, the direction `avm_schema.json` cannot exercise because it is not a `.sh`.
_r = build_root.rstrip("/")
probe_paths = [
    _r + "/src/barretenberg/vm2/simulation/execution.cpp",
    _r + "/src/barretenberg/vm2/simulation/execution.hpp",
    _r + "/CMakeLists.txt",
    _r + "/src/barretenberg/vm2/some_new_kind_of_file.zzz",
    _r + "/docs/Fuzzing.md",
    _r + "/scripts/remake-constants.sh",
    _r + "/scripts/chonk_inputs.sh",
]
probe_bi, probe_ni = classify(probe_paths)

# `_`-prefixed keys in that block are the file's own prose (`_what`, `_why`,
# `_maintenance`), exactly as in `acknowledged`. They are not paths and must not be
# able to satisfy a lookup.
non_input_decl = {k: v for k, v in ack_doc.get("build_root_non_inputs", {}).items()
                  if not k.startswith("_")}

inp = {
    "base": base, "tip": tip,
    "build_root": build_root,
    "overlap": overlap,
    "upstream_paths": up_paths,
    "ack": ack_doc["acknowledged"],
    "build_inputs": sorted(build_inputs),
    "build_root_non_inputs": sorted(non_inputs),
    "non_input_declarations": non_input_decl,
    "cmake_inputs_scanned": len(cmake_inputs),
    "cmake_positive_control": referenced_by_cmake("avm_schema.json"),
    "classifier_probe": {"build_inputs": probe_bi, "non_inputs": probe_ni},
    "upstream_blobs": {p: {"before": blob(base, p), "after": blob(tip, p)}
                       for p in sorted(set(overlap) | set(in_tree))},
    "upstream_ranges": {p: ranges(p) for p in overlap},
    "carry_ranges": {p: exposure.get("union_pre_ranges", {}).get(p, []) for p in overlap},
    "patch_owners": {p: owners.get(p, []) for p in overlap},
}
Path(out_p).write_text(json.dumps(inp, indent=2, sort_keys=True) + "\n")
PY
assert_file "the overlap decision's input was assembled" "$SCRATCH/input.json"

# Per-path facts, printed and asserted individually rather than folded into the
# verdict, so a failure says which path and which conjunct.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  ur="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["upstream_ranges"].get(sys.argv[2],[]))' "$SCRATCH/input.json" "$path")"
  cr="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["carry_ranges"].get(sys.argv[2],[]))' "$SCRATCH/input.json" "$path")"
  note "overlap $path: upstream changed $ur, the carry set changes $cr"

  # The exposure measurement counts upstream commits on each modified path between
  # the base and the tip, by a completely different route (`git rev-list`). It must
  # agree that upstream has touched this one. Two independent measurements of the
  # same fact; when they disagreed, one of them was wrong, and it was this
  # direction that found it.
  since="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["churn_since_base"].get(sys.argv[2],0))' "$EXPOSURE" "$path")"
  assert_ge "$path: the exposure measurement independently reports upstream commits on it since the base" \
    1 "$since"

  # The acknowledgement declares the region upstream changed, and it must be the region this check
  # just computed. CARRY-LEDGER.md's `Upstream changes` column is rendered from that field; before
  # it existed the column was scraped out of the entry's `reason` with a regex for one phrasing, so
  # a true reason worded any other way rendered as `see below` — which is a number derived from a
  # sentence, the thing this campaign has been bitten by four times. Now it is data, and this is
  # what stops the data from drifting away from the measurement.
  declared_ur="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acknowledged"].get(sys.argv[2],{}).get("upstream_ranges","<none>"))' "$ACK" "$path")"
  assert_eq "$path: the acknowledgement declares the region upstream changed, and it is the one measured" \
    "$ur" "$declared_ur"

  ack_tip="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acknowledged"].get(sys.argv[2],{}).get("acknowledged_at_tip",""))' "$ACK" "$path")"
  if [ -n "$ack_tip" ] && git -C "$FORK_ROOT" merge-base --is-ancestor "$ack_tip" "$tip" 2>/dev/null; then
    pass "$path: the acknowledgement was made at a commit in upstream's history at or before the tip  [$ack_tip]"
  else
    fail "$path: the acknowledgement names no upstream commit at or before the tip  [${ack_tip:-<none>}]"
  fi
done < "$SCRATCH/overlap.txt"

verdict_json="$(python3 "$DECIDE" --input "$SCRATCH/input.json")"
vrc=$?
printf '%s\n' "$verdict_json" | sed 's/^/  |  /'
verdict="$(printf '%s' "$verdict_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')"
n_in_build="$(printf '%s' "$verdict_json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["upstream_paths_in_build_tree"]))')"

note "upstream changed $n_in_build path(s) under $BUILD_ROOT since the base"

# --- the narrowed conjunct 1, and its own calibration ------------------------
#
# The classifier is a thing under test. Three assertions before its verdict is
# used: it scanned a non-empty set of cmake inputs, its search CAN answer "yes"
# (a name that really is referenced comes back referenced), and every in-tree path
# landed in exactly one of the two buckets, so a path cannot go missing between them.
n_cmake="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cmake_inputs_scanned"])' "$SCRATCH/input.json")"
assert_ge "the build-input classifier scanned the build root's cmake inputs" 50 "$n_cmake"
assert_eq "…and its reference search can answer YES, so a NO is a measurement" "True" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cmake_positive_control"])' "$SCRATCH/input.json")"
n_class="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d["build_inputs"]) + len(d["build_root_non_inputs"]))' "$SCRATCH/input.json")"
assert_eq "…and every path upstream changed under the build root was classified exactly once" \
  "$n_in_build" "$n_class"

# THE CLASSIFIER RUN OVER SYNTHETIC PATHS, THROUGH THE SAME FUNCTION. Until this, the
# fail-safe branch — "anything neither rule places is a build input" — was never
# executed: the five real paths are all `.md`/`.sh`, and the two mutation arms below
# that attack this conjunct inject into the DECISION PROCEDURE's input and never reach
# the classifier. So the property the whole narrowing rests on was a property of dead
# code, and flipping the branch left this check green.
probe() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))["classifier_probe"]
print(" ".join(sorted(p.rsplit("/",1)[-1] for p in d[sys.argv[2]])))' "$SCRATCH/input.json" "$1"; }
assert_eq "the classifier, run over synthetic paths, calls a TU, a header, a CMake input, an unknown extension and a cmake-referenced script BUILD INPUTS" \
  "CMakeLists.txt execution.cpp execution.hpp remake-constants.sh some_new_kind_of_file.zzz" \
  "$(probe build_inputs)"
assert_eq "…and only the documentation and the un-referenced script non-inputs, so the partition is exhaustive and neither side is empty" \
  "Fuzzing.md chonk_inputs.sh" \
  "$(probe non_inputs)"

n_build_inputs="$(printf '%s' "$verdict_json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["build_inputs_changed"]))')"
assert_eq "upstream changed no BUILD INPUT under $BUILD_ROOT — no translation unit, no header, no cmake input, and nothing the classifier could not place" \
  "0" "$n_build_inputs"

# Each surviving non-input is named, and its declaration is pinned to upstream's
# blob ids at both ends, so the day upstream touches the path again the entry
# expires rather than going on excusing a change nobody looked at.
while IFS= read -r nip; do
  [ -n "$nip" ] || continue
  note "build-root non-input $nip: declared, and pinned to upstream's blobs at both ends"
done <<EOF
$(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["build_root_non_inputs"]))' "$SCRATCH/input.json")
EOF
n_non_accepted="$(printf '%s' "$verdict_json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["build_root_non_inputs_accepted"]))')"
assert_eq "…and every one of them is accepted, which is the whole of the in-tree set minus the build inputs" \
  "$((n_in_build - n_build_inputs))" "$n_non_accepted"

# A DECLARATION IS NOT EVIDENCE. Each declared non-input additionally has to be
# shown UNREACHED by M6's and M10's own build machinery, by the same invocation
# predicate the top-level `bootstrap.sh` acknowledgement already uses — and the
# predicate is spliced-in-tested per basename, so a name that had silently stopped
# matching fails rather than reporting an absence.
while IFS= read -r nip; do
  [ -n "$nip" ] || continue
  b="$(basename "$nip")"
  b_re="(^|[^a-zA-Z0-9_/.-])(\./)?$(printf '%s' "$b" | sed 's/[.]/\\./g')([ 	\"']|\$)"
  hits="$(grep -nE "$b_re" \
    "$VERIFY_DIR/lib_avm_wasm.sh" "$VERIFY_DIR/lib_m10_cmake_split.sh" \
    "$VERIFY_DIR/build_avm_wasm.sh" 2>/dev/null | grep -v '^[^:]*:[0-9]*: *#' || true)"
  assert_eq "$nip: M6's and M10's build machinery never invokes it" \
    "0" "$(printf '%s\n' "$hits" | grep -c . || true)"
  cp "$VERIFY_DIR/lib_avm_wasm.sh" "$SCRATCH/lib_with_$b"
  printf '  ./%s run\n' "$b" >> "$SCRATCH/lib_with_$b"
  assert_eq "…and the predicate for $b finds one when it is spliced in" "1" \
    "$(grep -cE "$b_re" "$SCRATCH/lib_with_$b" || true)"
done <<EOF
$(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["build_root_non_inputs"]))' "$SCRATCH/input.json")
EOF

assert_eq "every overlap outside it is acknowledged, pinned to upstream's exact change, and in disjoint line regions, so M6's and M10's builds of BASE + this stack still describe the rebased tree" \
  "transfers" "$verdict"
assert_eq "the decision procedure's exit status agrees with its verdict" "0" "$vrc"

# --- the decision procedure, attacked --------------------------------------
#
# Six mutations of the SAME input, each breaking exactly one rule. Each must flip
# the verdict to `void` AND name its own reason: a mutation that goes void for the
# wrong reason is a check that would pass a different bug.

mutate() { # <name> <python-expression-body> <expected-reason-token> [<path>]
  local name="$1" body="$2" token="$3" mpath="${4:-}"
  local f="$SCRATCH/mut-$name.json" v="$SCRATCH/out-$name.json"
  python3 - "$SCRATCH/input.json" "$f" "$mpath" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
P = sys.argv[3]
$body
json.dump(d, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
  python3 "$DECIDE" --input "$f" > "$v" 2>&1
  local mrc=$?
  local mv reasons
  mv="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$v" 2>/dev/null || echo "<unparseable>")"
  reasons="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
rs={r for v in d["rejected"].values() for r in v}
rs |= {r for v in d.get("build_root_rejected", {}).values() for r in v}
print(" ".join(sorted(rs)))' "$v" 2>/dev/null || echo "")"
  assert_eq "mutation '$name' voids the transfer" "void" "$mv"
  case " $reasons " in
    *" $token "*) pass "mutation '$name' is rejected for '$token'  [$reasons]" ;;
    *)            fail "mutation '$name' was rejected for [$reasons], not '$token'" ;;
  esac
  assert_eq "mutation '$name' exits non-zero" "2" "$mrc"
}

FIRST_OVERLAP="$(head -1 "$SCRATCH/overlap.txt")"
[ -n "$FIRST_OVERLAP" ] || die "there is no overlap to mutate; the controls below would be vacuous"

mutate unacknowledged 'd["ack"].pop(P, None)' \
  "unacknowledged-overlap" "$FIRST_OVERLAP"

mutate stale-blob 'd["ack"][P]["upstream_after"] = "0" * 40' \
  "acknowledgement-does-not-match-upstreams-current-change" "$FIRST_OVERLAP"

mutate wrong-owner 'd["ack"][P]["patch"] = ["p9"]' \
  "acknowledgement-names-the-wrong-patch" "$FIRST_OVERLAP"

mutate region-collision 'd["carry_ranges"][P] = list(d["upstream_ranges"][P])' \
  "upstream-and-carry-change-the-same-lines" "$FIRST_OVERLAP"

mutate ack-not-an-overlap 'd["ack"]["barretenberg/cpp/src/nowhere.cpp"] = dict(d["ack"][P])' \
  "acknowledged-path-is-not-in-the-overlap" "$FIRST_OVERLAP"

# The one that must be unwaivable: a fully-formed, blob-accurate, region-disjoint
# acknowledgement for a path INSIDE the build tree must still be refused.
mutate build-tree-overlap '
q = d["build_root"] + "/src/barretenberg/vm2/simulation_helper.cpp"
d["overlap"].append(q)
d["upstream_paths"].append(q)
d["upstream_blobs"][q] = {"before": "a"*40, "after": "b"*40}
d["upstream_ranges"][q] = [[1, 2]]
d["carry_ranges"][q] = [[900, 901]]
d["patch_owners"][q] = ["p4"]
d["ack"][q] = {"patch": ["p4"], "upstream_before": "a"*40, "upstream_after": "b"*40,
               "acknowledged_at_tip": d["tip"], "reason": "a plausible sentence"}
' "overlap-inside-the-tree-the-evidence-compiles" "$FIRST_OVERLAP"

# --- three more, for the narrowed conjunct 1 --------------------------------
#
# The narrowing is the only substantive change this milestone makes to the
# decision procedure, so it gets a negative case per conjunct rather than one that
# happens to fire. Each breaks exactly one rule.

# (a) A TRANSLATION UNIT MOVES. The classifier puts it in `build_inputs`; nothing
#     anywhere can excuse that, and there is deliberately no field to try.
mutate build-input-changed '
q = d["build_root"] + "/src/barretenberg/vm2/simulation/execution.cpp"
d["upstream_paths"].append(q)
d["build_inputs"].append(q)
d["upstream_blobs"][q] = {"before": "a"*40, "after": "b"*40}
d["non_input_declarations"][q] = {"upstream_before": "a"*40, "upstream_after": "b"*40,
                                  "reason": "a plausible sentence that must not help"}
' "upstream-changed-a-build-input" ""

# (b) A PATH THE CLASSIFIER COULD NOT PLACE. It is in neither list, and the
#     fail-safe direction must treat it as a build input rather than ignore it.
#     Without this, a classifier that quietly stopped recognising a file would make
#     the milestone SMALLER instead of RED.
mutate build-root-unclassified '
q = d["build_root"] + "/src/barretenberg/vm2/some_new_kind_of_file.zzz"
d["upstream_paths"].append(q)
d["upstream_blobs"][q] = {"before": "a"*40, "after": "b"*40}
' "upstream-changed-a-build-input" ""

# (c) A DECLARED NON-INPUT WHOSE BLOBS HAVE MOVED. This is what makes a
#     declaration expire instead of standing for ever: upstream touching the path
#     again must reopen the decision.
mutate non-input-stale '
p = d["build_root_non_inputs"][0]
d["non_input_declarations"][p]["upstream_after"] = "0" * 40
' "non-input-declaration-does-not-match-upstreams-current-change" ""

finish
