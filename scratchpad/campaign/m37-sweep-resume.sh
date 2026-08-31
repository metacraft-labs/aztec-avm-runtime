#!/usr/bin/env bash
# The M37 sweep, RESUMED from m12 and made SELF-LIMITING.
#
#   TMPDIR=$HOME/.cache/aztec-verification-scratch nohup direnv exec <repo> \
#       bash scratchpad/campaign/m37-sweep-resume.sh > ~/.cache/aztec-m37-sweep-part2.log 2>&1 &
#
# WHY THIS EXISTS RATHER THAN A SECOND FULL RUN. The first full run on this host died at m13:
# 37 GB free when m10 started, 12 GB when m13 failed, against milestones that require 14 GB each.
# THE SWEEP CONSUMED THE DISK ITSELF -- m9's observer trees (5.6 GB) and m6's wasm build (9.2 GB)
# were 15 GB of it -- so this is not background pressure and it will recur on any host without
# ~60 GB of headroom. m0..m11 are already measured and recorded in the part-1 log; re-running
# them would cost hours and change nothing.
#
# RECLAIM WAS REMOVED, AND THE REASON IS THE WHOLE POINT OF THIS COMMENT.
#
# This script originally deleted each milestone's work directory once its rc= marker was written,
# on the reasoning that "the log is the artefact and the trees are scratch". THAT REASONING IS
# WRONG, and it cost m19..m24 before it was caught. THE MILESTONES ARE NOT INDEPENDENT: later
# checks consume artefacts earlier ones leave behind, and a work directory is an INPUT to
# milestones downstream of the one that created it.
#
# Measured after the fact -- 22 of ~30 work directories are referenced by a file belonging to some
# other milestone. The one that bit: `m19_find_module` looks for a built `avm.wasm` in
#     $HOME/.cache/aztec-m18-orchestration/m12/.../avm.wasm
#     $HOME/.cache/aztec-m17-node-host/m12/.../avm.wasm
#     $HOME/.cache/aztec-m12-reactor/m12/.../avm.wasm
# and reclaim had deleted all three. m19, m20, m21, m22, m23 and m24 then refused with
# "no built avm.wasm was found" -- correctly, loudly, and entirely because of this script.
#
# The check that would have prevented it takes one query over verification/ and was run AFTER the
# damage rather than before. Disk pressure is handled by headroom and by reclaiming BETWEEN runs,
# never inside one.
#
# `upstream/next` IS NOT FETCHED DURING THIS RUN, DELIBERATELY. m19 resolves it and has not run;
# m7, m10 and m11 resolved it already and did not have it. Fetching mid-resume would put the
# campaign total across two states of `aztec-packages`. The fetch, and m11's re-measurement,
# happen AFTER SWEEPDONE as their own declared move.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

export TMPDIR="${TMPDIR:-$HOME/.cache/aztec-verification-scratch}"
mkdir -p "$TMPDIR"

# m12 leads, and not to be re-measured: it REBUILDS the avm.wasm that reclaim destroyed,
# into the path m19..m24 search. Its own numbers should reproduce 691 exactly, which is a
# free check that the rebuild really restored the input rather than merely a file.
MILESTONES="${MILESTONES:-m12 m19 m20 m21 m22 m23 m24 m25 m26 m27 m28 m29 m30 m31 m32 m33 m34 m35 m36}"

printf 'resume starting %s\n' "$(date -Is)"
printf 'node: %s   TMPDIR: %s\n' "$(node --version 2>/dev/null)" "$TMPDIR"
printf 'free at start: %s\n' "$(df -h / | tail -1 | awk '{print $4}')"

for m in $MILESTONES; do
  printf '######## %s start %s   free=%s\n' "$m" "$(date -Is)" "$(df -h / | tail -1 | awk '{print $4}')"
  t0=$(date +%s)
  just "verify-$m"
  rc=$?
  t1=$(date +%s)
  printf '######## %s rc=%d secs=%d\n' "$m" "$rc" "$((t1 - t0))"
  printf '#### free after %s: %s\n' "$m" "$(df -h / | tail -1 | awk '{print $4}')"
done

printf 'resume finished %s\n' "$(date -Is)"
printf 'SWEEPDONE\n'
