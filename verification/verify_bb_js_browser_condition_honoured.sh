#!/usr/bin/env bash
# verify_bb_js_browser_condition_honoured
#
# M27 verification: "module resolution draws from the bb.js browser build and from no node-build
# file at all", and the deliverable adds "end to end".
#
# ===========================================================================================
# CHECKED ON THE BUILT ARTEFACT, NOT ON THE CONFIGURATION.
# ===========================================================================================
#
# The configuration says `platform: 'browser'`, which sets esbuild's export conditions. That is
# intent. What is measured here is which FILES the build actually resolved — every input path under
# `@aztec/bb.js` in the esbuild metafile — plus content probes over the emitted bytes, because a
# metafile is still build metadata and the deliverable says "end to end".
#
# THE PROPERTY IS NOT AUTOMATIC AND THE PACKAGE SAYS SO. `@aztec/bb.js`'s `exports` map has THREE
# subpaths at this pin, and only ONE of them has a `browser` condition:
#
#     "."            { require: ./dest/node-cjs/index.js, browser: ./dest/browser/index.js,
#                      default: ./dest/node/index.js }
#     "./aztec-wsdb" { default: ./dest/node/aztec-wsdb/index.js }
#     "./platform"   { default: ./dest/node/bb_backends/node/platform.js }
#
# So an import of either subpath resolves into `dest/node/` whatever the platform is, and "the
# browser condition is honoured" would be true and useless. The absence of those two subpaths from
# the graph is asserted separately, by name, rather than being folded into the count.
#
# AND THE COUNT HAS A CONTROL. "Zero files from `dest/node/`" is what a metafile with no bb.js in it
# at all reports. So the number of files from `dest/browser/` is asserted NON-ZERO and the
# `dest/node/` residue is PRINTED rather than counted, which is the scanner shape
# `CAMPAIGN-BRIEF.md` asks for.
#
# Run: just verify-browser-bbjs-condition

TEST_NAME="verify_bb_js_browser_condition_honoured"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_bundle

echo "== 1. what the PACKAGE offers, read out of its own manifest"

PKG="$ORCH_DIR/node_modules/@aztec/bb.js/package.json"
assert_file "@aztec/bb.js is installed" "$PKG"
EXPORTS="$(python3 - "$PKG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k, v in d["exports"].items():
    print("%s -> %s" % (k, json.dumps(v, sort_keys=True)))
PY
)"
note "$(printf '%s' "$EXPORTS" | tr '\n' ' ')"
assert_true "its '.' subpath declares a browser condition" \
  str_has_line_re "$EXPORTS" '^\. -> .*"browser":'
assert_true "…pointing at dest/browser/index.js" str_has_sub "$EXPORTS" 'dest/browser/index.js'
assert_true "…while its 'default' is the NODE build" str_has_sub "$EXPORTS" 'dest/node/index.js'
# The two subpaths that have NO browser condition. If either ever grows one, this assertion goes red
# and the paragraph above needs rewriting — which is the point of pinning it.
assert_false "…and './aztec-wsdb' has no browser condition" \
  str_has_line_re "$EXPORTS" '^\./aztec-wsdb -> .*"browser":'
assert_false "…and './platform' has none either" \
  str_has_line_re "$EXPORTS" '^\./platform -> .*"browser":'

echo "== 2. what the BUILD resolved, read out of the metafile"

RESOLVED="$(python3 - "$BROWSER_DIST/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
browser, node, other = [], [], []
for p in m["inputs"]:
    if "@aztec/bb.js/" not in p:
        continue
    rest = p.split("@aztec/bb.js/", 1)[1]
    if rest.startswith("dest/browser/"):
        browser.append(rest)
    elif rest.startswith("dest/node/") or rest.startswith("dest/node-cjs/"):
        node.append(rest)
    else:
        other.append(rest)
print("BROWSER %d" % len(browser))
print("NODE %d" % len(node))
print("OTHER %d" % len(other))
# THE RESIDUE IS PRINTED, not counted: a scanner that reports what it cannot place turns a class
# that is too narrow into a red line instead of a silent undercount.
for r in node:
    print("NODEFILE %s" % r)
for r in other:
    print("OTHERFILE %s" % r)
PY
)"
N_BROWSER="$(printf '%s\n' "$RESOLVED" | sed -n 's/^BROWSER //p')"
N_NODE="$(printf '%s\n' "$RESOLVED" | sed -n 's/^NODE //p')"
N_OTHER="$(printf '%s\n' "$RESOLVED" | sed -n 's/^OTHER //p')"
note "bb.js files resolved: $N_BROWSER from dest/browser, $N_NODE from dest/node, $N_OTHER elsewhere"
printf '%s\n' "$RESOLVED" | sed -n 's/^NODEFILE /  --   RESIDUE node: /p'
printf '%s\n' "$RESOLVED" | sed -n 's/^OTHERFILE /  --   RESIDUE other: /p'

# THE NON-EMPTINESS IS THE CONTROL. Zero from `dest/node/` is what a metafile with no bb.js in it
# reports, and the M27 build could plausibly have removed bb.js entirely — it substitutes the two
# `@aztec/foundation` modules that CALL it. It does not, deliberately: bb.js stays in the graph so
# that this check has a subject.
assert_ge "the build resolved a substantial number of bb.js BROWSER files" 20 "$N_BROWSER"
assert_eq "…and ZERO from the node build" "0" "$N_NODE"
assert_eq "…with nothing the classifier could not place" "0" "$N_OTHER"

echo "== 3. …and the two node-only subpaths are absent BY NAME"

GRAPH="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print("\n".join(sorted(m["inputs"])))' "$BROWSER_DIST/meta.json")"
assert_false "no file from bb.js aztec-wsdb is in the graph" str_has_sub "$GRAPH" 'bb.js/dest/node/aztec-wsdb'
assert_false "…and none from its node platform locator" \
  str_has_sub "$GRAPH" 'bb.js/dest/node/bb_backends/node/platform'
# THE CONTROL FOR THOSE TWO ABSENCES: the same haystack DOES contain the browser platform locator,
# so the needle family is one that can match.
assert_true "…while the BROWSER platform locator IS in the graph" \
  str_has_sub "$GRAPH" 'bb.js/dest/browser/bb_backends/browser/platform'

echo "== 4. END TO END: the emitted bytes, not the metafile"

BYTES="$(cat "$BROWSER_DIST"/browser.js "$BROWSER_DIST"/testing.js "$BROWSER_DIST"/demo.js \
  "$BROWSER_DIST"/chunks/*.js)"
NODE_BUNDLE="$(cat "$BROWSER_DIST"/node/node.js "$BROWSER_DIST"/node/chunks/*.js 2>/dev/null)"
# `findNapiBinary` is exported from BOTH platform locators, so its presence proves nothing. What
# distinguishes them is the NODE build's use of `node:` builtins to find a `.node` addon, which the
# browser build replaces with a throw. Both spellings are probed so that "absent" is a measurement.
assert_false "the emitted bundles contain no nodejs_module.node locator string" \
  str_has_sub "$BYTES" 'nodejs_module.node'
assert_false "…and no reference to bb.js's node CJS entry" str_has_sub "$BYTES" 'node-cjs'
# THE PAIRED POSITIVE, and the marker is chosen rather than guessed: `bb_backends/*/platform.js`
# exists in BOTH builds with the same three exported names, and the browser one's bodies are
# `throw new Error('Not implemented in browser environment.')`. That string is in `dest/browser` and
# in no file of `dest/node`, so finding it says WHICH build was resolved rather than that bb.js is
# present at all.
assert_true "the BROWSER platform locator's own refusal string IS emitted" \
  str_has_sub "$BYTES" 'Not implemented in browser environment.'
assert_false "…and it is absent from the node bundle, so it discriminates" \
  str_has_sub "$NODE_BUNDLE" 'Not implemented in browser environment.'
# A second browser-only marker, so the discrimination does not rest on one string.
assert_true "…as is the browser helper's navigator.hardwareConcurrency probe" \
  str_has_sub "$BYTES" 'hardwareConcurrency'

echo "== 5. and the proving chunk is present, lazy, and never in an eager set"

CHUNKS="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print("\n".join(r["file"] for r in c["files"]))' "$BROWSER_DIST/chunks.json")"
assert_true "the barretenberg chunk was emitted" str_has_line_re "$CHUNKS" '^chunks/barretenberg-[A-Z0-9]+\.js$'
assert_true "…and its threaded sibling" str_has_line_re "$CHUNKS" '^chunks/barretenberg-threads-[A-Z0-9]+\.js$'
EAGER="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print("\n".join(f for r in c["eager"] for f in r["files"]))' "$BROWSER_DIST/chunks.json")"
assert_false "…and neither is in the eager set of ANY entry point" str_has_sub "$EAGER" 'barretenberg'
assert_ge "…while the eager sets are not empty" 10 "$(printf '%s\n' "$EAGER" | grep -c .)"

m27_finish
