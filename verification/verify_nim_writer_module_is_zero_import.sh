#!/usr/bin/env bash
# verify_nim_writer_module_is_zero_import
#
# M41 verification: the Path B module — Rust event ABI, Nim writer, cross-built libzstd, all in one
# linear memory — declares ZERO wasm imports and instantiates against a literally empty import
# object.
#
# WHY THIS IS THE MILESTONE'S LOAD-BEARING MEASUREMENT. DD-7 chose Path A for the browser partly on
# "19 WASI imports", which turned out to be an artefact of building the Nim writer as a WASI
# COMMAND with a `main`. A library-shaped build imports nothing. That claim has been made about a
# vendored copy in another tree and about a standalone module in the trace-format repository; what
# has never been measured until now is THIS module — the one with the thirty-eight-function ABI on
# top — built by this repository's own `build.rs`.
#
# THE IMPORT COUNT IS MEASURED THREE WAYS, and they are not redundant. This mirrors
# `verify_ct_writer_wasm_zero_imports`, which does the same for Path A, because the two modules are
# different artefacts and a property of one is not a property of the other:
#   1. `WebAssembly.Module.imports()` — the engine's own answer.
#   2. The import SECTION read out of the binary — `imports()` reports names and kinds and NOT
#      whether a memory is shared, and a shared memory would invalidate the `static mut` the
#      module's state lives in.
#   3. INSTANTIATION against a literal `{}` — a module can declare an import an engine tolerates,
#      and the only proof that nothing is owed is that nothing was given.
#
# AND THE CONTROL IS A MODULE THAT DOES IMPORT SOMETHING, assembled here from two dozen bytes so
# the control never depends on somebody else's build. Without it, "the import list is empty" is
# satisfied by a reader that cannot see imports at all — this campaign's
# absence-asked-of-a-tree-that-cannot-answer defect.
#
# THE PIN IS ASSERTED PUBLISHED, for the reason `pins.json`'s `trace_format` anchor records at
# length: M24 pinned a commit that lived on one unpushed branch on one machine, `git archive`
# resolved locally, and every check stayed green while the build would have failed in CI and in
# every other checkout. The writer anchor gets the same gate, with a negative control on the
# counter so "zero refs contain it" cannot be produced by a search that finds nothing ever.
#
# Run: just verify-nim-writer-zero-imports

TEST_NAME="verify_nim_writer_module_is_zero_import"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TAB=$'\t'

# ---------------------------------------------------------------------------
# 1. The anchor is real, and it is PUBLISHED.
# ---------------------------------------------------------------------------
WRITER_REV="$(python3 -c "
import json
a = json.load(open('$REPO_ROOT/pins.json', encoding='utf-8'))['anchors'].get('trace_format_nim_writer') or {}
print(a.get('commit',''))
")"
assert_true "pins.json declares a trace_format_nim_writer anchor" \
  test -n "$WRITER_REV"
m41_say "trace_format_nim_writer = ${WRITER_REV:0:10}"

NIM_REPO="${TRACE_FORMAT_NIM_REPO:-$(cd "$REPO_ROOT/.." && pwd)/codetracer-trace-format-nim}"
assert_dir "the sibling trace-format-nim checkout is where the build expects it" "$NIM_REPO/.git"
assert_true "and it has the pinned revision in its object store" \
  git -C "$NIM_REPO" cat-file -e "$WRITER_REV^{commit}"

PUBLISHED="$(git -C "$NIM_REPO" for-each-ref --contains "$WRITER_REV" refs/remotes 2>/dev/null | grep -c . || true)"
assert_ge "the writer anchor is reachable from at least one refs/remotes ref" 1 "$PUBLISHED"
# THE NEGATIVE CONTROL ON THE COUNTER. A commit that exists and is NOT published must count zero,
# or the assertion above is satisfied by a command that always reports something.
UNPUBLISHED="$(git -C "$NIM_REPO" hash-object -t commit -w --stdin <<EOF 2>/dev/null || true
tree $(git -C "$NIM_REPO" rev-parse "$WRITER_REV^{tree}")
parent $WRITER_REV
author m41 probe <m41@example.invalid> 0 +0000
committer m41 probe <m41@example.invalid> 0 +0000

a commit nothing points at, so the publication counter has something to report zero for
EOF
)"
if [ -n "$UNPUBLISHED" ]; then
  N="$(git -C "$NIM_REPO" for-each-ref --contains "$UNPUBLISHED" refs/remotes 2>/dev/null | grep -c . || true)"
  assert_eq "a commit no ref points at counts ZERO, so the counter discriminates" "0" "$N"
else
  fail "the publication counter's negative control could not be constructed, so the count above is unverified"
fi

# ---------------------------------------------------------------------------
# 2. The module.
# ---------------------------------------------------------------------------
m41_require_path_b
assert_file "the Path B module was built by ct-writer's own build.rs" "$M41_PATH_B"

REPORT="$(m41_bounded 300 "the Path B module probe" node -e '
const fs = require("node:fs");
const b = fs.readFileSync(process.argv[1]);
const m = new WebAssembly.Module(b);
const imps = WebAssembly.Module.imports(m);
console.log("BYTES\t" + b.length);
console.log("IMPORTS\t" + imps.length);
for (const i of imps) console.log("IMPORT\t" + i.module + "." + i.name + "\t" + i.kind);
console.log("EXPORTS\t" + WebAssembly.Module.exports(m).length);
try {
  const inst = new WebAssembly.Instance(m, {});
  console.log("INSTANTIATED\tyes");
  console.log("MEMORY\t" + (inst.exports.memory instanceof WebAssembly.Memory ? "own" : "none"));
  console.log("KIND\t" + inst.exports.ct_writer_kind());
} catch (e) {
  console.log("INSTANTIATED\tno\t" + e.message);
}
' "$M41_PATH_B" && cat "$M41_LAST_LOG")" || die "the module probe failed: $(cat "$M41_LAST_LOG" 2>/dev/null)"
REPORT="$(cat "$M41_LAST_LOG")"

assert_contains "the engine reports ZERO imports" "IMPORTS${TAB}0" "$REPORT"
assert_contains "the module instantiates against a literal {}" "INSTANTIATED${TAB}yes" "$REPORT"
assert_contains "and it owns its own memory rather than being handed one" "MEMORY${TAB}own" "$REPORT"
assert_contains "and the instance is the Nim writer" "KIND${TAB}2" "$REPORT"
assert_contains "and it exports thirty-nine things" "EXPORTS${TAB}39" "$REPORT"
m41_say "$(printf '%s\n' "$REPORT" | grep '^BYTES')"

# ---------------------------------------------------------------------------
# 3. The import SECTION, read out of the binary. `imports()` cannot say whether a memory is shared.
# ---------------------------------------------------------------------------
SECTION="$(python3 "$REPO_ROOT/verification/_m41_wasm_sections.py" "$M41_PATH_B")" \
  || die "the module's sections could not be read"
assert_contains "the binary declares no import section at all" "IMPORT_SECTION${TAB}absent" "$SECTION"
assert_contains "and no shared memory, so the module's static mut state is sound" \
  "SHARED_MEMORY${TAB}no" "$SECTION"

# ---------------------------------------------------------------------------
# 4. THE CONTROL: a module that DOES import something, so the counter is shown to count.
# ---------------------------------------------------------------------------
CONTROL="$M41_WORK/one-import.wasm"
mkdir -p "$M41_WORK"
python3 "$REPO_ROOT/verification/_m41_wasm_sections.py" --emit-control "$CONTROL" \
  || die "the one-import control module could not be assembled"
assert_file "the control module was assembled" "$CONTROL"

CONTROL_REPORT="$(m41_bounded 60 "the control module probe" node -e '
const fs = require("node:fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
console.log("IMPORTS\t" + WebAssembly.Module.imports(m).length);
' "$CONTROL"; cat "$M41_LAST_LOG")"
assert_contains "the control module reports ONE import, so zero is a measurement" \
  "IMPORTS${TAB}1" "$CONTROL_REPORT"

CONTROL_SECTION="$(python3 "$REPO_ROOT/verification/_m41_wasm_sections.py" "$CONTROL")"
assert_contains "and the section reader SEES that import section" \
  "IMPORT_SECTION${TAB}present" "$CONTROL_SECTION"

finish
