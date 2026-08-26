#!/usr/bin/env bash
# test_dropped_column_awareness_asserted
#
# M24 verification, DD-7: requesting column-aware tracing from a writer that cannot carry columns
# FAILS LOUDLY AT CONFIGURATION TIME rather than producing a silently degraded container.
#
# ---------------------------------------------------------------------------
# A TYPESCRIPT-ONLY GUARANTEE IS NOT A RUNTIME GUARANTEE, AND THIS CHECK EXECUTES THE BYPASSES.
#
# M23 shipped an honesty disclosure protected by `private constructor`. Node's type stripper
# ERASES `private`; the constructor was public at run time and the disclosure was bypassable
# through the package's own public export until a check tried it. Reading the source would not
# have found it — the source says `private`.
#
# So the gate here rests on nothing a stripper can erase, and this check proves that by DOING the
# bypasses rather than by grepping for them:
#
#   * a `columns: true` smuggled past the type through `JSON.parse` — the value check runs;
#   * a shape-identical configuration object that never passed the gate — object identity in a
#     module-private `WeakSet` runs;
#   * `new CtWriter(...)` reached directly through the package's public export;
#   * and a static scan asserting the gate does NOT use a `private` constructor, a branded type or
#     a literal type as its enforcement, because those would each pass this file's positive cases
#     while being erased.
#
# THE CONTROL IS AN ORDINARY RECORDING THAT MUST NOT THROW. Without it every refusal above is
# satisfied by a host that refuses everything, and DD-7 would be "honoured" by a writer that
# cannot write. It is the fifth gate in the arms report and it is asserted here by name.
#
# AND THE SECOND HALF OF DD-7 IS THAT THE ASSERTION IS CONDITIONAL. `dropped_column_awareness()`
# is read on every recording and is a FAILURE only where columns were requested; asserting it
# unconditionally would fail every ordinary recording, because the signal is false precisely
# because nobody asked. Both directions are exercised.
#
# Run: just verify-ct-dd7

TEST_NAME="test_dropped_column_awareness_asserted"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m24_ct_writer.sh"
m24_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m24_require_module
MODULE="$M24_MODULE"
m24_require_arms
ARMS="$M24_ARMS"
assert_file "the arms run produced its report" "$ARMS"

# ---------------------------------------------------------------------------
# The four refusals and their control, as the arms run EXECUTED them.
# ---------------------------------------------------------------------------
gate_threw() { m24_arm "[g for g in d['gates'] if g['name']=='$1'][0]['threw']"; }
gate_kind()  { m24_arm "[g for g in d['gates'] if g['name']=='$1'][0]['kind']"; }
gate_error() { m24_arm "[g for g in d['gates'] if g['name']=='$1'][0]['error']"; }

assert_eq "the arms run exercised five gates, four refusals and one control" "5" \
  "$(m24_arm 'len(d["gates"])')"

assert_eq "columns requested of Path A THROWS at configuration time" "true" \
  "$(gate_threw columns-on-path-a)"
assert_eq "and it is DD-7's own refusal, by class" "ColumnAwarenessUnavailable" \
  "$(gate_kind columns-on-path-a)"
assert_true "and the refusal says WHY, in the writer's structural terms" \
  str_has_sub "$(gate_error columns-on-path-a)" 'no column-bearing step encoder'
assert_true "and names the meta.dat capability bits it does not set" \
  str_has_sub "$(gate_error columns-on-path-a)" 'capability bits 4/6/7'

assert_eq "a columns:true smuggled past the TYPE is refused just the same" "true" \
  "$(gate_threw columns-on-path-a-through-any)"
assert_eq "by the same class, so it is the same gate and not a different error" \
  "ColumnAwarenessUnavailable" "$(gate_kind columns-on-path-a-through-any)"

assert_eq "a shape-identical config that never passed the gate is REFUSED by the writer" "true" \
  "$(gate_threw unresolved-config-object)"
assert_eq "and the refusal is the identity check, not a type error" "UnresolvedTracingConfig" \
  "$(gate_kind unresolved-config-object)"
assert_true "which says plainly that identity is checked rather than shape" \
  str_has_sub "$(gate_error unresolved-config-object)" 'Object identity is checked rather than shape'

assert_eq "columns requested and then DROPPED by the module is refused at close" "true" \
  "$(gate_threw columns-requested-then-dropped)"
assert_eq "by the writer's own dropped-column-awareness signal" "ColumnAwarenessDropped" \
  "$(gate_kind columns-requested-then-dropped)"
assert_true "and the refusal names the module kind that reported it" \
  str_has_sub "$(gate_error columns-requested-then-dropped)" 'ct_writer_kind() = 1'

# THE CONTROL. Everything above is satisfied by a host that refuses everything.
assert_eq "AN ORDINARY RECORDING IS ALLOWED — the gates are not a blanket refusal" "false" \
  "$(gate_threw ordinary-recording-is-allowed)"
assert_eq "and it reported no error at all" "MISSING" "$(gate_error ordinary-recording-is-allowed)"

# DD-7's conditionality, in both directions, from the roundtrip arm.
assert_eq "an ordinary recording does not request columns" "false" \
  "$(m24_arm 'd["roundtrip"]["columnsRequested"]')"
assert_eq "and reports NO dropped column awareness, so the assertion cannot fire on it" "false" \
  "$(m24_arm 'd["roundtrip"]["droppedColumnAwareness"]')"

# "record which writer path produced the container" — DD-7's second half, recorded rather than
# inferred, and read from the module rather than from the configuration.
assert_eq "the recording records WHICH writer path produced it" "path-a-pure-rust" \
  "$(m24_arm 'd["roundtrip"]["writerPath"]')"
assert_eq "and the module's own kind agrees with it" "1" "$(m24_arm 'd["roundtrip"]["writerKind"]')"
assert_eq "which is the kind the surface probe read straight off the module" \
  "$(m24_arm 'd["surface"]["writerKind"]')" "$(m24_arm 'd["roundtrip"]["writerKind"]')"

# ---------------------------------------------------------------------------
# THE BYPASSES, RUN HERE, THROUGH THE PACKAGE'S PUBLIC EXPORT.
#
# The arms driver runs them too; this runs them again from a separate process against the public
# entry point, because the deliverable is about what a CONSUMER can do and the arms driver is not
# one. M23's disclosure was bypassable "through the public export" specifically.
# ---------------------------------------------------------------------------
BYPASS="$(m24_require_bounded 300 "the bypass probe" node --experimental-strip-types -e '
import { readFileSync } from "node:fs";
const m = await import(process.argv[1] + "/src/index.ts");
const bytes = readFileSync(process.argv[2]);
const ok = (n) => console.log("ALLOWED\t" + n);
const no = (n, e) => console.log("REFUSED\t" + n + "\t" + (e?.name ?? "unknown"));
const base = { program: "p", recordingId: "01949fcc-7d92-7e9c-8000-00000000beef", sourcePath: "/a/b", workdir: "/a" };

// 1. The plain refusal.
try { m.resolveTracingConfig({ ...base, columns: true }, m.WRITER_PATH_A_PURE_RUST); ok("plain"); }
catch (e) { no("plain", e); }

// 2. `true` smuggled past the type. `JSON.parse` returns `any` at run time and the stripper has
//    already removed every type by then, so this is the real shape of the bypass.
try {
  const smuggled = JSON.parse(JSON.stringify({ ...base, columns: true }));
  m.resolveTracingConfig(smuggled, m.WRITER_PATH_A_PURE_RUST); ok("smuggled");
} catch (e) { no("smuggled", e); }

// 3. A forged resolved config straight into the constructor, through the public export.
const inst = await m.instantiateCtWriter(bytes);
try {
  new m.CtWriter(inst, { ...base, columns: true, writerPath: m.WRITER_PATH_A_PURE_RUST }, { batchRecords: 4 });
  ok("forged-constructor");
} catch (e) { no("forged-constructor", e); }

// 4. A forged config with columns FALSE — still forged, still refused. Proves gate 3 is the
//    identity check and not the column check wearing its clothes.
const inst2 = await m.instantiateCtWriter(bytes);
try {
  new m.CtWriter(inst2, { ...base, columns: false, writerPath: m.WRITER_PATH_A_PURE_RUST }, { batchRecords: 4 });
  ok("forged-constructor-no-columns");
} catch (e) { no("forged-constructor-no-columns", e); }

// 5. Mutating a RESOLVED config after the gate ran. The gate cannot be re-run, so this is the one
//    bypass that WORKS at configuration time -- and it is caught at close by the module`s own
//    signal instead. Recorded as what it is rather than claimed shut.
const inst3 = await m.instantiateCtWriter(bytes);
const cfg = m.resolveTracingConfig({ ...base, columns: false }, m.WRITER_PATH_A_PURE_RUST);
cfg.columns = true;
try {
  const w = new m.CtWriter(inst3, cfg, { batchRecords: 4 });
  const addr = new Uint8Array(32);
  w.push({ contextId: 0, pc: 1, opcode: 2, l2Gas: 3n, daGas: 4n, contractAddress: addr });
  w.close();
  ok("mutated-after-resolve");
} catch (e) { no("mutated-after-resolve", e); }

// 6. THE CONTROL: an ordinary recording, through the public export, must be ALLOWED.
const inst4 = await m.instantiateCtWriter(bytes);
try {
  const w = new m.CtWriter(inst4, m.resolveTracingConfig({ ...base, columns: false }, m.WRITER_PATH_A_PURE_RUST), { batchRecords: 4 });
  const addr = new Uint8Array(32);
  for (let i = 0; i < 9; i++) w.push({ contextId: 0, pc: i, opcode: i, l2Gas: 1n, daGas: 0n, contractAddress: addr });
  const r = w.close();
  console.log("CONTROLEVENTS\t" + r.events);
  ok("ordinary");
} catch (e) { no("ordinary", e); }
' "$M24_HOST" "$MODULE")" || die "the bypass probe failed to run"
[ -n "$BYPASS" ] || die "the bypass probe printed nothing"

TAB=$'\t'
assert_true "through the public export, a plain columns:true is REFUSED" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}plain${TAB}ColumnAwarenessUnavailable\$"
assert_true "a columns:true that arrived through JSON.parse — past every erased type — is REFUSED" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}smuggled${TAB}ColumnAwarenessUnavailable\$"
assert_true "a forged config handed straight to the public constructor is REFUSED" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}forged-constructor${TAB}UnresolvedTracingConfig\$"
assert_true "and so is a forged config with columns FALSE, so gate 3 really is the identity check" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}forged-constructor-no-columns${TAB}UnresolvedTracingConfig\$"
# THE ONE THAT GETS THROUGH THE FIRST GATE, RECORDED AS SUCH. Mutating a resolved object after
# the fact cannot be caught at configuration time by anything short of freezing, and claiming
# otherwise would be exactly the kind of unearned assurance this check exists to prevent. It is
# caught at CLOSE, by the module's own signal, and that is what is asserted.
assert_true "a config MUTATED after it was resolved gets past the config-time gate and is caught at CLOSE" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}mutated-after-resolve${TAB}ColumnAwarenessDropped\$"
assert_true "THE CONTROL: an ordinary recording through the public export is ALLOWED" \
  str_has_line_re "$BYPASS" "^ALLOWED${TAB}ordinary\$"
assert_true "and it actually wrote its nine events rather than being allowed to do nothing" \
  str_has_line_re "$BYPASS" "^CONTROLEVENTS${TAB}9\$"

# ---------------------------------------------------------------------------
# THE ENFORCEMENT IS NOT A TYPE. Read out of the source, because the positive cases above would
# all still pass if somebody replaced the WeakSet with a `private constructor` tomorrow — and
# that replacement is precisely M23's defect.
# ---------------------------------------------------------------------------
CFG_SRC="$(cat "$M24_HOST/src/config.ts")"
WRITER_SRC="$(cat "$M24_HOST/src/writer.ts")"
assert_true "the gate's memory is a WeakSet, which exists at run time" \
  str_has_sub "$CFG_SRC" 'const RESOLVED = new WeakSet<object>()'
assert_true "and the writer asks it by identity" \
  str_has_sub "$WRITER_SRC" 'if (!isResolvedTracingConfig(config))'
assert_true "the column refusal tests the VALUE true, not a type" \
  str_has_sub "$CFG_SRC" 'config.columns === true'
# A CITATION IS THE OPPOSITE OF A DEPENDENCY, AND THIS ASSERTION CAUGHT ITS OWN AUTHOR.
# The first draft counted with a raw `grep -rc 'private constructor'` and went RED at 1 — the
# occurrence being the comment at the top of `config.ts` that names the construct while explaining
# why it is not used. That is the campaign's "a citation counted as a call", in the check written
# to prevent the defect the citation is about. The count is taken over CODE now, and the presence
# of the phrase in a comment is asserted TOO, so the stripper is shown to be doing work rather
# than silently returning nothing.
#
# THE DESCRIPTIONS BELOW ARE SINGLE-QUOTED, and that is the second thing this line taught: a
# backtick inside a DOUBLE-quoted bash string is command substitution. `"no `private constructor`
# anywhere"` ran `private constructor` as a command, and the assertion printed its own name with
# the subject missing from it.
HOST_CODE="$(python3 "$VERIFY_DIR/_strip_ts_comments.py" "$M24_HOST/src")" \
  || die "the comment stripper failed over $M24_HOST/src"
assert_ge "the comment stripper left a substantial amount of code (the scan is not vacuous)" \
  "300" "$(printf '%s\n' "$HOST_CODE" | grep -c . || true)"
assert_true "and it left the gate itself, so it did not strip its own subject" \
  str_has_sub "$HOST_CODE" 'config.columns === true'
assert_eq 'no `private constructor` in ct-host CODE — the construct Node erases' "0" \
  "$(printf '%s\n' "$HOST_CODE" | grep -c 'private constructor' || true)"
assert_ge 'and the phrase IS in a comment, so the stripper is doing work rather than returning nothing' \
  "1" "$(grep -rc 'private constructor' "$M24_HOST/src" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
# `#private` FIELDS ARE NOT ERASED and would be a legitimate runtime guarantee; their ABSENCE is
# not asserted. What is asserted is that nothing relies on the erasable constructs.
assert_eq 'no `enum` or `declare` in ct-host code either' "0" \
  "$(printf '%s\n' "$HOST_CODE" | grep -cE '^[[:space:]]*(declare|enum|const enum) ' || true)"

# The three DD-7 constants exist as DATA, so adding Path B is a row rather than an edit to a
# conditional — and the table's Path A row is the structural `false`.
assert_true "the column capability is a data table" str_has_sub "$CFG_SRC" 'export const CARRIES_COLUMNS'
assert_true "and Path A's row is false" \
  str_has_sub "$CFG_SRC" '[WRITER_PATH_A_PURE_RUST]: false'
assert_true "and Path B's row is true, so the gate is not a constant refusal" \
  str_has_sub "$CFG_SRC" '[WRITER_PATH_B_NIM]: true'

m24_finish
