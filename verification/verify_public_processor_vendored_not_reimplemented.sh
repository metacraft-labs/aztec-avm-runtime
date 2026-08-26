#!/usr/bin/env bash
# verify_public_processor_vendored_not_reimplemented — M22.
#
# THE DELIVERABLE IS A NEGATIVE AND THAT IS WHY THIS CHECK EXISTS. M22's first line says
# `PublicProcessor.process` drives the block, "*This class is upstream's, imported at HEAD by four
# production consumers*, and is reused rather than reimplemented". Every other check in this
# milestone asserts that a block BEHAVES correctly, and a block would behave correctly if the loop
# had been rewritten from the same description. So this check asks the different question: is the
# loop upstream's code, at the pinned commit, with only the edits PROVENANCE.md declares?
#
# Six parts.
#
#   1. THE CLAIM IN THE DELIVERABLE, RE-DERIVED. "Four production consumers at HEAD" is measured
#      out of the fork rather than quoted: the set of PACKAGES whose non-test sources import
#      `PublicProcessor` or `PublicProcessorFactory` from `@aztec/simulator/server`, compared AS A
#      SET, so three would fail and five would fail. It is measured at HEAD, not at the anchor,
#      because the deliverable says "at HEAD" — and this campaign has quoted a stale tip four times
#      across two documents.
#   2. THE COPY IS THE ANCHOR'S. Every one of the ten vendored files is diffed against
#      `git show <ts anchor>:<path>` with the provenance header stripped by the provenance tool's
#      OWN stripper, and the five that are supposed to be byte-identical are.
#   3. THE FIVE THAT DIFFER, DIFF EXACTLY AS DECLARED. Whole lines, never fragments — the campaign
#      has a recorded defect where a comparison matched changed lines against a regex of substrings
#      and `this.depth = depth + 1` was excused by `this.depth = depth`. The three small files are
#      pinned as their COMPLETE changed-line set; the processor is pinned by exact counts plus a
#      per-line classification in which every added non-comment line must fall into one of the four
#      declared edit shapes.
#   4. THE LOOP IS STILL THERE. Six load-bearing lines of upstream's `process` — the fork
#      checkpoint, the `hasPublicCalls()` dispatch, the two reverts, the `finally` commit and the
#      unchanged-state check — are required to be present in the copy AND in the anchor blob, as
#      WHOLE LINES. A needle that is satisfied by prose is not a dependency; a citation is the
#      opposite of a call.
#   5. WHAT WAS DELIBERATELY REMOVED IS GONE, AND WAS THERE. `PublicProcessorFactory`,
#      `TelemetryCppPublicTxSimulator`, `generateProvingRequest` and `AvmProvingRequest` are absent
#      from the copy and PRESENT in the anchor blob — an absence measured against a haystack that
#      could have contained it. Comment-stripped, because the copy's own header NAMES all four in
#      the paragraph that explains why they went, and a bare-text search would find them there.
#   6. NOTHING OF OURS RE-IMPLEMENTS IT. No file under `orchestration/src` outside `vendor/`
#      contains a `hasPublicCalls()` dispatch, a `ForkCheckpoint.new` per transaction, or a
#      `revertToCheckpoint` — with the control that the VENDORED file does, by the same needle.
#
# Run: just verify-processor-vendored

TEST_NAME="verify_public_processor_vendored_not_reimplemented"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m22_block.sh"

m22_summary_on_abnormal_exit
m22_require_anchor

PP_UP="yarn-project/simulator/src/public/public_processor/public_processor.ts"
PP_LOCAL="$M22_VENDOR/public_processor/public_processor.ts"

note "ts anchor $M22_TS_ANCHOR"

# ---------------------------------------------------------------------------
# PART 1 — "imported at HEAD by four production consumers", re-derived
# ---------------------------------------------------------------------------

# The tip is MEASURED rather than quoted. M21 quoted a stale one four times.
FORK_HEAD="$(git -C "$FORK_ROOT" rev-parse HEAD)"
note "fork HEAD $FORK_HEAD"
assert_eq "the fork HEAD is a resolved commit" "commit" \
  "$(git -C "$FORK_ROOT" cat-file -t "$FORK_HEAD" 2>/dev/null || echo missing)"

consumers_at() { # <rev> -> the packages whose non-test sources import the processor from @aztec/simulator
  git -C "$FORK_ROOT" grep -l -E "PublicProcessorFactory|PublicProcessor\b" "$1" -- 'yarn-project/**/*.ts' 2>/dev/null \
    | sed "s|^$1:||" \
    | grep -v '^yarn-project/simulator/' \
    | grep -v '\.test\.ts$' \
    | grep -v '/test/' \
    | grep -v '/mocks/' \
    | while IFS= read -r f; do
        body="$(git -C "$FORK_ROOT" show "$1:$f" 2>/dev/null || true)"
        # Call-shaped, not prose-shaped: the name must appear in a single-line import specifier
        # that names @aztec/simulator, or in a `new PublicProcessor(` construction.
        #
        # A THIRD ARM WAS REMOVED. It matched `^  PublicProcessor,$` — a FORMATTING of a member of a
        # multi-line import list — and it was both fragile and redundant: the two files it was meant
        # to catch (validator-client's checkpoint builder and TXE's top-level context) both
        # CONSTRUCT the class, so the second arm already has them. A needle kept "just in case" is a
        # needle nobody re-derives, and this one would have matched an object literal or an export
        # list as readily as an import.
        if str_has_line_re "$body" "^import .*Public(Processor|ProcessorFactory).*from '@aztec/simulator" \
          || str_has_re "$body" "new PublicProcessor\("; then
          printf '%s\n' "$f" | cut -d/ -f2
        fi
      done | sort -u
}

HEAD_CONSUMERS="$(consumers_at "$FORK_HEAD")"
printf '%s\n' "$HEAD_CONSUMERS" | sed 's/^/      /'
assert_eq "the packages that consume PublicProcessor at upstream HEAD, as a SET" \
  "aztec-node prover-node txe validator-client" \
  "$(printf '%s' "$HEAD_CONSUMERS" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and there are four of them, which is the number the deliverable states" "4" \
  "$(printf '%s\n' "$HEAD_CONSUMERS" | grep -c . || true)"

# The control for that enumeration: a name upstream does not have is found in no package, by the
# SAME scanner — so "four" is four of a lookup that can also answer zero.
assert_eq "a class upstream does not have is consumed by no package, by the same scanner" "0" \
  "$(git -C "$FORK_ROOT" grep -l "PublicProcessorNoSuchClass" "$FORK_HEAD" -- 'yarn-project/**/*.ts' 2>/dev/null \
      | grep -c . || true)"

# ---------------------------------------------------------------------------
# PART 2 — the copy is the anchor's
# ---------------------------------------------------------------------------

echo "== every vendored file is the anchor's, byte for byte where it is declared to be"

IDENTICAL="contracts_db_checkpoint.ts:yarn-project/simulator/src/public/contracts_db_checkpoint.ts
db_interfaces.ts:yarn-project/simulator/src/public/db_interfaces.ts
public_errors.ts:yarn-project/simulator/src/public/public_errors.ts
public_tx_simulator_interface.ts:yarn-project/simulator/src/public/public_tx_simulator/public_tx_simulator_interface.ts
txe_block_creation.ts:yarn-project/txe/src/utils/block_creation.ts"

while IFS=: read -r local upstream; do
  [ -n "$local" ] || continue
  d="$(m22_vendor_diff "$local" "$upstream")"
  assert_eq "$local carries NO local edit at all" "" "$d"
done <<EOF
$IDENTICAL
EOF

# …and the comparison is not vacuous: the same machinery reports a difference for a file that has
# one. Without this, five empty diffs would also be what a broken differ produces.
assert_true "the same comparison DOES report a difference for a file that has one" \
  test -n "$(m22_vendor_diff side_effect_errors.ts yarn-project/simulator/src/public/side_effect_errors.ts)"

# ---------------------------------------------------------------------------
# PART 3 — the five that differ, diff exactly as declared
# ---------------------------------------------------------------------------

echo "== the recorded edits, as WHOLE LINES"

# `side_effect_errors.ts` — one specifier.
SEE_DIFF="$(m22_vendor_diff side_effect_errors.ts yarn-project/simulator/src/public/side_effect_errors.ts)"
assert_eq "side_effect_errors.ts: the complete removed set" \
  "import { CheckedPublicExecutionError } from './public_errors.js';" \
  "$(printf '%s\n' "$SEE_DIFF" | sed -n 's/^< //p')"
assert_eq "side_effect_errors.ts: the complete added set" \
  "import { CheckedPublicExecutionError } from './public_errors.ts';" \
  "$(printf '%s\n' "$SEE_DIFF" | sed -n 's/^> //p')"

# `guarded_merkle_tree.ts` — one parameter property. DD-3's class, unchanged in every other line.
GMT_DIFF="$(m22_vendor_diff public_processor/guarded_merkle_tree.ts \
  yarn-project/simulator/src/public/public_processor/guarded_merkle_tree.ts)"
assert_eq "guarded_merkle_tree.ts: the complete removed set" \
  "  constructor(private target: MerkleTreeWriteOperations) {" \
  "$(printf '%s\n' "$GMT_DIFF" | sed -n 's/^< //p')"
assert_eq "guarded_merkle_tree.ts: the complete added set" \
  "  private target: MerkleTreeWriteOperations;
  constructor(target: MerkleTreeWriteOperations) {
    this.target = target;" \
  "$(printf '%s\n' "$GMT_DIFF" | sed -n 's/^> //p')"

# `public_processor_metrics.ts` — one import specifier, and the NAMES are unchanged.
PPM_DIFF="$(m22_vendor_diff public_processor/public_processor_metrics.ts \
  yarn-project/simulator/src/public/public_processor/public_processor_metrics.ts)"
assert_eq "public_processor_metrics.ts: the complete removed set" \
  "} from '@aztec/telemetry-client';" \
  "$(printf '%s\n' "$PPM_DIFF" | sed -n 's/^< //p')"
assert_eq "public_processor_metrics.ts: the complete added set" \
  "} from '../../telemetry.ts';" \
  "$(printf '%s\n' "$PPM_DIFF" | sed -n 's/^> //p')"

# `public_db_sources.ts` — three specifiers and two parameter properties, and nothing else.
PDS_DIFF="$(m22_vendor_diff public_db_sources.ts yarn-project/simulator/src/public/public_db_sources.ts)"
assert_eq "public_db_sources.ts: the complete removed set" \
  "import { ContractsDbCheckpoint } from './contracts_db_checkpoint.js';
import type { PublicContractsDBInterface, PublicStateDBInterface } from './db_interfaces.js';
import { L1ToL2MessageIndexOutOfRangeError, NoteHashIndexOutOfRangeError } from './side_effect_errors.js';
  constructor(
    private dataSource: ContractDataSource,
    bindings?: LoggerBindings,
  ) {
  constructor(
    private readonly db: MerkleTreeWriteOperations,
    bindings?: LoggerBindings,
  ) {" \
  "$(printf '%s\n' "$PDS_DIFF" | sed -n 's/^< //p')"
assert_eq "public_db_sources.ts: the complete added set" \
  "import { ContractsDbCheckpoint } from './contracts_db_checkpoint.ts';
import type { PublicContractsDBInterface, PublicStateDBInterface } from './db_interfaces.ts';
import { L1ToL2MessageIndexOutOfRangeError, NoteHashIndexOutOfRangeError } from './side_effect_errors.ts';
  private dataSource: ContractDataSource;
  constructor(dataSource: ContractDataSource, bindings?: LoggerBindings) {
    this.dataSource = dataSource;
  private readonly db: MerkleTreeWriteOperations;
  constructor(db: MerkleTreeWriteOperations, bindings?: LoggerBindings) {
    this.db = db;" \
  "$(printf '%s\n' "$PDS_DIFF" | sed -n 's/^> //p')"

# `public_processor.ts` — the big one. Pinned by exact counts AND by classifying every added
# non-comment line, because a 184-line changed set written out in full would be unreadable and an
# unreadable pin is one nobody re-derives.
PP_DIFF="$(m22_vendor_diff public_processor/public_processor.ts "$PP_UP")"
PP_REMOVED="$(printf '%s\n' "$PP_DIFF" | sed -n 's/^< //p')"
PP_ADDED="$(printf '%s\n' "$PP_DIFF" | sed -n 's/^> //p')"
# Counted off the DIFF and not off the extracted text, so a removed or added BLANK line counts.
# Extracting with `sed -n 's/^< //p'` and then `grep -c .` drops them, which reported 106/69 for a
# diff that is 112/72 — six lines a later edit could have moved without the pin noticing.
assert_eq "public_processor.ts: the removed line count is pinned" "112" \
  "$(printf '%s\n' "$PP_DIFF" | grep -c '^<' || true)"
assert_eq "public_processor.ts: the added line count is pinned" "72" \
  "$(printf '%s\n' "$PP_DIFF" | grep -c '^>' || true)"

# Every added line is a comment, blank, or one of the four declared shapes. Anything else is an
# undeclared edit and fails BY BEING PRINTED, not by moving a count.
UNCLASSIFIED="$(printf '%s\n' "$PP_ADDED" | python3 -c '
import re, sys
shapes = [
    # (1) node-strip-types: a .ts relative specifier
    re.compile(r"^\s*(import|}) .*from \x27(\.\./|\./)[A-Za-z0-9_/.]+\.ts\x27;$"),
    re.compile(r"^import \{ ForkCheckpoint \} from \x27\.\./\.\./fork_checkpoint\.ts\x27;$"),
    # (1) node-strip-types: a desugared parameter property — a field or an assignment
    re.compile(r"^\s{2,4}(private|protected|public)( readonly)? [A-Za-z0-9_]+: .+;$"),
    re.compile(r"^\s{4}this\.[A-Za-z0-9_]+ = [A-Za-z0-9_]+;$"),
    re.compile(r"^\s{4}[A-Za-z0-9_]+: .+,$"),
    # (2) telemetry / narrowed imports that lost a name
    re.compile(r"^import \{ type Logger, createLogger \} from \x27@aztec/foundation/log\x27;$"),
    re.compile(r"^import \{ PublicDataWrite \} from \x27@aztec/stdlib/avm\x27;$"),
    # (6) the narrowed contracts-DB type
    re.compile(r"^export type ProcessorContractsDB = .*$"),
    # (4) the proving-request removal, at the call site and at the destructuring
    re.compile(r"^\s+const \{ publicTxEffect, gasUsed, revertCode /\*callStackMetadata\*/ \} = result;$"),
    re.compile(r"^\s+undefined /\* avmProvingRequest — see above \*/,$"),
    # comment and structural lines
    re.compile(r"^\s*(//|/\*\*|\*|\*/).*$"),
    re.compile(r"^\s*$"),
    re.compile(r"^/\*\*$"),
]
for line in sys.stdin.read().splitlines():
    if not any(s.match(line) for s in shapes):
        print(line)
')"
if [ -z "$UNCLASSIFIED" ]; then
  pass "public_processor.ts: every added line falls into a declared edit shape"
else
  printf '%s\n' "$UNCLASSIFIED" | sed 's/^/      /'
  fail "public_processor.ts: $(printf '%s\n' "$UNCLASSIFIED" | grep -c .) added line(s) match no declared edit shape"
fi

# THE PERMISSIVE SHAPES ARE NOT THE LAST WORD, AND THERE ARE THREE OF THEM. The desugaring of a
# parameter property produces three line shapes, and the classifier above accepts all three by
# PATTERN: the constructor's own parameter line (`^\s{4}name: value,$`), the field declaration
# (`^\s{2,4}private|protected|public name: type;$`) and the assignment
# (`^\s{4}this.name = name;$`). Each matches ANY line of that form. The exact 112/72 counts stop an
# ADDITION, but a one-for-one SWAP keeps both counts and satisfies the shape, so a pattern alone
# cannot be the last word for any of the three.
#
# THE FIRST DRAFT PINNED ONLY THE FIRST OF THE THREE, and the review measured what the other two
# then admitted. `this.dateProvider = dateProvider;` -> `this.dateProvider = log;` is a real
# corruption of upstream's constructor — the date provider field ends up holding the logger — and it
# passed this check at 59 assertions and ZERO failures; it died only because the block run crashed
# downstream, which is a different check answering a different question. And
# `private dateProvider: DateProvider;` -> `private dateProvider: PublicProcessorMetrics;` is erased
# by the type stripper, so it passed EVERYTHING: `just check-drift` 22/0, this check 59/0,
# `just verify-m22` 247 assertions 4/4 exit 0, with an undeclared edit sitting in a vendored file.
# `check-drift` cannot help here by construction: it pins only the DIRECTION of a difference (a file
# PROVENANCE declares `none` must be identical, one it declares modified must differ), never its
# content. The content pin is this block and nothing else, so all three shapes are pinned.
PARAM_LINES="$(printf '%s\n' "$PP_ADDED" | python3 -c '
import re, sys
shape = re.compile(r"^\s{4}[A-Za-z0-9_]+: .+,$")
for line in sys.stdin.read().splitlines():
    if shape.match(line):
        print(line.strip())
')"
assert_eq "public_processor.ts: the desugared constructor's parameter lines, pinned exactly" \
  "globalVariables: GlobalVariables,
guardedMerkleTree: GuardedMerkleTreeOperations,
contractsDB: ProcessorContractsDB,
publicTxSimulator: PublicTxSimulatorInterface,
dateProvider: DateProvider,
log: Logger = createLogger('simulator:public-processor'),
opts: Pick<SequencerConfig, 'fakeProcessingDelayPerTxMs' | 'fakeThrowAfterProcessingTxCount'> = {},
debugLogStore: DebugLogStore = new NullDebugLogStore()," "$PARAM_LINES"

# …the field declarations the desugaring emits, pinned the same way. A swap here is invisible at run
# time — the type stripper erases it — so this assertion is the ONLY thing standing between the copy
# and an undeclared type change.
FIELD_LINES="$(printf '%s\n' "$PP_ADDED" | python3 -c '
import re, sys
shape = re.compile(r"^\s{2,4}(private|protected|public)( readonly)? [A-Za-z0-9_]+: .+;$")
for line in sys.stdin.read().splitlines():
    if shape.match(line):
        print(line.strip())
')"
assert_eq "public_processor.ts: the desugared field declarations, pinned exactly" \
  "protected globalVariables: GlobalVariables;
private guardedMerkleTree: GuardedMerkleTreeOperations;
protected contractsDB: ProcessorContractsDB;
protected publicTxSimulator: PublicTxSimulatorInterface;
private dateProvider: DateProvider;
private log: Logger;
private opts: Pick<SequencerConfig, 'fakeProcessingDelayPerTxMs' | 'fakeThrowAfterProcessingTxCount'>;
private debugLogStore: DebugLogStore;" "$FIELD_LINES"

# …and the assignments, where a swap is a real behavioural corruption: `this.dateProvider = log;`
# type-checks nowhere but runs, and every field is assigned from a parameter of the same name, which
# is the property the pin states.
ASSIGN_LINES="$(printf '%s\n' "$PP_ADDED" | python3 -c '
import re, sys
shape = re.compile(r"^\s{4}this\.[A-Za-z0-9_]+ = [A-Za-z0-9_]+;$")
for line in sys.stdin.read().splitlines():
    if shape.match(line):
        print(line.strip())
')"
assert_eq "public_processor.ts: the desugared constructor's assignments, pinned exactly" \
  "this.globalVariables = globalVariables;
this.guardedMerkleTree = guardedMerkleTree;
this.contractsDB = contractsDB;
this.publicTxSimulator = publicTxSimulator;
this.dateProvider = dateProvider;
this.log = log;
this.opts = opts;
this.debugLogStore = debugLogStore;" "$ASSIGN_LINES"

# The three pinned sets must each have found something. Without this a shape that stopped matching —
# a rename, a reindent — would silently pin the empty set against the empty set, which is the
# campaign's first catalogued vacuous form.
for pinned in "parameter lines:$PARAM_LINES" "field declarations:$FIELD_LINES" \
              "assignments:$ASSIGN_LINES"; do
  assert_eq "the desugared ${pinned%%:*} set is the eight the desugaring emits" "8" \
    "$(printf '%s\n' "${pinned#*:}" | grep -c . || true)"
done

# The classifier's own control: a line that is NOT one of the shapes must be reported by it. Run
# on a planted line rather than on the file, so nothing is written to the tree.
assert_eq "the added-line classifier reports a line that matches no declared shape" \
  "const somethingUndeclared = 1;" \
  "$(printf '%s\n' "const somethingUndeclared = 1;" | python3 -c '
import re, sys
shapes = [re.compile(r"^\s*(//|/\*\*|\*|\*/).*$"), re.compile(r"^\s*$")]
for line in sys.stdin.read().splitlines():
    if not any(s.match(line) for s in shapes):
        print(line)
')"

# ---------------------------------------------------------------------------
# PART 4 — the loop is still upstream's, line for line
# ---------------------------------------------------------------------------

echo "== the six load-bearing lines of upstream's process(), in the copy AND in the anchor"

PP_LOCAL_BODY="$(m22_strip_header "$PP_LOCAL")"
PP_ANCHOR_BODY="$(m22_anchor_file "$PP_UP")"
assert_ge "the anchor blob is a real file and not an empty string" 500 \
  "$(printf '%s\n' "$PP_ANCHOR_BODY" | grep -c . || true)"

LOOP_LINES="      const checkpoint = await ForkCheckpoint.new(this.guardedMerkleTree.getUnderlyingFork());
      const startStateReference = await this.guardedMerkleTree.getUnderlyingFork().getStateReference();
      tx.hasPublicCalls() ? () => this.processTxWithPublicCalls(tx) : () => this.processPrivateOnlyTx(tx);
        await checkpoint.revertToCheckpoint();
        await checkpoint.commit();
        await this.checkWorldStateUnchanged(startStateReference, txHash, err);"

n_loop=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n_loop=$((n_loop + 1))
  in_local=no; in_anchor=no
  str_has_line "$PP_LOCAL_BODY" "$line" && in_local=yes
  str_has_line "$PP_ANCHOR_BODY" "$line" && in_anchor=yes
  assert_eq "the loop line [$(printf '%s' "$line" | sed 's/^ *//' | cut -c1-56)…] is in BOTH" \
    "local=yes anchor=yes" "local=$in_local anchor=$in_anchor"
done <<EOF
$LOOP_LINES
EOF
assert_eq "six loop lines were checked" "6" "$n_loop"

# The needle is whole-line and exact, so a line that ALMOST matches does not. Without this, the six
# above would be satisfied by any file that happened to contain a superstring.
assert_false "a loop line with one character changed is NOT found in the copy" \
  str_has_line "$PP_LOCAL_BODY" "      const checkpoint = await ForkCheckpoint.new(this.guardedMerkleTree.getUnderlyingFork())"

# ---------------------------------------------------------------------------
# PART 5 — what was removed is gone from the CODE, and was present upstream
# ---------------------------------------------------------------------------

echo "== the four removals, comment-stripped, against a haystack that contains them upstream"

# COMMENT-STRIPPED, because the copy's own header names all four in the paragraph that explains why
# they went. This is M21's "a citation counted as a call" defect, met in the place where it is
# guaranteed to arise: the file documents its own removals.
strip_comments() { # <text>
  printf '%s\n' "$1" | sed -e 's|//.*$||' -e 's|^\s*\*.*$||' -e 's|/\*.*\*/||'
}
PP_LOCAL_CODE="$(strip_comments "$PP_LOCAL_BODY")"
PP_ANCHOR_CODE="$(strip_comments "$PP_ANCHOR_BODY")"

# THE STRIPPER IS A THING UNDER TEST, AND IT IS THE DANGEROUS DIRECTION THAT NEEDS THE CONTROL.
# `sed 's|//.*$||'` is the scanner this campaign has a recorded defect for: a `//` inside a STRING
# LITERAL begins a comment and eats the rest of the line. Over-stripping here would make the four
# absences below MORE likely to pass, which is exactly the wrong way for an absence check to fail.
# So the stripper is required to leave CODE alone, on lines chosen to be load-bearing.
for kept in "export class PublicProcessor implements Traceable {" \
            "    const { maxTransactions, deadline, maxBlockGas, maxBlobFields, isBuildingProposal, signal } = limits;" \
            "      const checkpoint = await ForkCheckpoint.new(this.guardedMerkleTree.getUnderlyingFork());"; do
  assert_true "comment-stripping leaves code intact: [$(printf '%s' "$kept" | sed 's/^ *//' | cut -c1-48)…]" \
    str_has_line "$PP_LOCAL_CODE" "$kept"
done
# …and it really is stripping something, so the three lines above are not the whole story.
assert_false "…while a whole-line comment does not survive it" \
  str_has_sub "$PP_LOCAL_CODE" "THE FACTORY IS REMOVED HERE"

for needle in "class PublicProcessorFactory" "new TelemetryCppPublicTxSimulator(" \
              "PublicProcessor.generateProvingRequest(" "): AvmProvingRequest {"; do
  present_local=no; present_anchor=no
  str_has_sub "$PP_LOCAL_CODE" "$needle" && present_local=yes
  str_has_sub "$PP_ANCHOR_CODE" "$needle" && present_anchor=yes
  assert_eq "[$needle] is gone from the copy and WAS in the anchor" \
    "copy=no anchor=yes" "copy=$present_local anchor=$present_anchor"
done

# And the comment-stripping is load-bearing rather than decorative: the copy's PROSE does mention
# all four, so the un-stripped body would answer "present" and the four assertions above would be
# measuring the comment rather than the code.
for needle in "PublicProcessorFactory" "TelemetryCppPublicTxSimulator" "generateProvingRequest" \
              "AvmProvingRequest"; do
  assert_true "the copy's prose DOES mention $needle, which is why stripping comments matters" \
    str_has_sub "$PP_LOCAL_BODY" "$needle"
  assert_false "…and it does NOT survive comment-stripping" \
    str_has_sub "$PP_LOCAL_CODE" "$needle"
done

# The proving request is not merely un-generated; the parameter is passed as `undefined` at the one
# call site, which is what makes "removed" a property of the transaction rather than of the file.
assert_true "makeProcessedTxFromTxWithPublicCalls is still called, with undefined for the request" \
  str_has_line "$PP_LOCAL_BODY" "      undefined /* avmProvingRequest — see above */,"
assert_true "and the anchor passed a generated one there" \
  str_has_line "$PP_ANCHOR_BODY" "      avmProvingRequest,"

# ---------------------------------------------------------------------------
# PART 6 — nothing of ours re-implements the loop
# ---------------------------------------------------------------------------

echo "== the loop exists once in this tree, and it is the vendored one"

# `fork_checkpoint.ts` is EXCLUDED BY NAME and the reason is not "it is inconvenient": it is
# upstream's `ForkCheckpoint`, vendored under RI-26, and `revertToCheckpoint` is its own METHOD
# DECLARATION rather than a call from a loop of ours. Excluding it by name rather than by pattern
# means a second file appearing with the same content fails.
OURS="$(find "$ORCH_SRC" -name '*.ts' -not -path "$M22_VENDOR/*" ! -name 'fork_checkpoint.ts' | sort)"
assert_true "the excluded file is the vendored ForkCheckpoint and nothing else" \
  test -f "$ORCH_SRC/fork_checkpoint.ts"
assert_true "…and revertToCheckpoint is a method DECLARATION there, not a call" \
  str_has_line "$(cat "$ORCH_SRC/fork_checkpoint.ts")" "  async revertToCheckpoint(): Promise<void> {"
assert_ge "there are orchestration sources outside vendor/ to search" 10 \
  "$(printf '%s\n' "$OURS" | grep -c . || true)"

for needle in "hasPublicCalls()" "ForkCheckpoint.new(" "revertToCheckpoint("; do
  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    body="$(strip_comments "$(cat "$f")")"
    str_has_sub "$body" "$needle" && hits="$hits $(basename "$f")"
  done <<EOF
$OURS
EOF
  assert_eq "no file of ours outside vendor/ calls $needle" "" "$hits"
  # The control: the VENDORED file does, by the same needle and the same stripping.
  assert_true "…and the vendored processor does, by the same needle" \
    str_has_sub "$PP_LOCAL_CODE" "$needle"
done

m22_finish
