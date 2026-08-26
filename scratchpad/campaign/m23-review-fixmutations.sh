#!/usr/bin/env bash
# m23-review-fixmutations.sh — every assertion the review ADDED, shown capable of failing.
#
# A fix is not a fix until the mutation it was written against goes red. Each row below breaks
# exactly the property the new assertion claims, runs the one check that owns it, and restores from
# a copy this script takes itself.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 90
BACKUP="$HOME/.cache/aztec-m23rev-fixmut"; rm -rf "$BACKUP"; mkdir -p "$BACKUP" || exit 90

save()    { cp "$REPO/$1" "$BACKUP/$(printf '%s' "$1" | tr '/' '_')" || exit 90; }
restore() { cp "$BACKUP/$(printf '%s' "$1" | tr '/' '_')" "$REPO/$1" || exit 90; }

run_check() {
  local out rc line
  out="$(verification/"$1".sh 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E "^$1: [0-9]+ assertion\(s\), [0-9]+ failure\(s\)$" | tail -1)"
  [ -z "$line" ] && { printf 'NO-SUMMARY NO-SUMMARY %d\n' "$rc"; return; }
  printf '%s %s %d\n' \
    "$(printf '%s' "$line" | sed -E 's/.*: ([0-9]+) assertion.*/\1/')" \
    "$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failure.*/\1/')" "$rc"
}

mutate() { # <label> <check> <file> <python>
  local label="$1" check="$2" file="$3" mutator="$4"
  save "$file"
  python3 - "$REPO/$file" <<PY
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
$mutator
p.write_text(s)
PY
  if [ $? -ne 0 ]; then restore "$file"; printf '  %-58s MUTATION-DID-NOT-APPLY\n' "$label"; return; fi
  local r; r="$(run_check "$check")"
  restore "$file"
  printf '  %-58s %s\n' "$label" "$r"
}

echo "== each newly-added assertion, shown capable of failing"

# §8.4: the disclosure back in the factory, where the constructor route bypasses it.
mutate "D1 disclosure moved back out of the constructor" test_receipt_declares_no_proving \
  orchestration/src/avm_runtime.ts \
  'old = "    const sink = options.disclosureSink ?? ((l: string) => console.warn(l));\n    sink(this.disclosure.line);\n"
assert s.count(old) == 1
s = s.replace(old, "")
old2 = "  static create(deps: AvmRuntimeDeps, options: AvmRuntimeOptions = {}): AvmRuntime {\n    return new AvmRuntime(deps, options);"
assert s.count(old2) == 1
s = s.replace(old2, "  static create(deps: AvmRuntimeDeps, options: AvmRuntimeOptions = {}): AvmRuntime {\n    const r = new AvmRuntime(deps, options);\n    const sink = options.disclosureSink ?? ((l: string) => console.warn(l));\n    sink(r.disclosure.line);\n    return r;")'

# §8.4: the record forgeable again — the constructor takes the caller's object.
mutate "D2 the constructor accepts a caller-supplied disclosure" test_receipt_declares_no_proving \
  orchestration/src/avm_runtime.ts \
  'old = "  private constructor(deps: AvmRuntimeDeps, options: AvmRuntimeOptions) {\n    this.disclosure = Object.freeze({"
assert s.count(old) == 1
s = s.replace(old, "  private constructor(deps: AvmRuntimeDeps, options: AvmRuntimeOptions, forged?: Disclosure) {\n    this.disclosure = forged ?? Object.freeze({")'

# The TXE wall-clock correction: the document allowed to drift back to the false sentence.
mutate "T1 CHAIN-LOOP.md drifts back to \"never reads a wall clock\"" \
  verify_txe_reuse_verdict_recorded CHAIN-LOOP.md \
  'old = "**TXE never ADVANCES block time from a wall clock. It SEEDS it from one.**"
assert s.count(old) == 1
s = s.replace(old, "**TXE never reads a wall clock for block time.**")'

# The lmdb-v2 figure, now exact rather than `>=`.
mutate "T2 the lmdb-v2 count is asserted against the wrong value" \
  verify_txe_reuse_verdict_recorded verification/verify_txe_reuse_verdict_recorded.sh \
  'old = "assert_eq \"@aztec/kv-store/lmdb-v2 exactly three times\" \"3\" \"$N_KV\""
assert s.count(old) == 1
s = s.replace(old, "assert_eq \"@aztec/kv-store/lmdb-v2 exactly three times\" \"6\" \"$N_KV\"")'

# The declared deviation, which passed the whole milestone green before the fix.
mutate "V1 wallClockDeviationSeconds is always 0" \
  test_timestamps_strictly_monotonic_subsecond orchestration/src/chain.ts \
  'old = "      wallClockDeviationSeconds: timestamp - wallClockSeconds,"
assert s.count(old) == 1
s = s.replace(old, "      wallClockDeviationSeconds: 0n,")'

# The deviation identity, broken the other way: the field is off by one.
mutate "V2 the declared deviation is off by one" \
  test_timestamps_strictly_monotonic_subsecond orchestration/src/chain.ts \
  'old = "      wallClockDeviationSeconds: timestamp - wallClockSeconds,"
assert s.count(old) == 1
s = s.replace(old, "      wallClockDeviationSeconds: timestamp - wallClockSeconds + 1n,")'

# The archive roots, now four values rather than three: block 3 stops moving the archive.
mutate "E1 the third block re-reads the archive before the seal" \
  test_empty_block_advances_number_and_archive orchestration/src/chain.ts \
  'old = "    const archiveAfter = this.deps.merkleDb.archiveSnapshot();"
assert s.count(old) == 1
s = s.replace(old, "    const archiveAfter = number === 3 ? archiveBefore : this.deps.merkleDb.archiveSnapshot();")'

# The replay monotonicity refusal, now RUN rather than read.
mutate "S1 produceBlock stops refusing a timestamp that does not advance" \
  e2e_chain_snapshot_export_import_roundtrip orchestration/src/chain.ts \
  'old = "    if (timestamp <= this.lastTimestamp && this.produced.length > 0) {"
assert s.count(old) == 1
s = s.replace(old, "    if (false && timestamp <= this.lastTimestamp && this.produced.length > 0) {")'
