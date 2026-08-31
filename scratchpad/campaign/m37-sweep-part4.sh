#!/usr/bin/env bash
# The M37 sweep, PART 4 — m19..m36 re-measured with the environment PART 3 DID NOT HAVE.
#
#   TMPDIR=$HOME/.cache/aztec-verification-scratch nohup direnv exec <repo> \
#       bash scratchpad/campaign/m37-sweep-part4.sh > ~/.cache/aztec-m37-sweep-part4.log 2>&1 &
#
# WHY PART 3 DOES NOT COUNT, EVEN THOUGH IT PRINTED `SWEEPDONE`.
#
# Part 3 ran to completion and the summariser ACCEPTED it: balanced start/rc= markers, a
# `SWEEPDONE` at column 0, no holes, and a printed TOTAL of 2,991 against a reference of 5,683.
# That total is worthless, and the summariser could not have known:
#
#   * `M27_CHROMIUM` was never exported, so `m27_require_chromium` refused in m27, m28, m29, m32,
#     m33, m34, m35 and m36 -- 23 checks, every one of them `0 assertion(s), 1 failure(s)`.
#   * m20, m22 and m23 still refused with "no built avm.wasm was found", because the reclaim in the
#     PART 2 script had deleted the trees their `*_find_module` searches. Part 3's m12 did rebuild
#     one -- into `aztec-m12-reactor`, which is on m19's search list and on NOBODY ELSE'S.
#   * m25, m26, m30 and m31 refused on probe/wasm builds that failed.
#
# THE LESSON IS ABOUT THE INSTRUMENT, NOT THE RUN. `SWEEPDONE` plus a clean summariser is a
# STRUCTURAL check on the log; it cannot see a run in which every check refused for an
# environmental reason. A milestone reporting `0 assertion(s), 1 failure(s)` is not a milestone
# that failed -- it is a milestone that NEVER RAN, and the two must not be added into one total.
#
# WHAT THIS RUN FIXES, AND WHAT IT CANNOT.
#
#   * `M27_CHROMIUM` is exported to the system Google Chrome. Measured on m36 before this script
#     was written: `verify_local_history_boundary_declared` 13 assertions/1 failure -> 34/0, and
#     m36 as a whole 13 -> 140 against a reference of 137.
#   * `AVM_WASM_PATH` is exported, which is the override AGENTS.md itself prescribes and the exact
#     path its example names. This is a DECLARED SUBSTITUTION and must be read as one: m20, m22 and
#     m23 are being pointed at m27's module rather than at the m13/m15/m17/m18 trees their own
#     discovery prefers, because those trees no longer exist.
#   * IT CANNOT restore m13-contractdb, m15-shapes, m17-node-host or m18-orchestration. Rebuilding
#     them is the ~60 GB this host does not have.
#
# THE DISK GUARD IS THE POINT OF THE LOOP. This host had 14 GB free when the script was written
# against milestones that want 14 GB each. The guard stops BEFORE a milestone rather than during
# one, so the log ends at a milestone boundary and the summariser's hole detection stays meaningful.
# A run that dies mid-milestone is the failure mode part 1 already paid for.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

export TMPDIR="${TMPDIR:-$HOME/.cache/aztec-verification-scratch}"
mkdir -p "$TMPDIR"

# The two environment facts part 3 lacked.
export M27_CHROMIUM="${M27_CHROMIUM:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
export AVM_WASM_PATH="${AVM_WASM_PATH:-$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"

MIN_FREE_GB="${MIN_FREE_GB:-6}"
MILESTONES="${MILESTONES:-m19 m20 m21 m22 m23 m24 m25 m26 m27 m28 m29 m30 m31 m32 m33 m34 m35 m36}"

# `df -Pk` AND NOT `df -g`. The first version of this used `df -g`, which is a BSD spelling; the
# `df` on this host's PATH comes from nix and is GNU, which rejects it. Every call printed nothing,
# so `free=G` went into the log, `[ "" -lt 6 ]` errored, and — because this script sets `-u` and
# `-o pipefail` but NOT `-e` — the loop carried on with NO DISK GUARD AT ALL for the whole run.
#
# A guard that fails OPEN is worse than no guard, because the log still reads as though one was
# armed. `-Pk` is POSIX, works under both dfs, and 1K blocks divided out is the only arithmetic.
free_gb() { df -Pk / | awk 'NR==2{printf "%d", $4/1048576}'; }

printf 'part4 starting %s\n' "$(date -Is)"
printf 'node: %s   TMPDIR: %s\n' "$(node --version 2>/dev/null)" "$TMPDIR"
printf 'chromium: %s\n' "$("$M27_CHROMIUM" --version 2>/dev/null)"
printf 'avm.wasm: %s (%s bytes)\n' "$AVM_WASM_PATH" "$(wc -c < "$AVM_WASM_PATH" 2>/dev/null)"
printf 'free at start: %sG (guard %sG)\n' "$(free_gb)" "$MIN_FREE_GB"

stopped=""
for m in $MILESTONES; do
  f="$(free_gb)"
  if [ "$f" -lt "$MIN_FREE_GB" ]; then
    printf '#### STOPPING BEFORE %s: %sG free is under the %sG guard\n' "$m" "$f" "$MIN_FREE_GB"
    stopped="$m"
    break
  fi
  printf '######## %s start %s   free=%sG\n' "$m" "$(date -Is)" "$f"
  t0=$(date +%s)
  just "verify-$m"
  rc=$?
  t1=$(date +%s)
  printf '######## %s rc=%d secs=%d\n' "$m" "$rc" "$((t1 - t0))"
  printf '#### free after %s: %sG\n' "$m" "$(free_gb)"
done

printf 'part4 finished %s\n' "$(date -Is)"
# SWEEPDONE IS PRINTED ONLY IF NOTHING WAS SKIPPED. The marker means "the requested set ran", and
# a guard-stop means it did not. Printing it anyway is how part 3 came to be believed.
if [ -n "$stopped" ]; then
  printf 'PART4 INCOMPLETE — stopped before %s on the disk guard\n' "$stopped"
else
  printf 'SWEEPDONE\n'
fi
