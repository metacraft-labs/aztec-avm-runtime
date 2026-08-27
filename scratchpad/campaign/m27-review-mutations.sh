#!/usr/bin/env bash
# M27 review mutations.
#
# The implementation agent left NO `m27-mutations.sh` (see the review log, F0), so the eleven arms
# the milestone describes cannot be re-run. These are the review's own, written against the CLAIMS
# the milestone makes rather than against the arms it says it ran.
#
#   ./m27-review-mutations.sh <arm>
#
# EVERY ARM RESTORES ITS SUBJECT ON EXIT, including on a signal, because CAMPAIGN-BRIEF.md records a
# mutated artefact outliving its restored source. Restoration is verified by `git diff` afterwards.
#
# ARMS
#   P1  fee-juice shim: one line REPEATED TWENTY TIMES            -> verify_browser_artifacts_lazy
#   P2  fee-juice shim: two adjacent lines SWAPPED                -> verify_browser_artifacts_lazy
#   P3  fee-juice shim: fee payer replaced by a constant          -> verify_browser_artifacts_lazy
#   D   the poseidon2 redirect DELETED (DD-11's first route)      -> verify_public_only_page_…
#   E   the negative control stops calling initSingleton          -> verify_public_only_page_…
#   A   the browser download made a no-op                         -> e2e_browser_downloads_…
#   B   ONE frame instead of two                                  -> e2e_browser_downloads_…
#   C   poseidon2's answer perturbed by one                       -> test_browser_crypto_matches_bb_js
#   F   a lazy contract artifact made EAGER                       -> the BUILD must refuse
#   F2  a budget DELETED                                          -> the BUILD must refuse
#   H   an arm that never settles (THE HANG)                      -> a named failure + a summary line
#   I   a check killed before `finish` (DIE-BEFORE-SUMMARY)       -> the trap prints a summary
set -uo pipefail

REPO="/home/zahary/m/blocktracer/aztec-avm-runtime"
LOG="${M27R_LOG:-$HOME/.cache/m27-review}"
mkdir -p "$LOG"
cd "$REPO"

restore() { git checkout -- "$@" 2>/dev/null || git checkout-index -f -- "$@"; }

run_check() {
  local name="$1"
  direnv exec . bash -c "cd '$REPO' && unset TMPDIR && verification/$name.sh" \
    > "$LOG/$ARM.$name.log" 2>&1
  local rc=$?
  printf '%s rc=%d | %s\n' "$name" "$rc" \
    "$(grep -E "^$name: [0-9]+ assertion\(s\), [0-9]+ failure\(s\)$" "$LOG/$ARM.$name.log" | tail -1)"
  grep -E '^  FAIL|^[a-z_0-9]+: (cannot run|FAIL)' "$LOG/$ARM.$name.log" | head -6
  return $rc
}

run_build() {
  direnv exec . bash -c "cd '$REPO' && unset TMPDIR && node browser/build.mjs" \
    > "$LOG/$ARM.build.log" 2>&1
  printf 'browser/build.mjs rc=%d\n' "$?"
  tail -6 "$LOG/$ARM.build.log"
}

ARM="${1:?usage: m27-review-mutations.sh <arm>}"
SUBJ=""

case "$ARM" in

P1)
  SUBJ=browser/src/shims/protocol_fee_juice.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
line = "  return deriveStorageSlotInMap(artifact.storageLayout.balances.slot, feePayer);\n"
assert src.count(line) == 1
open(p, 'w').write(src.replace(line, line * 20))
PY
  run_check verify_browser_artifacts_lazy ;;

P2)
  SUBJ=browser/src/shims/protocol_fee_juice.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
a = "  const balanceSlot = await computeFeePayerBalanceStorageSlot(feePayer);\n"
b = "  return computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, balanceSlot);\n"
assert src.count(a) == 1 and src.count(b) == 1
open(p, 'w').write(src.replace(a + b, b + a))
PY
  run_check verify_browser_artifacts_lazy ;;

P3)
  SUBJ=browser/src/shims/protocol_fee_juice.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
line = "  return deriveStorageSlotInMap(artifact.storageLayout.balances.slot, feePayer);\n"
assert src.count(line) == 1
open(p, 'w').write(src.replace(line, "  feePayer = ProtocolContractAddress.FeeJuice;\n" + line))
PY
  run_check verify_browser_artifacts_lazy ;;

# THE DD-11 ARM. Delete the poseidon2 redirect and the page goes back to `@aztec/foundation`'s
# bb.js-backed poseidon, which in a browser is `BarretenbergSync.initSingleton()`.
D)
  SUBJ=browser/build.mjs; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = """  [path.join(ORCH, 'node_modules/@aztec/foundation/dest/crypto/poseidon/index.js')]:
    path.join(HERE, 'src/foundation_poseidon.ts'),
"""
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, ""))
PY
  run_check verify_public_only_page_never_fetches_barretenberg ;;

# THE CONTROL'S OWN CONTROL. If the negative control page stops reaching barretenberg, the check
# must notice — otherwise a control that never fires is indistinguishable from one that reports
# nothing, which is the defect the control exists to rule out.
# The mutation is in the RUNNER, not in the page, and deliberately so: editing
# `loadProvingStack` out of `demo/main.ts` removes the only dynamic import of bb.js from the entry
# set, which re-splits the chunks and trips a shared-chunk budget — the build then refuses and the
# arm reddens for a reason that has nothing to do with the control. Silencing the CALL leaves the
# module graph, the chunks and every budget exactly as they are, and asks the one question the
# control exists to answer: does the check notice an observer that never fired?
E)
  SUBJ=tools/run_browser_arms.mjs; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "      control = await page.eval('window.avmDemo.loadProvingStack()');\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, "      control = { fetched: false }; // MUTATION E: the control never fires\n"))
PY
  run_check verify_public_only_page_never_fetches_barretenberg ;;

# THE PRODUCT CLAIM'S FIRST LINK. If the container does not come out of the BROWSER's download
# machinery, the check must fail — no Node-side path may substitute for it.
A)
  SUBJ=browser/src/ct_download.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "  if (options.download !== false) offerDownload(recording.container, filename);\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, "  // MUTATION A: the browser download is not offered.\n"))
PY
  run_check e2e_browser_downloads_ct_container_and_ct_print_parses ;;

# ONE FRAME INSTEAD OF TWO. The milestone names this as arm G.
B)
  SUBJ=browser/src/ct_download.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "  const names = options.frameNames.length ? options.frameNames : ['public_dispatch'];\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, "  const names = ['public_dispatch'];\n"))
PY
  run_check e2e_browser_downloads_ct_container_and_ct_print_parses ;;

# THE SUBSTITUTION, NUMERICALLY WRONG. One field element off is what a wrong round constant looks
# like from the host side.
C)
  SUBJ=browser/src/poseidon.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "  return Fr.fromBuffer(Buffer.from(raw));\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(
    needle,
    "  const bad = Buffer.from(raw); bad[31] ^= 1; // MUTATION C: one bit, like a wrong round constant\n"
    "  return Fr.fromBuffer(bad);\n"))
PY
  run_check test_browser_crypto_matches_bb_js ;;

# THE BUDGET MUST BE ABLE TO REFUSE. F makes a lazy artifact eager; F2 deletes a budget.
# F is the REALISTIC regression rather than a contrived one: the class-registry redirect is DROPPED,
# so the eager `index.js` with its 998 KB artifact import comes back. The build's own
# "every redirect fired" guard cannot see this — a redirect that is not in the table fired zero
# times only in the sense that it does not exist — so the only thing left to notice is a budget.
F)
  SUBJ=browser/build.mjs; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "  [path.join(PC, 'class-registry/index.js')]: path.join(PC, 'class-registry/lazy.js'),\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, ""))
PY
  run_build ;;

# F-RIGHT: the same regression, with the entry budget raised out of the way, to find out whether
# `verify_browser_artifacts_lazy`'s EDGE-KIND assertions — the ones written for this — can fail at
# all, or whether the budget always gets there first.
F-RIGHT)
  SUBJ="browser/build.mjs browser/chunk-budgets.json"; trap 'restore $SUBJ' EXIT
  python3 - <<'PY'
import json
p = 'browser/build.mjs'; src = open(p).read()
needle = "  [path.join(PC, 'class-registry/index.js')]: path.join(PC, 'class-registry/lazy.js'),\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, ""))
b = 'browser/chunk-budgets.json'; d = json.load(open(b))
for row in d['budgets']:
    row['maxGzipKB'] = 99999
for row in d['entryBudgets']:
    row['maxGzipKB'] = 99999
json.dump(d, open(b, 'w'), indent=2)
PY
  run_check verify_browser_artifacts_lazy ;;

F2)
  SUBJ=browser/chunk-budgets.json; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
before = len(d["budgets"])
d["budgets"] = [b for b in d["budgets"] if b.get("name") != "shared-chunk"]
assert len(d["budgets"]) < before, "no shared-chunk budget to delete"
json.dump(d, open(p, "w"), indent=2)
PY
  run_build ;;

# THE HANG. An arm that never settles must become a NAMED failure with a summary line, not silence.
H)
  SUBJ=browser/demo/main.ts; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = "async function armTokenTransfer(): Promise<Record<string, unknown>> {\n"
assert src.count(needle) == 1
open(p, 'w').write(src.replace(needle, needle + "  await new Promise(() => {}); // MUTATION H: never settles\n"))
PY
  M27_ARMS_TIMEOUT=60 run_check verify_public_only_page_never_fetches_barretenberg ;;

# DIE BEFORE `finish`. The trap must still print a summary line, or the milestone reads SMALLER
# rather than RED.
I)
  SUBJ=verification/verify_public_only_page_never_fetches_barretenberg.sh; trap 'restore "$SUBJ"' EXIT
  python3 - "$SUBJ" <<'PY'
import sys
p = sys.argv[1]; src = open(p).read()
needle = 'echo "== 4. THE NEGATIVE CONTROL'
i = src.index(needle)
open(p, 'w').write(src[:i] + "kill -TERM $$   # MUTATION I: die before finish\n" + src[i:])
PY
  run_check verify_public_only_page_never_fetches_barretenberg ;;

*) echo "unknown arm $ARM" >&2; exit 2 ;;
esac

[ -n "$SUBJ" ] && { restore $SUBJ; git diff --quiet -- $SUBJ && echo "restored: $SUBJ" || echo "NOT RESTORED: $SUBJ"; }
