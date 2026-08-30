#!/usr/bin/env bash
# verify_oracle_interface_hash_matches — M37 (Aztec-AVM-Runtime).
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# WHY THIS EXISTS: THIS REPOSITORY DECLARES `ORACLE_INTERFACE_HASH` AND CHECKS IT WITH NOTHING.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# `browser/src/vendor/pxe/oracle_version.ts` carries upstream's constant:
#
#     export const ORACLE_INTERFACE_HASH = '16a4ca6f…';
#
# and its own doc comment says what it is for — "computed from `ORACLE_REGISTRY` (each oracle's
# name, ordered parameter names and types, and return type) and used to detect when the oracle
# interface changes". **Upstream ships a program that enforces it**
# (`yarn-project/pxe/src/bin/check_oracle_version.ts`). We vendored the constant and not the check,
# so until this file existed the hash was a comment with a hex string in it.
#
# THAT MATTERS MOST DURING M37, WHICH IS WHY IT IS M37's. The reconciliation re-takes every vendored
# file from a new anchor — 68 oracle entries among them — and the failure this catches is precisely
# a re-vendoring in which one oracle's parameter list or return type moved. `check-drift` catches a
# vendored file that DIVERGED from its anchor; this catches a vendored file that MATCHES a *new*
# anchor whose interface is not the one the environment's constant describes.
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# AND IT IS THE ONLY HALF THAT *CAN* BE CHECKED. THE OTHER HALF IS NOT ON THE WIRE.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# `PRIVATE-EXECUTION.md` records a wire-shape divergence that `assertCompatibleOracleVersion`
# passes. M37 measured why, and the reason is stronger than "the rule is too coarse":
#
#   **THE VERSION PAIR IS NOT A FUNCTION OF THE INTERFACE.** Upstream commits `c2ca120898`
#   (2026-07-28) and `8ed295c2c7` (2026-08-14) both declare oracle version **30.8**, are both under
#   the same hash algorithm, and declare **different** `ORACLE_INTERFACE_HASH` values — because
#   `aztec_prv_notifyCreatedContractClassLog`'s parameter list went from one `CONTRACT_CLASS_LOG` to
#   three params of different types. An EXACT version match does not imply an identical interface.
#
# So the gate cannot be repaired by tightening the comparison: there is nothing finer to compare.
# `aztec_misc_assertCompatibleOracleVersion` takes exactly two parameters — `major: U32`,
# `minor: U32` — so **the contract cannot tell the environment its interface hash**, and no
# environment-side change can recover information the wire does not carry. Closing that half needs
# an upstream change to the oracle's own signature; §3 pins the evidence so the claim is a
# measurement rather than a paragraph, and so that upstream FIXING it reddens this check and forces
# a deliberate edit.
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# THE MECHANISM, AND WHY IT BUNDLES RATHER THAN IMPORTS.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# The vendored oracle layer cannot be imported by Node directly, for two measured reasons:
#   * `browser/` has no `node_modules`, so its `@aztec/*` imports resolve to nothing; and
#   * its relative imports are spelled `./private/acvm/index.js` against `.ts` files on disk, which
#     Node's type stripping does not rewrite and esbuild does.
# So the check materialises the vendored tree beside an install and bundles it, which is what
# `browser/build.mjs` does for the same tree and the same reasons.
#
# IT RESOLVES AGAINST `npm.current`, NOT `deletion_era`, AND THAT IS ITSELF AN M37 MEASUREMENT: the
# `cpp`-anchor oracle layer builds against `npm.current` with **no shims**, and against
# `deletion_era` it fails on `allToCompletion` — the anchor-versus-pin gap `browser/build.mjs`
# carries two shims for. The vendored layer belongs on the line that matches its anchor.
#
# Run: just verify-oracle-interface-hash

set -uo pipefail
TEST_NAME="verify_oracle_interface_hash_matches"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

WORK="${M37_ORACLE_WORK:-$HOME/.cache/aztec-m37-oracle}"
VENDOR="$REPO_ROOT/browser/src/vendor"
VERSION_FILE="$VENDOR/pxe/oracle_version.ts"
REGISTRY_FILE="$VENDOR/pxe/contract_function_simulator/oracle/oracle_registry.ts"
NPM_CURRENT="$REPO_ROOT/replay/node_modules"

assert_file "the vendored oracle version constants" "$VERSION_FILE"
assert_file "the vendored oracle registry" "$REGISTRY_FILE"
assert_dir "the npm.current install the cpp-anchor layer resolves against" "$NPM_CURRENT/@aztec"

ESBUILD="$(for c in "$REPO_ROOT/spike/node_modules/.bin/esbuild" "$REPO_ROOT/diffsim/node_modules/.bin/esbuild"; do [ -x "$c" ] && { echo "$c"; break; }; done)"
[ -n "$ESBUILD" ] || die "no esbuild in spike/ or diffsim/ node_modules. Remedy: npm ci in one of them."
assert_true "esbuild was found, which is how the vendored tree is made runnable" test -x "$ESBUILD"

# ---------------------------------------------------------------------------
# The harness: materialise, bundle, run. Every step bounded; a failure is named.
# ---------------------------------------------------------------------------
BANNER="import{createRequire as __cr}from'node:module';import{fileURLToPath as __f}from'node:url';import{dirname as __d}from'node:path';const require=__cr(import.meta.url);const __filename=__f(import.meta.url);const __dirname=__d(__filename);"

# `pino` and its transitive set are external for `esbuild-driver.mjs`'s own reason: bundled, their
# `__dirname + '/lib/worker.js'` points into a directory that does not exist.
EXTERNALS=(--external:pino --external:pino-abstract-transport --external:pino-pretty
           --external:thread-stream --external:sonic-boom)

hash_of() { # <label> <optional python mutator over the copied tree> -> prints the computed hash
  local label="$1" mutator="${2:-}"
  local w="$WORK/$label"
  rm -rf "$w"; mkdir -p "$w"
  cp -R "$VENDOR" "$w/vendor"
  ln -sfn "$NPM_CURRENT" "$w/node_modules"

  # THE ONE SPECIFIER THE BUILD ALIASES, REWRITTEN THE SAME WAY IT DOES. `@aztec/simulator` is
  # deliberately not installed (DD-9: its hard deps are the two packages DD-9 forbids), and
  # `browser/build.mjs` points the specifier at upstream's own entry point vendored from the same
  # anchor. Passed to esbuild as an alias below rather than edited, so the copy stays byte-identical
  # to the vendored source and this check cannot silently measure an edited tree.

  if [ -n "$mutator" ]; then
    python3 - "$w" <<PY || die "the $label mutator failed"
$mutator
PY
  fi

  cat >"$w/entry.ts" <<'EOS'
import { ORACLE_REGISTRY } from './vendor/pxe/contract_function_simulator/oracle/oracle_registry.ts';
import { ORACLE_INTERFACE_HASH, ORACLE_VERSION_MAJOR, ORACLE_VERSION_MINOR }
  from './vendor/pxe/oracle_version.ts';
import { keccak256String } from '@aztec/foundation/crypto/keccak';

// VERBATIM FROM UPSTREAM: yarn-project/pxe/src/bin/oracle_version_helpers.ts at anchors.cpp.
// Ten lines, copied rather than vendored-with-provenance because vendoring a file to run it once
// inside a check would put a `PROVENANCE.md` row on a test fixture. §1 asserts this copy still
// matches upstream's source at the anchor, so it cannot drift.
function getOracleRegistrySignature(registry: any): string {
  const oracleSignatures = Object.entries(registry).map(([name, entry]: [string, any]) => {
    const paramSignatures = entry.params.map((p: any) => `${p.name}: ${p.type.label}`);
    const returnType = entry.returnType === undefined ? 'void' : entry.returnType.label;
    return `${name}(${paramSignatures.join(', ')}): ${returnType}`;
  });
  oracleSignatures.sort();
  return oracleSignatures.join('\n');
}

const signature = getOracleRegistrySignature(ORACLE_REGISTRY);
console.log('entries ' + Object.keys(ORACLE_REGISTRY).length);
console.log('version ' + ORACLE_VERSION_MAJOR + '.' + ORACLE_VERSION_MINOR);
console.log('declared ' + ORACLE_INTERFACE_HASH);
console.log('computed ' + keccak256String(signature));
console.log('signatureBytes ' + signature.length);
console.log('done 1');
EOS

  ( cd "$w" && timeout "${M37_BUILD_TIMEOUT:-600}" "$ESBUILD" entry.ts --bundle --format=esm \
      --platform=node --outfile=out.mjs \
      "--alias:@aztec/simulator/client=$w/vendor/simulator/client.ts" \
      "${EXTERNALS[@]}" "--banner:js=$BANNER" --log-limit=6 ) >"$w/build.log" 2>&1 \
    || die "the $label bundle failed to build; esbuild's output is in $w/build.log:
$(tail -12 "$w/build.log")"

  ( cd "$w" && timeout "${M37_RUN_TIMEOUT:-300}" node out.mjs ) >"$w/run.out" 2>"$w/run.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    die "the $label probe exited $rc. Its stderr:
$(head -12 "$w/run.err")"
  fi
  require_complete_transcript "$w/run.out" "done" "the $label probe's"
  awk '$1=="computed"{print $2}' "$w/run.out"
}

f() { awk -v k="$2" '$1==k{print $2}' "$WORK/$1/run.out"; }

# ---------------------------------------------------------------------------
echo "== 1. the vendored registry recomputes to the vendored constant"
# ---------------------------------------------------------------------------
REAL="$(hash_of real)"
DECLARED="$(f real declared)"

assert_eq "the vendored registry has 68 oracle entries" "68" "$(f real entries)"
assert_eq "…and declares oracle version 30.8" "30.8" "$(f real version)"
assert_ge "…and its signature is a substantial string rather than an empty one" 3000 \
  "$(f real signatureBytes)"
assert_eq "THE RECOMPUTED HASH EQUALS THE DECLARED ONE" "$DECLARED" "$REAL"
assert_true "…and it is a full keccak digest rather than a truncation" \
  bash -c "[[ '$REAL' =~ ^[0-9a-f]{64}$ ]]"

# THE VENDORING IS FAITHFUL TO THE ANCHOR, measured rather than trusted. `check-drift` compares
# bytes; this compares the INTERFACE the bytes describe, which is the thing that matters.
ANCHOR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
ANCHOR_HASH="$(git -C "$FORK_ROOT" show "$ANCHOR:yarn-project/pxe/src/oracle_version.ts" 2>/dev/null \
  | sed -nE "s/^export const ORACLE_INTERFACE_HASH = '([0-9a-f]+)';/\1/p")"
assert_true "the fork checkout has the cpp anchor, so the comparison reads a real tree" \
  git -C "$FORK_ROOT" cat-file -e "$ANCHOR^{commit}"
assert_eq "…and the vendored constant is the anchor's own" "$ANCHOR_HASH" "$DECLARED"

# The helper this check runs is upstream's, and it is pinned so a paraphrase cannot creep in.
UPSTREAM_HELPER="$(git -C "$FORK_ROOT" show "$ANCHOR:yarn-project/pxe/src/bin/oracle_version_helpers.ts" 2>/dev/null \
  | sed -n '/export function getOracleRegistrySignature/,/^}/p')"
assert_contains "upstream's helper builds each signature from param name and type LABEL" \
  'p.name}: ${p.type.label}' "$UPSTREAM_HELPER"
assert_contains "…uses 'void' for an absent return type" "'void'" "$UPSTREAM_HELPER"
assert_contains "…and SORTS, so the hash does not depend on declaration order" "sort()" "$UPSTREAM_HELPER"

# ---------------------------------------------------------------------------
echo "== 2. THE CONTROL: an interface change MOVES the hash, and a non-interface change does NOT"
#
# Without the first, "the hashes match" is satisfied by a hash of nothing. Without the second, it is
# satisfied by a hash of the FILE — which would redden on every comment and be abandoned within a
# month.
# ---------------------------------------------------------------------------
MUTATED="$(hash_of mutated "$(cat <<'PY'
import sys, re, os
w = sys.argv[1]
p = os.path.join(w, 'vendor/pxe/contract_function_simulator/oracle/oracle_registry.ts')
s = open(p, encoding='utf-8').read()
needle = "{ name: 'major', type: U32 }"
assert needle in s, 'MUTATION MISS: the needle is not in the registry'
open(p, 'w', encoding='utf-8').write(s.replace(needle, "{ name: 'majorRenamed', type: U32 }", 1))
PY
)")"
assert_false "renaming ONE parameter of ONE oracle moves the hash" \
  test "$MUTATED" = "$REAL"
assert_true "…and the mutated hash is still a well-formed digest, so it moved rather than broke" \
  bash -c "[[ '$MUTATED' =~ ^[0-9a-f]{64}$ ]]"
assert_eq "…over the same 68 entries, so the arm changed a shape and not the census" "68" \
  "$(f mutated entries)"

COMMENTED="$(hash_of commented "$(cat <<'PY'
import sys, os
w = sys.argv[1]
p = os.path.join(w, 'vendor/pxe/contract_function_simulator/oracle/oracle_registry.ts')
s = open(p, encoding='utf-8').read()
needle = 'export const ORACLE_REGISTRY = {'
assert needle in s, 'MUTATION MISS: the registry declaration is not where expected'
open(p, 'w', encoding='utf-8').write(
    s.replace(needle, '// a comment that changes no interface\n' + needle, 1))
PY
)")"
assert_eq "adding a COMMENT does not move the hash — it is over the interface, not the file" \
  "$REAL" "$COMMENTED"

# ---------------------------------------------------------------------------
echo "== 3. THE FINDING, PINNED: the version pair is NOT a function of the interface"
#
# Two upstream commits, both oracle version 30.8, both under the same hash algorithm, declaring
# DIFFERENT interface hashes. An exact version match does not imply an identical interface, so
# `assertCompatibleOracleVersion` cannot be repaired by tightening its comparison.
#
# Asserted so that upstream FIXING this reddens the check and forces a deliberate edit, rather than
# leaving a paragraph that has quietly stopped being true.
# ---------------------------------------------------------------------------
A1=c2ca120898   # 2026-07-28
A2=8ed295c2c7   # 2026-08-14
read_at() { git -C "$FORK_ROOT" show "$1:yarn-project/pxe/src/oracle_version.ts" 2>/dev/null; }
v_of() { read_at "$1" | sed -nE "s/^export const ORACLE_VERSION_$2 = ([0-9]+);/\1/p"; }
h_of() { read_at "$1" | sed -nE "s/^export const ORACLE_INTERFACE_HASH = '([0-9a-f]+)';/\1/p"; }

assert_true "the fork has the earlier of the two commits" git -C "$FORK_ROOT" cat-file -e "$A1^{commit}"
assert_true "…and the later one" git -C "$FORK_ROOT" cat-file -e "$A2^{commit}"
assert_ge "…and both answer a real oracle_version.ts" 60 "$(read_at "$A1" | wc -c | tr -d ' ')"

assert_eq "the earlier commit declares major 30" "30" "$(v_of "$A1" MAJOR)"
assert_eq "…and minor 8" "8" "$(v_of "$A1" MINOR)"
assert_eq "the later commit declares major 30" "30" "$(v_of "$A2" MAJOR)"
assert_eq "…and minor 8 — THE SAME VERSION" "8" "$(v_of "$A2" MINOR)"
assert_false "AND YET THEIR INTERFACE HASHES DIFFER" test "$(h_of "$A1")" = "$(h_of "$A2")"
assert_eq "…the later one being the anchor's, which is what this repository vendored" \
  "$DECLARED" "$(h_of "$A2")"

# WHAT CHANGED, named — so the claim is about an oracle rather than about two hex strings.
REG=yarn-project/pxe/src/contract_function_simulator/oracle/oracle_registry.ts
DIFF="$(git -C "$FORK_ROOT" diff "$A1" "$A2" -- "$REG" 2>/dev/null)"
assert_ge "the registry really did change between them" 100 "$(printf '%s' "$DIFF" | wc -c | tr -d ' ')"
assert_contains "…in aztec_prv_notifyCreatedContractClassLog" \
  "aztec_prv_notifyCreatedContractClassLog" "$DIFF"
assert_contains "…whose single CONTRACT_CLASS_LOG parameter was removed" \
  "-      { name: 'log', type: CONTRACT_CLASS_LOG }" "$DIFF"
assert_contains "…and replaced by three parameters of different types" \
  "+      { name: 'contractAddress', type: AZTEC_ADDRESS }" "$DIFF"

# AND THE OTHER HALF CANNOT BE CHECKED AT ALL, because the wire does not carry it.
VERSION_ORACLE="$(sed -n '/aztec_misc_assertCompatibleOracleVersion: makeEntry({/,/}),/p' "$REGISTRY_FILE")"
assert_contains "the version oracle takes a major" "{ name: 'major', type: U32 }" "$VERSION_ORACLE"
assert_contains "…and a minor" "{ name: 'minor', type: U32 }" "$VERSION_ORACLE"
assert_eq "…and NOTHING ELSE — two parameters, so the contract cannot send its interface hash" "2" \
  "$(printf '%s\n' "$VERSION_ORACLE" | grep -c "name: '")"
# `str_has_sub` rather than `printf … | grep -q`: the pipeline form is what
# `verify_no_pipeline_predicates` pins BY NAME, and this line was a sixth survivor —
# so M21 went 69/3 for a spelling in an M37 check. The pipe was harmless here (it is
# inside `bash -c`, so the failure counter is not in a subshell), which is exactly why
# a census pinned by name and not by harm is the instrument that catches it.
assert_false "…and it declares no return type through which one could come back" \
  str_has_sub "$VERSION_ORACLE" returnType
# …and the predicate is shown able to say YES, so the absence above is a measurement
# rather than a needle that stopped matching.
assert_true "…and that same predicate finds a returnType when one is spliced in" \
  str_has_sub "$VERSION_ORACLE
      returnType: FIELD," returnType

finish
