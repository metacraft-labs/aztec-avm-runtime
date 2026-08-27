#!/usr/bin/env bash
# verify_browser_bundle_builds
#
# M27 verification: "the browser entry point bundles for esm and es2022 with the runtime's full
# execution surface, including block assembly".
#
# THREE THINGS, AND THE THIRD IS THE ONE THAT COULD BE FAKED.
#
#   1. IT BUILDS. Asserted by building it — `m27_require_bundle` runs `browser/build.mjs` whenever
#      an input is newer than the metafile, under a bound, and a build failure is a `die` naming the
#      log. "It builds" is not a claim this check reads off a file.
#   2. THE FORMAT IS WHAT THE ENTRY SAYS. `esm`, `es2022`, `browser`, read out of the esbuild
#      metafile and the emitted bytes, not out of `build.mjs`'s source.
#   3. THE EXECUTION SURFACE IS THERE. This is the part a bundle can pass vacuously: a build that
#      emitted an empty module would satisfy (1) and (2). So the browser entry's EXPORT NAMES are
#      read out of the BUILT ARTEFACT — by importing it in Node and taking `Object.keys` — and
#      required to contain the block-assembly surface by name, together with the facade, the chain
#      and the AVM host. `CAMPAIGN-BRIEF.md` records that reading an export set out of a module
#      rather than grepping `export {` is the difference between a measurement and a source scan,
#      and `test_public_processor_never_defaults_to_cpp` already does it that way.
#
# AND THE NODE-BUILTIN ABSENCE IS MEASURED WITH A CONTROL. Zero Node builtins in the browser
# bundles is an absence, and an absence needs an instrument shown to be capable of finding one: the
# SAME scanner over the NODE bundle finds `node:fs/promises`, because that entry point genuinely
# imports it. Without that, a scanner with a typo'd needle reports the same zero.
#
# Run: just verify-browser-build

TEST_NAME="verify_browser_bundle_builds"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"

m27_require_bundle

echo "== 1. the build produced the four entry points and a metafile"

for f in browser.js testing.js demo.js node/node.js meta.json chunks.json substitution.json index.html; do
  assert_file "the build produced $f" "$BROWSER_DIST/$f"
done

# The build's own budget report. A build that failed a budget exits non-zero, so reaching here at
# all means the budgets held — but the report is read anyway, because "the build passed" and "the
# report says it passed" are different statements and only the second survives into a log.
VIOLATIONS="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["violations"]))' "$BROWSER_DIST/chunks.json")"
assert_eq "the chunk report records no budget violation" "0" "$VIOLATIONS"
UNCOVERED="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["uncovered"]))' "$BROWSER_DIST/chunks.json")"
assert_eq "…and no output file is covered by no budget" "0" "$UNCOVERED"

echo "== 2. the format is esm / es2022 / browser, read off the artefacts"

BROWSER_JS="$(cat "$BROWSER_DIST/browser.js")"
assert_true "browser.js is an ES module: it has a top-level export statement" \
  str_has_re "$BROWSER_JS" '(^|;|\n)export ?\{'
assert_false "…and no CommonJS module.exports" str_has_sub "$BROWSER_JS" 'module.exports'
# es2022 rather than a downlevel target: `??=`, `?.` and class fields survive rather than being
# transpiled to helper functions. `__publicField` is esbuild's class-field helper and appears only
# when the target is BELOW es2022.
assert_false "…and no es2022 downlevel helper (__publicField) was emitted" \
  str_has_sub "$BROWSER_JS$(cat "$BROWSER_DIST"/chunks/chunk-*.js)" '__publicField'

FORMAT="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
outs = [k for k in m["outputs"] if k.endswith("browser.js")]
print(outs[0] if outs else "MISSING")' "$BROWSER_DIST/meta.json")"
assert_true "the metafile names the browser entry output" str_has_sub "$FORMAT" 'browser.js'

echo "== 3. the EXECUTION SURFACE, read out of the built module rather than out of a source"

SURFACE="$(cd "$BROWSER_DIST" && node --input-type=module -e '
const m = await import("./browser.js");
console.log(Object.keys(m).sort().join("\n"));
' 2>&1)" || die "the built browser entry could not be imported:
$SURFACE"

N_EXPORTS="$(printf '%s\n' "$SURFACE" | grep -c .)"
note "the browser entry exports $N_EXPORTS name(s)"
assert_ge "the browser entry exports a substantial surface" 40 "$N_EXPORTS"

# BLOCK ASSEMBLY BY NAME, because the deliverable says "including block assembly" and a bundle that
# tree-shook it away would otherwise pass everything above.
for name in assembleBlock sealBlock createBlockProcessor AvmChain AvmRuntime \
            WasmAvmPublicTxSimulator ResidentMerkleWriteOperations ResidentContractsDB \
            openAvmRuntime compileAvmFromUrl instantiateAvm createBrowserWasi \
            createAvmPoseidon2 createAvmGrumpkin CtWriter recordAndDownload; do
  assert_true "the built browser entry exports $name" str_has_line "$SURFACE" "$name"
done

# THE CONTROL FOR THAT LIST: a name that is deliberately NOT exported. `PublicProcessor` is DD-9's
# subject and `index.ts` says so; if it appeared here the list above would be measuring nothing
# about what is excluded.
assert_false "…and does NOT export PublicProcessor (DD-9)" str_has_line "$SURFACE" 'PublicProcessor'
assert_false "…and exports no type named AztecNode (§8.4)" str_has_line "$SURFACE" 'AztecNode'

echo "== 4. no Node builtin in the browser bundles — with the Node bundle as the control"

# The scanner: every `import`/`require` specifier the built bundles still carry unresolved. In an
# esbuild browser build a Node builtin cannot be resolved, so an import of one either failed the
# build or appears here as a bare specifier.
BUILTINS='node:fs node:fs/promises node:path node:url node:process node:wasi node:crypto
node:child_process node:worker_threads node:net node:tty node:readline node:os node:zlib'

BROWSER_BYTES="$(cat "$BROWSER_DIST"/browser.js "$BROWSER_DIST"/testing.js "$BROWSER_DIST"/demo.js \
  "$BROWSER_DIST"/chunks/*.js)"
NODE_BYTES="$(cat "$BROWSER_DIST"/node/node.js "$BROWSER_DIST"/node/chunks/*.js 2>/dev/null)"

FOUND_BROWSER=""
FOUND_NODE=""
for b in $BUILTINS; do
  str_has_sub "$BROWSER_BYTES" "\"$b\"" && FOUND_BROWSER="$FOUND_BROWSER $b"
  str_has_sub "$BROWSER_BYTES" "'$b'" && FOUND_BROWSER="$FOUND_BROWSER $b"
  str_has_sub "$NODE_BYTES" "\"$b\"" && FOUND_NODE="$FOUND_NODE $b"
  str_has_sub "$NODE_BYTES" "'$b'" && FOUND_NODE="$FOUND_NODE $b"
done
note "browser bundles mention:${FOUND_BROWSER:- (none)}"
note "node bundle mentions:${FOUND_NODE:- (none)}"
assert_eq "the browser bundles mention no node: builtin" "" "$FOUND_BROWSER"
# THE CONTROL. Without this the line above is satisfied by a needle list that matches nothing.
assert_true "…and the SAME scanner finds node:fs/promises in the NODE bundle" \
  str_has_sub "$FOUND_NODE" 'node:fs/promises'

# `Buffer` and `process` are supplied through esbuild `inject`, so neither survives as a free
# identifier. Measured as the presence of the injection rather than as an absence of the name,
# because the name legitimately appears inside the injected shim.
assert_true "the browser bundle carries the injected buffer implementation" \
  str_has_sub "$BROWSER_BYTES" 'INSPECT_MAX_BYTES'
assert_false "…and does not reach for a bare require of buffer" str_has_sub "$BROWSER_BYTES" "require(\"buffer\")"

echo "== 5. the DD-11 redirects all fired"

SUBST="$(cat "$BROWSER_DIST/substitution.json")"
N_ZERO="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for p in d["passes"] for v in p.values() if v == 0))' "$BROWSER_DIST/substitution.json")"
assert_eq "every redirect fired in every pass" "0" "$N_ZERO"
N_TARGETS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["passes"][0]))' "$BROWSER_DIST/substitution.json")"
assert_eq "there are five declared redirects" "5" "$N_TARGETS"
assert_true "…and the poseidon module is one of them" str_has_sub "$SUBST" 'crypto/poseidon/index.js'
assert_true "…and the grumpkin module is another" str_has_sub "$SUBST" 'crypto/grumpkin/index.js'

m27_finish
