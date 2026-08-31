#!/usr/bin/env bash
# lib_m29_steps.sh — shared machinery for the M29 (executed steps, not mapped ones) checks.
#
# Not to be executed directly: sourced after lib.sh and lib_m27_browser.sh by verification/*.sh.
#
# M29 asserts that what a page writes into a `.ct` is what the AVM EXECUTED. Its checks read three
# things:
#
#   1. the M27 browser arms, extended with `arms.publicOnly.transfer.executed` (the drained step
#      stream, with its opcode histogram and every record) and `arms.nativeParity` (one corpus
#      program run in the page from the native driver's own blobs);
#   2. the NATIVE x86-64 `avm_differential`, run HERE — `steps` for the reference transcript and
#      `reactorinputs` for the blobs the page is handed. Both are produced by this library in this
#      run, because "never depend on state you did not produce", and both are cheap: 3.0 s and
#      0.9 s respectively on this host;
#   3. the container the page downloaded.
#
# THE NATIVE BINARY IS M12's, LOCATED THROUGH M12's OWN MACHINERY rather than by a path guess.
# `m12_measured` reads `measured.env`, builds the tree if there is no measurement on record, and
# asserts the artefacts exist. M29 adds nothing to that and re-uses the same binary the M12 checks
# compare against — a second build would be a second thing that can disagree.
#
# EVERY SUBPROCESS IS BOUNDED, for M27's reason and M23's review's: a check that hangs reports
# nothing at all and blocks the sweep behind it, which is worse than one that fails.

M29_WORK="${M29_WORK:-$HOME/.cache/aztec-m29-steps}"
export M29_WORK

# The corpus program the differential uses. `burn` is M9's and M12's: 38,903 records, the largest of
# the eight, and the one whose per-record agreement M12 already established for the NODE host.
M29_PARITY_PROGRAM="${M29_PARITY_PROGRAM:-burn}"
# M9's measured instruction count for it. Asserted rather than derived from the run, because a
# derivation from the run is a number that agrees with itself.
M29_PARITY_RECORDS="${M29_PARITY_RECORDS:-38903}"
export M29_PARITY_PROGRAM M29_PARITY_RECORDS

M29_NATIVE_TIMEOUT="${M29_NATIVE_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, carried the way `lib_m27_browser.sh` carries it and for the same reason: a check
# that dies before `finish` prints no summary and reads as a SMALLER milestone rather than a red
# one. M22 said a third milestone wanting it is when it moves into `lib.sh`; M23, M24 and M27 each
# declined for M22's own reason and M29 declines for it too.
# ---------------------------------------------------------------------------
# DELEGATED TO `lib.sh` ON 2026-08-31. These eight lines were copied into FOURTEEN
# milestone libraries, m22..m37. M22 wrote them and said the third milestone wanting
# them is when they move into `lib.sh`; M24 declined for M22's own reason and recorded
# it as owed. The fifteenth caller turned out to be M9 — not a new milestone but the
# campaign's oldest open item — so the move is made and these are wrappers. The public
# names are unchanged, so no check needed editing, and the behaviour is identical: one
# implementation instead of fourteen, verified by the sweep.
m29_finish() { finish; }
m29_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

m29_native_steps()   { printf '%s\n' "$M29_WORK/native.steps"; }
m29_parity_inputs()  { printf '%s\n' "$M29_WORK/reactor-inputs.txt"; }

# ---------------------------------------------------------------------------
# m29_require_native — the native driver's two transcripts, produced here.
#
# Both are regenerated when the BINARY is newer than them, so a rebuilt driver cannot be compared
# against a transcript an older one produced. That is the "a mutated artefact outlived its restored
# source" rule in its mildest form and it costs four seconds.
# ---------------------------------------------------------------------------
m29_require_native() {
  m12_measured
  M29_NATIVE_BIN="$(m12_native_bin avm_differential)"
  export M29_NATIVE_BIN
  [ -x "$M29_NATIVE_BIN" ] || die "no native avm_differential at $M29_NATIVE_BIN.
             Remedy: just verify-avm-wasm-imports (which builds M12's tree and writes measured.env)"
  mkdir -p "$M29_WORK"
  local mode out
  for mode in steps reactorinputs; do
    case "$mode" in
      steps)         out="$(m29_native_steps)" ;;
      reactorinputs) out="$(m29_parity_inputs)" ;;
    esac
    if [ ! -s "$out" ] || [ "$M29_NATIVE_BIN" -nt "$out" ]; then
      note "running the native avm_differential $mode into $out"
      timeout -s KILL "$M29_NATIVE_TIMEOUT" "$M29_NATIVE_BIN" "$mode" >"$out.tmp" 2>"$out.err"
      local rc=$?
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        die "the native avm_differential $mode did not finish within ${M29_NATIVE_TIMEOUT}s.
             That is the HANG state CAMPAIGN-BRIEF.md names, reported rather than waited on."
      fi
      [ "$rc" -eq 0 ] || die "the native avm_differential $mode exited $rc; see $out.err"
      mv "$out.tmp" "$out" || die "could not install $out"
    fi
    [ -s "$out" ] || die "the native avm_differential $mode produced nothing at $out"
  done
  M29_NATIVE_SHA="$(sha256sum "$M29_NATIVE_BIN" | cut -d' ' -f1)"
  export M29_NATIVE_SHA
}

# ---------------------------------------------------------------------------
# m29_require_arms — the M27 arms, WITH M29's parity arm in them.
#
# The arms are shared with M27 and M28, and an M27 run produces them with no `M29_PARITY_INPUTS` in
# the environment, so the parity arm records a reason instead of a result. A stale report of that
# shape would make every M29 assertion read `MISSING`, which is the "both sides absent" family. So
# the arm's presence is a PRECONDITION with one forced refresh behind it, and a second absence is a
# named failure rather than a silent one.
# ---------------------------------------------------------------------------
m29_require_arms() {
  m29_require_native
  M29_PARITY_INPUTS="$(m29_parity_inputs)"
  export M29_PARITY_INPUTS M29_PARITY_PROGRAM
  m27_require_arms
  local skipped
  skipped="$(m27_arm nativeParity skipped)"
  if [ "$skipped" != "MISSING" ]; then
    note "the shared arm report has no parity arm ($skipped) — forcing one refresh"
    M27_ARMS_REFRESH=1 m27_require_arms
    skipped="$(m27_arm nativeParity skipped)"
  fi
  [ "$skipped" = "MISSING" ] || die "the browser arm report still has no native-parity arm: $skipped
             M29's differential cannot be measured without it, and an absent arm must be a failure
             rather than a smaller milestone."
}

# ---------------------------------------------------------------------------
# m29_absent <name>=<value> ... — the names whose value is `MISSING` or empty.
#
# THE NON-EMPTINESS PARTNER, IN ONE ASSERTION THAT NAMES ITS OFFENDERS. `m27_arm` prints `MISSING`
# for a path that is not there, and two `MISSING`s compare equal — which is the first and most
# common shape on `CAMPAIGN-BRIEF.md`'s list, and it fired on this check's own first run: five
# assertions over `arms.publicOnly.executed` when the field is at `arms.publicOnly.transfer.executed`,
# of which two PASSED comparing MISSING with MISSING.
#
# Printing the offending names rather than a count is deliberate: a red assertion that says "3" is a
# red assertion somebody has to go and reproduce.
# ---------------------------------------------------------------------------
m29_absent() {
  local pair name value out=""
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    if [ -z "$value" ] || [ "$value" = "MISSING" ] || [ "$value" = "None" ]; then
      out="$out $name"
    fi
  done
  printf '%s\n' "${out# }"
}

# m29_records <file> <prefix> — the driver's own `<prefix><i> ctx=…` records, in index order.
m29_records() { # <file> <prefix>
  python3 - "$1" "$2" <<'PY'
import re, sys
path, prefix = sys.argv[1], sys.argv[2]
pat = re.compile(r'^' + re.escape(prefix) + r'(\d+) (ctx=.*)$')
rows = {}
for line in open(path):
    m = pat.match(line.rstrip('\n'))
    if m:
        rows[int(m.group(1))] = m.group(2)
for i in sorted(rows):
    print(rows[i])
PY
}
