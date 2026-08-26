#!/usr/bin/env bash
# m24-mutations.sh — break what each M24 check claims to detect, and record whether it noticed.
#
#   scratchpad/campaign/m24-mutations.sh [mutation-id ...]
#
# A check that has never failed is indistinguishable from a check that cannot fail, and this
# campaign has now had a mutation pass an ENTIRE MILESTONE green in both M22 and M23. So the
# reviewer will mutate these checks; this gets there first, and it deliberately includes the three
# shapes the brief names:
#
#   * a mutation that makes a check HANG rather than redden (M23's chain, one character);
#   * a mutation that bypasses a TYPESCRIPT-ONLY guarantee (M23's erased `private constructor`);
#   * a mutation that produces no visible symptom at all unless something reads the DATA.
#
# EVERY MUTATION IS RESTORED, from a copy this script takes itself, and the restoration is
# VERIFIED by hash — not by `git checkout`, because a file that is not tracked would silently not
# be restored, and not by re-applying an inverse edit, because an inverse that does not exactly
# invert leaves a corrupted tree that the next run reports as a regression.
#
# NOTHING HERE EDITS A SHELL SCRIPT. A check reads its own file while it runs, so mutating one
# kills the run rather than reddening it; the subjects are Rust, TypeScript, Python and JSON.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
LOG="$ROOT/scratchpad/campaign/m24-mutation-results.txt"
BACKUP="$HOME/.cache/aztec-m24-mutation-backup"
mkdir -p "$BACKUP"

say() { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
record() { printf '%s\n' "$*" | tee -a "$LOG"; }

save() { # <path...>
  local f
  for f in "$@"; do
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp -p "$f" "$BACKUP/$f"
  done
}
# A MUTATED ARTEFACT OUTLIVED ITS RESTORED SOURCE, AND IT COST AN HOUR.
#
# `cp -p` preserves mtime. Cargo's fingerprint is mtime-based. So restoring `ct-writer/src/lib.rs`
# from the backup put the ORIGINAL timestamp back, cargo said "up to date", and `ct_writer.wasm`
# KEPT M6's infinite-spin body while the source it came from was clean — `grep -c MUTATION` was 0
# on every file. Everything downstream then hung: the arms run, `just verify-m24`, and a
# "reproducibility" measurement that recorded the mutated artefact's size and hash as the clean
# build's. The campaign brief names this exact shape — "A mutated artefact outlived its restored
# source" — and it is why the restore TOUCHES what it restores, and why `--force` is not enough on
# its own.
restore() { # <path...>
  local f ok=1
  for f in "$@"; do
    cp -p "$BACKUP/$f" "$f"
    cmp -s "$BACKUP/$f" "$f" || ok=0
    touch "$f"          # <- defeat cargo's mtime fingerprint; see the comment above
  done
  [ "$ok" = 1 ] || { record "RESTORE FAILED — the tree is dirty, stop and fix it by hand"; exit 9; }
  # And drop the derived artefacts outright, because "the source is clean" and "what was built
  # from it is clean" are different statements and only the second one matters downstream.
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
}

# run_check <check> [env-assignments...] -> prints "rc=<n> assertions=<n> failures=<n>"
run_check() {
  local check="$1"; shift
  local out rc
  out="$(env "$@" nix develop "$ROOT" --command bash -c "cd '$ROOT' && verification/$check.sh" 2>&1)"
  rc=$?
  local line
  line="$(printf '%s\n' "$out" | grep -E "^$check: [0-9]+ assertion" | tail -1)"
  printf 'rc=%s  %s\n' "$rc" "${line:-<NO SUMMARY LINE AT ALL>}"
  printf '%s\n' "$out" | grep -E '^  FAIL' | head -4 | sed 's/^/       /'
}

want() { # <id>
  [ "$#" = 0 ] && return 0
  return 1
}
SELECTED=("$@")
selected() {
  [ "${#SELECTED[@]}" -eq 0 ] && return 0
  local s
  for s in "${SELECTED[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

printf '# M24 mutation matrix — %s\n' "$(date -Is)" >>"$LOG"

# ---------------------------------------------------------------------------
# BASELINE. Without it, "the mutated run is red" is not evidence that the mutation caused it.
# ---------------------------------------------------------------------------
if selected baseline; then
  say "BASELINE — every check, unmutated"
  for c in verify_ct_writer_wasm_zero_imports test_ct_container_roundtrip_ct_print \
           test_dropped_column_awareness_asserted test_single_trace_types_instantiation \
           test_trace_writer_backpressure verify_trace_event_abi_batched_faster; do
    record "  $c: $(run_check "$c")"
  done
fi

# ---------------------------------------------------------------------------
# M1 — THE SILENT ONE. Drop one of the five per-event variables from `emit()`.
# The container still reads, every step is still there, every count still looks plausible. Only a
# check that compares the VALUE count against the event count can see it.
# ---------------------------------------------------------------------------
if selected M1; then
  say "M1 — emit() writes four variables per step instead of five (silent: the container still reads)"
  save ct-writer/src/lib.rs
  python3 - <<'PY'
p = 'ct-writer/src/lib.rs'
s = open(p).read()
old = """    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "daGas",
        ValueRecord::Int { i: da_gas as i64, type_id: s.type_id },
    );
"""
assert old in s
open(p, 'w').write(s.replace(old, "", 1))
PY
  record "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print)"
  record "  test_trace_writer_backpressure:       $(run_check test_trace_writer_backpressure)"
  restore ct-writer/src/lib.rs
fi

# ---------------------------------------------------------------------------
# M2 — THE TYPE-ERASURE BYPASS. Replace the WeakSet identity gate with the construct Node erases.
# This is M23's §8.4 defect, reproduced: the source still says the configuration is protected, and
# at run time it is not.
# ---------------------------------------------------------------------------
if selected M2; then
  say "M2 — the DD-7 identity gate becomes a TypeScript-only guarantee (erased at run time)"
  save ct-host/src/writer.ts
  python3 - <<'PY'
p = 'ct-host/src/writer.ts'
s = open(p).read()
old = """    if (!isResolvedTracingConfig(config)) {
      throw new UnresolvedTracingConfig();
    }"""
new = """    // MUTATION: the gate is now a TYPE. `ResolvedTracingConfig` is structural, so any object of
    // the right shape satisfies it at compile time, and NOTHING checks at run time.
    const _typedOnly: ResolvedTracingConfig = config;
    void _typedOnly;"""
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  record "  test_dropped_column_awareness_asserted: $(run_check test_dropped_column_awareness_asserted)"
  restore ct-host/src/writer.ts
fi

# ---------------------------------------------------------------------------
# M3 — THE VALUE CHECK BECOMES A TYPE CHECK. The config-time DD-7 refusal is removed and only the
# type forbids `columns: true` on Path A — which is exactly nothing, after stripping.
# ---------------------------------------------------------------------------
if selected M3; then
  say "M3 — the config-time column refusal is removed; only the type forbids it"
  save ct-host/src/config.ts
  python3 - <<'PY'
p = 'ct-host/src/config.ts'
s = open(p).read()
old = """  if (config.columns === true && CARRIES_COLUMNS[writerPath] !== true) {
    throw new ColumnAwarenessUnavailable(writerPath);
  }"""
new = """  // MUTATION: the refusal is gone. The declared types still say Path A cannot carry columns.
"""
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  record "  test_dropped_column_awareness_asserted: $(run_check test_dropped_column_awareness_asserted)"
  restore ct-host/src/config.ts
fi

# ---------------------------------------------------------------------------
# M4 — THE DROPPED-COLUMN SIGNAL BECOMES A PRINTED CONSTANT. The module reports 0 whatever the
# writer said. This is the campaign's "a printed literal" family, in the one place DD-7 depends on
# a signal being READ.
# ---------------------------------------------------------------------------
if selected M4; then
  say "M4 — ct_dropped_column_awareness() returns a constant 0 instead of the writer's signal"
  save ct-writer/src/lib.rs
  python3 - <<'PY'
p = 'ct-writer/src/lib.rs'
s = open(p).read()
old = "    let dropped = s.writer.dropped_column_awareness();"
new = "    let dropped = false; // MUTATION: the writer's own signal is no longer read"
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  record "  test_dropped_column_awareness_asserted: $(run_check test_dropped_column_awareness_asserted)"
  restore ct-writer/src/lib.rs
fi

# ---------------------------------------------------------------------------
# M5 — THE HANG. M23's chain hung a whole milestone on a one-character defect, because a trap
# fires on exit and a process that never exits has none. The arms driver is made to hang; the
# check must produce a NAMED FAILURE with a summary line, not silence.
#
# `M24_ARMS_TIMEOUT=25` so the demonstration takes half a minute rather than fifteen.
# ---------------------------------------------------------------------------
if selected M5; then
  say "M5 — THE HANG: the arms driver never exits (the state a trap cannot reach)"
  save tools/run_ct_writer_arms.mjs
  python3 - <<'PY'
p = 'tools/run_ct_writer_arms.mjs'
s = open(p).read()
old = "const out = { module: MODULE,"
new = "await new Promise(() => {}); // MUTATION: hang forever, before writing anything\nconst out = { module: MODULE,"
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
  record "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print M24_ARMS_TIMEOUT=25)"
  record "  test_trace_writer_backpressure:       $(run_check test_trace_writer_backpressure M24_ARMS_TIMEOUT=25)"
  restore tools/run_ct_writer_arms.mjs
fi

# ---------------------------------------------------------------------------
# M6 — THE HANG, INSIDE THE MODULE. A wasm loop that never returns is worse than a hung script:
# there is no signal handler, no stack to unwind, and `timeout` is the only thing that ends it.
# ---------------------------------------------------------------------------
if selected M6; then
  say "M6 — THE HANG, IN WASM: ct_ingest spins forever (no signal handler, no unwind)"
  save ct-writer/src/lib.rs
  python3 - <<'PY'
p = 'ct-writer/src/lib.rs'
s = open(p).read()
old = "    let n = len / CT_RECORD_SIZE;\n    let buf = if len == 0 { &[][..] }"
new = "    let n = len / CT_RECORD_SIZE;\n    if n > 0 { let mut x = 0u64; loop { x = x.wrapping_add(1); core::hint::black_box(x); } } // MUTATION: spin\n    #[allow(unreachable_code)]\n    let buf = if len == 0 { &[][..] }"
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
  record "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print M24_ARMS_TIMEOUT=25)"
  restore ct-writer/src/lib.rs
fi

# ---------------------------------------------------------------------------
# M7 — UNBOUNDED HOST-SIDE BUFFERING. `flush()` becomes a no-op until close, so the "batch" is the
# whole transaction. The container is still correct; only the crossing identity and the buffer
# bound can see it.
# ---------------------------------------------------------------------------
if selected M7; then
  say "M7 — the host stops flushing until close (the container is still correct)"
  save ct-host/src/writer.ts
  python3 - <<'PY'
p = 'ct-host/src/writer.ts'
s = open(p).read()
old = "    this.filled += 1;\n    if (this.filled === this.batchRecords) this.flush();"
new = "    this.filled += 1;\n    // MUTATION: never flush early; the buffer grows to the whole transaction\n    if (this.filled === this.batchRecords) this.growBuffer();"
assert old in s
s = s.replace(old, new, 1)
old2 = "  /** Hand whatever is buffered to the module. One crossing; a no-op when nothing is pending. */"
new2 = """  /** MUTATION: enlarge the wasm-side buffer instead of flushing. */
  private growBuffer(): void {
    this.batchRecordsMut = this.batchRecords * 2;
  }
  private batchRecordsMut = 0;

  /** Hand whatever is buffered to the module. One crossing; a no-op when nothing is pending. */"""
assert old2 in s
open(p, 'w').write(s.replace(old2, new2, 1))
PY
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
  record "  test_trace_writer_backpressure: $(run_check test_trace_writer_backpressure)"
  restore ct-host/src/writer.ts
fi

# ---------------------------------------------------------------------------
# M8 — TWO INSTANTIATIONS. The trap RI-42 exists to prevent, applied to the real manifest.
# ---------------------------------------------------------------------------
if selected M8; then
  say "M8 — a second path to codetracer_trace_types in the real manifest"
  save ct-writer/Cargo.toml
  rm -rf "$HOME/.cache/aztec-m24-mutation-ctt"
  mkdir -p "$HOME/.cache/aztec-m24-mutation-ctt"
  cp -r ct-writer/build-wasm-deps/ctf/codetracer_trace_types \
        "$HOME/.cache/aztec-m24-mutation-ctt/codetracer_trace_types"
  sed -i 's/^version = "0.19.0"$/version = "0.19.1"/' \
    "$HOME/.cache/aztec-m24-mutation-ctt/codetracer_trace_types/Cargo.toml"
  printf 'ctt_second = { package = "codetracer_trace_types", version = "0.19.1", path = "%s/codetracer_trace_types" }\n' \
    "$HOME/.cache/aztec-m24-mutation-ctt" >>ct-writer/Cargo.toml
  record "  test_single_trace_types_instantiation: $(run_check test_single_trace_types_instantiation)"
  restore ct-writer/Cargo.toml
  rm -rf "$HOME/.cache/aztec-m24-mutation-ctt"
fi

# ---------------------------------------------------------------------------
# M9 — THE COMPARATOR ALWAYS SAYS `within-noise`. If nothing catches this, the OQ-6 verdict is a
# constant the check prints rather than a measurement it made.
# ---------------------------------------------------------------------------
if selected M9; then
  say "M9 — the OQ-6 comparator can only ever return within-noise"
  save verification/_oq6_compare.py
  python3 - <<'PY'
p = 'verification/_oq6_compare.py'
s = open(p).read()
old = "        resolves = obs_lo > margin or obs_hi < -margin"
new = "        resolves = False  # MUTATION: the verdict is now a constant"
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  record "  verify_trace_event_abi_batched_faster: $(run_check verify_trace_event_abi_batched_faster)"
  restore verification/_oq6_compare.py
fi

# ---------------------------------------------------------------------------
# M10 — THE READER PIN MOVES TO THE PRE-FIX COMMIT. If the roundtrip check does not notice, its
# "this container needs that reader" claim is unevidenced.
# ---------------------------------------------------------------------------
if selected M10; then
  say "M10 — pins.json points the reader at the PRE-fix commit"
  save pins.json
  python3 - <<'PY'
import json, collections
p = 'pins.json'
with open(p, encoding='utf-8') as fh:
    d = json.load(fh, object_pairs_hook=collections.OrderedDict)
a = d['anchors']['trace_format_nim']
a['commit'] = a['control_commit']
with open(p, 'w', encoding='utf-8') as fh:
    fh.write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  rm -f "$HOME/.cache/aztec-m24-ctprint/ct-print" "$HOME/.cache/aztec-m24-ctprint/ct-print.rev"
  record "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print)"
  restore pins.json
  rm -f "$HOME/.cache/aztec-m24-ctprint/ct-print" "$HOME/.cache/aztec-m24-ctprint/ct-print.rev"
fi

# ---------------------------------------------------------------------------
# M11 — THE TWO ABIs STOP AGREEING. `writeStepPerCall` skips every other event, so the per-event
# container is half the size. The equivalence claim is the only thing that can see it.
# ---------------------------------------------------------------------------
if selected M11; then
  say "M11 — the per-event ABI silently drops every other event"
  save ct-host/src/writer.ts
  python3 - <<'PY'
p = 'ct-host/src/writer.ts'
s = open(p).read()
old = "    this.bytes.set(e.contractAddress, this.addrPtr);\n    const status = this.ex[this.stepName]("
new = "    this.bytes.set(e.contractAddress, this.addrPtr);\n    if ((this.crossings & 1) === 1) { this.crossings += 1; return; } // MUTATION: drop every other event\n    const status = this.ex[this.stepName]("
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
  record "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print)"
  restore ct-host/src/writer.ts
fi

# ---------------------------------------------------------------------------
# M12 — THE MODULE GROWS AN IMPORT. The whole browser story rests on there being none.
# ---------------------------------------------------------------------------
if selected M12; then
  say "M12 — the module declares one wasm import"
  save ct-writer/src/lib.rs
  python3 - <<'PY'
p = 'ct-writer/src/lib.rs'
s = open(p).read()
old = "/// Bytes per event record on the batched path.\npub const CT_RECORD_SIZE: usize = 64;"
new = """// MUTATION: one declared import. A real host would have to supply it.
unsafe extern "C" {
    fn host_owes_us_something(x: u32) -> u32;
}

/// Bytes per event record on the batched path.
pub const CT_RECORD_SIZE: usize = 64;"""
assert old in s
s = s.replace(old, new, 1)
old2 = "pub extern \"C\" fn ct_record_size() -> usize {\n    CT_RECORD_SIZE\n}"
new2 = "pub extern \"C\" fn ct_record_size() -> usize {\n    CT_RECORD_SIZE + unsafe { host_owes_us_something(0) } as usize\n}"
assert old2 in s
open(p, 'w').write(s.replace(old2, new2, 1))
PY
  record "  verify_ct_writer_wasm_zero_imports: $(run_check verify_ct_writer_wasm_zero_imports)"
  restore ct-writer/src/lib.rs
fi

# ---------------------------------------------------------------------------
# M13 — THE RECORD SIZE DRIFTS. Module says 72, host encodes 64: every field of every event is
# shifted and the container still opens. The most dangerous shape in the whole ABI.
# ---------------------------------------------------------------------------
if selected M13; then
  say "M13 — the module's record size drifts from the host's (silent misalignment)"
  save ct-writer/src/lib.rs
  python3 - <<'PY'
p = 'ct-writer/src/lib.rs'
s = open(p).read()
old = "pub extern \"C\" fn ct_record_size() -> usize {\n    CT_RECORD_SIZE\n}"
new = "pub extern \"C\" fn ct_record_size() -> usize {\n    72 // MUTATION: the module now disagrees with the host\n}"
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
  record "  verify_ct_writer_wasm_zero_imports: $(run_check verify_ct_writer_wasm_zero_imports)"
  restore ct-writer/src/lib.rs
fi

say "DONE — restoring the built artefacts to the unmutated sources"
rm -rf "$ROOT/ct-writer/target"
verification/build_ct_writer_wasm.sh --force >/dev/null 2>&1
rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
verification/build_ct_print.sh >/dev/null 2>&1
record "tree restored; re-run 'just verify-m24' to confirm"
