#!/usr/bin/env bash
# verify_m11_carry_set_resolved_or_retired
#
# M37 verification: M11's standing red is resolved, and resolved by a NARROWING
# that cannot excuse the thing it was protecting against.
#
# THE HISTORY, because "M11 is green" is only interesting against it. Upstream's
# `next` has moved NINE times during this campaign, and for the first six of them
# `verify_carry_set_applies_to_upstream_head`'s first conjunct — *upstream changed
# no path under `barretenberg/cpp`, the tree M6 and M10 compile* — held for free.
# It is a SUFFICIENT condition: if no path under the build root moved, no
# translation unit, header or CMake input either build reads can differ between
# BASE + stack and TIP + stack, so M6's and M10's build evidence transfers.
#
# `38fd5fc6e9` ended it, and for a reason that has nothing to do with C++: it
# renames `yarn-project/` to `labs/yarn-project/` in five paths under the build
# root — `bootstrap.sh`, `docs/Fuzzing.md` and three benchmark-input scripts. The
# sufficient condition became unavailable for a change no compiler can see, and
# M11 has been red since. `CAMPAIGN-BRIEF.md` records the state exactly: *"the
# seventh is a new class and is OPEN"*, with the narrowing named as a DECISION
# nobody had taken.
#
# WHAT THIS CHECK ASSERTS, and the second half is the one that matters:
#
#   1. THE OUTCOME. The carry set still applies at the recorded tip — every patch,
#      replayed, from the report the replay itself wrote — and the five build-root
#      paths are each declared with blob ids that this check RE-DERIVES from the
#      fork rather than reads back out of the declaration.
#   2. THE NARROWING IS STILL UNWAIVABLE WHERE IT COUNTS. Driven over synthetic
#      inputs: a translation unit under the build root is refused WITH a complete,
#      blob-accurate declaration in front of it; a file the classifier cannot place
#      is refused; and a declaration whose blobs have moved is refused. If any of
#      those three ever passed, "M11 is green" would mean nothing.
#
# A note on scope: this check deliberately does NOT fetch and does NOT replay. That
# is `verify_carry_set_applies_to_upstream_head`'s job, and two checks fetching the
# same remote inside one sweep is two different tips inside one measurement.
#
# Run: just verify-m37-m11

TEST_NAME="verify_m11_carry_set_resolved_or_retired"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m37.sh"
m37_summary_on_abnormal_exit

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"

DECIDE="$VERIFY_DIR/_carry_overlap.py"
REBASE="$REPO_ROOT/carry/rebase.json"
ACK="$REPO_ROOT/carry/overlap.json"
for f in "$DECIDE" "$REBASE" "$ACK"; do
  [ -f "$f" ] || die "missing $f"
done

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

printf '\n=== %s\n' "$TEST_NAME"

# --- §1 the outcome ----------------------------------------------------------
BASE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base"])' "$REBASE")"
TIP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tip"])' "$REBASE")"
# A commit id read out of a report is a value the report could have omitted, and an
# empty rev makes `git rev-parse ":path"` resolve against the INDEX — which is how
# the first run of this check compared the base blob with itself and called it a
# mismatch. Both are refused here rather than allowed to become measurements.
assert_ge "the replay report names a base commit" 40 "${#BASE}"
assert_ge "the replay report names a tip commit" 40 "${#TIP}"
note "replay recorded: base ${BASE:0:10} -> tip ${TIP:0:10}"

assert_eq "the tip the replay ran against is a commit this fork has" "commit" \
  "$(git -C "$FORK_ROOT" cat-file -t "$TIP" 2>/dev/null || echo missing)"
assert_true "…and the base is an ancestor of it, so the replay was forward" \
  git -C "$FORK_ROOT" merge-base --is-ancestor "$BASE" "$TIP"

N_PATCH="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$REBASE")"
N_OK="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for p in d["patches"] if p.get("result") in ("applies","already-upstream")))' "$REBASE")"
assert_ge "the carry set is not empty, so 'every patch applies' is not a statement about nothing" 5 "$N_PATCH"
assert_eq "every patch in the carry set still applies at the recorded tip" "$N_PATCH" "$N_OK"

# --- the five declarations, RE-DERIVED rather than read back -----------------
#
# The entries carry upstream's blob ids at both ends. Reading them out of the file
# and comparing them with themselves would be this campaign's most degenerate
# defect; they are recomputed from the fork at the base and the tip.
NON="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1])).get("build_root_non_inputs",{})
print("\n".join(k for k in d if not k.startswith("_")))' "$ACK")"
N_NON="$(printf '%s\n' "$NON" | grep -c . || true)"
assert_ge "the build-root non-inputs are declared" 1 "$N_NON"
note "$N_NON declared build-root non-input(s)"

blob() { git -C "$FORK_ROOT" rev-parse --verify -q "$1:$2" 2>/dev/null || true; }
n_ok=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  want_b="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build_root_non_inputs"][sys.argv[2]]["upstream_before"])' "$ACK" "$p")"
  want_a="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build_root_non_inputs"][sys.argv[2]]["upstream_after"])'  "$ACK" "$p")"
  got_b="$(blob "$BASE" "$p")"; got_a="$(blob "$TIP" "$p")"
  assert_eq "$p: the declared pre-image blob is the one the fork has at the base" "$want_b" "$got_b"
  assert_eq "$p: the declared post-image blob is the one the fork has at the tip"  "$want_a" "$got_a"
  # A declaration over a path upstream did NOT change would be an entry
  # pre-authorising something, so the two ends must differ.
  if [ -n "$got_b" ] && [ "$got_b" != "$got_a" ]; then
    pass "$p: upstream really did change it, so the declaration is about something"
    n_ok=$((n_ok + 1))
  else
    fail "$p: the two blobs are the same [$got_b]; this entry declares a change that did not happen"
  fi
  # It is under the build root — otherwise it belongs in `acknowledged`, not here.
  case "$p" in
    barretenberg/cpp/*) pass "$p: is under the build root, which is what this block is for" ;;
    *) fail "$p: is not under barretenberg/cpp and does not belong in this block" ;;
  esac
done <<EOF
$NON
EOF
assert_eq "every declared non-input was re-derived against the fork" "$N_NON" "$n_ok"

# --- §2 the narrowing, attacked ---------------------------------------------
#
# A minimal synthetic input, so the controls exercise the DECISION and not the
# assembly. It starts in the state the real one is in — no overlap, one declared
# non-input, verdict `transfers` — and each arm breaks exactly one thing.
python3 - "$SCRATCH/base.json" <<'PY'
import json, sys
doc = str("barretenberg/cpp/docs/Fuzzing.md")
inp = {
    "base": "b" * 40, "tip": "t" * 40,
    "build_root": "barretenberg/cpp",
    "overlap": [],
    "upstream_paths": [doc, "some/other/path.ts"],
    "ack": {},
    "build_inputs": [],
    "build_root_non_inputs": [doc],
    "non_input_declarations": {doc: {"upstream_before": "1" * 40, "upstream_after": "2" * 40,
                                     "reason": "documentation"}},
    "upstream_blobs": {doc: {"before": "1" * 40, "after": "2" * 40}},
    "upstream_ranges": {}, "carry_ranges": {}, "patch_owners": {},
}
json.dump(inp, open(sys.argv[1], "w"), indent=1)
PY

# `DEC_RC` is written to a FILE and not to a variable, because every caller runs
# this inside `$( … )` and a variable set in a subshell is lost — the same shape as
# this campaign's "a pipe that put the failure counter in a subshell", which
# printed FAIL and reported 0 failures in the same run.
run_decide() { # <input> -> prints "<verdict> <reasons…>"; writes rc to $SCRATCH/rc
  local out; out="$(python3 "$DECIDE" --input "$1" 2>&1)"; printf '%s' "$?" > "$SCRATCH/rc"
  printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rs={r for v in d["rejected"].values() for r in v}
rs|={r for v in d.get("build_root_rejected",{}).values() for r in v}
print(d["verdict"], " ".join(sorted(rs)))'
}

BASE_OUT="$(run_decide "$SCRATCH/base.json")"
assert_eq "the synthetic baseline transfers, so the arms below start from a green" "transfers" "${BASE_OUT%% *}"
assert_eq "…and its exit status agrees" "0" "$(cat "$SCRATCH/rc")"

arm() { # <name> <python-body> <expected-token>
  local name="$1" body="$2" token="$3"
  python3 - "$SCRATCH/base.json" "$SCRATCH/$name.json" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
$body
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
  local out; out="$(run_decide "$SCRATCH/$name.json")"
  assert_eq "arm '$name' voids the transfer" "void" "${out%% *}"
  case " ${out#* } " in
    *" $token "*) pass "arm '$name' is rejected for '$token'  [${out#* }]" ;;
    *)            fail "arm '$name' was rejected for [${out#* }], not '$token'" ;;
  esac
  assert_eq "arm '$name' exits non-zero" "2" "$(cat "$SCRATCH/rc")"
}

# (a) THE ONE THAT MUST NEVER PASS. A translation unit under the build root, with a
#     complete and blob-accurate declaration sitting in front of it. If a
#     declaration could excuse this, the narrowing would have retired the conjunct
#     rather than narrowed it.
arm build-input-with-a-full-declaration '
q = "barretenberg/cpp/src/barretenberg/vm2/simulation/execution.cpp"
d["upstream_paths"].append(q)
d["build_inputs"].append(q)
d["upstream_blobs"][q] = {"before": "3"*40, "after": "4"*40}
d["build_root_non_inputs"].append(q)
d["non_input_declarations"][q] = {"upstream_before": "3"*40, "upstream_after": "4"*40,
                                  "reason": "a complete, blob-accurate, entirely persuasive sentence"}
' "upstream-changed-a-build-input"

# (b) A file neither rule places. It must fail rather than be ignored: an
#     unrecognised file under the tree the evidence compiles is a reason to
#     rebuild, and a classifier that quietly stops recognising something must make
#     this RED rather than smaller.
arm unclassifiable-file-under-the-build-root '
q = "barretenberg/cpp/src/barretenberg/vm2/a_new_kind_of_input.zzz"
d["upstream_paths"].append(q)
d["upstream_blobs"][q] = {"before": "5"*40, "after": "6"*40}
' "upstream-changed-a-build-input"

# (c) A declaration that has stopped matching upstream. This is what makes an entry
#     expire instead of standing for ever, and it is the same mechanism the
#     `acknowledged` block already uses.
arm declaration-blobs-moved '
p = d["build_root_non_inputs"][0]
d["non_input_declarations"][p]["upstream_after"] = "0" * 40
' "non-input-declaration-does-not-match-upstreams-current-change"

# (d) A build-root change with no declaration at all.
arm undeclared-non-input '
d["non_input_declarations"].pop(d["build_root_non_inputs"][0])
' "build-root-change-not-declared-a-non-input"

# --- the conjunct is still WRITTEN as unwaivable ----------------------------
# The three arms above measure behaviour; this reads the file, because the
# behaviour is produced by an ordering — the build-root test runs before and
# independently of any lookup — and an ordering is worth pinning by name.
SRC="$(cat "$DECIDE")"
assert_true "the decision procedure still refuses an ACKNOWLEDGED path under the build root" \
  str_has_sub "$SRC" "R_IN_BUILD_TREE"
assert_true "…and still has a build-input rejection that no declaration can clear" \
  str_has_sub "$SRC" "R_BUILD_INPUT"
assert_false "…and the control needle, which must not match, does not" \
  str_has_sub "$SRC" "R_THIS_TOKEN_DOES_NOT_EXIST"

m37_finish
