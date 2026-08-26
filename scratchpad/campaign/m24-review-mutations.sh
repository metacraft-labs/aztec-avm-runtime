#!/usr/bin/env bash
# m24-review-mutations.sh — the review's own mutations, aimed at the three claims M24's own
# matrix does NOT actually cover.
#
#   RM1  THE UNBOUNDED-BUFFERING MUTATION M24's M7 CLAIMED TO BE AND IS NOT.
#        M24's M7 sets `flush()` aside and lets `filled` run past `batchRecords`, so the very
#        first `encodeStep` writes past the end of the wasm-side buffer and node dies with
#        `RangeError: offset is out of bounds` two seconds in. The check reports one failure —
#        "cannot run: run_ct_writer_arms.mjs failed" — which detects the mutation but detects it
#        as a CRASH. Not one backpressure assertion runs. So the check's central claim, that the
#        crossing identity and the heap ratio can see unbounded host-side buffering, has never
#        been exercised. RM1 is that mutation done CORRECTLY: events are held in a JS array and
#        encoded into a freshly allocated wasm buffer in ONE crossing at flush time, so the
#        container is still byte-correct and the host's buffer grows with the transaction.
#
#   RM2  THE ARM TABLE'S ROWS SWAPPED. `verify_trace_event_abi_batched_faster` re-derives every
#        figure in TRACE-ABI.md §2 from `arms.tsv` — but matches each as `| <number> |`, anywhere
#        in the file. Does it notice when `batched`'s median is attributed to `perEvent`?
#
#   RM3  THE MODULE'S BYTE COUNT IN TRACE-ABI.md §7 CHANGED TO THE MUTATION-ERA FIGURE.
#        Does anything at all re-derive it?
#
# NOTHING HERE EDITS A SHELL SCRIPT. Restores are from a copy this script takes itself, verified
# by `cmp`, and `touch`ed so cargo's mtime fingerprint cannot keep a stale artefact alive.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
BK="$HOME/.cache/aztec-m24rev/rm-backups"; mkdir -p "$BK"
LOG="$ROOT/scratchpad/campaign/m24-review-mutation-results.txt"

say() { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
rec() { printf '%s\n' "$*" | tee -a "$LOG"; }

save() { cp -p "$1" "$BK/$(basename "$1")"; }
restore() {
  cp -p "$BK/$(basename "$1")" "$1"; touch "$1"
  cmp -s "$BK/$(basename "$1")" "$1" || { rec "RESTORE FAILED for $1"; exit 9; }
  rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
}
run_check() {
  local c="$1"; shift
  local out rc
  out="$(env "$@" nix develop "$ROOT" --command bash -c "cd '$ROOT' && verification/$c.sh" 2>&1)"
  rc=$?
  printf 'rc=%s  %s\n' "$rc" \
    "$(printf '%s\n' "$out" | grep -E "^$c: [0-9]+ assertion" | tail -1 || true)"
  printf '%s\n' "$out" | grep -E '^  FAIL' | head -6 | sed 's/^/       /'
}

printf '# M24 REVIEW mutation matrix — %s\n' "$(date -Is)" >>"$LOG"

if [ "$#" -eq 0 ] || [ "${1:-}" = RM1 ]; then
say "RM1 — UNBOUNDED host-side buffering, done correctly (the container stays right)"
save ct-host/src/writer.ts
python3 - <<'PY'
p = 'ct-host/src/writer.ts'
s = open(p).read()
old = """  push(e: StepEvent): void {
    this.assertOpen();
    this.refresh();
    encodeStep(this.view, this.bytes, this.bufPtr + this.filled * RECORD_SIZE, e);
    this.filled += 1;
    if (this.filled === this.batchRecords) this.flush();
  }"""
new = """  private held: StepEvent[] = [];

  push(e: StepEvent): void {
    // MUTATION (review RM1): unbounded HOST-SIDE buffering. Every event is retained in a JS array
    // and nothing crosses the boundary until flush(). The container is unchanged.
    this.assertOpen();
    this.held.push(e);
  }"""
assert old in s
s = s.replace(old, new, 1)
old2 = """  flush(): void {
    this.assertOpen();
    if (this.filled === 0) return;
    const len = this.filled * RECORD_SIZE;
    const n = this.ex[this.ingestName](this.bufPtr, len);
    this.crossings += 1;
    if (n < 0) throw new CtWriterError(this.ingestName, n, this.lastError());
    if (n !== this.filled) {
      throw new Error(`${this.ingestName} accepted ${n} of ${this.filled} records`);
    }
    this.filled = 0;
  }"""
new2 = """  flush(): void {
    // MUTATION (review RM1): one crossing for the whole transaction, out of a buffer sized to it.
    this.assertOpen();
    if (this.held.length === 0) return;
    const count = this.held.length;
    const len = count * RECORD_SIZE;
    const ptr = this.ex.ct_alloc(len);
    this.refresh();
    for (let i = 0; i < count; i++) {
      encodeStep(this.view, this.bytes, ptr + i * RECORD_SIZE, this.held[i]!);
    }
    const n = this.ex[this.ingestName](ptr, len);
    this.crossings += 1;
    this.ex.ct_free(ptr, len);
    if (n < 0) throw new CtWriterError(this.ingestName, n, this.lastError());
    if (n !== count) {
      throw new Error(`${this.ingestName} accepted ${n} of ${count} records`);
    }
    this.held = [];
    this.filled = 0;
  }"""
assert old2 in s
open(p, 'w').write(s.replace(old2, new2, 1))
PY
rm -f "$HOME/.cache/aztec-m24-ct-writer/ct.json"
rec "  test_trace_writer_backpressure:       $(run_check test_trace_writer_backpressure)"
rec "  test_ct_container_roundtrip_ct_print: $(run_check test_ct_container_roundtrip_ct_print)"
restore ct-host/src/writer.ts
fi

if [ "$#" -eq 0 ] || [ "${1:-}" = RM2 ]; then
say "RM2 — TRACE-ABI.md §2: batched's and perEvent's measured numbers swapped between rows"
save TRACE-ABI.md
python3 - <<'PY'
p = 'TRACE-ABI.md'
s = open(p).read()
a = "| `batched` | 534,565 | 523,133 | 25 | 4,435,968 |\n| `perEvent` | 535,350 | 524,353 | 100,000 | 4,435,968 |"
b = "| `batched` | 535,350 | 524,353 | 25 | 4,435,968 |\n| `perEvent` | 534,565 | 523,133 | 100,000 | 4,435,968 |"
assert a in s, "the §2 arm table is not in the expected shape"
open(p, 'w').write(s.replace(a, b, 1))
PY
rec "  verify_trace_event_abi_batched_faster: $(run_check verify_trace_event_abi_batched_faster)"
restore TRACE-ABI.md
fi

if [ "$#" -eq 0 ] || [ "${1:-}" = RM3 ]; then
say "RM3 — TRACE-ABI.md §7: the module's byte count set back to the MUTATION-era figure"
save TRACE-ABI.md
python3 - <<'PY'
p = 'TRACE-ABI.md'
s = open(p).read()
assert "**246,527 bytes**" in s
open(p, 'w').write(s.replace("**246,527 bytes**", "**245,724 bytes**", 1))
PY
rec "  verify_trace_event_abi_batched_faster: $(run_check verify_trace_event_abi_batched_faster)"
rec "  verify_ct_writer_wasm_zero_imports:    $(run_check verify_ct_writer_wasm_zero_imports)"
restore TRACE-ABI.md
fi

rec "REVIEW MUTATIONS DONE"
