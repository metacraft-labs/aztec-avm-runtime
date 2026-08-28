#!/usr/bin/env bash
# verify_transpiler_wasm_output_identical_to_native — M31.
#
#   verification/verify_transpiler_wasm_output_identical_to_native.sh   (or: just verify-m31)
#
# ============================================================================================
# THE ACCEPTANCE TEST: THE SAME BYTES, FROM A BROWSER AND FROM THE NATIVE BINARY.
# ============================================================================================
#
# `avm-transpiler` declares `crate-type = ["staticlib", "rlib"]` — no `cdylib`, no wasm target —
# and nobody had attempted this. Two symbols blocked it and both are named in
# `scratchpad/campaign/m31-impl-log.md` §2: `getrandom::backends::fill_inner` (a COMPILE-time
# refusal on `wasm32-unknown-unknown`) and `libc::{c_char, c_int, size_t}` (absent for a target
# libc does not know). Neither is in this crate's logic; the second is one line and is the
# prepared upstream contribution.
#
# ============================================================================================
# IDENTITY IS NOT THE IDENTITY OF TWO EMPTY BUFFERS, AND THAT IS ASSERTED THREE WAYS.
# ============================================================================================
#
# 1. every output is NON-EMPTY and begins with the transpiled artifact's own first key;
# 2. `counter` and `counter_variant` differ by ONE TOKEN in the Noir source (`+ 1` versus `+ 2`)
#    and their outputs must DIFFER — a comparer that reported identity for everything would have
#    to report it here;
# 3. the digests are taken at three points: the native binary writing a FILE, the module in NODE,
#    and the module in CHROMIUM returning base64 over CDP.
#
# BUT THAT IS THREE MEASUREMENT POINTS AND **TWO** PRODUCERS, AND THE DIFFERENCE MATTERS.
# This header, the milestone and the implementation log all said "three independent producers".
# Measured by M31's review: `tools/run_transpiler_arms.mjs` copies `$M31_MODULE` ITSELF into the
# served site and the node arm reads the SAME FILE — the arm report's
# `arms.browser.modules.sha256` equals `module.sha256` — so node and Chromium run the same wasm
# bytes on the same engine family. WebAssembly is deterministic; their agreement is automatic
# except for the host-side glue (node writes into `memory` directly, the page goes through
# `wasm_host.mjs`'s `callWithString`), and that glue is worth measuring but is not a producer.
#
# The two producers are NATIVE x86-64 through `avm_transpile_file` — a separate process, real
# files — and WASM32 through `avm_transpile_bytecode`. They are more independent than the
# milestone claimed for a reason nobody declared: they resolve DIFFERENT dependency versions
# (different `serde_json`, different `flate2`), which `verify_transpiler_native_build_unaffected`
# §6 now measures.
#
# The browser arm is the one the milestone is about; the node arm exists because M30's review
# established that a zero measured in one host is worth re-deriving in another.
#
# ============================================================================================
# AND THE MODULE IS READ AS BYTES.
# ============================================================================================
#
# `chrono` is in the linked closure and `js-sys` under it — which is exactly M30's blocker, where
# `SsaBuilder::run_passes` called `chrono::Utc::now()` unconditionally and trapped at
# `js_sys::Date::new_0` on every compile. Here the import section is walked by an INDEPENDENT
# leb128 reader and the clock bindings are shown to be absent, with the import count non-zero so
# the absence is not vacuous.

TEST_NAME="verify_transpiler_wasm_output_identical_to_native"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m31_transpiler.sh"
m31_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m31_require_arms

# ---------------------------------------------------------------------------
echo "== 0. the report has data in it"
# ---------------------------------------------------------------------------
# ONE assertion that names every absent field, before the first comparison — M29's remedy. A
# report with no data in it is a failure, not a smaller check.
MODULE_SHA="$(m31_arm module.sha256)"
MODULE_BYTES="$(m31_arm module.bytes)"
NATIVE_SHA="$(m31_arm native.sha256)"
FIXTURES="$(m31_arm fixtures)"
NODE_REACHED="$(m31_arm arms.node.reachedImports)"
NODE_DECLARED="$(m31_arm arms.node.declaredImports)"
BROWSER_REACHED="$(m31_arm arms.browser.reachedImports)"
BROWSER_DECLARED_N="$(m31_arm arms.browser.modules.declaredImportCount)"
INSTANTIATIONS="$(m31_arm arms.browser.instantiations)"
ABSENT="$(m31_absent module.sha256="$MODULE_SHA" module.bytes="$MODULE_BYTES" \
  native.sha256="$NATIVE_SHA" fixtures="$FIXTURES" node.reachedImports="$NODE_REACHED" \
  node.declaredImports="$NODE_DECLARED" browser.reachedImports="$BROWSER_REACHED" \
  browser.declaredImportCount="$BROWSER_DECLARED_N" browser.instantiations="$INSTANTIATIONS")"
[ -z "$ABSENT" ] || die "the arm report is missing:$ABSENT — every comparison below would be a
     comparison of two absent values. Delete $M31_ARMS and re-run."
assert_eq "the arm report carries every field this check reads" "" "$ABSENT"
# `arms.error` is DELIBERATELY NOT ASSERTED HERE. The runner sets a non-zero exit when the browser
# arm throws and `m31_require_arms` refuses the report, so an assertion that it is absent could
# never be red — an assertion that cannot fail, found in this check's own self-review. What CAN be
# read instead is what the page actually FETCHED, which is a measurement of the run.
REQUESTS="$(m31_arm arms.browser.requests)"
assert_true "the page fetched the module" str_has_sub "$REQUESTS" "avm_transpiler_wasm.wasm"
assert_true "…and M30's wasm host, which is the module it was reused from" \
  str_has_sub "$REQUESTS" "wasm_host.mjs"
assert_true "…and the fixture list" str_has_sub "$REQUESTS" "fixtures.json"

# ---------------------------------------------------------------------------
echo "== 1. the corpus is several contracts, and they are not all the same"
# ---------------------------------------------------------------------------
FIXTURE_NAMES="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["fixtures"]))' "$M31_ARMS")"
FIXTURE_COUNT="$(printf '%s\n' "$FIXTURE_NAMES" | grep -c . || true)"
assert_ge "the corpus is several contracts, not one" 5 "$FIXTURE_COUNT"
for want in counter counter_variant branches memory multi private_only reverting; do
  assert_true "…including $want" str_has_line "$FIXTURE_NAMES" "$want"
done
# The shapes differ, so "identical" is not being asserted seven times about one program.
DISTINCT_NATIVE="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(len({v["nativeSha256"] for v in d["identity"].values() if v["nativeSha256"]}))' "$M31_ARMS")"
assert_eq "every fixture transpiles to a DIFFERENT artifact" "$FIXTURE_COUNT" "$DISTINCT_NATIVE"

# ---------------------------------------------------------------------------
echo "== 2. the module was built for wasm32 and its imports carry no clock"
# ---------------------------------------------------------------------------
assert_file "the module exists" "$M31_MODULE"
IMPORTS="$(m31_wasm_imports "$M31_MODULE")"
IMPORT_COUNT="$(printf '%s\n' "$IMPORTS" | grep -c . || true)"
assert_true "the artefact really is a wasm module" test "$IMPORTS" != "NOT-A-WASM-MODULE"
# NON-EMPTY FIRST. An absence measured over an empty list is the campaign's oldest defect, and the
# import section is exactly where it would hide.
assert_ge "the module declares imports at all, so an absence below means something" 1 "$IMPORT_COUNT"
assert_eq "…and there are exactly four of them" "4" "$IMPORT_COUNT"
for absent in \
  '__wbg_new0' '__wbg_getTime' '__wbg_now' 'wasi_snapshot_preview1' 'env.' \
  '__wbg_randomFillSync' '__wbg_getRandomValues' '__wbg_crypto'; do
  assert_false "no import matching '$absent' — M30's blocker was __wbg_new0_… from Date::new_0" \
    str_has_sub "$IMPORTS" "$absent"
done
# The paired positive: the needles above CAN match something, demonstrated on a string that
# contains one. Without this the eight assertions are eight greps of an unread variable.
assert_true "…and that scanner can match, shown on a string that carries the needle" \
  str_has_sub "x __wbg_new0_f788a2397c7ca929 y" '__wbg_new0'

EXPORTS="$(m31_wasm_exports "$M31_MODULE")"
for want in avmt_alloc avmt_free avmt_result_len avmt_ok avmt_transpile memory; do
  assert_true "the module exports $want" str_has_line "$EXPORTS" "$want"
done
# Upstream's own C ABI survives into the cdylib, unrenamed. This is the whole point: the browser
# calls the SAME entry point the C++ side links.
assert_true "…and upstream's own avm_transpile_bytecode is exported" \
  str_has_line "$EXPORTS" avm_transpile_bytecode
assert_true "…and avm_transpile_file, which is the one that would need a filesystem" \
  str_has_line "$EXPORTS" avm_transpile_file

# ---------------------------------------------------------------------------
echo "== 3. nothing was reached, and 'nothing' is measured against a non-empty declaration"
# ---------------------------------------------------------------------------
assert_eq "the module reached no import in NODE" "[]" "$NODE_REACHED"
assert_eq "…nor in CHROMIUM" "[]" "$BROWSER_REACHED"
assert_eq "…and it declared four in node, so the empty list is not vacuous" "4" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$NODE_DECLARED")"
assert_eq "…and four in the browser" "4" "$BROWSER_DECLARED_N"
assert_eq "the browser instantiated the module exactly once for all of it" "1" "$INSTANTIATIONS"
assert_eq "…and fetched exactly one .wasm" "1" "$(m31_arm arms.browser.wasmRequests)"
assert_eq "…with no page error" "[]" "$(m31_arm arms.browser.pageErrors)"
assert_eq "…and no console error" "[]" "$(m31_arm arms.browser.consoleErrors)"

# ---------------------------------------------------------------------------
echo "== 4. BYTE-IDENTICAL, per contract, in both hosts"
# ---------------------------------------------------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  NAT="$(m31_arm "identity.$name.nativeSha256")"
  NOD="$(m31_arm "identity.$name.nodeSha256")"
  BRO="$(m31_arm "identity.$name.browserSha256")"
  NATB="$(m31_arm "identity.$name.nativeBytes")"
  BROB="$(m31_arm "identity.$name.browserBytes")"
  MISS="$(m31_absent native="$NAT" node="$NOD" browser="$BRO")"
  [ -z "$MISS" ] || die "$name is missing digests:$MISS"
  # NON-EMPTY BEFORE EQUAL. Two zero-byte outputs have the same digest.
  assert_ge "$name: the native output is not empty" 500 "$NATB"
  assert_ge "$name: the browser output is not empty" 500 "$BROB"
  assert_eq "$name: the browser's bytes are the native binary's, exactly" "$NAT" "$BRO"
  assert_eq "$name: and node's are too" "$NAT" "$NOD"
  assert_eq "$name: the browser reported success" "1" "$(m31_arm "identity.$name.browserOk")"
  assert_eq "$name: the native binary wrote a file" "ok" "$(m31_arm "arms.native.$name.status")"
done <<<"$FIXTURE_NAMES"

# ---------------------------------------------------------------------------
echo "== 5. THE CONTROL: a different input must produce a different output"
# ---------------------------------------------------------------------------
# `counter` and `counter_variant` differ by one token of Noir (`+ 1` vs `+ 2`). The difference is
# re-derived from the FIXTURE SOURCES here rather than described, so a variant that silently
# became a copy of its base would fail this rather than making section 5 vacuous.
BASE_SRC="$M31_FIXTURES/counter/src/main.nr"
VAR_SRC="$M31_FIXTURES/counter_variant/src/main.nr"
assert_file "the base fixture source exists" "$BASE_SRC"
assert_file "the variant fixture source exists" "$VAR_SRC"
SRC_DIFF="$(diff "$BASE_SRC" "$VAR_SRC" | grep -c '^[<>]' || true)"
assert_ge "the two fixtures' sources really do differ" 2 "$SRC_DIFF"
C_NAT="$(m31_arm identity.counter.nativeSha256)"
V_NAT="$(m31_arm identity.counter_variant.nativeSha256)"
C_BRO="$(m31_arm identity.counter.browserSha256)"
V_BRO="$(m31_arm identity.counter_variant.browserSha256)"
assert_false "the two inputs do not produce the same native output" test "$C_NAT" = "$V_NAT"
assert_false "…nor the same browser output" test "$C_BRO" = "$V_BRO"
assert_eq "…and each browser output still equals ITS OWN native one" "true true" \
  "$(m31_arm identity.counter.identicalBrowserVsNative) $(m31_arm identity.counter_variant.identicalBrowserVsNative)"

# ---------------------------------------------------------------------------
echo "== 6. the inputs the browser transpiled are the ones on disk"
# ---------------------------------------------------------------------------
# TWO INDEPENDENTLY PRODUCED DIGESTS, which is the correction M30's review made to its own check:
# the page hashes the bytes it FETCHED over HTTP, this check hashes the file in the artifacts
# directory, and neither reads the other's number.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  ON_DISK="$(sha256sum "$M31_ARTIFACTS/$name.json" | cut -d' ' -f1)"
  IN_PAGE="$(m31_arm "arms.browser.contracts.$name.inputSha256")"
  assert_eq "$name: the page transpiled the artifact this check names" "$ON_DISK" "$IN_PAGE"
done <<<"$FIXTURE_NAMES"
# And the page's own host module is M30's, byte-identical to the one in the repository — compared
# against the digest THE PAGE took of the bytes it FETCHED, not against the runner's digest of the
# copy the runner had just made. The old form read `wasmHost.servedSha256`, which the runner
# computes over `$SITE/wasm_host.mjs` moments after `copyFileSync`-ing the repository's file into
# it: two readings of one file in one process, equal by construction, which is exactly the shape
# M30's review found green over a mismatch. Corrected by M31's review.
assert_eq "the page ran M30's wasm_host.mjs unchanged, as the PAGE hashed it" \
  "$(sha256sum "$REPO_ROOT/verification/m30/page/wasm_host.mjs" | cut -d' ' -f1)" \
  "$(m31_arm arms.browser.modules.hostSha256)"
assert_ge "…and it is a real module and not an empty response" 1000 \
  "$(m31_arm arms.browser.modules.hostBytes)"
# THE SAME CORRECTION FOR THE MODULE ITSELF, which nothing had compared: the page hashes the
# `.wasm` bytes it fetched, this check hashes `$M31_MODULE` on disk, and the two must agree — so
# "the browser transpiled it" is a statement about the module this check names.
assert_eq "the page instantiated the module this check names" \
  "$(sha256sum "$M31_MODULE" | cut -d' ' -f1)" "$(m31_arm arms.browser.modules.sha256)"
assert_eq "…and the runner agrees about that file's size" "$MODULE_BYTES" \
  "$(m31_arm arms.browser.modules.bytes)"

# ---------------------------------------------------------------------------
echo "== 7. the output really is a transpiled artifact and not an echo of the input"
# ---------------------------------------------------------------------------
# An identity check between two producers says nothing about WHAT they produced. These read the
# browser's own bytes back off disk.
for name in counter branches multi; do
  OUT="$M31_WORK/browser-$name.out.json"
  assert_file "$name: the browser's output was written out" "$OUT"
  assert_eq "$name: it declares transpiled: true" "True" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transpiled"])' "$OUT")"
  assert_false "$name: and the INPUT does not, so the flag is the transpiler's doing" \
    python3 -c 'import json,sys; raise SystemExit(0 if json.load(open(sys.argv[1])).get("transpiled") else 1)' \
    "$M31_ARTIFACTS/$name.json"
  # The AVM function's bytecode changed from ACIR/Brillig to AVM: a base64 string of a different
  # length over the same function name.
  CHANGED="$(python3 - "$M31_ARTIFACTS/$name.json" "$OUT" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
ai = {f["name"]: f["bytecode"] for f in a["functions"]}
changed = 0
for f in b["functions"]:
    if "abi_public" in f.get("custom_attributes", []) and f["name"] in ai:
        if f["bytecode"] != ai[f["name"]]:
            changed += 1
print(changed)
PY
)"
  assert_ge "$name: at least one AVM function's bytecode was rewritten" 1 "$CHANGED"
done

# ---------------------------------------------------------------------------
echo "== 8. the refusal path, exercised in the browser"
# ---------------------------------------------------------------------------
# A refusal is a throw, never a plausible value — the campaign's rule. Each of these must come
# back `ok == 0` carrying the transpiler's OWN message, not a fabricated artifact.
assert_eq "bytes that are not JSON are refused" "0" "$(m31_arm arms.browser.refusals.notJson.ok)"
assert_contains "…naming the wire format" "wire format" "$(m31_arm arms.browser.refusals.notJson.message)"
assert_eq "JSON that is not a contract artifact is refused" "0" \
  "$(m31_arm arms.browser.refusals.jsonButNotAContract.ok)"
assert_eq "an already-transpiled artifact is refused" "0" \
  "$(m31_arm arms.browser.refusals.alreadyTranspiled.ok)"
assert_eq "…by name" "Contract already transpiled" \
  "$(m31_arm arms.browser.refusals.alreadyTranspiled.message)"
assert_eq "an empty input is refused" "0" "$(m31_arm arms.browser.refusals.empty.ok)"
# THE PAIRED POSITIVE: `ok` is not the constant 0. Every real fixture above came back 1, and this
# names one of them so section 8 cannot pass over a module that refuses everything.
assert_eq "…and a real artifact is NOT refused, so ok is not a constant" "1" \
  "$(m31_arm arms.browser.contracts.counter.ok)"

# ---------------------------------------------------------------------------
echo "== 9. the build is pinned, and the pin is read rather than typed"
# ---------------------------------------------------------------------------
# THE ANCHOR IS READ FROM `pins.json`, NOT TYPED IN. A literal here would be a second declaration
# of a pin this repository already makes in one place, and a check that compares a constant with a
# default is comparing two copies of the same decision.
PINNED_CPP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
assert_ge "pins.json declares a cpp anchor" 40 "${#PINNED_CPP}"
assert_eq "the transpiler came from that anchor" "${PINNED_CPP:0:10}" "$M31_AZTEC_REV"
DECLARED_NOIR="$(git -C "$WORKSPACE_ROOT/aztec-packages" ls-tree "$M31_AZTEC_REV" noir/noir-repo | awk '{print $3}')"
assert_ge "…and aztec-packages declares a noir/noir-repo gitlink there" 40 "${#DECLARED_NOIR}"
assert_eq "…and the noir the build used is the one that gitlink names" "$DECLARED_NOIR" "$M31_NOIR_REV"
# THE NOIR COMMIT IS PUBLISHED, and that is measured rather than argued. M24's rule: a pin that is
# not reachable from a remote ref resolves on this machine and fails everywhere else, and
# `git archive` of it is exactly the shape that hides it. M31's own log recorded that `noir` has
# ZERO `refs/remotes/*` refs so the predicate could not be applied — measured by this review, it
# has 57, and the pin is contained in two of them. The predicate carries its own negative control
# IN THE SAME REPOSITORY, so it cannot answer 0 for the reason M26's review found (a predicate
# short-circuiting on a directory that is not a git repo agrees with whatever it is controlling).
m31_refcount() { # <repo> <rev>
  git -C "$1" for-each-ref --contains "$2" --format='%(refname)' refs/remotes 2>/dev/null \
    | grep -c . || true
}
NOIR_REPO_DIR="$WORKSPACE_ROOT/noir"
assert_dir "the noir checkout the build archives from is a git repository" "$NOIR_REPO_DIR/.git"
assert_ge "…and it has remote refs at all, so a zero below would mean something" 1 \
  "$(git -C "$NOIR_REPO_DIR" for-each-ref --format='%(refname)' refs/remotes | grep -c . || true)"
assert_ge "the pinned noir commit is reachable from a PUBLISHED remote ref" 1 \
  "$(m31_refcount "$NOIR_REPO_DIR" "$M31_NOIR_REV")"
# THE CONTROL: a commit in the SAME repository that is local-only must answer 0. `wasm/webpage` is
# OQ-7's fact 7 — it is deliberately unpublished — so this both controls the predicate and
# re-measures that fact on every run.
assert_eq "…and the same predicate answers 0 for a local-only branch in that repository" "0" \
  "$(m31_refcount "$NOIR_REPO_DIR" "$(git -C "$NOIR_REPO_DIR" rev-parse wasm/webpage 2>/dev/null || echo HEAD)")"
# `avm-transpiler/` is unchanged between the anchor and aztec-packages' tip, so working at the
# anchor is also working at the tip. Measured, not assumed.
assert_eq "avm-transpiler is byte-identical between the anchor and aztec-packages HEAD" "0" \
  "$(git -C "$WORKSPACE_ROOT/aztec-packages" diff --name-only "$M31_AZTEC_REV" HEAD -- avm-transpiler/ | grep -c . || true)"
# …and the comparison can find a difference, shown on a path that HAS moved between the two.
assert_ge "…and that comparison is capable of reporting a difference" 1 \
  "$(git -C "$WORKSPACE_ROOT/aztec-packages" diff --name-only "$M31_AZTEC_REV" HEAD | grep -c . || true)"

m31_finish
