#!/usr/bin/env bash
# verify_browser_replay_dd9_clean — L4 (Aztec-Live-Chain-Replay).
#
# "The shipped replay bundle reaches no native dependency, checked on the built artifact.
#  Control: a planted import is caught."
#
# ─────────────────────────────────────────────────────────────────────────────
# "CHECKED ON THE BUILT ARTIFACT" IS THE WHOLE POINT, AND IS WHY THIS CHECK DID NOT EXIST UNTIL NOW.
#
# L4's first pass measured DD-9 with a grep over `replay/src` and REFUSED to ship it under this name,
# because a source-level grep is a strictly weaker claim: it sees what this repository wrote and not
# what the bundler pulled in. The difference is not hypothetical — `replay/src` names
# `@aztec/stdlib/world-state` (a type-only import of `WorldStateRevision`) and never names
# `@aztec/bb.js`, and the BUILT graph contains 32 bb.js inputs and zero world-state ones. A grep
# would have got both backwards.
#
# So this check builds the bundle and reads esbuild's own METAFILE — the list of every module that
# actually entered the graph — plus the emitted bytes.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CONTROL IS A REACH THE SCANNER *DOES* FIND, WHICH IS THE ONLY HONEST ONE AVAILABLE.
#
# The milestone says "a planted import is caught". A planted `@aztec/native` import cannot be built:
# the package is deliberately not installed, so esbuild fails to RESOLVE it and the arm reddens at
# the build rather than at the assertion — which reddens for the wrong reason and demonstrates
# nothing about the scanner. This campaign has shipped that shape before and named it: "an absence
# asked of a tree that excluded its subject by construction".
#
# So the control is §3, and it is the same instrument turned on something that IS there:
# **`@aztec/bb.js` is in the graph, 32 inputs, and the scanner finds them.** The zeros in §2 are
# therefore measured absences taken by an instrument shown to be capable of seeing a presence. §3
# also traces the import chain, because *why* bb.js is there is the finding: it enters through
# `@aztec/foundation/dest/curves/bn254/field.js` — the `Fr` class itself — so it is unavoidable in
# any graph that touches a field element, and it is NOT a DD-9 violation. DD-9 forbids
# `@aztec/native`, `@aztec/world-state` and `cpp_*`; DD-11's separate demand is that a page never
# FETCHES the barretenberg wasm, which is a question about network requests and needs a page. This
# check does not answer it and says so rather than implying it did.
#
# ─────────────────────────────────────────────────────────────────────────────
# AND §4 IS A FALSE POSITIVE THIS CHECK WOULD OTHERWISE HAVE SHIPPED.
#
# A naive `grep -c 'node:'` over the minified bundle returns 2. Neither is a module specifier: both
# are inside identifiers — `shiftNodeUp(t,r){…}` and `getNode(t)`. A check that counted them would
# be red for ever over a bundle with no Node builtins in it at all. The specifiers are asserted from
# the METAFILE, where a builtin would appear as an unresolved input, and the substring count is
# recorded beside it as the trap it is.
#
# Run: just verify-browser-replay-dd9

set -uo pipefail
TEST_NAME="verify_browser_replay_dd9_clean"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l2_prepare

# `src/index.js`, NOT `index.js`. esbuild preserves the entries' relative layout once there is more
# than one, and the page entry made this pass multi-entry — so the library entry moved into
# `dist-browser/src/`. The old path silently stopped existing and the check said so, which is the
# assertion working.
BUNDLE="$REPO_ROOT/replay/dist-browser/src/index.js"
META="$REPO_ROOT/replay/dist-browser/meta.json"
BUILDER="$REPO_ROOT/replay/tools/build_browser_bundle.mjs"
BUDGETS="$REPO_ROOT/replay/browser-budgets.json"
DIST="$REPO_ROOT/replay/dist-browser"

assert_file "the bundle builder is committed" "$BUILDER"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/build_browser_bundle.mjs"
assert_file "…and the budgets it enforces are DATA, not a literal in the builder" "$BUDGETS"
assert_true "…also TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/browser-budgets.json"

# ---------------------------------------------------------------------------
echo "== 1. the artifact is BUILT here, not assumed"
#
# Built every run rather than read from wherever a previous run left it: a DD-9 claim over a stale
# bundle is a claim about a tree that no longer exists.
# ---------------------------------------------------------------------------
rm -rf "$REPO_ROOT/replay/dist-browser"
BUILD_LOG="$L2_WORK/probes/dd9-build.log"
mkdir -p "$(dirname "$BUILD_LOG")"
if ! timeout "${L4_BUILD_TIMEOUT:-600}" node "$BUILDER" >"$BUILD_LOG" 2>&1; then
  die "the browser bundle failed to build; esbuild's own output is in $BUILD_LOG:
$(tail -20 "$BUILD_LOG")"
fi
assert_file "the entry chunk was emitted" "$BUNDLE"
assert_file "…with esbuild's metafile beside it" "$META"
EAGER_BYTES_EARLY="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1])); outs = m["outputs"]
entry = next(k for k, v in outs.items() if (v.get("entryPoint") or "").endswith("src/index.ts"))
eager = {entry}; stack = [entry]
while stack:
    cur = stack.pop()
    for imp in outs[cur].get("imports", []):
        if imp.get("kind") == "import-statement" and imp["path"] in outs and imp["path"] not in eager:
            eager.add(imp["path"]); stack.append(imp["path"])
print(sum(outs[k]["bytes"] for k in eager))
' "$META")"
# THE ENTRY FILE ITSELF IS TINY — 2,711 bytes — because splitting puts the substance in shared
# chunks. Measuring "is this a real bundle" on the entry alone would be measuring the wrong file, so
# the size assertion is over the EAGER CLOSURE, which is what a page actually downloads.
assert_ge "…and the EAGER CLOSURE is a real bundle rather than a stub" 500000 "$EAGER_BYTES_EARLY"
assert_ge "the build produced SEVERAL outputs, so splitting really happened" 5 \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["outputs"]))' "$META")"

INPUTS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["inputs"]))' "$META")"
assert_ge "the shipped graph has a substantial number of inputs" 500 "$INPUTS"

reach() { # <metafile> <needle> — how many inputs contain the needle
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for k in d["inputs"] if sys.argv[2] in k))
' "$1" "$2"
}

# ---------------------------------------------------------------------------
echo "== 2. DD-9: THE FORBIDDEN SET IS ABSENT FROM THE BUILT GRAPH"
#
# `@aztec/native` and `@aztec/world-state` are the two packages DD-9 forbids;
# `verify_differential_containment` asserts against them in three places on the other side of the
# repository. `@aztec/simulator` is here too because its own hard dependencies are those two.
# ---------------------------------------------------------------------------
assert_eq "no @aztec/native anywhere in the graph" "0" "$(reach "$META" '@aztec/native')"
assert_eq "…no @aztec/world-state (the PACKAGE, which is not @aztec/stdlib/world-state)" "0" \
  "$(reach "$META" '@aztec/world-state/')"
assert_eq "…no @aztec/simulator, whose own hard deps are those two" "0" \
  "$(reach "$META" '@aztec/simulator')"
assert_eq "…and no cpp_ module" "0" "$(reach "$META" 'cpp_')"

# THE PIN, ASSERTED ON THE ARTIFACT. `browser/build.mjs` resolves @aztec through
# `orchestration/node_modules` (deletion_era); this bundle must resolve through `replay/`'s
# (npm.current), and if it did not, every `Fr` in it would be the wrong class.
#
# ---------------------------------------------------------------------------
# THE PATTERN COULD NOT MATCH THE GOOD CASE, AND THAT IS WHY THIS BLOCK CHANGED.
#
# It read `re.search(r"(.*?/node_modules)/@aztec/", k)`, which needs at least one character before
# `/node_modules`. `build_browser_bundle.mjs` runs esbuild with `cwd: REPLAY`, so a module resolved
# through `replay/node_modules` — the CORRECT root, the one this section exists to require —
# appears in the metafile as the bare key `node_modules/@aztec/foundation/…` and matches nothing.
# Measured on the artefact this check had just built: 380 inputs mention `@aztec`, every one of
# them under `replay/node_modules`, and `ROOTS` came back EMPTY, so `expected [1], got [0]`.
#
# This is `Testing/Verification-Harness-Traps.md` §4 in its loud form: a scanner whose pattern
# cannot express the state it is looking for. The rewrite is meaning-preserving — the wrong root
# `../orchestration/node_modules/@aztec/…` still matches and still comes back with its prefix — and
# the empty prefix is NAMED as `replay/node_modules` rather than dropped, because a root the scan
# cannot spell is a root the assertion below cannot check for.
# ---------------------------------------------------------------------------
ROOTS="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
roots = set()
for k in d["inputs"]:
    m = re.search(r"(.*?)node_modules/@aztec/", k)
    if not m:
        continue
    prefix = m.group(1)
    # esbuild wrote this metafile with cwd = replay/, so a BARE `node_modules/…` key IS
    # replay/node_modules. Naming it is what lets the assertion below say so.
    roots.add((prefix + "node_modules") if prefix else "replay/node_modules")
print("\n".join(sorted(roots)))
' "$META")"
# THE SCAN IS ASSERTED NON-EMPTY BEFORE ANYTHING IS ASSERTED ABOUT ITS CONTENTS. Without this, a
# pattern that stopped matching reports "exactly one root" as `0 != 1` — which is what happened —
# and, worse, the `assert_not_contains` two lines down would pass over an empty haystack forever.
assert_ge "the @aztec scan reached the graph at all, before any claim about which root" 1 \
  "$(printf '%s\n' "$ROOTS" | grep -c . )"
assert_eq "every @aztec module comes from EXACTLY ONE node_modules root" "1" \
  "$(printf '%s\n' "$ROOTS" | grep -c . )"
assert_contains "…and it is replay's, which is npm.current" "replay/node_modules" "$ROOTS"
assert_not_contains "…NOT orchestration's, which is the deletion_era line" "orchestration/node_modules" \
  "$ROOTS"

# ---------------------------------------------------------------------------
echo "== 2b. SPLITTING MUST NOT MAKE THE BOUNDARY UNPROVABLE"
#
# THE HAZARD THIS SECTION EXISTS FOR, NAMED: once the graph has more than one output, a check that
# counted inputs in ONE output would call the bundle DD-9 clean while a forbidden module sat in a
# lazy chunk. §2 counts the metafile's GLOBAL `inputs` map, which esbuild populates for the whole
# graph regardless of splitting — but "regardless of splitting" is an assumption about a bundler,
# and this section turns it into an assertion:
#
# AND THE FIRST VERSION OF THIS SECTION ASSERTED SOMETHING FALSE ABOUT esbuild, which is recorded
# rather than quietly corrected. It required the union of the outputs' inputs to EQUAL the global
# `inputs` map. Measured: global 947, union 572, **375 inputs in the global map appear in no output
# at all**. The global map is the RESOLVED graph — every module esbuild parsed — and the per-output
# maps are the SHIPPED graph, after tree-shaking. They are a superset and a subset, not two spellings
# of one thing.
#
# That makes §2's count CONSERVATIVE IN THE SAFE DIRECTION: a forbidden module that was resolved and
# then tree-shaken away would still fail §2. Good. What this section adds is the other end — the
# forbidden set is absent from the SHIPPED graph too, PER OUTPUT, eager and lazy alike — so the
# answer does not depend on which map was read, which is the property that becomes unprovable the
# moment the graph has more than one output.
# ---------------------------------------------------------------------------
UNION_VS_GLOBAL="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
glob = set(m["inputs"])
union = set()
for o in m["outputs"].values():
    union |= set(o.get("inputs", {}))
print(len(glob), len(union), len(glob - union), len(union - glob))
' "$META")"
read -r N_GLOBAL N_UNION ONLY_GLOBAL ONLY_UNION <<<"$UNION_VS_GLOBAL"
assert_eq "every input an OUTPUT carries is in the global map, so no output smuggles one in" "0" \
  "$ONLY_UNION"
assert_ge "the SHIPPED graph is a non-trivial subset of the resolved one" 500 "$N_UNION"
assert_ge "…and the RESOLVED graph is larger, which is tree-shaking working" 1 "$ONLY_GLOBAL"
assert_true "…so §2's global count is the CONSERVATIVE reading, not the loose one" \
  test "$N_GLOBAL" -gt "$N_UNION"

PER_OUTPUT_BAD="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
forbidden = ("@aztec/native", "@aztec/world-state/", "@aztec/simulator", "cpp_")
bad = []
for name, o in m["outputs"].items():
    for k in o.get("inputs", {}):
        for f in forbidden:
            if f in k:
                bad.append(f"{name}: {k}")
print(len(bad))
print("\n".join(bad[:5]))
' "$META")"
assert_eq "the forbidden set is absent from EVERY output, eager and lazy alike" "0" \
  "$(printf '%s\n' "$PER_OUTPUT_BAD" | head -1)"

# THE BUDGET, RE-READ FROM THE SAME FILE THE BUILDER ENFORCES. The builder fails the build; this
# asserts the shape it enforced, so a builder that stopped enforcing is visible here too.
EAGER="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
outs = m["outputs"]
entry = next(k for k, v in outs.items() if (v.get("entryPoint") or "").endswith("src/index.ts"))
eager = {entry}; stack = [entry]
while stack:
    cur = stack.pop()
    for imp in outs[cur].get("imports", []):
        if imp.get("kind") == "import-statement" and imp["path"] in outs and imp["path"] not in eager:
            eager.add(imp["path"]); stack.append(imp["path"])
lazy = set(outs) - eager
print(sum(outs[k]["bytes"] for k in eager))
print(len(eager))
print(sum(outs[k]["bytes"] for k in lazy))
print(" ".join(sorted(k.split("/")[-1] for k in lazy)))
' "$META")"
EAGER_BYTES="$(printf '%s\n' "$EAGER" | sed -n 1p)"
EAGER_FILES="$(printf '%s\n' "$EAGER" | sed -n 2p)"
LAZY_BYTES="$(printf '%s\n' "$EAGER" | sed -n 3p)"
LAZY_NAMES="$(printf '%s\n' "$EAGER" | sed -n 4p)"
MAX_BYTES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["library"]["maxEagerBytes"])' "$BUDGETS")"

assert_true "the EAGER total is within the declared budget" \
  test "$EAGER_BYTES" -le "$MAX_BYTES"
assert_ge "…and the budget is a real ceiling rather than an open one" 1 \
  "$(( MAX_BYTES < 2000000 ? 1 : 0 ))"
assert_true "the eager chunk count is within budget" \
  test "$EAGER_FILES" -le "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["library"]["maxEagerFiles"])' "$BUDGETS")"

# DD-11's OWN PROPERTY, STRUCTURALLY: the two barretenberg blobs are LAZY. A byte budget catches
# this only incidentally, by being smaller than 4 MB; this names them.
assert_contains "barretenberg is a LAZY chunk, not an eager one" "barretenberg-" "$LAZY_NAMES"
assert_contains "…and so is barretenberg-threads" "barretenberg-threads-" "$LAZY_NAMES"
assert_ge "…and together they are the bulk that a replay never fetches" 8000000 "$LAZY_BYTES"
# BOTH ENTRIES ARE BUDGETED, and the page is the one a user waits for. Asserted here as well as
# enforced by the builder, so a builder that stopped enforcing is visible from the check too.
assert_ge "the PAGE entry has its own budget, because it is the thing a user loads" 1 \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(1 if d.get("page",{}).get("maxEagerBytes") else 0)' "$BUDGETS")"
assert_true "…and it is a real ceiling rather than an open one" \
  test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["page"]["maxEagerBytes"])' "$BUDGETS")" -lt 2000000
assert_true "the EAGER total is a small fraction of the whole graph" \
  test "$EAGER_BYTES" -lt "$LAZY_BYTES"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROL: the scanner FINDS a reach that is really there"
#
# Without this, the four zeros above are satisfied by a scanner that returns zero for everything.
# A planted `@aztec/native` import would fail to RESOLVE (the package is deliberately not
# installed), so the arm would redden at the build and demonstrate nothing about the instrument —
# "an absence asked of a tree that excluded its subject by construction", which this campaign has
# shipped before. bb.js IS in the graph, so it is the honest control.
# ---------------------------------------------------------------------------
BBJS="$(reach "$META" '@aztec/bb.js')"
assert_ge "@aztec/bb.js IS in the graph, and the scanner sees it" 20 "$BBJS"
assert_ge "…so is barretenberg-named code" 5 "$(reach "$META" 'barretenberg')"
assert_eq "a FABRICATED package name is absent, so 'found' is not 'finds anything'" "0" \
  "$(reach "$META" '@aztec/this-package-does-not-exist')"

# WHY it is there, which is the finding rather than the count.
CHAIN="$(python3 -c '
import json, sys
from collections import deque
meta = json.load(open(sys.argv[1]))
d = meta["inputs"]
target = {k for k in d if "@aztec/bb.js" in k}
# THE ENTRY KEY IS RELATIVE TO THE BUILD CWD (`replay/`), so it is `src/index.ts` and not an
# absolute path. The first version matched on `replay/src/index.ts`, found nothing, and printed
# "NO PATH" — which reads as "bb.js is unreachable" over a graph with 32 bb.js inputs in it. It is
# taken from the metafile'"'"'s own outputs[].entryPoint now rather than guessed.
entry = [v["entryPoint"] for v in meta["outputs"].values()
         if (v.get("entryPoint") or "").endswith("src/index.ts")]
seen = set(entry); q = deque((e, [e]) for e in entry)
while q:
    cur, pathv = q.popleft()
    for imp in d.get(cur, {}).get("imports", []):
        p = imp["path"]
        if p in seen: continue
        seen.add(p)
        if p in target:
            print(" -> ".join(x.split("node_modules/")[-1] for x in pathv + [p])); raise SystemExit
        q.append((p, pathv + [p]))
print("NO PATH")
' "$META")"
assert_contains "bb.js enters through the Fr class itself, not through a proving path" \
  "curves/bn254/field.js" "$CHAIN"
assert_not_contains "…and NOT through a prover or a circuit" "prover" "$CHAIN"
# So its presence is not a DD-9 violation, and this check says which question it does NOT answer.
assert_eq "DD-11's separate question — does a PAGE fetch the barretenberg wasm — is a NETWORK
     question, needs a page, and is deliberately not answered here" "network" "network"

# ---------------------------------------------------------------------------
echo "== 4. no Node builtin SPECIFIERS — and the substring trap that would fake one"
# ---------------------------------------------------------------------------
UNRESOLVED="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["inputs"]
builtins = {"fs","path","util","assert","tty","module","os","crypto","stream","buffer","child_process","worker_threads"}
bad = []
for k, v in d.items():
    for imp in v.get("imports", []):
        p = imp["path"]
        if p.startswith("node:") or p in builtins:
            bad.append(f"{k} -> {p}")
print(len(bad))
print("\n".join(bad[:5]))
' "$META")"
assert_eq "no input imports a Node builtin, by specifier, anywhere in the graph" "0" \
  "$(printf '%s\n' "$UNRESOLVED" | head -1)"

# THE TRAP, RECORDED RATHER THAN AVOIDED. A naive substring count over the minified bytes finds two
# `node:` occurrences and BOTH are inside identifiers — `shiftNodeUp(` and `getNode(`. A check built
# on that count would be red for ever over a clean bundle.
# OVER EVERY EAGER CHUNK, not just the entry: splitting moved the substance out of the entry file,
# and a scan of the entry alone would report zero for a bundle full of whatever it was looking for.
EAGER_FILES_LIST="$(python3 -c '
import json, os, sys
m = json.load(open(sys.argv[1])); outs = m["outputs"]
entry = next(k for k, v in outs.items() if (v.get("entryPoint") or "").endswith("src/index.ts"))
eager = {entry}; stack = [entry]
while stack:
    cur = stack.pop()
    for imp in outs[cur].get("imports", []):
        if imp.get("kind") == "import-statement" and imp["path"] in outs and imp["path"] not in eager:
            eager.add(imp["path"]); stack.append(imp["path"])
print(" ".join(os.path.join(sys.argv[2], os.path.relpath(k, "dist-browser")) for k in sorted(eager)))
' "$META" "$DIST")"
NAIVE="$(cat $EAGER_FILES_LIST | grep -o 'node:' | wc -l | tr -d ' ')"
assert_ge "a NAIVE substring count over the bytes finds 'node:' occurrences…" 1 "$NAIVE"
assert_true "…every one of which is inside an identifier such as getNode( — which is why §4 reads
     the metafile's specifiers and not the bytes" \
  bash -c "! cat $EAGER_FILES_LIST | grep -oE \"[\\\"']node:[a-z_/]+[\\\"']\" | grep -q ."

# And the things a native reach would actually leave behind.
for pat in 'process.binding' '__dirname' 'require("fs")' 'cpp_'; do
  assert_eq "the emitted bytes contain no $pat" "0" \
    "$(cat $EAGER_FILES_LIST | grep -o -- "$pat" | wc -l | tr -d ' ')"
done

finish
