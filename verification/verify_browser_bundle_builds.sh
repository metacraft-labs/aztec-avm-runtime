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
# `str_has_line_re`, NOT `str_has_re`. Bash's `=~` has no `REG_NEWLINE` and no `\n` escape, so the
# `\n` alternative in the old needle `(^|;|\n)export ?\{` was the LETTER n — a dead newline branch
# and a spurious `n` branch, confirmed directly: `nexport{a}` matched and a real newline did not.
# `lib.sh` names this trap for exactly this predicate pair.
assert_true "browser.js is an ES module: it has a top-level export statement" \
  str_has_line_re "$BROWSER_JS" '(^|;)export ?\{'
assert_false "…and no CommonJS module.exports" str_has_sub "$BROWSER_JS" 'module.exports'
# es2022 rather than a downlevel target: `??=`, `?.` and class fields survive rather than being
# transpiled to helper functions. `__publicField` is esbuild's class-field helper and appears only
# when the target is BELOW es2022.
#
# ALL THE CHUNKS, not `chunk-*.js`. The old glob missed ten of the seventeen emitted chunks —
# `barretenberg-*`, `ContractClassRegistry-*`, `FeeJuice-*`, `secp256k1-*` and the rest — which is a
# scanner narrowed in the direction that reads as good news.
ALL_BROWSER_JS="$BROWSER_JS$(cat "$BROWSER_DIST"/chunks/*.js)"
assert_ge "…and the scanner had something to scan" 1000000 "${#ALL_BROWSER_JS}"
assert_false "…and no es2022 downlevel helper (__publicField) was emitted" \
  str_has_sub "$ALL_BROWSER_JS" '__publicField'

# ===========================================================================================
# THE FORMAT AND THE TARGET, READ OFF SOMETHING THAT COULD SAY OTHERWISE.
# ===========================================================================================
#
# What stood here was `outs = [k for k in m["outputs"] if k.endswith("browser.js")]` followed by
# `str_has_sub "$FORMAT" 'browser.js'` — a needle whose haystack is a set FILTERED BY THAT NEEDLE.
# Its only failure mode was the output going missing entirely, and neither `esm`, nor `es2022`, nor
# `browser` was read from the metafile anywhere in this check, while the section's heading said all
# three. Setting `target: 'esnext'` in the driver passed it.
OUT_FACTS="$(python3 - "$BROWSER_DIST/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
out = next((v for k, v in m["outputs"].items() if k.endswith("/browser.js")), None)
if out is None:
    print("ENTRYPOINT\tMISSING"); print("NEXPORTS\t0"); raise SystemExit(0)
print("ENTRYPOINT\t%s" % out.get("entryPoint", "MISSING"))
# esbuild records an `exports` list for an ESM output and omits it for a CJS one, so this is the
# format read off the artefact rather than off the flag that produced it.
print("NEXPORTS\t%d" % len(out.get("exports", [])))
PY
)"
outfact() { printf '%s\n' "$OUT_FACTS" | sed -n "s/^$1\t//p"; }
assert_eq "the metafile joins browser.js to the DD-5 reference entry source" \
  "browser/src/entry_browser.ts" "$(outfact ENTRYPOINT)"
assert_ge "…and records an ESM export list for it, which a CJS output would not have" 40 \
  "$(outfact NEXPORTS)"
# The two flags themselves are pinned at their declaration site, because nothing in an artefact
# distinguishes es2022 from esnext for this input — the `__publicField` absence above is consistent
# with both. Stating where the claim comes from is the point; `CAMPAIGN-BRIEF.md`'s rule is that a
# figure nobody re-derives rots, not that every figure must be derivable from bytes.
DRIVER="$(cat "$BROWSER_DIR/esbuild-driver.mjs")"
assert_ge "the esbuild driver was read" 100 "$(printf '%s\n' "$DRIVER" | grep -c .)"
assert_true "…and it declares format: 'esm'" str_has_line_re "$DRIVER" "^ *format: 'esm',$"
assert_true "…and target: 'es2022'" str_has_line_re "$DRIVER" "^ *target: 'es2022',$"
assert_true "…and platform: 'browser' for the browser pass" str_has_line_re "$DRIVER" "^ *platform: 'browser',$"

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
# The TYPE half of §8.4 is verify_browser_entry_points_are_dd5_shaped §6b: a TypeScript type is not
# in `Object.keys` of a built bundle, so this assertion can only catch a VALUE by that name.
assert_false "…and exports no VALUE named AztecNode (§8.4)" str_has_line "$SURFACE" 'AztecNode'

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

echo "== 6. NO BROWSER-AUTOMATION PACKAGE ENTERED THE DEPENDENCY TREE"

# ===========================================================================================
# THE MILESTONE CLAIMS THIS IN THREE COMMENTS AND NOTHING MEASURED IT.
# ===========================================================================================
#
# "There is no puppeteer and no playwright: Node 24's global `WebSocket` speaks CDP directly." It is
# TRUE — measured by M27's review — and it was stated in `Justfile`, in `tools/browser_cdp.mjs` and
# in the milestone, and asserted nowhere, which is `CAMPAIGN-BRIEF.md`'s "bind claims to data, or
# expect them to rot". It matters beyond tidiness: M28 is the browser CI gate and its subject is
# what a checkout has to install, and a browser-automation package brings a browser DOWNLOAD with it.
#
# TWO TREES, because either alone is an absence asked of something that cannot answer: every tracked
# `package.json`'s four dependency fields — what a fresh checkout would install — AND the installed
# tree `browser/node_modules` symlinks to, which is what this run actually resolved against.
DEPSCAN="$(cd "$REPO_ROOT" && git ls-files '*package.json' | grep -v node_modules \
  | xargs python3 "$VERIFY_DIR/_m27_depscan.py")"
depscan() { printf '%s\n' "$DEPSCAN" | sed -n "s/^$1\t//p"; }
note "package.json files scanned: $(depscan FILES); automation hits: $(depscan AUTOMATION)"
assert_ge "the dependency scan read every tracked package.json" 5 "$(depscan FILES)"
assert_eq "no tracked package.json declares a browser-automation package" "" "$(depscan AUTOMATION)"
# THE CONTROL FOR THAT ZERO, same instrument, same files: a package that IS declared must be found,
# so a scan that silently stopped reading fails here instead of reporting a clean tree.
assert_true "…while the same scan DOES find esbuild, which is declared" \
  str_has_sub "$(depscan CONTROL)" 'esbuild'

# AND THE INSTALLED TREE. `browser/node_modules` is a symlink to the orchestration's, so this is the
# tree the demo page, the arm runner and every check here resolved against.
INSTALLED_AUTOMATION="$(ls "$ORCH_DIR/node_modules" 2>/dev/null \
  | grep -iE '^(puppeteer|playwright|selenium|webdriverio|chromedriver|chrome-launcher|chrome-remote-interface)' || true)"
INSTALLED_TOTAL="$(ls "$ORCH_DIR/node_modules" 2>/dev/null | grep -c . || true)"
note "installed packages: $INSTALLED_TOTAL; automation: ${INSTALLED_AUTOMATION:- (none)}"
assert_ge "the installed tree is populated, so the zero below is not an empty directory" 100 \
  "$INSTALLED_TOTAL"
assert_eq "…and no browser-automation package is installed in it" "" "$INSTALLED_AUTOMATION"

# The driver that stands in for them is one tracked file with no dependency: every `import` in it
# resolves to a Node builtin or to a relative path.
assert_file "the CDP driver that replaces them is tracked" "$REPO_ROOT/tools/browser_cdp.mjs"
BARE_IMPORTS="$(grep -oE "^import [^;]*from '[^.'][^']*'" "$REPO_ROOT/tools/browser_cdp.mjs" \
  | grep -oE "'[^']*'$" | tr -d "'" | grep -v '^node:' || true)"
note "non-builtin bare imports in browser_cdp.mjs: ${BARE_IMPORTS:- (none)}"
assert_eq "…and it imports no npm package, only node: builtins and relative paths" "" "$BARE_IMPORTS"

m27_finish
