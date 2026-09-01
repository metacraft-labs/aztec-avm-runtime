#!/usr/bin/env bash
#
# e2e_aztec_contract_compiles_in_browser.sh
#
# THE CLAIM: a real Aztec contract compiles in a browser tab, against the compiler
# `ide.codetracer.com` serves, out of a virtual filesystem the page holds in memory.
#
# ==============================================================================================
# WHAT MADE THIS POSSIBLE, AND WHY THE CHECK HAS THREE ARMS RATHER THAN ONE.
# ==============================================================================================
#
# The deployed compiler already RECOGNISES a `type = "contract"` package. What it could not do
# was find `aztec-nr`, because aztec-nr and `protocol_types` each declare two of their
# dependencies as GIT dependencies, and `compiler/wasm/src/vfs.rs:537-548` refuses those by name:
#
#     kind: "git-dependency-refused"
#     "…A virtual filesystem cannot fetch it. Vendor it into the tree and depend on it by
#      `path`, or resolve it before you build the tree."
#
# `tools/vendor_noir_tree.py` does exactly that remedy. This check measures that it is what made
# the difference, which one green compile cannot:
#
#   before   a `type = "contract"` package with no aztec-nr at all. The compiler recognises the
#            contract and refuses with a POSITIONED diagnostic naming `#[public]`. So the
#            contract path was never the blocker.
#   refused  the vendored tree with ONE manifest — aztec-nr's — put back the way upstream wrote
#            it, git dependencies and all. `kind: "git-dependency-refused"`, positioned at the
#            offending line of the manifest.
#   after    the vendored tree. A contract artifact.
#
# Without `refused`, a green `after` is equally consistent with the git rewrite having been
# unnecessary; without `before`, it is equally consistent with the contract path having been the
# thing that changed. Both are arms this campaign has been wrong about before.
#
# THE MODULE IS THE DEPLOYED ONE, AND THAT IS MEASURED RATHER THAN LABELLED. The page fetches
# `https://ide.codetracer.com/assets/noir_wasm.wasm` cross-origin; this check asserts its byte
# count and its sha256 against the same URL fetched independently by `curl`, and asserts the
# browser's OWN network log contains that request. A local `.wasm` would be a check about a file
# on this machine.
#
# THE COMPILE HAPPENS INSIDE WEBASSEMBLY, AND THAT IS COUNTED. Every import the module declares
# is satisfied by a function that records the call and then throws (`m30/page/wasm_host.mjs`).
# The module declares 28 of them — `wasm-bindgen` links them whether or not the bare `nv_*` path
# reaches them — and this check asserts that the DECLARED count is non-zero and the REACHED list
# is empty. An empty list from a module that declared nothing would say nothing.
#
# ==============================================================================================
# WHERE THIS TREE SHOULD LIVE IN THE PRODUCT, AND WHY IT IS LAZY.
# ==============================================================================================
#
# Measured by this check on every run, out of `vfs.json` and its sidecar:
#
#     9 packages, 420 files, 4,278,171 source bytes, 4,386,545 JSON bytes,
#     1,373,755 bytes gzipped
#
# THAT IS NOT 481 KB, and the difference is the whole subject. A count taken over aztec-nr and
# protocol-types alone comes to ~2.24 MB — but such a tree does not compile, because it is
# exactly the two GIT dependencies (`noir-lang/sha256` and `noir-lang/poseidon`, v0.3.0) that
# the refusal is about, and `poseidon` alone is 1,936,350 bytes of constant tables. A figure
# that omits the dependencies whose absence is the blocker is a figure for a tree that still
# does not work.
#
# THE PLACEMENT, in the product's own terms (`src/frontend/viewmodel/platform/web_deployment.nim`):
#
#   * A NINTH `RuntimeAsset` in `webRuntimeAssets()`, `mode: damFetched, required: false`, with
#     an `absenceBehaviour` sentence — the same slot and the same mode the two `.wasm` modules
#     already occupy. That is not a new mechanism: `/assets/*` already carries the immutable
#     cache class, `web_deploy_guard.nim` already fails when the document declares an asset the
#     tree lacks OR the tree carries one nothing references, and the deploy workflow already
#     re-fetches and size-checks every placed asset.
#   * GENERATED FROM A PIN, NOT COMMITTED. `ci/deploy/noir-wasm.pin` already names
#     `NOIR_REPO/NOIR_REF/NOIR_REV`; an `AZTEC_PACKAGES_REV` line beside it is the whole change.
#     Committing 4.3 MB of a third party's sources into the product's repository would put a
#     vendored copy on a drift path with no pin, which is the failure this campaign has a whole
#     document about.
#   * LAZY, fetched when a `type = "contract"` package is first built. Every non-contract Noir
#     program compiles without one byte of it — M30's own arms are the measurement — so an
#     eager 1.34 MB would be paid by every session for a capability most never use, beside a
#     compiler that is itself 14.7 MB and itself lazy.
#
# THE COST OF LAZY, NAMED RATHER THAN WAVED THROUGH: one new egress site.
# `ci/test/noir-studio-signed-out.sh` counts `fetch(`-shaped call sites per named surface, with
# `EGRESS_EXPECTED_TOTAL=13` and `LOOP_ARM_EGRESS_EXPECTED=0`. So the budget array and the total
# must be edited, and the fetch must not land in the development-loop surface. That is a
# declared change to a gate, which is the point of the gate.
#
# THE ALTERNATIVE IS REJECTED ON A MEASUREMENT, not on the usual folklore. "Compile it into
# `ui.js` as Nim constants" is the `noir_template.nim` pattern and it does NOT blow up the way
# the folk rule says: `nim js -d:release` (Nim 2.2.8, the dev shell's) emits a `staticRead`
# string constant as `makeNimstrLit("…")` — a real JS string literal, not a byte array. Measured
# on a 202,582-byte slice of this very tree: 234,302 bytes of JS, 52,430 gzipped against the
# slice's own 47,571. So the expansion is ~1.1x and that is not the objection. The objection is
# that `ui.js` is `damBundled, required: true`: every byte of it is fetched by every page load,
# including the ones that never open a contract.
#
# ==============================================================================================
# CONTRACT AND DEBUG ARE MUTUALLY EXCLUSIVE, AND WHAT THAT COSTS — MEASURED ON THIS MODULE.
# ==============================================================================================
#
# `compile_vfs.rs:135-141` derives two independent booleans from ONE mode string:
#
#     let as_contract   = request.mode == "contract";
#     let for_debugging = request.mode == "debug";
#
# and `vfs::compile_resolved(plan, files, as_contract, for_debugging)` takes them as independent
# parameters. So the exclusivity is in the DISPATCHER, not in the compiler underneath it: there
# is simply no spelling that produces `(true, true)`.
#
# The consequence is worse than "two compiles". Driven over this very tree, on the deployed
# module (`tools/`-free, one Node process, the same import-counting host):
#
#     mode "resolve"          ok=true       22 ms   a plan, no artifact
#     mode "contract"         ok=true   22,842 ms   a contract artifact, 27 functions
#     mode "debug"            ok=FALSE   3,338 ms   "cannot compile crate into a program as it
#                                                    does not contain a `main` function"
#     mode "contract-debug"   ok=FALSE   3,408 ms   ditto — an UNKNOWN mode silently degrades to
#                                                    `program` rather than being refused
#     mode "program"          ok=FALSE   3,356 ms   ditto
#
# So a contract cannot be made steppable by the deployed compiler AT ALL — not in two compiles,
# not in ten. `debug` is `compile_main` and a contract crate has no `main`. Debugging a contract
# needs a change in `noir/compiler/wasm`, and the change is small: two lines in the dispatcher to
# make `as_contract` and `for_debugging` independently settable, plus a rebuild and a pin bump
# in `ci/deploy/noir-wasm.pin` (the deploy workflow already builds the module from that pin).
# What is NOT established here, and must not be assumed, is whether `compile_contract` under
# `instrument_debug: true, force_brillig: true` yields an artifact the tracer can step: that is
# read in source only and needs a build to answer.
#
# The unknown-mode fallthrough is a second, smaller defect worth naming: a host that asks for a
# mode this module does not know gets a `program` compile and a diagnostic pointing at
# `std/aes128.nr:1:1`, rather than a refusal naming the mode.
#
# Run: just verify-aztec-contract-in-browser

set -uo pipefail
TEST_NAME="e2e_aztec_contract_compiles_in_browser"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# `lib_m27_browser.sh` builds its export list on `lib_m23_chain.sh`, and only
# `m27_require_chromium` is wanted here; the order is the one `ci_browser_gate.sh` uses.
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
m27_require_chromium

WORK="${AZTEC_CONTRACT_WORK:-$HOME/.cache/aztec-contract-in-browser}"
mkdir -p "$WORK"

# ----------------------------------------------------------------------------------------------
# 1. The sources. Two trees on disk, named rather than searched for.
# ----------------------------------------------------------------------------------------------
echo "== 1. the sources the tree is vendored from"

AZTEC_PACKAGES="${AZTEC_PACKAGES:-$(cd "$REPO_ROOT/.." && pwd)/aztec-packages}"
CONTRACT_DIR="${AZTEC_CONTRACT_DIR:-$AZTEC_PACKAGES/noir-projects/labs/noir-contracts/contracts/app/simple_token_contract}"
GIT_DEPS_ROOT="${AZTEC_GIT_DEPS_ROOT:-$HOME/.cache/aztec-vendor-noirlibs}"

assert_dir "the aztec-packages fork is beside this repository" "$AZTEC_PACKAGES"
assert_file "the entry contract declares a manifest" "$CONTRACT_DIR/Nargo.toml"
assert_true "…and it is a type = \"contract\" package, which is the whole subject" \
  grep -qx 'type = "contract"' "$CONTRACT_DIR/Nargo.toml"

# THE TWO GIT DEPENDENCIES, MATERIALISED ONCE. The vendoring script never reaches the network —
# a vendoring step whose output depends on when it ran is not a vendoring step — so the clones
# are made here, at the tag the manifests name, and their revisions are recorded.
for repo in sha256 poseidon; do
  if [ ! -f "$GIT_DEPS_ROOT/$repo/Nargo.toml" ]; then
    note "cloning noir-lang/$repo at v0.3.0 into $GIT_DEPS_ROOT"
    mkdir -p "$GIT_DEPS_ROOT"
    git clone --quiet --depth 1 --branch v0.3.0 \
      "https://github.com/noir-lang/$repo" "$GIT_DEPS_ROOT/$repo" \
      || die "could not clone noir-lang/$repo at v0.3.0"
  fi
  assert_file "noir-lang/$repo is materialised" "$GIT_DEPS_ROOT/$repo/Nargo.toml"
done

# The manifests upstream wrote, asserted to still declare `git` — because the `refused` arm below
# restores one of them, and an arm whose premise has been removed by other work reports
# "could not be measured" forever while looking like coverage.
AZTEC_NR_MANIFEST="$AZTEC_PACKAGES/noir-projects/labs/aztec-nr/aztec/Nargo.toml"
TYPES_MANIFEST="$AZTEC_PACKAGES/noir-projects/fnd/noir-protocol-circuits/crates/types/Nargo.toml"
assert_file "aztec-nr's own manifest is where the vendoring reads it" "$AZTEC_NR_MANIFEST"
assert_eq "aztec-nr declares exactly two git dependencies, which is what makes this necessary" \
  "2" "$(grep -cE '^[a-z0-9_]+ *= *\{[^}]*git *=' "$AZTEC_NR_MANIFEST" || true)"
assert_eq "…and protocol_types declares the same two" \
  "2" "$(grep -cE '^[a-z0-9_]+ *= *\{[^}]*git *=' "$TYPES_MANIFEST" || true)"

# ----------------------------------------------------------------------------------------------
# 2. The vendoring, and what it produced.
# ----------------------------------------------------------------------------------------------
echo "== 2. the vendored tree"

rm -f "$WORK/vfs.json" "$WORK/vfs.json.manifest.json"
python3 "$REPO_ROOT/tools/vendor_noir_tree.py" \
  --entry "$CONTRACT_DIR" \
  --roots "$GIT_DEPS_ROOT" \
  --out "$WORK/vfs.json" >"$WORK/vendor.log" 2>&1 \
  || die "vendoring failed; see $WORK/vendor.log"
assert_file "the vendored tree was written" "$WORK/vfs.json"
assert_file "…with a sidecar recording where every package came from" "$WORK/vfs.json.manifest.json"

VENDOR_FACTS="$(python3 - "$WORK/vfs.json" "$WORK/vfs.json.manifest.json" <<'PY'
import gzip
import json
import re
import sys

vfs = json.load(open(sys.argv[1], encoding="utf-8"))
side = json.load(open(sys.argv[2], encoding="utf-8"))
raw = open(sys.argv[1], "rb").read()
manifests = sorted(p for p in vfs if p.endswith("Nargo.toml"))
print("files %d" % len(vfs))
print("manifests %d" % len(manifests))
print("packages %d" % side["packages"])
print("source_bytes %d" % side["source_bytes"])
print("json_bytes %d" % len(raw))
print("gzip_bytes %d" % len(gzip.compress(raw, 9)))
# THE POST-CONDITION, re-derived here rather than trusted from the script that wrote it.
surviving = [p for p in manifests if re.search(r"^\s*[^#\n]*\bgit\s*=", vfs[p], re.M)]
print("manifests_still_git %s" % (",".join(surviving) or "-"))
print("path_deps %d" % sum(len(re.findall(r"\bpath\s*=", vfs[p])) for p in manifests))
PY
)"
printf '%s\n' "$VENDOR_FACTS" | sed 's/^/    /'
vf() { printf '%s\n' "$VENDOR_FACTS" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }

assert_eq "the tree holds one manifest per package" "$(vf packages)" "$(vf manifests)"
assert_ge "…and it is a real closure rather than one package" 9 "$(vf packages)"
assert_ge "…carrying the sources of all of them" 400 "$(vf files)"
assert_ge "…which is megabytes of Noir, not a stub" 4000000 "$(vf source_bytes)"
# THE WHOLE POINT, ASSERTED ON THE ARTEFACT: no manifest in the emitted tree carries `git =`.
assert_eq "no manifest in the vendored tree still declares a git dependency" "-" \
  "$(vf manifests_still_git)"
assert_ge "…while every manifest's dependencies are paths, and there are some" 8 "$(vf path_deps)"

# ----------------------------------------------------------------------------------------------
# 3. The module the page will drive, fetched here too, so the page's copy has a control.
# ----------------------------------------------------------------------------------------------
echo "== 3. the deployed compiler"

MODULE_URL="${AZTEC_NOIR_WASM_URL:-https://ide.codetracer.com/assets/noir_wasm.wasm}"
if [ ! -s "$WORK/noir_wasm.wasm" ]; then
  note "fetching $MODULE_URL"
  curl -fsS -o "$WORK/noir_wasm.wasm" "$MODULE_URL" || die "could not fetch $MODULE_URL"
fi
CURL_BYTES="$(wc -c <"$WORK/noir_wasm.wasm" | tr -d ' ')"
CURL_SHA="$(shasum -a 256 "$WORK/noir_wasm.wasm" | awk '{print $1}')"
note "curl: $CURL_BYTES bytes, sha256 $CURL_SHA"
assert_ge "the deployed module is the multi-megabyte compiler and not an error page" \
  10000000 "$CURL_BYTES"
# The deployment's OWN descriptor is the third party to this: the page ide.codetracer.com serves
# declares the module's byte count and the noir revision it was built from. Read out of the
# document rather than assumed, so a redeploy is a failure here rather than a silent drift.
curl -fsS "${AZTEC_IDE_ORIGIN:-https://ide.codetracer.com}/noir/" -o "$WORK/ide.html" \
  || die "could not fetch the deployment's entry document"
DESCRIBED="$(python3 - "$WORK/ide.html" <<'PY'
import json
import re
import sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'id="codetracer-deployment"[^>]*>(.*?)</script>', html, re.S)
if not m:
    raise SystemExit("no deployment descriptor in the document")
d = json.loads(m.group(1))
mod = [x for x in d["modules"] if x["id"] == "noir-compiler"][0]
print("bytes %d" % mod["bytes"])
print("url %s" % mod["url"])
print("builtFrom %s" % mod["builtFrom"])
print("revision %s" % d["revision"])
PY
)"
printf '%s\n' "$DESCRIBED" | sed 's/^/    /'
df() { printf '%s\n' "$DESCRIBED" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }
assert_eq "the bytes curl fetched are the bytes the deployment says it placed" \
  "$(df bytes)" "$CURL_BYTES"
assert_eq "…at the path the deployment names" "/assets/noir_wasm.wasm" "$(df url)"
assert_true "…and it was built from the noir fork's codetracer branch" \
  str_has_sub "$(df builtFrom)" "noir@codetracer"

# ----------------------------------------------------------------------------------------------
# 4. The page.
# ----------------------------------------------------------------------------------------------
echo "== 4. the browser arms"

python3 - "$WORK/fixture.js" "$MODULE_URL" "$AZTEC_NR_MANIFEST" <<'PY'
import json
import sys
out, module_url, upstream_manifest = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(upstream_manifest, encoding="utf-8").read()
lines = [
    "window.__MODULE_URL__ = %s;" % json.dumps(module_url),
    'window.__VFS_URL__ = "./vfs.json";',
    'window.__PACKAGE_DIR__ = "contract";',
    'window.__GIT_MANIFEST_PATH__ = "vendor/noir_aztec/Nargo.toml";',
    "window.__GIT_MANIFEST_TEXT__ = %s;" % json.dumps(text),
]
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
assert_file "the page's fixture was written" "$WORK/fixture.js"
assert_true "…and the restored manifest it carries really does declare a git dependency" \
  grep -q 'git = ' "$WORK/fixture.js"

rm -f "$WORK/arms.json"
M27_CHROMIUM="$M27_CHROMIUM" node "$REPO_ROOT/tools/run_aztec_contract_arms.mjs" "$WORK" \
  >"$WORK/arms.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || die "the browser arms exited $rc; see $WORK/arms.log and $WORK/arms.json"
assert_file "the arms report exists" "$WORK/arms.json"

FACTS="$(python3 - "$WORK/arms.json" <<'PY'
import json
import sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
p = r["page"]
say = lambda k, v: print("%s %s" % (k, v))
say("chromium", r.get("chromium"))
say("module_bytes", p["module"]["bytes"])
say("module_sha256", p["module"]["sha256"])
say("module_content_type", p["module"].get("contentType"))
say("declared_imports", p["module"]["declaredImports"])
say("reached_imports", ",".join(p["module"]["reachedImports"]) or "-")
say("vfs_files", p["vfs"]["files"])
say("vfs_source_bytes", p["vfs"]["sourceBytes"])
say("console_errors", len(r.get("consoleErrors") or []))

# The network log the browser itself recorded: was the module fetched cross-origin?
ext = [q for q in r["browserRequests"] if "ide.codetracer.com" in q["url"]]
say("requests_to_ide", len(ext))
say("ide_urls", ",".join(sorted({q["url"] for q in ext})) or "-")
local = [q for q in r["localServerRequests"] if q["status"] == 200]
say("local_200s", len(local))
say("local_paths", ",".join(sorted(q["path"] for q in local)))

for name in ("before", "refused", "after"):
    a = p["arms"][name]
    say("%s_ok" % name, a["ok"])
    say("%s_kind" % name, a["kind"] or "-")
    say("%s_stage" % name, a["stage"] or "-")
    say("%s_ms" % name, a["ms"])
    say("%s_imports" % name, a["importsReachedByThisArm"])
    if a.get("plan"):
        say("%s_packages" % name, a["plan"]["packages"])
        say("%s_sources" % name, a["plan"]["sources"])
        say("%s_type" % name, a["plan"]["package_type"])
    for d in (a.get("diagnostics") or [])[:1]:
        say("%s_diag0" % name, "%s|%s:%d:%d" % (d["message"], d["file"], d["line"], d["column"]))
    say("%s_diags" % name, len(a.get("diagnostics") or []))
    if a.get("manifest"):
        say("%s_manifest" % name, "%s:%s:%s" % (a["manifest"], a["line"], a["column"]))
    if a.get("message"):
        say("%s_message" % name, a["message"])
    art = a.get("artifact")
    if art:
        for k in ("name", "noir_version", "jsonBytes", "functions", "bytecodeBytes",
                  "abiParameters", "publicFunctions", "privateFunctions", "unconstrained",
                  "fileMapEntries"):
            say("%s_art_%s" % (name, k), art[k])
        say("%s_art_has_public_dispatch" % name,
            "public_dispatch" in art["functionNames"])
        say("%s_art_has_transfer" % name,
            "__aztec_nr_internals__private_transfer" in art["functionNames"])
PY
)"
printf '%s\n' "$FACTS" | sed 's/^/    /'
f() { printf '%s\n' "$FACTS" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }

echo "== 5. the module the tab drove is the one the product serves"
assert_eq "the page fetched the deployed module byte for byte" "$CURL_BYTES" "$(f module_bytes)"
assert_eq "…and the same bytes, by digest" "$CURL_SHA" "$(f module_sha256)"
assert_eq "…served as application/wasm" "application/wasm" "$(f module_content_type)"
assert_eq "the browser's own network log shows exactly one request to the product" "1" \
  "$(f requests_to_ide)"
assert_eq "…and it is the compiler" "$MODULE_URL" "$(f ide_urls)"
assert_eq "…while the local server served only the page, its two scripts and the tree" \
  "fixture.js,index.html,page.mjs,vfs.json,wasm_host.mjs" "$(f local_paths)"
assert_eq "the page logged no uncaught error" "0" "$(f console_errors)"

echo "== 6. the compile happened inside WebAssembly"
assert_ge "the module DECLARES imports, so an empty reached list is a measurement" 1 \
  "$(f declared_imports)"
assert_eq "…and across all three arms it reached none of them" "-" "$(f reached_imports)"
assert_eq "the successful arm in particular reached none" "0" "$(f after_imports)"

echo "== 7. arm 'before' — the contract path works; the library is what was missing"
assert_eq "a contract with no aztec-nr does not compile" "False" "$(f before_ok)"
assert_eq "…and it is a COMPILE error, so the contract package itself was accepted" \
  "compile-error" "$(f before_kind)"
assert_eq "…reached at the compile stage rather than at resolution" "compile" "$(f before_stage)"
assert_eq "…and the plan it produced calls it a contract" "contract" "$(f before_type)"
assert_ge "…with at least one positioned diagnostic" 1 "$(f before_diags)"
assert_true "…naming the attribute that aztec-nr provides, at a line and column" \
  str_has_sub "$(f before_diag0)" "Attribute function \`public\` is not in scope|c/src/main.nr:2:5"

echo "== 8. arm 'refused' — the git dependency is what stood in the way"
assert_eq "the same tree with aztec-nr's own manifest restored does not resolve" "False" \
  "$(f refused_ok)"
assert_eq "…and the refusal is the compiler's own named one" "git-dependency-refused" \
  "$(f refused_kind)"
assert_eq "…taken at RESOLUTION, before anything was compiled" "resolve" "$(f refused_stage)"
assert_true "…positioned at the offending line of the manifest it names" \
  str_has_re "$(f refused_manifest)" "^vendor/noir_aztec/Nargo\.toml:[0-9]+:[0-9]+$"
assert_true "…and it says how to fix it, which is what this check did" \
  str_has_sub "$(f refused_message)" "Vendor it into the tree and depend on it by"

echo "== 9. arm 'after' — a real Aztec contract, compiled in the tab"
assert_eq "the vendored tree compiles" "True" "$(f after_ok)"
assert_eq "…as a contract" "contract" "$(f after_type)"
assert_eq "…over the whole closure" "$(vf packages)" "$(f after_packages)"
assert_ge "…drawing on hundreds of Noir sources" 400 "$(f after_sources)"
assert_eq "…and the tree the page compiled is the tree that was vendored" "$(vf files)" \
  "$(f vfs_files)"
assert_eq "the artifact names the contract" "SimpleToken" "$(f after_art_name)"
assert_ge "…and carries its functions" 20 "$(f after_art_functions)"
assert_ge "…with real bytecode behind them" 500000 "$(f after_art_bytecodeBytes)"
assert_ge "…and a real ABI" 40 "$(f after_art_abiParameters)"
assert_ge "…public entry points" 10 "$(f after_art_publicFunctions)"
assert_ge "…and private ones, which is what makes it an Aztec contract" 5 \
  "$(f after_art_privateFunctions)"
assert_eq "…including the dispatcher every Aztec contract's public half is entered through" \
  "True" "$(f after_art_has_public_dispatch)"
assert_eq "…and the token's private transfer" "True" "$(f after_art_has_transfer)"
assert_ge "…with a debug file map, so the artifact is positioned against the tree" 100 \
  "$(f after_art_fileMapEntries)"
assert_ge "…and the artifact is megabytes rather than a stub" 1000000 "$(f after_art_jsonBytes)"

note "arm timings, in the tab: before $(f before_ms) ms, refused $(f refused_ms) ms, after $(f after_ms) ms"
note "chromium: $(f chromium)"
note "the artefacts are in $WORK (arms.json, vfs.json, vfs.json.manifest.json)"

finish
