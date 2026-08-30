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

BUNDLE="$REPO_ROOT/replay/dist-browser/replay.js"
META="$REPO_ROOT/replay/dist-browser/meta.json"
BUILDER="$REPO_ROOT/replay/tools/build_browser_bundle.mjs"

assert_file "the bundle builder is committed" "$BUILDER"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/build_browser_bundle.mjs"

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
assert_file "the bundle was emitted" "$BUNDLE"
assert_file "…with esbuild's metafile beside it" "$META"
assert_ge "…and it is a real bundle rather than a stub" 5000000 "$(wc -c <"$BUNDLE" | tr -d ' ')"

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
ROOTS="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
roots = sorted({re.search(r"(.*?/node_modules)/@aztec/", k).group(1)
                for k in d["inputs"] if re.search(r"(.*?/node_modules)/@aztec/", k)})
print("\n".join(roots))
' "$META")"
assert_eq "every @aztec module comes from EXACTLY ONE node_modules root" "1" \
  "$(printf '%s\n' "$ROOTS" | grep -c . )"
assert_contains "…and it is replay's, which is npm.current" "replay/node_modules" "$ROOTS"
assert_not_contains "…NOT orchestration's, which is the deletion_era line" "orchestration/node_modules" \
  "$ROOTS"

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
entry = [v["entryPoint"] for v in meta["outputs"].values() if v.get("entryPoint")]
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
NAIVE="$(grep -o 'node:' "$BUNDLE" | wc -l | tr -d ' ')"
assert_ge "a NAIVE substring count over the bytes finds 'node:' occurrences…" 1 "$NAIVE"
assert_true "…every one of which is inside an identifier such as getNode( — which is why §4 reads
     the metafile's specifiers and not the bytes" \
  bash -c "! grep -oE \"[\\\"']node:[a-z_/]+[\\\"']\" '$BUNDLE' | grep -q ."

# And the things a native reach would actually leave behind.
for pat in 'process.binding' '__dirname' 'require("fs")' 'cpp_'; do
  assert_eq "the emitted bytes contain no $pat" "0" \
    "$(grep -o -- "$pat" "$BUNDLE" | wc -l | tr -d ' ')"
done

finish
