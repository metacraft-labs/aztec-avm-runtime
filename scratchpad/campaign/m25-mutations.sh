#!/usr/bin/env bash
# M25's mutation matrix. Run from aztec-avm-runtime/:
#
#   direnv exec /home/zahary/m/blocktracer bash scratchpad/campaign/m25-mutations.sh 2>&1 | tee ~/.cache/aztec-m25-mut.log
#
# EVERY MUTATION IS RESTORED BY A TRAP, INCLUDING ON ^C, and the restore is VERIFIED by re-running
# the check afterwards — M6's "a mutated ARTEFACT outlived its restored source" is the reason.
# For the wasm module that means a REBUILD after restore, because cargo fingerprints on mtime and
# a `cp -p` puts the old timestamp back.
#
# WHEN A MUTATION REDDENS, READ *WHICH* ASSERTIONS WENT RED. "The check failed" and "the check saw
# what I broke" are different statements and only the second is coverage — M24 declared three hang
# mutations and exactly one hung. Each arm below names the assertion it expects.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
BAK="$HOME/.cache/aztec-m25-mutbak"
LOG="$HOME/.cache/aztec-m25-mutout"
mkdir -p "$BAK" "$LOG"

FILES=(
  ct-writer/src/lib.rs
  ct-host/src/source_map.ts
  ct-host/src/config.ts
  tools/run_trace_arms.mjs
  verification/_import_closure.py
  verification/lib_m25_trace.sh
  SOURCE-MAPPING.md
)
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp -p "$ROOT/$f" "$BAK/$f"; done

# THE `-p` IS THE DEFECT AND THE `touch` IS THE FIX, AND THIS HARNESS SHIPPED WITH THE DEFECT.
#
# `cp -p` restores the BACKUP's mtime, which is older than the module built from the last
# mutation. cargo fingerprints on mtime, so `rebuild_module` then decides the artefact is current
# and rebuilds NOTHING — and the restored source sits beside a MUTATED module. That is this
# campaign's catalogued "a mutated ARTEFACT outlived its restored source", which the header of
# this very file claims to defeat, reproduced by the file that claims it.
#
# It was caught by the restore-verification arm, which is the only reason it is a finding rather
# than a corrupt handover: `test_trace_metadata_declares_mapping_rung` came back 83/8 over a
# module carrying M5's disabled violation counter, while the three checks that do not read that
# behaviour passed. Restore now stamps the sources forward so cargo cannot skip the rebuild.
restore() {
  for f in "${FILES[@]}"; do cp -p "$BAK/$f" "$ROOT/$f"; done
  touch "$ROOT/ct-writer/src/lib.rs" "$ROOT/ct-writer/Cargo.toml"
  rm -f "$HOME/.cache/aztec-m25-trace/trace.json"
}
trap restore EXIT INT TERM

rebuild_module() {
  verification/build_ct_writer_wasm.sh >/dev/null 2>&1 || { echo "    (module rebuild FAILED)"; return 1; }
}

run_check() { # <check> <label>
  local check="$1" label="$2" out
  out="$LOG/$label.$check.txt"
  timeout 1800 verification/"$check".sh >"$out" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E '^[A-Za-z_0-9][A-Za-z_0-9 .-]*: [0-9]+ assertion\(s\), [0-9]+ failure\(s\)$' "$out" | tail -1)"
  printf '    %-46s rc=%-3s %s\n' "$check" "$rc" "${summary:-<NO SUMMARY LINE>}"
  grep -E '^  FAIL' "$out" | head -6 | sed 's/^/        /'
}

arm() { # <label> <description> <mutate-fn> <needs-module-rebuild 0|1> <check...>
  local label="$1" desc="$2" fn="$3" rebuild="$4"; shift 4
  echo
  echo "=== $label — $desc"
  restore
  "$fn"
  if [ "$rebuild" = 1 ]; then rebuild_module; fi
  rm -f "$HOME/.cache/aztec-m25-trace/trace.json"
  for c in "$@"; do run_check "$c" "$label"; done
  restore
}

# ---------------------------------------------------------------------------
# The mutations.
# ---------------------------------------------------------------------------

m1() { # OQ-4: render the address LITTLE-endian
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-writer/src/lib.rs'); s = p.read_text()
s = s.replace('    for b in bytes {\n        s.push(HEX[(b >> 4) as usize] as char);',
              '    for b in bytes.iter().rev() {\n        s.push(HEX[(b >> 4) as usize] as char);')
p.write_text(s)
PY
}

m2() { # OQ-4: put M24's low-64 Int rendering back
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-writer/src/lib.rs'); s = p.read_text()
s = s.replace('''        "contractAddress",
        ValueRecord::String { text: hex32(address), type_id: s.field_type_id },''',
'''        "contractAddressLow",
        ValueRecord::Int { i: { let mut l = 0i64; for (i, b) in address.iter().rev().take(8).enumerate() { l |= (*b as i64) << (8 * i); } l }, type_id: s.field_type_id },''')
p.write_text(s)
PY
}

m3() { # rung: ignore every supplied position, record Line(pc) always
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-writer/src/lib.rs'); s = p.read_text()
s = s.replace('        Some(p) if p.line != 0 => {', '        Some(p) if false && p.line != 0 => {')
p.write_text(s)
PY
}

m4() { # rung: declare silently — keep the table, drop the trace event
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-writer/src/lib.rs'); s = p.read_text()
s = s.replace('''    TraceWriter::register_special_event(
        &mut s.writer,
        EventLogKind::TraceLogEvent,
        CT_RUNG_EVENT_METADATA,
        &content,
    );''', '    let _ = &content;')
p.write_text(s)
PY
}

m5() { # rung: never count a violation
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-writer/src/lib.rs'); s = p.read_text()
s = s.replace('        if d.rung == CT_RUNG_SOURCE && d.unpositioned > 0 {',
              '        if false && d.rung == CT_RUNG_SOURCE && d.unpositioned > 0 {')
p.write_text(s)
PY
}

m6() { # doc: swap two figures BETWEEN rows, leaving both present in the file
  python3 - <<'PY'
import pathlib
p = pathlib.Path('SOURCE-MAPPING.md'); s = p.read_text()
s = s.replace('public_dispatch        bytecode 50,939 bytes', 'public_dispatch        bytecode 50,526 bytes')
s = s.replace('brillig_locations["0"] 9,021 entries, keys in [706, 50,526]',
              'brillig_locations["0"] 9,021 entries, keys in [706, 50,939]')
p.write_text(s)
PY
}

m7() { # rungFor: always answer rung 1
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-host/src/source_map.ts'); s = p.read_text()
s = s.replace('  if (!debugInfo || typeof debugInfo !== \'object\' || !debugInfo.brillig_locations) {',
              '  if (false) {')
s = s.replace('  if (entries.length === 0) {', '  if (false) {')
s = s.replace('  if (bytecodeLength > 0 && max >= bytecodeLength) {', '  if (false) {')
s = s.replace('  if (!files || files.size === 0) {', '  if (false) {')
p.write_text(s)
PY
}

m8() { # HANG: the arms driver never exits
  python3 - <<'PY'
import pathlib
p = pathlib.Path('tools/run_trace_arms.mjs'); s = p.read_text()
s = s.replace("const out = { module: MODULE, artifactPath: ARTIFACT };",
              "const out = { module: MODULE, artifactPath: ARTIFACT };\nfor (;;) { /* deliberate hang */ }")
p.write_text(s)
PY
}

m9() { # DIE BEFORE SUMMARY: no artifact anywhere
  python3 - <<'PY'
import pathlib
p = pathlib.Path('verification/lib_m25_trace.sh'); s = p.read_text()
s = s.replace('M25_ARTIFACT_REL="node_modules/@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json"',
              'M25_ARTIFACT_REL="node_modules/@aztec/noir-test-contracts.js/artifacts/NO_SUCH_ARTIFACT.json"')
p.write_text(s)
PY
}

m10() { # the closure walker's own defect, restored
  python3 - <<'PY'
import pathlib
p = pathlib.Path('verification/_import_closure.py'); s = p.read_text()
s = s.replace(r'''IMPORT_RE = re.compile(r"""(?:^|[\n;}])\s*(?:import|export)\b[^;]*?\bfrom\s+['"]([^'"]+)['"]""")''',
              r'''IMPORT_RE = re.compile(r"""(?:^|[\n;}])\s*(?:import|export)\b[^;\n]*?\bfrom\s+['"]([^'"]+)['"]""")''')
p.write_text(s)
PY
}

m11() { # locationsOf: stop at the innermost node, do not walk parents
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-host/src/source_map.ts'); s = p.read_text()
s = s.replace('    const parent = node.parent;\n    cursor = typeof parent === \'number\' ? parent : null;',
              '    cursor = null;')
p.write_text(s)
PY
}

m12() { # the column gate stops reading the rung
  python3 - <<'PY'
import pathlib
p = pathlib.Path('ct-host/src/config.ts'); s = p.read_text()
s = s.replace("const recordable = CARRIES_COLUMNS[writerPath] === true || mappingRung === RUNG_SOURCE;",
              "const recordable = true;")
p.write_text(s)
PY
}

FR=test_fr_rendering_matches_noir_tracer
RUNG=test_trace_metadata_declares_mapping_rung
OQ5=verify_oq5_source_mapping_verdict_recorded
CLO=verify_transaction_builder_closure_measured

arm M1  "OQ-4: the address renders LITTLE-endian"                  m1  1 "$FR"
arm M2  "OQ-4: M24's low-64 contractAddressLow is back"            m2  1 "$FR" "$RUNG"
arm M3  "rung: every supplied position is ignored"                 m3  1 "$RUNG" "$OQ5"
arm M4  "rung: declared, but no event written into the container"  m4  1 "$RUNG"
arm M5  "rung: a rung-1 violation is never counted"                m5  1 "$RUNG"
arm M6  "doc: two figures SWAPPED between rows, both still present" m6 0 "$OQ5"
arm M7  "rungFor always answers rung 1"                            m7  0 "$OQ5" "$RUNG"
arm M8  "HANG: the arms driver never exits"                        m8  0 "$RUNG"
arm M9  "DIE: the artifact cannot be found"                        m9  0 "$RUNG" "$OQ5"
arm M10 "the closure walker loses multi-line imports"              m10 0 "$CLO"
arm M11 "locationsOf stops at the innermost frame"                 m11 0 "$RUNG"
arm M12 "the column gate stops reading the rung"                   m12 0 "$RUNG"

echo
echo "=== RESTORE VERIFIED — the module is rebuilt from the restored source and all four re-run"
restore
rebuild_module
rm -f "$HOME/.cache/aztec-m25-trace/trace.json"
for c in "$OQ5" "$FR" "$RUNG" "$CLO"; do run_check "$c" restored; done
echo "MUTDONE"
