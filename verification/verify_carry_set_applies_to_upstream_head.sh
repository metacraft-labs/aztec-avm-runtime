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

inp = {
    "base": base, "tip": tip,
    "build_root": build_root,
    "overlap": overlap,
    "upstream_paths": up_paths,
    "ack": ack_doc["acknowledged"],
    "upstream_blobs": {p: {"before": blob(base, p), "after": blob(tip, p)} for p in overlap},
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

assert_eq "upstream changed no path under $BUILD_ROOT, the tree M6 and M10 compile" "0" "$n_in_build"
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
rs=sorted({r for v in d["rejected"].values() for r in v})
if d["upstream_paths_in_build_tree"]: rs.append("upstream-changed-the-build-tree")
print(" ".join(rs))' "$v" 2>/dev/null || echo "")"
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

finish
