#!/usr/bin/env bash
# verify_browser_artifacts_lazy
#
# DD-11's other half: "avm.wasm and CONTRACT ARTIFACTS load lazily".
#
# ===========================================================================================
# WHAT THIS PINS, AND WHY EACH PART NEEDS PINNING.
# ===========================================================================================
#
# The build redirects FIVE modules. Two of them are ours (poseidon, grumpkin) and are held by
# `test_browser_crypto_matches_bb_js`. The other three are the artifact ones, and they are what this
# check owns:
#
#   `fee-juice/index.js`         -> `browser/src/shims/protocol_fee_juice.ts`   (ours, six lines)
#   `class-registry/index.js`    -> `class-registry/lazy.js`                     (UPSTREAM'S)
#   `instance-registry/index.js` -> `instance-registry/lazy.js`                  (UPSTREAM'S)
#
# THREE PROPERTIES, AND EACH ONE HAS A WAY OF BEING SILENTLY FALSE.
#
#   1. THE UPSTREAM LAZY MODULES ARE API-IDENTICAL to the eager ones they replace. `class-registry/
#      lazy.js` and `instance-registry/lazy.js` `export *` the same event modules their eager
#      siblings do — which is the whole reason the redirect is safe rather than merely convenient.
#      Asserted by comparing the two files' `export *` lines, out of the installed package.
#   2. OUR fee-juice SHIM IS ONE-FOR-ONE with upstream's barrel, minus the eager constant. The two
#      slot helpers' BODIES are upstream's; the check compares the operative lines rather than
#      counting them, because `CAMPAIGN-BRIEF.md` records a vendored-diff classifier that accepted a
#      corruption by SHAPE while the line counts stayed identical.
#   3. THE ARTIFACTS ARE ACTUALLY LAZY IN THE BUILD. Each becomes its own chunk, reached by a
#      `dynamic-import` edge in the metafile and by NO eager edge — and the metafile's own edge
#      KINDS are read, because "it is in a separate chunk" and "it is loaded lazily" are different
#      statements and only the second is DD-11.
#
# Run: just verify-browser-artifacts-lazy

TEST_NAME="verify_browser_artifacts_lazy"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_bundle

PC="$ORCH_DIR/node_modules/@aztec/protocol-contracts/dest"
[ -d "$PC" ] || die "@aztec/protocol-contracts is not installed at $PC"

echo "== 1. upstream ships the lazy loaders, and they are API-identical to the eager ones"

for name in class-registry instance-registry fee-juice; do
  assert_file "upstream ships $name/lazy.js" "$PC/$name/lazy.js"
  assert_file "…beside its eager $name/index.js" "$PC/$name/index.js"
  # The lazy module must NOT import the artifact statically, and the eager one must.
  assert_true "…the EAGER $name/index.js imports its artifact JSON statically" \
    str_has_line_re "$(cat "$PC/$name/index.js")" "^import .*from '\.\./\.\./artifacts/"
  assert_false "…while the LAZY one does not" \
    str_has_line_re "$(cat "$PC/$name/lazy.js")" "^import .*from '\.\./\.\./artifacts/"
  assert_true "…it uses a dynamic import instead" \
    str_has_sub "$(cat "$PC/$name/lazy.js")" "await import('../../artifacts/"
done

# THE API-IDENTITY, for the two that are redirected straight at upstream's lazy module. The eager
# barrels re-export event modules; the lazy ones must re-export the SAME ones, or the redirect
# silently drops a symbol our own sources import.
for name in class-registry instance-registry; do
  EAGER_STARS="$(grep -E "^export \* from" "$PC/$name/index.js" | LC_ALL=C sort)"
  LAZY_STARS="$(grep -E "^export \* from" "$PC/$name/lazy.js" | LC_ALL=C sort)"
  assert_ge "…$name/index.js re-exports at least one event module" 1 \
    "$(printf '%s\n' "$EAGER_STARS" | grep -c .)"
  assert_eq "…and $name/lazy.js re-exports exactly the same ones" "$EAGER_STARS" "$LAZY_STARS"
done

echo "== 2. …and the two symbols this runtime imports from them survive the redirect"

# Read out of the BUILT bundle rather than out of the package: these are the names
# `resident_contracts_db.ts` and the vendored `public_db_sources.ts` import.
BUNDLE="$(cat "$BROWSER_DIST"/chunks/*.js "$BROWSER_DIST"/browser.js)"
assert_true "ContractClassPublishedEvent survived into the bundle" \
  str_has_sub "$BUNDLE" 'ContractClassPublishedEvent'
assert_true "…and ContractInstancePublishedEvent" str_has_sub "$BUNDLE" 'ContractInstancePublishedEvent'

echo "== 3. our fee-juice shim is one-for-one with the barrel it replaces, minus the eager constant"

SHIM="$BROWSER_SRC/shims/protocol_fee_juice.ts"
assert_file "the fee-juice shim exists" "$SHIM"
assert_true "…and is tracked" git -C "$REPO_ROOT" ls-files --error-unmatch "browser/src/shims/protocol_fee_juice.ts"

SHIM_TEXT="$(cat "$SHIM")"
BARREL="$(cat "$PC/fee-juice/index.js")"

# THE TWO HELPERS THIS RUNTIME ACTUALLY IMPORTS. Named exactly, in both files.
# The needle is the DECLARATION SITE, not the `export function` spelling: upstream declares one of
# the two `async` and the other not, and a needle that assumed one spelling would have gone red for
# a reason with nothing to do with its subject.
for fn in computeFeePayerBalanceStorageSlot computeFeePayerBalanceLeafSlot; do
  assert_true "upstream's barrel declares $fn(feePayer)" str_has_sub "$BARREL" "$fn(feePayer)"
  assert_true "…and the shim exports it too" str_has_sub "$SHIM_TEXT" "export async function $fn"
done

# THE BODIES, LINE BY LINE rather than by shape. Upstream's storage-slot derivation is
# `deriveStorageSlotInMap(<artifact>.storageLayout.balances.slot, feePayer)`; the shim's differs
# only in where the artifact comes from. The LEAF slot line must be upstream's exactly.
assert_true "upstream derives the storage slot from storageLayout.balances.slot" \
  str_has_sub "$BARREL" 'deriveStorageSlotInMap(FeeJuiceArtifact.storageLayout.balances.slot, feePayer)'
assert_true "…and the shim derives it from the same field of the LAZY artifact" \
  str_has_sub "$SHIM_TEXT" 'deriveStorageSlotInMap(artifact.storageLayout.balances.slot, feePayer)'
assert_true "upstream computes the leaf slot from ProtocolContractAddress.FeeJuice" \
  str_has_sub "$BARREL" 'computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, balanceSlot)'
assert_true "…and the shim's line is upstream's, unchanged" \
  str_has_sub "$SHIM_TEXT" 'computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, balanceSlot)'
# ===========================================================================================
# AND THE FOUR ASSERTIONS ABOVE ARE CONTAINMENT, NOT A PIN — WHICH IS THE DEFECT THIS BLOCK CLOSES.
# ===========================================================================================
#
# `str_has_sub` says a line is PRESENT. It says nothing about what else is present, how many times
# it is present, or in what order. Measured by M27's review, three mutations of this shim, each
# reported by this check as **61 assertions, 0 failures, exit 0**:
#
#   * the storage-slot line REPEATED TWENTY TIMES  (M26's review's exact shape);
#   * the leaf-slot body's TWO ADJACENT LINES SWAPPED;
#   * one inserted line, `feePayer = ProtocolContractAddress.FeeJuice;`, immediately above the
#     pinned derivation — which is a REAL corruption: under it the fee payer is funded at a leaf
#     slot nobody reads and `smoke_browser_token_transfer` goes from `processed` to **failed**,
#     exactly the four-layers-away failure this file's own header predicts.
#
# The milestone says this check pins the shim "line by line" and that it stands in for `check-drift`,
# which cannot own the file because the file DELIBERATELY differs from what it replaces. A pin that
# a real corruption walks through is not a pin, and "it deliberately differs so we pinned it
# differently" is the shape of an exclusion that hides a defect. So the bodies are compared as
# ORDERED LISTS OF LINES against an expectation DERIVED FROM UPSTREAM'S BARREL — not typed in here —
# by applying the two declared substitutions and nothing else. Upstream drifting therefore moves the
# expectation, which a typed literal would not.
BODIES="$(python3 - "$SHIM" "$PC/fee-juice/index.js" <<'PY'
import json, re, sys

def body(text, fn):
    """The lines between `function <fn>(` and the closing brace at column 0, indentation stripped."""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if re.search(r"function %s\(" % re.escape(fn), l)), None)
    if start is None:
        return None
    out = []
    for l in lines[start + 1:]:
        if l.startswith("}"):
            return out
        out.append(l.strip())
    return None

shim = open(sys.argv[1]).read()
barrel = open(sys.argv[2]).read()

A = "computeFeePayerBalanceStorageSlot"
B = "computeFeePayerBalanceLeafSlot"

up_a, up_b = body(barrel, A), body(barrel, B)
me_a, me_b = body(shim, A), body(shim, B)

# THE TWO DECLARED SUBSTITUTIONS, and there are exactly two. The artifact is fetched rather than
# imported eagerly, so the shim adds one line and rewrites the eager constant's name to the local.
want_a = None if up_a is None else ["const artifact = await getFeeJuiceArtifact();"] + [
    l.replace("FeeJuiceArtifact.", "artifact.") for l in up_a
]
want_b = up_b

for key, value in (("UP-A", up_a), ("UP-B", up_b),
                   ("WANT-A", want_a), ("WANT-B", want_b),
                   ("GOT-A", me_a), ("GOT-B", me_b)):
    print("%s\t%s" % (key, json.dumps(value)))
PY
)"
bodyline() { printf '%s\n' "$BODIES" | sed -n "s/^$1\t//p"; }

# NON-EMPTINESS FIRST, both sides, because two `null`s compare equal and an extractor that found
# nothing would otherwise report agreement. `CAMPAIGN-BRIEF.md`: "any comparison whose sides could
# both be absent needs a non-emptiness assertion beside it."
assert_ge "upstream's storage-slot body was extracted" 1 \
  "$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(0 if v is None else len(v))' "$(bodyline UP-A)")"
assert_ge "…and its leaf-slot body" 2 \
  "$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(0 if v is None else len(v))' "$(bodyline UP-B)")"
assert_ge "…and the shim's storage-slot body" 2 \
  "$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(0 if v is None else len(v))' "$(bodyline GOT-A)")"
assert_ge "…and the shim's leaf-slot body" 2 \
  "$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(0 if v is None else len(v))' "$(bodyline GOT-B)")"

assert_eq "the shim's storage-slot body is upstream's, line for line, with the artifact awaited" \
  "$(bodyline WANT-A)" "$(bodyline GOT-A)"
assert_eq "…and its leaf-slot body is upstream's, line for line, UNCHANGED" \
  "$(bodyline WANT-B)" "$(bodyline GOT-B)"

# THE ONE DELIBERATE OMISSION, asserted so it is a decision rather than an oversight.
assert_true "upstream's barrel exports the EAGER FeeJuiceArtifact constant" \
  str_has_sub "$BARREL" 'export const FeeJuiceArtifact'
assert_false "…and the shim does not, because it cannot exist without the eager import" \
  str_has_sub "$SHIM_TEXT" 'export const FeeJuiceArtifact'
# …AND NOTHING IN THIS RUNTIME NAMES IT, which is what makes the omission safe.
#
# `browser/src` IS IN THE MEASURED SET, minus the shim itself. It was not, and the shim's own header
# says it was — so the absence was asked of a tree from which the shipped BROWSER sources were
# missing entirely, which is `CAMPAIGN-BRIEF.md`'s "an absence asked of a tree that excludes the
# subject by construction" in its mildest form. The residue is PRINTED rather than counted.
NAMERS="$(cd "$REPO_ROOT" && grep -rl 'FeeJuiceArtifact' browser/src orchestration/src node-host/src ct-host/src 2>/dev/null \
  | grep -v '^browser/src/shims/protocol_fee_juice.ts$' || true)"
note "shipped sources naming FeeJuiceArtifact, other than the shim: ${NAMERS:-(none)}"
assert_eq "no shipped source names FeeJuiceArtifact" "0" "$(printf '%s\n' "$NAMERS" | grep -c . || true)"
# THE CONTROL for that zero: the same grep over a file that DOES name it.
assert_ge "…while the same grep finds it where it IS named" 1 \
  "$(grep -c 'FeeJuiceArtifact' "$SHIM" || true)"

echo "== 4. THE ARTIFACTS ARE LAZY IN THE BUILD — edge KINDS, not chunk names"

# THE EDGE KINDS ARE READ ON THE INPUT GRAPH, not on the output graph, and the difference matters.
# An OUTPUT's `imports` list records which chunk loads which chunk, and a chunk that nothing in this
# entry set reaches has no entry there at all — which is a true fact about the two registries and
# reads exactly like "no dynamic import". The INPUT graph records the kind of every module-level
# edge, which is the property DD-11 is about: `import(...)` versus `import ... from`.
EDGES="$(python3 - "$BROWSER_DIST/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
targets = ("artifacts/FeeJuice.json", "artifacts/ContractClassRegistry.json",
           "artifacts/ContractInstanceRegistry.json",
           "fetch_code/browser/barretenberg.js", "fetch_code/browser/barretenberg-threads.js")
for path, node in m["inputs"].items():
    for imp in node.get("imports", []):
        for t in targets:
            if imp["path"].endswith(t):
                print("%s\t%s\t%s" % (t.split("/")[-1], imp["kind"], path.split("/")[-1]))
PY
)"
note "$(printf '%s\n' "$EDGES" | grep -c .) edge(s) reach a lazy artefact"
assert_ge "the classifier found the edges it is about" 5 "$(printf '%s\n' "$EDGES" | grep -c .)"
for t in FeeJuice.json ContractClassRegistry.json ContractInstanceRegistry.json \
         barretenberg.js barretenberg-threads.js; do
  KINDS="$(printf '%s\n' "$EDGES" | awk -F'\t' -v t="$t" '$1==t {print $2}' | LC_ALL=C sort -u | tr '\n' ' ')"
  IMPORTERS="$(printf '%s\n' "$EDGES" | awk -F'\t' -v t="$t" '$1==t {print $3}' | LC_ALL=C sort -u | tr '\n' ' ')"
  note "$t is reached by: ${KINDS:-(no edge)} from ${IMPORTERS:-(nobody)}"
  assert_true "$t is reached by a dynamic-import edge" str_has_sub "$KINDS" 'dynamic-import'
  assert_false "…and by NO import-statement edge" str_has_sub "$KINDS" 'import-statement'
  assert_false "…and by no require-call either" str_has_sub "$KINDS" 'require-call'
done
# AND EACH IS ITS OWN OUTPUT CHUNK, which is what makes the laziness observable over the network.
LAZY_CHUNKS="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("\n".join(r["file"] for r in c["files"]))' "$BROWSER_DIST/chunks.json")"
for t in FeeJuice ContractClassRegistry ContractInstanceRegistry barretenberg; do
  assert_true "…and $t is emitted as its own chunk" str_has_line_re "$LAZY_CHUNKS" "^chunks/$t"
done

echo "== 5. …and the sizes that makes lazy worth doing"

SIZES="$(python3 - "$BROWSER_DIST/chunks.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
for row in c["files"]:
    print("%s\t%d" % (row["file"], row["gzipBytes"]))
PY
)"
CCR="$(printf '%s\n' "$SIZES" | awk -F'\t' '$1 ~ /^chunks\/ContractClassRegistry-/ {print $2}')"
FJ="$(printf '%s\n' "$SIZES" | awk -F'\t' '$1 ~ /^chunks\/FeeJuice-/ {print $2}')"
CIR="$(printf '%s\n' "$SIZES" | awk -F'\t' '$1 ~ /^chunks\/ContractInstanceRegistry-/ {print $2}')"
note "lazy artifact chunks, gzipped: ContractClassRegistry $CCR, FeeJuice $FJ, ContractInstanceRegistry $CIR"
assert_ge "the class registry artifact is a large chunk" 300000 "${CCR:-0}"
assert_ge "…the fee-juice artifact too" 100000 "${FJ:-0}"
assert_ge "…and the instance registry" 50000 "${CIR:-0}"
# NONE of them is in an eager set. The three sizes above are what the browser entry does NOT pay.
EAGER="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print("\n".join(f for r in c["eager"] for f in r["files"]))' "$BROWSER_DIST/chunks.json")"
for t in FeeJuice ContractClassRegistry ContractInstanceRegistry; do
  assert_false "$t is in NO entry point's eager set" str_has_sub "$EAGER" "$t"
done

m27_finish
