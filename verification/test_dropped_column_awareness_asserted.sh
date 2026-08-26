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
# ---------------------------------------------------------------------------
# WHAT THIS CHECK MEANS CHANGED WHEN THE `trace_format` ANCHOR MOVED, AND IT WAS CHANGED
# DELIBERATELY RATHER THAN REPAIRED UNTIL IT WENT GREEN AGAIN.
#
# At `9cbc127ef8` the Path A writer could not carry columns, and DD-7 had two enforcement points:
# a refusal at configuration time, and `dropped_column_awareness()` at close for the one bypass
# that got past it (a resolved configuration mutated afterwards). At `592fa42cbf` the writer
# HONOURS a column request — delta-column opcode, `paths.dat` Layout A, `meta.dat` bits 4/6/7 —
# so:
#
#   * the gate that used to assert a THROW at close now asserts the module's own answer, that
#     the request was made and NOT dropped. It is renamed `columns-requested-are-honoured`,
#     because a gate whose name says "dropped" and whose assertion says "not dropped" is how a
#     check comes to be believed for the wrong reason;
#   * `dropped_column_awareness()` is no longer reachable as a `true` through this ABI, so
#     nothing may rest on it. The bypass it used to catch is closed at CONFIGURATION time by
#     `Object.freeze`, and this check EXECUTES that rather than reading `readonly` out of the
#     source — `readonly` is erased and would read identically;
#   * the DD-7 refusal itself stands, and its SUBJECT moved. It is no longer "this writer cannot
#     carry columns"; it is "this runtime has no source column to record", because `emit()` is on
#     rung 3 and writes a program counter as `Line(pc)`. The refusal message says that now, and
#     the assertions below quote the new sentence.
#
# The three facts that make the first bullet true are asserted FROM THE MODULE, not from here.
# ---------------------------------------------------------------------------
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

assert_eq "the arms run exercised six gates, four refusals, one measurement and one control" "6" \
  "$(m24_arm 'len(d["gates"])')"

assert_eq "columns requested of Path A THROWS at configuration time" "true" \
  "$(gate_threw columns-on-path-a)"
assert_eq "and it is DD-7's own refusal, by class" "ColumnAwarenessUnavailable" \
  "$(gate_kind columns-on-path-a)"
# THE REFUSAL'S REASON IS THE THING THAT MOVED, SO THE REASON IS WHAT IS PINNED.
# It used to say the writer has no column-bearing step encoder and sets no capability bits.
# That is false of the writer at the current anchor, and a refusal that gives a false reason is
# worse than one that gives none: it is the campaign's "prose drifts from measurement" defect
# with a user on the other end of it.
assert_true "the refusal says the WRITER can carry columns, which is true at this anchor" \
  str_has_sub "$(gate_error columns-on-path-a)" 'writer at the pinned trace_format anchor CAN carry'
assert_true "and locates the missing half in THIS runtime: rung 3, a program counter" \
  str_has_sub "$(gate_error columns-on-path-a)" 'records a program counter'
assert_true "and says what enabling it anyway would advertise" \
  str_has_sub "$(gate_error columns-on-path-a)" 'breakpoint-sharp columns over'
assert_false "and it no longer claims the writer has no column-bearing step encoder" \
  str_has_sub "$(gate_error columns-on-path-a)" 'This writer has no column-bearing step encoder'

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

# ---------------------------------------------------------------------------
# THE INVERTED GATE. A column request that REACHES the module is HONOURED at this anchor.
#
# Read off the module (`ct_columns_requested()` and `ct_dropped_column_awareness()` at close),
# never off the configuration: the two agreeing is a fact worth being able to fail, and the
# writer is the only thing that knows whether it honoured the request.
# ---------------------------------------------------------------------------
assert_eq "a column request that reaches the module does NOT throw any more" "false" \
  "$(gate_threw columns-requested-are-honoured)"
assert_eq "and the module recorded that columns WERE requested of it" "true" \
  "$(m24_arm 'd["columnRequest"]["columnsRequested"]')"
assert_eq "and reports it did NOT drop them — the capability exists at this anchor" "false" \
  "$(m24_arm 'd["columnRequest"]["droppedColumnAwareness"]')"
# NON-DEGENERACY: "not dropped" over a recording that wrote nothing would be true for the wrong
# reason. The arm pushed an event and produced a container, and both are asserted.
assert_ge "over a recording that actually wrote an event" "1" \
  "$(m24_arm 'd["columnRequest"]["events"]')"
assert_ge "and produced a container rather than an empty buffer" "1000" \
  "$(m24_arm 'd["columnRequest"]["containerBytes"]')"
assert_eq "on the Path A module, so this is Path A's answer and not another writer's" "1" \
  "$(m24_arm 'd["columnRequest"]["writerKind"]')"

# ---------------------------------------------------------------------------
# WHAT REPLACED THE CLOSE-TIME CATCH: THE RESOLVED CONFIGURATION IS FROZEN.
#
# `dropped_column_awareness()` was M24's backstop for the one bypass that got past the
# configuration-time gate. It cannot fire at this anchor, so the bypass is closed where DD-7 says
# it belongs — at configuration time. EXECUTED rather than read: `Object.freeze` is a call and
# `readonly` is a type, and only one of them exists at run time.
# ---------------------------------------------------------------------------
assert_eq "mutating a RESOLVED configuration throws, at the mutation" "true" \
  "$(gate_threw mutating-a-resolved-config)"
assert_eq "and it is strict mode's own refusal rather than a check of ours" "TypeError" \
  "$(gate_kind mutating-a-resolved-config)"

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

// 5. Mutating a RESOLVED config after the gate ran. This USED to be the one bypass that worked
//    at configuration time, caught at close by the writer`s dropped-column signal. The writer at
//    the current anchor honours a column request, so that signal cannot fire -- and the bypass is
//    closed at configuration time instead, by `Object.freeze`. THE ASSIGNMENT IS INSIDE THE TRY
//    on purpose: it is the assignment that throws now, and leaving it outside would kill the
//    probe rather than record the refusal.
const inst3 = await m.instantiateCtWriter(bytes);
try {
  const cfg = m.resolveTracingConfig({ ...base, columns: false }, m.WRITER_PATH_A_PURE_RUST);
  cfg.columns = true;
  const w = new m.CtWriter(inst3, cfg, { batchRecords: 4 });
  const addr = new Uint8Array(32);
  w.push({ contextId: 0, pc: 1, opcode: 2, l2Gas: 3n, daGas: 4n, contractAddress: addr });
  w.close();
  ok("mutated-after-resolve");
} catch (e) { no("mutated-after-resolve", e); }
// 5b. THE FREEZE`S OWN CONTROL. Freezing must not have made the object unreadable or the gate
//     unusable: a resolved config still reports the fields the writer needs. Without this,
//     "mutation throws" is satisfied by a resolveTracingConfig that returns something broken.
try {
  const cfg2 = m.resolveTracingConfig({ ...base, columns: false }, m.WRITER_PATH_A_PURE_RUST);
  console.log("FROZEN\t" + Object.isFrozen(cfg2));
  console.log("READBACK\t" + cfg2.program + "," + cfg2.writerPath + "," + String(cfg2.columns));
} catch (e) { no("frozen-config-readback", e); }

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
# THE ONE THAT USED TO GET THROUGH THE FIRST GATE. M24 recorded it as uncatchable at
# configuration time "by anything short of freezing" and caught it at close instead. The close-time
# catch cannot fire at this anchor, so the sentence's own remedy is what is in place: it is frozen,
# and the refusal is `TypeError` from strict mode rather than a class of ours.
assert_true "a config MUTATED after it was resolved is refused AT THE MUTATION, at config time" \
  str_has_line_re "$BYPASS" "^REFUSED${TAB}mutated-after-resolve${TAB}TypeError\$"
assert_true "and the resolved object really is frozen, read back through the public export" \
  str_has_line_re "$BYPASS" "^FROZEN${TAB}true\$"
# THE FREEZE'S CONTROL: it must not have broken the object it protects.
assert_true "and a frozen config still carries the fields the writer reads" \
  str_has_line_re "$BYPASS" "^READBACK${TAB}p,path-a-pure-rust,false\$"
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
