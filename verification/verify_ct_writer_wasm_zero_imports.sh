#!/usr/bin/env bash
# verify_ct_writer_wasm_zero_imports
#
# M24 verification: the writer module declares NO imports, so the TypeScript host owes it nothing
# but memory — and the module owns even that.
#
# WHY THIS IS THE MILESTONE'S FIRST CHECK. Zero imports is what makes the same host code run in
# Node and in a browser without a WASI shim, a `wasm-bindgen` glue file or an import object. M27
# packages for a browser and M28 gates on one; if this property is not true, both are impossible
# and the cheapest place to find that out is here.
#
# THE IMPORT COUNT IS MEASURED THREE WAYS AND THEY ARE NOT REDUNDANT:
#   1. `WebAssembly.Module.imports()` — the engine's own answer.
#   2. The import SECTION read out of the binary — because `imports()` reports names and kinds and
#      NOT whether a memory is shared, and a `-pthread` build's shared memory would invalidate the
#      `static mut` the module's state lives in.
#   3. An INSTANTIATION with a literally empty import object, `{}` — because a module can declare
#      an import the engine happens to tolerate, and the only proof that nothing is owed is that
#      nothing was given.
#
# AND THE CONTROL IS A MODULE THAT DOES IMPORT SOMETHING. Without it, "the import list is empty"
# is satisfied by a reader that cannot see imports at all — this campaign's absence-asked-of-a-
# tree-that-cannot-answer defect, twice recorded. `avm.wasm` imports twelve names; if it is not
# built, a two-instruction module with one declared import is assembled here instead, so the
# control never depends on somebody else's build.
#
# Run: just verify-ct-writer-imports

TEST_NAME="verify_ct_writer_wasm_zero_imports"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m24_ct_writer.sh"
m24_summary_on_abnormal_exit

# BASH'S `=~` IS A POSIX ERE AND `\t` IS NOT A TAB IN ONE. It matches a literal `t` (or, in some
# builds, nothing at all), so every pattern below carries a REAL tab through `$'\t'`. Found by
# these assertions going red on output that plainly contained the lines they were looking for —
# the cheap direction, and the reason the patterns are built rather than written inline.
TAB=$'\t'

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m24_require_module
MODULE="$M24_MODULE"
assert_file "the writer module was built" "$MODULE"

# ---------------------------------------------------------------------------
# 1. The engine's own answer, and 3. instantiation with an empty import object.
# ---------------------------------------------------------------------------
REPORT="$(m24_require_bounded 120 "the module probe" node -e '
const fs = require("node:fs");
const b = fs.readFileSync(process.argv[1]);
const m = new WebAssembly.Module(b);
const imps = WebAssembly.Module.imports(m);
console.log("BYTES\t" + b.length);
console.log("IMPORTS\t" + imps.length);
for (const i of imps) console.log("IMPORT\t" + i.module + "." + i.name + "\t" + i.kind);
for (const e of WebAssembly.Module.exports(m)) console.log("EXPORT\t" + e.name + "\t" + e.kind);
try {
  const inst = new WebAssembly.Instance(m, {});
  console.log("INSTANTIATED\tempty-import-object");
  console.log("RECORDSIZE\t" + inst.exports.ct_record_size());
  console.log("WRITERKIND\t" + inst.exports.ct_writer_kind());
  console.log("MEMPAGES\t" + (inst.exports.memory.buffer.byteLength / 65536));
} catch (e) {
  console.log("INSTANTIATED\tFAILED\t" + e.message);
}
' "$MODULE")" || die "the module probe failed"
[ -n "$REPORT" ] || die "the module probe printed nothing"

n_imports="$(printf '%s\n' "$REPORT" | sed -n 's/^IMPORTS\t//p')"
assert_eq "the engine reports ZERO imports" "0" "$n_imports"
assert_eq "no import line was printed at all" "0" \
  "$(printf '%s\n' "$REPORT" | grep -c "^IMPORT${TAB}" || true)"
assert_true "the module instantiates with a literally empty import object" \
  str_has_line_re "$REPORT" "^INSTANTIATED${TAB}empty-import-object\$"

# The exports the host requires, each asserted BY NAME. A count alone would pass on nineteen
# wrong names.
n_exports=0
for name in ct_alloc ct_free ct_record_size ct_writer_kind ct_writer_open ct_step ct_ingest \
            ct_ingest_control ct_nop_step ct_nop_ingest ct_nop_calls ct_nop_checksum \
            ct_writer_close ct_container_len ct_events_written ct_columns_requested \
            ct_dropped_column_awareness ct_last_error_ptr ct_last_error_len; do
  assert_true "the module exports $name() as a function" \
    str_has_line_re "$REPORT" "^EXPORT${TAB}${name}${TAB}function\$"
  n_exports=$((n_exports + 1))
done
assert_eq "nineteen exported functions were enumerated by name" "19" "$n_exports"
assert_true "the module exports its own linear memory" \
  str_has_line_re "$REPORT" "^EXPORT${TAB}memory${TAB}memory\$"

# The module's own answers, so the host's constants are checked against the module rather than
# against themselves.
assert_eq "the module declares a 64-byte event record" "64" \
  "$(printf '%s\n' "$REPORT" | sed -n 's/^RECORDSIZE\t//p')"
assert_eq "the module identifies itself as DD-7's Path A (kind 1)" "1" \
  "$(printf '%s\n' "$REPORT" | sed -n 's/^WRITERKIND\t//p')"
assert_ge "the module starts with a plausible amount of linear memory" "1" \
  "$(printf '%s\n' "$REPORT" | sed -n 's/^MEMPAGES\t//p')"
assert_ge "the module is a plausible size for the writer plus this ABI" "100000" \
  "$(printf '%s\n' "$REPORT" | sed -n 's/^BYTES\t//p')"

# ---------------------------------------------------------------------------
# 2. The import section, read out of the binary. `imports()` cannot tell us `shared`.
# ---------------------------------------------------------------------------
SECTIONS="$(python3 - "$MODULE" <<'PY'
import sys, struct

data = open(sys.argv[1], "rb").read()
if data[:4] != b"\x00asm":
    print("PROBLEM\tnot a wasm module"); raise SystemExit(0)
print("VERSION\t%d" % struct.unpack("<I", data[4:8])[0])
o = 8

def leb(o):
    r = s = 0
    while True:
        b = data[o]; o += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            return r, o
        s += 7

seen = []
while o < len(data):
    sid = data[o]; o += 1
    size, o = leb(o)
    seen.append(sid)
    if sid == 2:  # import
        n, p = leb(o)
        print("IMPORTSECTION\t%d" % n)
    if sid == 5:  # memory, declared rather than imported
        n, p = leb(o)
        print("MEMORYSECTION\t%d" % n)
        for _ in range(n):
            flags = data[p]; p += 1
            mn, p = leb(p)
            mx = None
            if flags & 0x1:
                mx, p = leb(p)
            print("MEMORY\tmin=%d\tmax=%s\tshared=%s" % (mn, mx if mx is not None else "-", "yes" if flags & 0x2 else "no"))
    o += size
print("SECTIONS\t%s" % ",".join(str(s) for s in seen))
PY
)" || die "the import-section reader failed"
[ -n "$SECTIONS" ] || die "the import-section reader printed nothing"

assert_not_contains "the section reader had no problem with the binary" "PROBLEM" "$SECTIONS"
assert_true "the binary is wasm version 1" str_has_line_re "$SECTIONS" "^VERSION${TAB}1\$"
assert_eq "there is NO import section in the binary at all" "0" \
  "$(printf '%s\n' "$SECTIONS" | grep -c '^IMPORTSECTION' || true)"
assert_true "the module DECLARES its memory rather than importing it" \
  str_has_line_re "$SECTIONS" "^MEMORYSECTION${TAB}1\$"
# THE `static mut` MODULE STATE IS SOUND ONLY BECAUSE THIS IS FALSE. A `-pthread` build's memory
# is shared, a second thread can then alias the writer's `&mut`, and `ct-writer/src/lib.rs`'s own
# comment says so. Asserted rather than assumed.
assert_true "the declared memory is NOT shared (the module's static state depends on it)" \
  str_has_line_re "$SECTIONS" "^MEMORY${TAB}min=[0-9]+${TAB}max=[^${TAB}]*${TAB}shared=no\$"

# ---------------------------------------------------------------------------
# THE CONTROL. A reader that cannot see imports would pass everything above.
# ---------------------------------------------------------------------------
CONTROL_WASM="$M24_WORK/control-with-one-import.wasm"
mkdir -p "$M24_WORK" || die "could not create $M24_WORK"
python3 - "$CONTROL_WASM" <<'PY' || die "could not assemble the control module"
import sys
# The smallest well-formed module that imports one function: type section with `() -> ()`, an
# import section naming `env.owed`, and nothing else. Hand-assembled rather than compiled, so the
# control cannot fail for want of somebody else's build.
mod = bytearray(b"\x00asm\x01\x00\x00\x00")
mod += bytes([1, 4, 1, 0x60, 0, 0])                       # type:   () -> ()
name_m, name_f = b"env", b"owed"
imp = bytes([1]) + bytes([len(name_m)]) + name_m + bytes([len(name_f)]) + name_f + bytes([0x00, 0])
mod += bytes([2, len(imp)]) + imp                         # import: env.owed (func 0)
open(sys.argv[1], "wb").write(bytes(mod))
PY
assert_file "the control module was assembled" "$CONTROL_WASM"

CONTROL_REPORT="$(m24_require_bounded 60 "the control probe" node -e '
const fs = require("node:fs");
const b = fs.readFileSync(process.argv[1]);
const m = new WebAssembly.Module(b);
console.log("IMPORTS\t" + WebAssembly.Module.imports(m).length);
try { new WebAssembly.Instance(m, {}); console.log("INSTANTIATED\tempty-import-object"); }
catch (e) { console.log("INSTANTIATED\tFAILED"); }
' "$CONTROL_WASM")" || die "the control probe failed"

assert_eq "the CONTROL module reports exactly one import, so the reader can see imports" "1" \
  "$(printf '%s\n' "$CONTROL_REPORT" | sed -n 's/^IMPORTS\t//p')"
assert_true "the CONTROL module REFUSES to instantiate with an empty import object" \
  str_has_line_re "$CONTROL_REPORT" "^INSTANTIATED${TAB}FAILED\$"

CONTROL_SECTIONS="$(python3 - "$CONTROL_WASM" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
o = 8
def leb(o):
    r = s = 0
    while True:
        b = data[o]; o += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80): return r, o
        s += 7
while o < len(data):
    sid = data[o]; o += 1
    size, o = leb(o)
    if sid == 2:
        n, _ = leb(o)
        print("IMPORTSECTION\t%d" % n)
    o += size
PY
)"
assert_true "the section reader FINDS the control's import section" \
  str_has_line_re "$CONTROL_SECTIONS" "^IMPORTSECTION${TAB}1\$"

# ---------------------------------------------------------------------------
# THE BOUND IS A THING UNDER TEST TOO.
#
# M23's review: a check that HANGS prints no summary, never exits, and reads as a smaller
# milestone rather than a red one. `m24_run_bounded` is what stops that, and a bound that has
# never fired is a bound nobody has tested. Two seconds against a one-second limit.
# ---------------------------------------------------------------------------
m24_run_bounded 1 "the deliberate overrun" sleep 5 >/dev/null 2>&1
overrun_rc=$?
assert_true "m24_run_bounded KILLS a command that exceeds its bound (rc 124 or 137)" \
  test "$overrun_rc" = 124 -o "$overrun_rc" = 137
m24_run_bounded 5 "the deliberate non-overrun" true >/dev/null 2>&1
under_rc=$?
assert_eq "and lets one that finishes in time through untouched" "0" "$under_rc"

# ---------------------------------------------------------------------------
# The host type-checks against the pinned tsc, with `erasableSyntaxOnly`.
#
# NOT COSMETIC: `erasableSyntaxOnly` is what makes "Node runs these sources by stripping types"
# safe rather than incidental — it refuses enums, namespaces and parameter properties, the
# constructs the stripper cannot erase. And `skipLibCheck: false` with no `@types/node` is what
# keeps `types/node-subset.d.ts` honest.
# ---------------------------------------------------------------------------
if command -v tsc >/dev/null 2>&1; then
  ts_out="$(m24_require_bounded 300 "the ct-host type-check" bash -c "cd '$M24_HOST' && tsc -p tsconfig.json 2>&1")"
  ts_rc=$?
  assert_eq "ct-host type-checks clean under strict + erasableSyntaxOnly" "0" "$ts_rc"
  assert_eq "and printed no diagnostics" "" "$ts_out"
else
  fail "tsc is not on PATH; run this check inside the dev shell (nix develop)"
fi
assert_true "ct-host's tsconfig turns on erasableSyntaxOnly" \
  str_has_sub "$(cat "$M24_HOST/tsconfig.json")" '"erasableSyntaxOnly": true'
assert_true "and does not skip lib checks, so types/node-subset.d.ts is checked" \
  str_has_sub "$(cat "$M24_HOST/tsconfig.json")" '"skipLibCheck": false'

# ---------------------------------------------------------------------------
# The module is built from the PINNED revision, out of the object store.
# ---------------------------------------------------------------------------
PIN="$(m24_pin trace_format commit)"
assert_true "pins.json declares a trace_format anchor commit" \
  str_has_re "$PIN" '^[0-9a-f]{40}$'
STAMP="$M24_CRATE/build-wasm-deps/materialised-at"
assert_file "the materialisation recorded which revision it took" "$STAMP"
assert_eq "the materialised dependency is the revision pins.json declares" \
  "$PIN" "$(cat "$STAMP" 2>/dev/null | tr -d '[:space:]')"
assert_true "the build script reads the revision from pins.json rather than declaring one" \
  str_has_sub "$(cat "$REPO_ROOT/verification/build_ct_writer_wasm.sh")" 'p["anchors"].get("trace_format")'
assert_false "no 40-hex commit literal is typed into the build script" \
  str_has_line_re "$(grep -v '^#' "$REPO_ROOT/verification/build_ct_writer_wasm.sh")" '[0-9a-f]{40}'

# THE PINNED REVISION IS PUBLISHED. See `m24_published_refcount` for why this exists: M24 pinned
# this anchor to a commit that lived only on a local branch on one machine, `git archive` found it
# here and would have found it nowhere else, and every assertion above was green either way.
CTF_REPO="$WORKSPACE_ROOT/codetracer-trace-format"
assert_dir "the codetracer-trace-format checkout is present" "$CTF_REPO"
assert_ge "the pinned trace_format commit is reachable from a PUBLISHED remote ref" "1" \
  "$(m24_published_refcount "$CTF_REPO" "$PIN")"
# THE INSTRUMENT'S OWN CONTROL. A counter that can only go up is not a test. Asked of a ref
# namespace that cannot contain anything, the same commit must come back UNpublished — otherwise
# the assertion above would pass on a repository with no remotes at all.
assert_eq "and the same question asked of a namespace with no refs answers 0, so the test can fail" \
  "0" "$(m24_published_refcount "$CTF_REPO" "$PIN" "refs/remotes/__no_such_remote__")"

# ---------------------------------------------------------------------------
# TRACE-ABI.md §7's TWO MEASURED FIGURES ARE RE-DERIVED FROM THE ARTEFACT.
#
# Added by M24's review, because they were not. Changing §7's byte count back to 245,724 — the
# figure M24 itself established was a MUTATED artefact's — passed `verify_trace_event_abi_batched_faster`
# 91/0 and this check 49/0, measured. The milestone's own deliverable line still carried 245,724
# for the same reason: nothing re-derived it. "Bind claims to data, or expect them to rot."
#
# This does not make the byte size a PINNED property, which the milestone deliberately declines to
# do — nothing here asserts a constant. It asserts that the document quotes whatever was built.
DOC_ABI="$REPO_ROOT/TRACE-ABI.md"
assert_file "the verdict document exists" "$DOC_ABI"
ABI_TEXT="$(cat "$DOC_ABI")"
MOD_BYTES="$(wc -c <"$MODULE" | tr -d '[:space:]')"
MOD_SHA="$(sha256sum "$MODULE" | cut -c1-8)"
assert_true "TRACE-ABI.md §7 quotes the module's MEASURED byte count ($MOD_BYTES)" \
  str_has_sub "$ABI_TEXT" "**$(python3 -c 'print(f"{int(__import__("sys").argv[1]):,}")' "$MOD_BYTES") bytes**"
assert_true "and its MEASURED sha256 prefix ($MOD_SHA)" \
  str_has_sub "$ABI_TEXT" "sha256 \`$MOD_SHA"

m24_finish
