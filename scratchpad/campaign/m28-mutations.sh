#!/usr/bin/env bash
# m28-mutations.sh — the M28 mutation matrix.
#
#   bash scratchpad/campaign/m28-mutations.sh [arm ...]      (no args: every arm)
#
# Run from the repository root, INSIDE this repository's own dev shell
# (`direnv exec . bash scratchpad/campaign/m28-mutations.sh`), and NEVER beside a verification
# sweep: a mutation harness and a sweep are two writers over one working tree.
#
# EVERY ARM RESTORES THE TREE AND THE RESTORATION IS CHECKED. `git diff --quiet` over the touched
# paths after each arm; a dirty tree stops the harness rather than poisoning the next arm.
# `CAMPAIGN-BRIEF.md`: "a mutated artefact outlived its restored source".
#
# AND WHEN AN ARM REDDENS, WHICH ASSERTIONS WENT RED IS PART OF THE RESULT. "The check failed" and
# "the check saw what I broke" are different statements and only the second is coverage. Every arm
# prints its failing assertion lines.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"
OUT="${M28_MUTATION_LOG:-$HOME/.cache/m28-mutations.log}"
: >"$OUT"

WANT=("$@")
want() { # <arm>
  [ "${#WANT[@]}" -eq 0 ] && return 0
  local a
  for a in "${WANT[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

say() { printf '\n########## %s\n' "$*" | tee -a "$OUT"; }
run_check() { # <check-name> [env assignments...]
  local check="$1"; shift
  local log="$HOME/.cache/m28-arm-$check.$$.log"
  ( env "$@" "$REPO/verification/$check.sh" ) >"$log" 2>&1
  local rc=$?
  {
    printf 'rc=%s\n' "$rc"
    grep -E "^${check}: |^just [a-z-]*: |^  FAIL|cannot run:" "$log" | head -25
  } | tee -a "$OUT"
  rm -f "$log"
}

BACKUPS=()
mutate_backup() { # <path>
  cp -p "$1" "$1.m28bak" && BACKUPS+=("$1")
}
restore_all() {
  local p
  for p in "${BACKUPS[@]}"; do
    # `touch` AFTER THE RESTORE, AND IT IS NOT COSMETIC. `cp -p` preserves mtimes, so a restored
    # source is OLDER than the bundle the mutation produced and `m27_bundle_newer_inputs` — which
    # compares mtimes — does not rebuild. Measured: M7's build failed at the chunk budget AFTER
    # esbuild had written `browser/dist`, the mutated bundle stayed on disk, and M9..M12 each
    # reported four extra failures naming figures from it. That is CAMPAIGN-BRIEF.md's "a mutated
    # artefact outlived its restored source", produced by this harness.
    [ -f "$p.m28bak" ] && mv "$p.m28bak" "$p" && touch "$p"
  done
  BACKUPS=()
  # New files an arm created are removed by the arm itself; this is the check that the tree is
  # back, and it is the ONLY thing that stops one arm's mutation being read as the next arm's
  # result.
  #
  # AGAINST A BASELINE TAKEN AT START, NOT AGAINST `git diff --quiet`. M28 is uncommitted work —
  # the Justfile, `DRIFT.md` and the workflow are all legitimately modified — so `--quiet` would
  # abort on the first arm. What must be invariant is the DIFF, and it is compared by digest.
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

# ---------------------------------------------------------------------------------------------
# M0 — THE REVERSE DIRECTION OF M27'S REVIEW FINDING #1.
# The fix is in the tree and §1 of the impl log shows a cold work directory running every check.
# This is the other half: with the `rc` guard removed, the same cold run must FAIL.
# ---------------------------------------------------------------------------------------------
if want M0; then
  say "M0  the arm install without its rc guard (M27 review finding #1, reversed)"
  LIB="$REPO/verification/lib_m27_browser.sh"
  mutate_backup "$LIB"
  python3 - "$LIB" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    if [ "$rc" -ne 0 ] && [ -s "$M27_ARMS.tmp" ]; then'
assert old in s, "the guard is not where the mutation expects it"
open(p, "w").write(s.replace(old, '    if [ -s "$M27_ARMS.tmp" ]; then'))
PY
  rm -rf "$HOME/.cache/aztec-m28-mut-cold"
  run_check verify_public_only_page_never_fetches_barretenberg \
    "M27_WORK=$HOME/.cache/aztec-m28-mut-cold" \
    "AVM_WASM_PATH=$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M1 / M2 — verify_browser_bundle_no_node_builtins
# ---------------------------------------------------------------------------------------------
if want M1; then
  say "M1  a Node builtin left EXTERNAL in the browser pass (util), which is the shape the gate is named for"
  DRIVER="$REPO/browser/esbuild-driver.mjs"
  mutate_backup "$DRIVER"
  # The browser pass has no `external` today; giving it one is exactly how a Node builtin comes to
  # be reached by a browser bundle WITHOUT the build refusing — which is the only version of this
  # mutation that reaches the check rather than being caught by esbuild first.
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

if want M2; then
  say "M2  a polyfill DECLARED that nothing imports (path added to the shim table)"
  BUILD="$REPO/browser/build.mjs"
  mutate_backup "$BUILD"
  python3 - "$BUILD" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  module: path.join(HERE, 'src/shims/module.js'),"
assert old in s
s = s.replace(old, old + "\n  path: path.join(REPO, 'browser-probe/shims/tty.js'),")
open(p, "w").write(s)
PY
  run_check verify_browser_bundle_no_node_builtins "M27_BUNDLE_REFRESH=1"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M3 / M4 — verify_browser_bundle_no_native_deps
# ---------------------------------------------------------------------------------------------
if want M3; then
  say "M3  a cpp_* file reached by the browser entry point"
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

# ---------------------------------------------------------------------------------------------
# M5 / M6 — verify_npm_pack_no_optional_native
# ---------------------------------------------------------------------------------------------
if want M5; then
  say "M5  a shipped package declares an optional native dependency"
  PKG="$REPO/node-host/package.json"
  mutate_backup "$PKG"
  python3 - "$PKG" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["optionalDependencies"] = {"@aztec/native": "5.0.0-nightly.20260626"}
json.dump(d, open(p, "w"), indent=2)
PY
  run_check verify_npm_pack_no_optional_native
  restore_all
fi

if want M6a; then
  say "M6a a prebuilt binary in a shipped package, caught by the EXTENSION arm"
  printf '\177ELF\002\001\001\000\377\376\375\374' >"$REPO/ct-host/src/prebuilt.node"
  run_check verify_npm_pack_no_optional_native
  rm -f "$REPO/ct-host/src/prebuilt.node"
  restore_all
fi

if want M6b; then
  say "M6b binary content under an INNOCENT name, which only the decode arm can catch"
  printf '\377\376\000\001not-text-at-all\000\377' >"$REPO/ct-host/src/lookup.json"
  run_check verify_npm_pack_no_optional_native
  rm -f "$REPO/ct-host/src/lookup.json"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M7 — verify_verification_code_unreachable_from_browser: THE PLANTED IMPORT
# ---------------------------------------------------------------------------------------------
if want M7; then
  say "M7  a browser entry point imports a file from diffsim/.../differential/"
  ENTRY="$REPO/browser/src/entry_browser.ts"
  mutate_backup "$ENTRY"
  printf "\nexport { injectFault } from '../../diffsim/src/public/public_tx_simulator/differential/fault_injection.ts';\n" >>"$ENTRY"
  run_check verify_verification_code_unreachable_from_browser "M27_BUNDLE_REFRESH=1"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M8 — smoke_browser_headless_full_flow: A BROKEN JOIN, WITH EVERY STAGE STILL "WORKING"
# ---------------------------------------------------------------------------------------------
if want M8; then
  say "M8  the downloaded container is not the bytes the page held (the load->container join)"
  ARMS="$REPO/tools/run_browser_arms.mjs"
  mutate_backup "$ARMS"
  python3 - "$ARMS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# The digest the PAGE reports is taken over one byte more than the page actually held. Every stage
# still succeeds — the transaction is processed, the block seals, a file reaches the download
# directory and `ct-print` parses it — and ONLY the identity between the page's bytes and the
# disk's is broken. That is the thing this check adds over M27's four, so it is the thing the
# mutation has to break.
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

# ---------------------------------------------------------------------------------------------
# M9..M12 — just ci-browser-gate
# ---------------------------------------------------------------------------------------------
if want M9; then
  say "M9  a check dropped from the gate recipe"
  JF="$REPO/Justfile"
  mutate_backup "$JF"
  python3 - "$JF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "      verify_npm_pack_no_optional_native \\\n      verify_verification_code_unreachable_from_browser \\\n      verify_browser_entry_points_are_dd5_shaped \\\n"
assert old in s, "the gate's check list is not where the mutation expects it"
new = old.replace("      verify_npm_pack_no_optional_native \\\n", "", 1)
open(p, "w").write(s.replace(old, new, 1))
PY
  run_check ci_browser_gate
  restore_all
fi

if want M10; then
  say "M10 continue-on-error added to the CI gate step"
  WF="$REPO/.github/workflows/avm-wasm.yml"
  mutate_backup "$WF"
  python3 - "$WF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "      - name: THE GATE — just ci-browser-gate\n"
assert old in s
open(p, "w").write(s.replace(old, old + "        continue-on-error: true\n", 1))
PY
  run_check ci_browser_gate
  restore_all
fi

if want M11; then
  say "M11 a figure in BROWSER-GATE.md rotted by one"
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

# ---------------------------------------------------------------------------------------------
# H — THE HANG. Two different paths, and they are not the same path.
# ---------------------------------------------------------------------------------------------
if want H1; then
  say "H1  the browser arms never settle (a promise that is never resolved), bound at 45s"
  ARMS="$REPO/tools/run_browser_arms.mjs"
  mutate_backup "$ARMS"
  python3 - "$ARMS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "const downloaded = "
i = s.index(needle)
open(p, "w").write(s[:i] + "await new Promise(() => {});\n  " + s[i:])
PY
  rm -rf "$HOME/.cache/aztec-m28-mut-hang"
  run_check smoke_browser_headless_full_flow \
    "M27_WORK=$HOME/.cache/aztec-m28-mut-hang" \
    "AVM_WASM_PATH=$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "M27_ARMS_TIMEOUT=45"
  restore_all
fi

if want H2; then
  say "H2  the timeout branch itself, driven directly with a bound smaller than the run"
  rm -rf "$HOME/.cache/aztec-m28-mut-hang2"
  run_check smoke_browser_headless_full_flow \
    "M27_WORK=$HOME/.cache/aztec-m28-mut-hang2" \
    "AVM_WASM_PATH=$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "M27_ARMS_TIMEOUT=3"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# D — DIE BEFORE SUMMARY. A check that dies must read as a RED gate, not a smaller one.
# ---------------------------------------------------------------------------------------------
if want D; then
  say "D   a check killed mid-run: the trap must still print a summary line"
  CHK="$REPO/verification/verify_browser_bundle_no_native_deps.sh"
  mutate_backup "$CHK"
  python3 - "$CHK" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'echo "== 4. CONTROL ONE'
assert old in s
open(p, "w").write(s.replace(old, "kill -TERM $$\n" + old, 1))
PY
  run_check verify_browser_bundle_no_native_deps
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# S — THE SCANNER TRUNCATES. Its report is a prefix, and every absence read from a prefix reads
# as a clean bundle. The sentinel is what turns that into a refusal.
# ---------------------------------------------------------------------------------------------
if want S; then
  say "S   the scanner dies before its sentinel (a truncated report must be REFUSED, not believed)"
  SCAN="$REPO/verification/_m28_bundle_scan.py"
  mutate_backup "$SCAN"
  python3 - "$SCAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    print("EMITTED-FILES\\t%d" % files)'
assert old in s, "the emitted-files line is not where the mutation expects it"
open(p, "w").write(s.replace(old, '    raise SystemExit("deliberate mid-report death")\n' + old, 1))
PY
  run_check verify_browser_bundle_no_node_builtins
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# S2 — THE SAME DEATH, SILENT. The scanner exits 0 with a truncated report, which is the shape
# the sentinel exists for: a non-zero exit is already caught by `m28_scan`'s first branch.
# ---------------------------------------------------------------------------------------------
if want S2; then
  say "S2  the scanner exits 0 with a TRUNCATED report (the sentinel's actual subject)"
  SCAN="$REPO/verification/_m28_bundle_scan.py"
  mutate_backup "$SCAN"
  python3 - "$SCAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    print("scan.done\\t1")'
assert old in s
open(p, "w").write(s.replace(old, '    pass  # sentinel deliberately not printed', 1))
PY
  run_check verify_browser_bundle_no_node_builtins
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M1b — M1 REDDENED NOTHING, AND THE REASON IS WORTH THE ARM.
# Adding `external: ['util']` to the browser pass changed nothing: esbuild applies `alias` BEFORE
# externalisation, so the shim still won. The mutation that reaches the check has to remove the
# alias as well — which is what a real regression looks like anyway (a shim dropped, the builtin
# reached).
# ---------------------------------------------------------------------------------------------
if want M1b; then
  say "M1b the util SHIM removed and util left external — the builtin genuinely reached"
  BUILD="$REPO/browser/build.mjs"
  DRIVER="$REPO/browser/esbuild-driver.mjs"
  mutate_backup "$BUILD"; mutate_backup "$DRIVER"
  python3 - "$BUILD" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  util: path.join(REPO, 'browser-probe/shims/util.js'),\n"
assert old in s, "the util shim entry is not where the mutation expects it"
open(p, "w").write(s.replace(old, "", 1))
PY2
  python3 - "$DRIVER" <<'PY2'
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
PY2
  run_check verify_browser_bundle_no_node_builtins "M27_BUNDLE_REFRESH=1"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# M7b — M7 REDDENED FOR THE WRONG REASON: the planted import took the eager set from 417 to well
# over its budget and the BUILD refused before the check ran. That is the right behaviour and it is
# not coverage of this check's assertions. M27's review met the same thing and called it F-RIGHT:
# raise the budgets out of the way and run the arm again.
# ---------------------------------------------------------------------------------------------
if want M7b; then
  say "M7b the same planted differential/ import, with the chunk budgets raised out of the way"
  ENTRY="$REPO/browser/src/entry_browser.ts"
  BUDGETS="$REPO/browser/chunk-budgets.json"
  mutate_backup "$ENTRY"; mutate_backup "$BUDGETS"
  python3 - "$BUDGETS" <<'PY2'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for b in d["budgets"]:
    b["maxGzipKB"] = 99999
for b in d["entryBudgets"]:
    b["maxGzipKB"] = 99999
json.dump(d, open(p, "w"), indent=2)
PY2
  printf "\nexport { injectFault } from '../../diffsim/src/public/public_tx_simulator/differential/fault_injection.ts';\n" >>"$ENTRY"
  run_check verify_verification_code_unreachable_from_browser "M27_BUNDLE_REFRESH=1"
  restore_all
fi

# ---------------------------------------------------------------------------------------------
# E — THE ARM-ERROR BRANCH, which is NOT the branch H1 and H2 took.
# Both hang arms exceeded the bound and were killed (rc 137). A run that FAILS FAST takes a
# different path: the report is filed as `browser-failed.json`, its `arms.error.message` is read
# back out, and the refusal names it. That branch is also the POSITIVE direction of M27's review's
# finding #1 — the failed report has to be kept, and it is only kept because the `mv` is guarded.
# ---------------------------------------------------------------------------------------------
if want E; then
  say "E   an arm THROWS: the failed report must be filed and its message read back into the refusal"
  ARMS="$REPO/tools/run_browser_arms.mjs"
  mutate_backup "$ARMS"
  python3 - "$ARMS" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "const recording = await page.eval('window.avmDemo.armRecord()');"
assert needle in s, "the record arm is not where the mutation expects it"
open(p, "w").write(s.replace(needle, "throw new Error('deliberate M28 arm failure');", 1))
PY2
  rm -rf "$HOME/.cache/aztec-m28-mut-fail"
  run_check smoke_browser_headless_full_flow \
    "M27_WORK=$HOME/.cache/aztec-m28-mut-fail" \
    "AVM_WASM_PATH=$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  printf 'browser-failed.json present: %s\n' \
    "$([ -s "$HOME/.cache/aztec-m28-mut-fail/browser-failed.json" ] && echo yes || echo no)" | tee -a "$OUT"
  printf 'browser.json present:        %s\n' \
    "$([ -s "$HOME/.cache/aztec-m28-mut-fail/browser.json" ] && echo yes || echo no)" | tee -a "$OUT"
  restore_all
fi

printf '\n########## DONE\n' | tee -a "$OUT"
