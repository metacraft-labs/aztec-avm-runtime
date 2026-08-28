#!/usr/bin/env bash
# test_vfs_compile_errors_carry_positions
#
# M30's second entry: a deliberate type error reports the right file and span AGAINST THE
# CALLER'S OWN VIRTUAL-FILESYSTEM PATHS. Control: a clean tree reports none.
#
# ===========================================================================================
# WHAT WAS THERE BEFORE, MEASURED RATHER THAN CHARACTERISED.
# ===========================================================================================
#
# `compiler/wasm/src/errors.rs` builds the `Diagnostic` the shipped compiler throws:
# `struct DiagnosticLabel` at **:75-80** is `{ message, start, end }` and `struct Diagnostic`
# at **:82-87** is `{ message, file, secondaries }`, so what crosses to JavaScript is a file
# name and BYTE OFFSETS — no line and no column anywhere. (An earlier draft of this header
# cited `:83-104` for `DiagnosticLabel`; that range is `Diagnostic` and its `impl`. Corrected
# by M30's review, read out of the file.) The consumer,
# `src/noir/noir-wasm-compiler.ts:192-203`, therefore reconstructs one:
#
#     const errorLine = lineOffsets.findIndex((offset) => offset > secondary.start);
#     logs.push(`    ${diag.file}:${errorLine}: …`);
#
# AND THE HONEST ACCOUNT OF THAT LINE IS NARROWER THAN "AN INDEX PRINTED AS A LINE NUMBER".
# `lineOffsets[i]` is the start offset of 0-based line `i`, so for an error on 0-based line
# `k` the first offset greater than `start` is at index `k+1` — which is the correct 1-based
# line. It is accidentally right. What it is NOT right about, measured rather than asserted:
# an error on the LAST line (or past every offset) makes `findIndex` return **-1**; there is
# no column at all; the secondary's own `message` is never printed; and `#resolveFile`'s
# `catch` returns `''` (`:176-183`), which makes `lineOffsets` `[0]` and therefore prints
# `-1` for EVERY position in a file it cannot read. M30's `position_diagnostics` asks the
# `FileManager`'s own `codespan_files::Files::location` instead, which is the same source
# `nargo`'s reporter uses.
#
# ===========================================================================================
# THE POSITION IS A MEASUREMENT, AND THAT IS ASSERTED TWICE OVER.
# ===========================================================================================
#
# A check that compared a reported line against a number typed into the check would be
# comparing a measurement with a constant its author read off the fixture —
# `CAMPAIGN-BRIEF.md`'s "a constant you have just typed into a check looks like a measurement
# to the person typing it". So:
#
#   - the expected line and column are DERIVED, in `tools/m30_vfs_trees.mjs`, by scanning the
#     fixture's own text for the offending token. Two derivations of one fact, neither
#     reading the other;
#   - and the same error is compiled a second time with six blank lines above it. The
#     reported line has to move by exactly six. A derivation that had silently stopped
#     working would have to be wrong twice, in step, to survive that.
#
# ===========================================================================================
# THE ERROR IS PLANTED IN THE DEPENDENCY ON PURPOSE.
# ===========================================================================================
#
# `src/noir/package.ts:112-114` re-keys every library source to `<alias>/<suffix>` so that
# `compile_new.rs`'s `add_noir_lib` can find `<alias>/lib.nr`. Under that scheme a diagnostic
# inside a dependency names `util/lib.nr` — a path the caller's virtual filesystem does not
# contain. M30 registers each package with `prepare_dependency` at its own VFS entry path
# instead, the way native `nargo` does, so §3 can require the reported path to be a KEY OF
# THE TREE. That assertion is the whole difference, and it is the one that would fail if the
# alias scheme came back.
#
# Run: just verify-m30-positions

TEST_NAME="test_vfs_compile_errors_carry_positions"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m30_vfs.sh"

m30_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m30_require_arms

echo "== 1. the fields every comparison reads are present"

WANT_LINE="$(m30_arm arms.modules.expectations.typeErrorLine)"
WANT_MOVED="$(m30_arm arms.modules.expectations.typeErrorMovedLine)"
WANT_COLUMN="$(m30_arm arms.modules.expectations.typeErrorColumn)"
GOT_FILE="$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.file)"
GOT_LINE="$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.line)"
GOT_COLUMN="$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.column)"
GOT_MOVED="$(m30_arm arms.compile.typeErrorInDependencyMoved.diagnostics.0.line)"

ABSENT="$(m30_absent "wantLine=$WANT_LINE" "wantMovedLine=$WANT_MOVED" "wantColumn=$WANT_COLUMN" \
                     "file=$GOT_FILE" "line=$GOT_LINE" "column=$GOT_COLUMN" "movedLine=$GOT_MOVED")"
assert_eq "every field the comparisons below read is present" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report is missing $ABSENT; every comparison would be between two
             absences. A failure, not a smaller check."

echo "== 2. the compile is refused, and it is refused for the right reason"

assert_eq "the tree with a deliberate type error does not compile" "false" \
  "$(m30_arm arms.compile.typeErrorInDependency.ok)"
assert_eq "…at the compile stage, not the resolve stage" "compile" \
  "$(m30_arm arms.compile.typeErrorInDependency.stage)"
assert_eq "…so the PLAN survives: which files the program is made of is an answer either way" \
  '["app/src/helper.nr","app/src/main.nr","util/src/lib.nr"]' \
  "$(m30_arm arms.compile.typeErrorInDependency.plan.sources)"
assert_eq "…and no artifact is produced" "false" \
  "$(m30_arm arms.compile.typeErrorInDependency.artifact.present)"

DIAGS="$(m30_arm arms.compile.typeErrorInDependency.diagnostics)"
COUNT="$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$DIAGS")"
assert_eq "two diagnostics: the declaration and its caller" "2" "$COUNT"

echo "== 3. the position, against the caller's own paths"

assert_eq "the first diagnostic names the file the error is IN — the DEPENDENCY" \
  "util/src/lib.nr" "$GOT_FILE"

# The path must be a key of the virtual filesystem the page held. Not "looks like a path",
# not "is non-empty" — a member of the set the caller supplied.
TREE_PATHS="$(m30_arm arms.compile.typeErrorInDependency.treePaths)"
assert_true "…and that path is a file the caller put in the virtual filesystem" \
  str_has_sub "$TREE_PATHS" "\"$GOT_FILE\""

assert_eq "the line is the line the offending return type is on" "$WANT_LINE" "$GOT_LINE"
assert_eq "the column is the column it starts at" "$WANT_COLUMN" "$GOT_COLUMN"
assert_ge "the span ends at or after where it starts" "$GOT_LINE" \
  "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.end_line)"
assert_ge "…and ends after the column it starts at" "$((GOT_COLUMN + 1))" \
  "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.end_column)"
assert_eq "the diagnostic is an error rather than a warning" "error" \
  "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.severity)"
assert_true "…and says what the mismatch is" \
  str_has_sub "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.message)" "expected type u8"
assert_true "…and carries the frontend's own secondary labels, which errors.rs's shape drops" \
  str_has_sub "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.secondary_messages)" \
  "because of return type"
assert_ge "…and the byte offsets the shipped Diagnostic carries are still there" 1 \
  "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.0.start)"

echo "== 3b. the SECOND diagnostic is in the OTHER package, and is positioned there"

assert_eq "the caller's error is reported in the entry package's own file" "app/src/main.nr" \
  "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.1.file)"
assert_ge "…at a real line" 1 "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.1.line)"
assert_ge "…and a real column" 1 "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.1.column)"
assert_false "…and it is NOT the same file as the first, so one position is not standing in for both" \
  test "$GOT_FILE" = "$(m30_arm arms.compile.typeErrorInDependency.diagnostics.1.file)"

echo "== 4. THE POSITION MOVES WITH THE ERROR: it is measured, not constant"

# Same error, same file, same column — six blank lines above it. Both sides of this move:
# the module's answer, and the expectation derived from the fixture.
assert_eq "moving the error down six lines moves the reported line to where it now is" \
  "$WANT_MOVED" "$GOT_MOVED"
assert_eq "…which is six lines further down" "6" "$((GOT_MOVED - GOT_LINE))"
assert_eq "…and the column does not move, because the error did not move sideways" \
  "$GOT_COLUMN" "$(m30_arm arms.compile.typeErrorInDependencyMoved.diagnostics.0.column)"
assert_eq "…and it is still the dependency's file" "util/src/lib.nr" \
  "$(m30_arm arms.compile.typeErrorInDependencyMoved.diagnostics.0.file)"

echo "== 5. THE CONTROL: a clean tree reports no diagnostics and no warnings"

assert_eq "the same tree without the error compiles" "true" "$(m30_arm arms.compile.multifile.ok)"
assert_eq "…reporting no diagnostics at all" "[]" "$(m30_arm arms.compile.multifile.diagnostics)"
assert_eq "…and no warnings either" "[]" "$(m30_arm arms.compile.multifile.warnings)"
assert_eq "…and it is the SAME tree but for one file, so the difference is the error" \
  "$(m30_arm arms.compile.multifile.treePaths)" \
  "$(m30_arm arms.compile.typeErrorInDependency.treePaths)"

echo "== 6. and the positions came out of the module, not out of JavaScript"

assert_eq "the module reached no import while producing them" "[]" \
  "$(m30_arm arms.modules.reached.compiler)"
assert_ge "…out of the imports it declares" 20 \
  "$(m30_arm arms.modules.modules.compiler.declaredImports)"

echo "== 7. the two diagnostic shapes, side by side, in the files that hold them"

# The header of this file states what the shipped path does. That is a claim about another
# file's behaviour and it rots the moment that file changes, so it is re-derived here. If one
# of these goes red, the enumeration in the header is stale and the right response is to
# re-read those files rather than to relax the assertion.
VFS_RS="$M30_VFS_SRC/vfs.rs"
ERRORS_RS="$M30_NOIR_ROOT/compiler/wasm/src/errors.rs"
TS_COMPILER="$M30_NOIR_ROOT/compiler/wasm/src/noir/noir-wasm-compiler.ts"
assert_file "M30's positioned diagnostic is where this check says it is" "$VFS_RS"
assert_file "the shipped Diagnostic type is where the header says" "$ERRORS_RS"
assert_file "…and so is its consumer" "$TS_COMPILER"

VFS_SRC_TEXT="$(cat "$VFS_RS" 2>/dev/null)"
assert_true "M30 asks the FileManager's own file map for a location" \
  str_has_sub "$VFS_SRC_TEXT" "files.location(diagnostic.file"
assert_true "…and its diagnostic declares a line" str_has_sub "$VFS_SRC_TEXT" "pub line: usize,"
assert_true "…and a column" str_has_sub "$VFS_SRC_TEXT" "pub column: usize,"

# THE CONTROL FOR THOSE THREE, AND IT IS THE POINT OF THE SECTION: the shipped label type
# carries byte offsets and NOTHING ELSE. The struct is extracted into a variable first rather
# than `sed … | grep -q`, because `verify_no_pipeline_predicates` pins the surviving count of
# that spelling by name.
LABEL_STRUCT="$(sed -n '/^struct DiagnosticLabel {/,/^}/p' "$ERRORS_RS" 2>/dev/null)"
assert_true "the shipped DiagnosticLabel was found and is not empty" \
  str_has_sub "$LABEL_STRUCT" "struct DiagnosticLabel"
assert_true "…and it carries a byte offset" str_has_sub "$LABEL_STRUCT" "start: u32,"
assert_false "…and no line" str_has_sub "$LABEL_STRUCT" "line"
assert_false "…and no column" str_has_sub "$LABEL_STRUCT" "column"
assert_true "…which is why its consumer reconstructs one by comparing byte offsets" \
  str_has_sub "$(cat "$TS_COMPILER" 2>/dev/null)" "lineOffsets.findIndex((offset) => offset > secondary.start)"

# AND THE ENVELOPE AROUND THE LABEL CARRIES NO POSITION EITHER. The header says "no line and
# no column anywhere", which is a claim about `Diagnostic` and not only about its labels, so
# it is read out of the file rather than left as a sentence. Same shape as the block above:
# the struct is extracted first, asserted non-empty, and only then asked what it lacks.
DIAG_STRUCT="$(sed -n '/^pub struct Diagnostic {/,/^}/p' "$ERRORS_RS" 2>/dev/null)"
assert_true "the shipped Diagnostic was found and is not empty" \
  str_has_sub "$DIAG_STRUCT" "file: String,"
assert_false "…and it carries no line of its own, so the label is the whole story" \
  str_has_sub "$DIAG_STRUCT" "line"

m30_finish
