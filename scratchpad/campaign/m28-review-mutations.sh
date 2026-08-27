#!/usr/bin/env bash
# m28-review-mutations.sh — M28's REVIEW mutation matrix.
#
#   direnv exec . bash scratchpad/campaign/m28-review-mutations.sh [arm ...]
#
# NEVER beside a sweep: a mutation harness and a verification sweep are two writers over one
# working tree. This harness runs only after the review sweep has printed SWEEPDONE.
#
# Every arm restores what it touched and the restoration is checked against a DIGEST of `git diff`
# taken at harness start — not `git diff --quiet`, because M28 is uncommitted work and the
# Justfile, `DRIFT.md`, `CAMPAIGN-BRIEF.md` and the workflow are legitimately modified.
#
# Restores `touch` the file: `cp -p` preserves mtimes, `m27_bundle_newer_inputs` is mtime-based,
# and M28's own harness produced CAMPAIGN-BRIEF.md's "a mutated artefact outlived its restored
# source" exactly that way.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"
OUT="${M28REV_LOG:-$HOME/.cache/m28rev-mutations.log}"
: >"$OUT"

WANT=("$@")
want() {
  [ "${#WANT[@]}" -eq 0 ] && return 0
  local a
  for a in "${WANT[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

say() { printf '\n########## %s\n' "$*" | tee -a "$OUT"; }
run_check() { # <check-name> [env assignments...]
  local check="$1"; shift
  local log="$HOME/.cache/m28rev-arm-$check.$$.log"
  ( env "$@" "$REPO/verification/$check.sh" ) >"$log" 2>&1
  local rc=$?
  {
    printf 'rc=%s\n' "$rc"
    grep -E "^${check}: |^just [a-z-]*: |^  FAIL|cannot run:" "$log" | head -30
  } | tee -a "$OUT"
  cp "$log" "$HOME/.cache/m28rev-last-$check.log"
  rm -f "$log"
}

BACKUPS=()
mutate_backup() { cp -p "$1" "$1.m28revbak" && BACKUPS+=("$1"); }
restore_all() {
  local p
  for p in "${BACKUPS[@]}"; do
    [ -f "$p.m28revbak" ] && mv "$p.m28revbak" "$p" && touch "$p"
  done
  BACKUPS=()
  local now
  now="$(git -C "$REPO" diff | sha256sum | cut -d' ' -f1)"
  if [ "$now" != "$BASELINE_DIFF" ]; then
    printf 'HARNESS ABORT: the working tree is not what it was before this arm:\n' | tee -a "$OUT"
    git -C "$REPO" diff --stat | tee -a "$OUT"
    exit 2
  fi
}
BASELINE_DIFF="$(git -C "$REPO" diff | sha256sum | cut -d' ' -f1)"
trap 'restore_all' EXIT

WARM_MODULE="$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"

# =============================================================================================
# R-DOC — THE FINDING. §5 of BROWSER-GATE.md carries TWO figures on one line and only one of them
# is re-derived, so the two can be SWAPPED and the document states the reverse of the data with
# every figure present. That is M24's review's OQ-6 defect verbatim, in the document whose own §6
# says each figure "is looked for on the line that names its subject", and in the section AFTER
# the one M28's impl log records converting to one-figure-per-line for exactly this reason.
# =============================================================================================
if want RDOC; then
  say "RDOC §5's two figures SWAPPED: 268 packages of which 3 declare -> 3 packages of which 268"
  DOC="$REPO/BROWSER-GATE.md"
  mutate_backup "$DOC"
  python3 - "$DOC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "dependency closure of the shipped package is **268** packages, of which **3** declare"
assert old in s, "the closure line is not where the mutation expects it"
new = "dependency closure of the shipped package is **3** packages, of which **268** declare"
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check ci_browser_gate
  restore_all
fi

# =============================================================================================
# R-PACK — THE SECOND FINDING. `m28_pack` calls `die` and every caller uses it as `$(m28_pack …)`,
# so the `exit` leaves the SUBSHELL. That is the family CAMPAIGN-BRIEF.md names by name and the
# one M28's impl log §5.3 records FIXING in `m28_scan` — two functions above, in the same file.
# Driven by a pack that cannot finish inside its bound.
# =============================================================================================
if want RPACK; then
  say "RPACK m28_pack's die inside \$(…): the pack bound made unreachable (M28_PACK_TIMEOUT=0.01)"
  run_check verify_npm_pack_no_optional_native "M28_PACK_TIMEOUT=0.01"
  restore_all
fi

# =============================================================================================
# R-WALK — THE POSITIVE CONTROL THE BRIEF ASKS FOR BY NAME: "a graph walk that resolves nothing
# reports a clean graph". §5 of verify_verification_code_unreachable_from_browser is supposed to
# be the arm that stops the absence in §3-§4 being a statement about a walk that resolved nothing.
# This breaks the walker so that it resolves nothing, and §5 must go red.
# =============================================================================================
if want RWALK; then
  say "RWALK the import walker resolves nothing — §5's positive control must redden"
  W="$REPO/tools/import_graph.mjs"
  mutate_backup "$W"
  python3 - "$W" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# The ENTRY still resolves; nothing beyond it does. The walk then reports a module count of 1 and
# an empty package set — exactly the "a walk that resolves nothing reports a clean graph" state
# CAMPAIGN-BRIEF.md names, rather than a crash.
old = "  const resolve = resolverFor(url);"
assert old in s, "the per-module resolver is not where the mutation expects it"
new = "  const resolve = () => { throw new Error('m28rev: resolution disabled'); };"
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check verify_verification_code_unreachable_from_browser
  restore_all
fi

# =============================================================================================
# R-STALE — THE THIRD FINDING. `m27_bundle_newer_inputs` watches `browser/src`, `browser/demo`,
# `orchestration/src`, `ct-host/src`, `browser/build.mjs` and `chunk-budgets.json`. It does NOT
# watch `browser-probe/shims/` (THREE of the four declared polyfills, and the whole
# "other than through the declared polyfill" carve-out rests on them), `node-host/src` (five real
# inputs of the shipped graph) or `browser/esbuild-driver.mjs` (which decides `platform`, `alias`
# and `external` — the exact three things the builtin gate measures).
#
# So this edits the `util` SHIM and runs the check WITHOUT `M27_BUNDLE_REFRESH`. If the bundle is
# not rebuilt the gate passes over a bundle that no longer describes the source.
# =============================================================================================
if want RSTALE; then
  say "RSTALE the util SHIM gutted, no M27_BUNDLE_REFRESH — is browser/dist rebuilt at all?"
  SHIM="$REPO/browser-probe/shims/util.js"
  mutate_backup "$SHIM"
  printf '// M28 review: deliberately gutted. Nothing is exported.\nexport const M28REV_GUTTED = 1;\n' >"$SHIM"
  printf 'shim mtime %s   meta.json mtime %s\n' \
    "$(stat -c %Y "$SHIM")" "$(stat -c %Y "$REPO/browser/dist/meta.json")" | tee -a "$OUT"
  run_check verify_browser_bundle_no_node_builtins
  printf 'did it rebuild? bundle build lines: %s\n' \
    "$(grep -c 'building the browser bundle' "$HOME/.cache/m28rev-last-verify_browser_bundle_no_node_builtins.log" || true)" | tee -a "$OUT"
  restore_all
fi

# =============================================================================================
# The four gates reproduced against their own planted violations.
# =============================================================================================
# =============================================================================================
# R-TABLE — §2 of BROWSER-GATE.md lists the seven checks by name in a table. Only the SIZE of that
# table's subject (7) and the EXISTENCE of every name it contains are re-derived; the composition
# is not. Replace one row's check with a different check that exists and see whether anything
# notices.
# =============================================================================================
if want RTABLE; then
  say "RTABLE §2's table names a DIFFERENT existing check — is the composition re-derived at all?"
  DOC="$REPO/BROWSER-GATE.md"
  mutate_backup "$DOC"
  python3 - "$DOC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "| `verify_npm_pack_no_optional_native` | the packed tarball declares no optional native dependency and holds no binary |"
assert old in s, "the table row is not where the mutation expects it"
new = "| `verify_carry_set_complete` | the packed tarball declares no optional native dependency and holds no binary |"
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check ci_browser_gate
  restore_all
fi

if want M6b; then
  say "M6b binary content under an INNOCENT name — only the UTF-8 decode arm can catch it"
  printf '\377\376\000\001not-text-at-all\000\377' >"$REPO/ct-host/src/lookup.json"
  run_check verify_npm_pack_no_optional_native
  rm -f "$REPO/ct-host/src/lookup.json"
  restore_all
fi

if want M3; then
  say "M3  a cpp_* file reached by the browser entry point (M28 records this as 1 failure)"
  ENTRY="$REPO/browser/src/entry_browser.ts"
  mutate_backup "$ENTRY"
  printf 'export const CPP_PROBE = 1;\n' >"$REPO/browser/src/cpp_probe.ts"
  printf "\nexport { CPP_PROBE } from './cpp_probe.ts';\n" >>"$ENTRY"
  run_check verify_browser_bundle_no_native_deps "M27_BUNDLE_REFRESH=1"
  rm -f "$REPO/browser/src/cpp_probe.ts"
  restore_all
fi

if want M4; then
  say "M4  the scanner's package derivation weakened from a BOUNDARY to a substring"
  SCAN="$REPO/verification/_m28_bundle_scan.py"
  mutate_backup "$SCAN"
  python3 - "$SCAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''    for p in FORBIDDEN_PACKAGES:
        print("FORBIDDEN-PACKAGE\\t%s\\t%d" % (p, 1 if p in packages else 0))'''
assert old in s, "the forbidden-package loop is not where the mutation expects it"
new = '''    for p in FORBIDDEN_PACKAGES:
        hit = 1 if any(p.split("/")[-1] in k for k in inputs) else 0
        print("FORBIDDEN-PACKAGE\\t%s\\t%d" % (p, hit))'''
open(p, "w").write(s.replace(old, new))
PY
  run_check verify_browser_bundle_no_native_deps
  restore_all
fi

if want M11; then
  say "M11 one figure in BROWSER-GATE.md rotted by one"
  DOC="$REPO/BROWSER-GATE.md"
  mutate_backup "$DOC"
  python3 - "$DOC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "- The browser bundle's module graph has 1061 inputs."
assert old in s, "the figure is not where the mutation expects it"
open(p, "w").write(s.replace(old, "- The browser bundle's module graph has 1060 inputs.", 1))
PY
  run_check ci_browser_gate
  restore_all
fi

if want M12; then
  say "M12 the CI job runs the checks itself instead of the recipe (the parallel copy)"
  WF="$REPO/.github/workflows/avm-wasm.yml"
  mutate_backup "$WF"
  python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "            dev-exec just ci-browser-gate' 2>&1 | tee ci-browser-gate.log\n"
assert old in s
new = ("            verification/verify_browser_bundle_no_node_builtins.sh\n"
       "            verification/smoke_browser_headless_full_flow.sh' 2>&1 | tee ci-browser-gate.log\n")
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check ci_browser_gate
  restore_all
fi

# ---- the two arms M28 honestly declared as NOT coverage, re-run to confirm the declaration -----
if want M1; then
  say "M1  external: ['util'] alone — DECLARED as not coverage; must still be 64/0 PASS"
  DRIVER="$REPO/browser/esbuild-driver.mjs"
  mutate_backup "$DRIVER"
  python3 - "$DRIVER" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out, done = [], False
for line in lines:
    out.append(line)
    if not done and "platform: 'browser'" in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(indent + "external: ['util'],")
        done = True
assert done, "no platform: 'browser' line to mutate"
open(p, "w").write("\n".join(out))
PY
  run_check verify_browser_bundle_no_node_builtins "M27_BUNDLE_REFRESH=1"
  restore_all
fi

if want M1b; then
  say "M1b the util SHIM removed AND util left external — the builtin genuinely reached"
  BUILD="$REPO/browser/build.mjs"
  DRIVER="$REPO/browser/esbuild-driver.mjs"
  mutate_backup "$BUILD"; mutate_backup "$DRIVER"
  python3 - "$BUILD" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  util: path.join(REPO, 'browser-probe/shims/util.js'),\n"
assert old in s, "the util shim entry is not where the mutation expects it"
open(p, "w").write(s.replace(old, "", 1))
PY
  python3 - "$DRIVER" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out, done = [], False
for line in lines:
    out.append(line)
    if not done and "platform: 'browser'" in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(indent + "external: ['util'],")
        done = True
assert done
open(p, "w").write("\n".join(out))
PY
  run_check verify_browser_bundle_no_node_builtins "M27_BUNDLE_REFRESH=1"
  restore_all
fi

if want M7; then
  say "M7  the planted differential/ import at the real budgets — DECLARED as not coverage"
  ENTRY="$REPO/browser/src/entry_browser.ts"
  mutate_backup "$ENTRY"
  printf "\nexport { injectFault } from '../../diffsim/src/public/public_tx_simulator/differential/fault_injection.ts';\n" >>"$ENTRY"
  run_check verify_verification_code_unreachable_from_browser "M27_BUNDLE_REFRESH=1"
  restore_all
fi

if want M7b; then
  say "M7b the same planted import with the chunk budgets raised out of the way"
  ENTRY="$REPO/browser/src/entry_browser.ts"
  BUDGETS="$REPO/browser/chunk-budgets.json"
  mutate_backup "$ENTRY"; mutate_backup "$BUDGETS"
  python3 - "$BUDGETS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for b in d["budgets"]:
    b["maxGzipKB"] = 99999
for b in d["entryBudgets"]:
    b["maxGzipKB"] = 99999
json.dump(d, open(p, "w"), indent=2)
PY
  printf "\nexport { injectFault } from '../../diffsim/src/public/public_tx_simulator/differential/fault_injection.ts';\n" >>"$ENTRY"
  run_check verify_verification_code_unreachable_from_browser "M27_BUNDLE_REFRESH=1"
  restore_all
fi

if want M8; then
  say "M8  the page's reported digest over ONE BYTE MORE than it held — only the JOIN breaks"
  ARMS="$REPO/tools/run_browser_arms.mjs"
  mutate_backup "$ARMS"
  python3 - "$ARMS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "createHash('sha256').update(Buffer.from(containerBase64, 'base64')).digest('hex')"
assert old in s, "the in-page digest is not where the mutation expects it"
new = ("createHash('sha256')"
       ".update(Buffer.concat([Buffer.from(containerBase64, 'base64'), Buffer.from([0])]))"
       ".digest('hex')")
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check smoke_browser_headless_full_flow "M27_ARMS_REFRESH=1"
  restore_all
fi

printf '\n########## DONE\n' | tee -a "$OUT"
