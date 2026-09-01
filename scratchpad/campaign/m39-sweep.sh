#!/usr/bin/env bash
# The M0–M39 sweep, one milestone at a time, in THIS repository's own dev shell.
#
#   setsid nohup direnv exec /home/zahary/m/blocktracer/aztec-avm-runtime \
#       bash scratchpad/campaign/m39-sweep.sh > ~/.cache/aztec-m39-sweep.log 2>&1 < /dev/null &
#
# THE SHELL IS THE MEASUREMENT'S, NOT THE AGENT'S CONVENIENCE. M19's review found M4 red by four
# assertions because clang's WebAssembly driver runs `wasm-opt` when it finds one on PATH, and M25
# found the OQ-6 benchmark running on the SYSTEM node — v25.9.0 / V8 14.1 — because the invocation
# used the workspace root's `.envrc` instead of this repository's. Both are the same defect: the
# engine is part of the measurement.
#
# `$TMPDIR` is under `~/.cache` and so is this log. `/tmp` on this host is a 32 GB tmpfs shared
# with every build and every other agent; M22's sweep lost two regions of its own log to it, and
# the campaign total survived both holes while the per-milestone attribution was destroyed.
#
# Each milestone gets a start marker AND an end marker carrying its rc and its elapsed seconds, so
# `m39-sweep-sum.py` can tell a milestone that ran from one whose output was lost, and REFUSE to
# print a total while a hole is open.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

export TMPDIR="${TMPDIR:-$HOME/.cache/aztec-verification-scratch}"
mkdir -p "$TMPDIR"

MILESTONES="${MILESTONES:-m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 m16 m17 m18 m19 m20 m21 m22 m23 m24 m25 m26 m27 m28 m29 m30 m31 m32 m33 m34 m35 m36 m37 m38 m39}"

printf 'sweep starting %s\n' "$(date -Is)"
printf 'node: %s   TMPDIR: %s\n' "$(node --version 2>/dev/null)" "$TMPDIR"

for m in $MILESTONES; do
  printf '######## %s start %s\n' "$m" "$(date -Is)"
  t0=$(date +%s)
  just "verify-$m"
  rc=$?
  t1=$(date +%s)
  printf '######## %s rc=%d secs=%d\n' "$m" "$rc" "$((t1 - t0))"
done

printf 'sweep finished %s\n' "$(date -Is)"
printf 'SWEEPDONE\n'
