# Standing Campaign Brief — Aztec AVM Runtime

Durable brief for every remaining milestone (M19–M36; M29 opened the M29–M36 extension). Read this **before** the
milestone's own section in
`codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`.

It exists so that an interrupted agent — or an interrupted coordinator — can
resume without re-deriving anything. If you are picking this up cold: the
milestone file is the plan, this is the accumulated discipline, and
`scratchpad/campaign/m<N>-impl-log.md` is where the last agent got to.

---

## The loop

**implement → review → fix (if needed) → commit → next.** One agent touches the
working copy at a time. Implementation agents **never commit**; the review agent
commits and pushes after verifying. Push to `metacraft-labs` only — never
`AztecProtocol`, never open a PR.

**Leave the tree quiescent and your log current at every step, not just at the end.** The
campaign is to be driven to completion without interruption, and an interrupted agent that
recorded which priorities are settled is worth far more than one that has to start over. Write
`scratchpad/campaign/m<N>-*-log.md` as you go.

**Stand the implementation agent down before its review starts.** Two agents
running verify sweeps concurrently has corrupted measurements twice (M9's
timing, and a self-inflicted `verify-m9` collision M15 misattributed to foreign
load).

---

## Rules that were learned the hard way

Each of these is a defect that shipped, not a precaution.

### An assertion must be capable of failing
**Thirty-seven instances.** (M29's review added the 31st, 32nd and 33rd — a needle with a space in
it asked of a minified bundle, an assertion over the number of arguments the check itself passed,
and a run-time key-set check over keys the function had just built from that very set; all three
are below, all three were in M29's own work, and all three were found by asking of each green
assertion what input would make it red. **M30 added the 34th and the 35th and found both in its
OWN work, before the milestone closed, with the instrument that exists for it** — its decoy
control compared two artifacts after EDITING a `.nr` file that is not part of the program, and an
edit to a file the compiler never reads cannot change the artifact whatever the resolver does, so
the mutation that made the resolver swallow the WHOLE virtual filesystem left those assertions
GREEN; and its dependency-sensitivity fixture changed `x + x` to `x + x + x - x`, which is
different SOURCE and the same CIRCUIT, folded back by the SSA passes. The first is fixed by making
the decoy an ADDITION rather than an edit — a file that enters the source set enters the
`FileManager` and shifts every later `FileId`, which is what the program `hash` is based on, so
the hash discriminates and the bytecode does not. The second went red on its own first run.
**M30's REVIEW ADDED THE 36th, AND IT IS THE PAIR THAT PROVED THE 34th.** M30 published the decoy
calibration as a measured pair in four places — "the hash goes from 1206613220 to 4090147220" —
and nothing re-derived it; re-taken by the review against the same module the checks build, the
true pair is **1076565353 -> 848041253**, because the fixture had moved under the figure. That is
the "a figure nobody re-derives rots" family. But the *assertion* that could not fail is the one
beside it, in BOTH browser checks: `trees.sha256 == trees.servedSha256`, where the arms runner
COPIES the fixture into the served site and then hashes both ends itself, in one process — two
digests of one file, equal by construction, advertised as "the trees the page compiled are
byte-identical to the ones this check names". The check named nothing; it read two numbers out of
the report. It takes the left-hand digest itself now, and a report measured over a different
fixture is red: demonstrated at
`a372fb3c…` (disk) against `450b56b6…` (served), one failure, where the old form was green.
**And the remedy for the rotted pair is not a corrected number** — it is
`multifileDecoyAddedUnderSrc`, the same file one directory lower where the resolver's own rule
puts it IN the program, so the calibration "the hash CAN move, and even then the bytecode does
not" is three assertions measured on every run and neither number appears anywhere.)
(Five places quote the running total: this line, the two M18 checks
`lib_m18_orchestration.sh` and `verify_no_telemetry_client_in_import_graph.sh`, and the two M19
files `fault_injection.ts` and `e2e_differential_wasm_vs_native_cpp.sh`. M18's review added three,
M19 added one, M19's review added one, M21 added one, and M22 added one. If you add one, move all
five numbers together — M19 wrote "eighteen" into its two new files in the same session it moved
the other three to "nineteen", which is the drift this parenthetical exists to prevent, and **M21
declared its 21st instance in three documents and moved none of the five**, which is the same drift
caught by its review instead of by its author. M22 moved all five in one edit, which is what the
rule asks for, and M22's review moved all five again for the 23rd, and M23's review for the 24th.
M25's review found the 25th and moved this line only — because four of the five now name the family
and point here instead of quoting a number, which is what the remedy above asked for. **The fifth
had not been converted**: `e2e_differential_wasm_vs_native_cpp.sh:19` still said "twenty-four
assertions that could not", found by grepping the spelling rather than trusting the paragraph that
claims all five were done. It points here now, so this line is the only place the number lives.
**M26 found the 26th and the 27th, both in its OWN checks and both before they landed**, which is
what "get there first" means: `verify_oq7_shared_writer_verdict_recorded` compared a value with
ITSELF — `assert_eq "…" "$(m26_row "$SHARED" STEPS)" "$(m26_row "$SHARED" STEPS)"`, the most
degenerate shape on this list, in the check whose author had read this paragraph the same day — and
the publication control beside it asked `m24_published_refcount` of a directory that is not a git
repository, so the predicate short-circuited to 0 for the same reason it answers 0 for the subject
and the control agreed with the thing it was controlling. The first is an identity now (the shared
container's step count equals the sum of the two split containers'); the second is
`refs/remotes/origin/master` IN THE SAME REPOSITORY, with the two commits asserted different.)

**AND THE FIVE ARE NOT THE ONLY PLACES — THAT WAS MEASURED, NOT ASSUMED.** M22 reported two
pre-existing strays outside the declared five. There are **five**, and one of them quotes a
different total from the others: `orchestration/src/form_a.ts:250`,
`verification/test_provenance_not_consulted_during_execution.sh:32`,
`verification/lib_m20_form_a.sh:182` and `verification/verify_pinned_nightly_single_source.sh:153`
all said "twenty times", and `verification/verify_txe_private_flow_prior_art_consulted.sh:13` said
"twenty-one". So the census of stale citations was itself an undercount, found by grepping only the
spelling the author remembered. **The fix is not to bump them — bumping makes ten places to keep in
step instead of five.** All five now name the family and point HERE for the number, which is what
`lib_m22_block.sh` did for itself when its author caught the same thing mid-milestone. If you write
a comment that wants this total, write the family's name and not the number.)
The forms seen so far:

- `assert_eq "" ""` — both sides read missing keys. *Renaming both keys left all
  219 assertions green.*
- `grep -c '…' == 0` on a needle that could never match — passes by construction.
- A **printed literal**: the thing under test emitted `hasRevertCodeProperty` as
  a constant `0`, so the assertion beside it could not move. The gap was
  reachable — a trap would have reported as a transaction that succeeded.
- An assertion requiring its own measurement to be **wrong** to pass:
  `assert_ge "at least one has it FASTER, which a fifth tree cannot cause" 1`.
- **`git status --porcelain -- <path>` on a path that is not tracked yet.** Two checks proved a
  probe had restored a file that way. While `orchestration/` was untracked the command printed
  nothing whatever the probe had done, so both reported success either way. Compare against a copy
  the check itself takes, and give the comparison a control.
- **An absence asked of a tree that excludes the subject by construction.** "No published
  `@aztec` package ships a `ForkCheckpoint`", measured against a `node_modules` from which
  `@aztec/world-state` is deliberately absent. The published package does ship one. Ask the
  question of a tree that could answer it the other way.
- **The same defect again, on a containment requirement, in a check whose header cited the one
  above.** "The shipped import graph does not reach `@aztec/native`", asked of
  `orchestration/node_modules`, where `@aztec/native` is not installed *because the orchestration
  does not depend on it* — which is the thing under test. An import of it is `MODULE_NOT_FOUND`,
  lands in the walker's `unresolvable` list, and never enters `packages`. With a real
  `import * as x from "@aztec/native"` in a reached module the check printed **34 assertions, 0
  failures, PASS**. Non-emptiness assertions do not close this: the tree is not empty, it merely
  cannot contain the subject. Read the walker's `unresolvable` list too, and put the negative
  control on a tree where the package IS resolvable. **And do not let a fixed-string grep be the
  only thing behind a graph claim** — the one here was single-quote-only, so the same import
  spelled `"@aztec/native"` passed everything.
- **A pipe that put the failure counter in a subshell.** `assert_false "…" printf '%s\n' "$x" | grep -q NEEDLE`
  binds the pipe to `assert_false`, not to `printf`: the helper ran `printf`, which succeeds, its own
  output went to `grep`, and its increment of `_FAILURES` happened in a subshell and was lost. The
  check printed `FAIL` and reported `0 failure(s)` **in the same run**, and the full-suite output was
  what showed it — reading the line had not. Compute the predicate into a variable first.
  **M21 found two LIVE ones** (`verify_wasi_shim_reuse_decision_recorded.sh:159-160`), and they are
  worse than the account above: with `assert_true` the `ok` line itself goes INTO `grep` and is
  swallowed, so the assertions printed **nothing at all** and were invisible between two neighbouring
  `ok` lines — the check reported 48 where it should report 50. `finish` refusing a run with **no**
  assertions is what catches the degenerate case; nothing catches the partial one but a census.
  There is now a repo-wide check, `verify_no_pipeline_predicates`, and five builtin string
  predicates in `lib.sh` (`str_has_line`, `str_has_sub`, `str_has_word`, `str_has_re`,
  `str_has_line_re`). **Use them.** The census of surviving `| grep -q` lines is pinned at five BY
  NAME, so a new one fails — M21's review wrote two while fixing something else and was caught by
  that pin. And `str_has_re` is not `str_has_line_re`: bash's `=~` has no `REG_NEWLINE`, so `^…$`
  anchors to the whole string and a translated `grep -qE '^foo$'` silently stops matching.
- **A comparison against *fragments* of the expected change rather than its lines.** The check
  that pins the one forced edit in a vendored copy matched each changed line against a regex of
  substrings with `re.search`, so `this.depth = depth + 1` was excused by `this.depth = depth`.
  Line counts were unchanged, so all three assertions passed on a corrupted copy — defeating the
  exact property the deliverable claimed. Compare exact lines; keep the mutation as the control.
- **A VALUE COMPARED WITH ITSELF.** `assert_eq "the funded amount is what the driver funded" "$FUNDING" "$(printf '%s' "$FUNDING")"`
  — one variable on both sides. It is the first form on this list in its most degenerate shape, and
  M22 wrote it into `test_failed_tx_leaves_no_state`, the check whose own brief NAMES that test as
  the classic vacuous-pass case, two paragraphs after quoting the rule. It reads the value out of
  the driver's source now, and the derivation is asserted to have found something rather than
  `UNREADABLE`. **The lesson is not "check your assertions" — it is that a constant you have just
  typed into a check looks like a measurement to the person typing it.** If a check needs a number
  that also exists in the thing under test, take it FROM the thing under test.
- **A PATTERN PINNED IN ONE PLACE AND LEFT PERMISSIVE IN TWO.** M22's vendored-diff classifier
  accepts each added line by SHAPE, and desugaring a constructor parameter property emits three
  shapes — the parameter line, the field declaration and the assignment. The self-review pass found
  that a shape is not a pin, because a one-for-one SWAP keeps the exact 112/72 line counts, and
  pinned the lines matching the first shape exactly. **It left the other two, six lines below, in
  the same file, in the same pass.** Measured by M22's review: `this.dateProvider = dateProvider;`
  -> `this.dateProvider = log;` is a real corruption of upstream's constructor and the vendoring
  check reported **59 assertions, 0 failures** on it; `private dateProvider: DateProvider;` ->
  `private dateProvider: PublicProcessorMetrics;` is erased by the type stripper and passed
  **everything** — `check-drift` 22/0, the vendoring check 59/0, `just verify-m22` 247/4-of-4/exit 0
  — with an undeclared edit sitting in a vendored file. All three are pinned now, each with a
  non-emptiness assertion beside it. **When you fix an instance of a form, grep for the form in the
  file you are fixing before you leave it.**

- **BOTH SIDES READ, BOTH SIDES ZERO — vacuity by DATA rather than by key.** M23 declares the
  block's deviation from the wall clock (`wallClockDeviationSeconds`) and its own milestone says a
  deviation field that lied would be worse than none. The identity
  `timestamp - wallClockSeconds == wallClockDeviationSeconds` is asserted per block — on the
  `emptyBlocks` arm, where a clock advanced exactly one second per block makes every term zero:
  1/1/0, 2/2/0, 3/3/0. Measured by M23's review: replacing the field with the constant `0n` passed
  the **whole milestone** green — 491 assertions, zero failures, fourteen of fourteen checks, exit
  0. Nothing on the list above applies; every key is present, every value is read from the artefact,
  and the comparison is still `0 == 0` three times. The arm where the deviation is REAL existed in
  the same run and did not record the field. **When an identity is asserted over data, assert that
  the data is not degenerate** — the fix is one more assertion, that at least one row is non-zero.

- **A NAME GREPPED IN THE FILE THAT DECLARES THAT NAME — VACUOUS AND FALSE AT ONCE, HOLDING UP A
  TWELVE-ENTRY DECISION.** M25's `verify_transaction_builder_closure_measured` supported the one
  sentence its whole unblocking rests on with
  `assert_ge "this runtime already has a MerkleTreeWriteOperations implementation" 1 "$(grep -c 'ResidentMerkleWriteOperations' orchestration/src/resident_merkle_operations.ts)"`.
  The haystack is the file that **declares** that class, so the count cannot be less than 1. It is
  the second form on this list wearing `grep -c … >= 1` instead of `== 0`, and the direction is
  what hides it — a non-emptiness check *looks* like a control, which is why it survived a
  self-review that was hunting for exactly this. It was also standing in for a SEMANTIC property
  with a name grep, which is "a citation is the opposite of a dependency" one level up. **And the
  property was false**: three lines from where the grep matched, the same file says the class is
  *"deliberately NOT declared `implements MerkleTreeWriteOperations`"*. Found by M25's review; the
  conclusion survived, on a stronger fact that nobody had measured. The lesson is narrower than
  "check your assertions": **when a check greps for a name to establish a property, ask what the
  haystack is — if the haystack is where the name is defined, the grep is a tautology.** The
  replacement pattern to copy is the paired zero: `merkleTree.` is 0 in the builder with 7 mentions
  as its control, so a needle that silently stopped matching drives both to zero and the control
  fails.

- **A NUMBER READ FROM THE PRODUCER'S OWN REPORT INSTEAD OF FROM WHAT THE PRODUCER PRODUCED.** M29's
  `test_browser_steps_are_executed_not_mapped` exists to say that a `.ct` container's opcodes are the
  AVM's and not a fabrication. It read the opcode histogram out of the browser arm's DRAINED records
  and out of the recording's own `distinctOpcodes` field — and the recorder computed that field from
  the same drained steps. Both are upstream of the writer. Measured by M29's own mutation harness:
  put M27's `opcode: (pc % 200) + 1` back into the recorder, changing what is WRITTEN and leaving
  what was DRAINED alone, and the check reports **42 assertions, 1 failure** — the one failure being
  a `grep` of the source tree. Every behavioural assertion passed over a container full of
  fabricated opcodes, in the check whose entire subject is fabricated opcodes. It reads them back
  out of the CONTAINER through the pinned reader now. *The general form is one step past "read it
  from the artefact": ask WHICH artefact. A producer's report about itself is not its output.*
- **TWO MISSING KEYS AGREEING, TWICE IN ONE MILESTONE, IN CHECKS WHOSE AUTHOR HAD READ THIS LIST
  THAT DAY.** M29 pointed five assertions at `arms.publicOnly.executed` when the field is at
  `arms.publicOnly.transfer.executed`; `m27_arm` prints `MISSING` for a path that is not there, and
  two of the five went GREEN. The same slip in a second check made a CONTROL pass on a bash error:
  `assert_false test "$HALVED_STEPS" -eq "$STAT"` with `$STAT` = `MISSING` is `test 516 -eq MISSING`,
  which is a syntax error, which `assert_false` reads as the false it wanted. The remedy that
  generalises is not another `assert_true … != MISSING` per value: it is `m29_absent name=value …`,
  ONE assertion that names every absent field, run before the first comparison, with a `die` behind
  it — because a report with no data in it is a failure and not a smaller check.
- **AND THE CONTROL THAT DOES NOT CONTROL, MEASURED RATHER THAN INHERITED.** The same check's
  "the reader does not emit the full count over half a container" is FALSE of this format: a `.ct`
  is a directory of independent streams and `ct-print --full` over a halved copy still emits all
  516 Step records. M27 had already recorded that halving does not make the reader refuse; M29
  wrote a control on top of it anyway and it passed only because of the `MISSING` bug above. The
  halved copy is now a reported NOTE and the control is a 512-byte stub, which is refused and emits
  none.
- **A NEEDLE WITH A SPACE IN IT, ASKED OF A MINIFIED BUNDLE.** M29's deliverable says the deleted
  synthetic rule's absence is asserted "over the browser SOURCE TREE and over the BUILT BUNDLE".
  The bundle half was `grep -rl '% 200' "$BROWSER_DIST"`, and `browser/esbuild-driver.mjs` sets
  `minify: true`, so the emitted bytes spell it `o%200+1`. Measured by M29's review, against the
  very esbuild the build uses: the minifier turns `(pc % 200) + 1` into `o%200+1`, and with the rule
  put back at the write site `grep -rl '% 200'` is **0** while `grep -rl '%200'` is **2**. The
  assertion was green over a bundle carrying the rule in two files. It also had no control, while
  the SOURCE grep beside it had one — the stripper's own effect is measured, so that half was
  sound. The remedy is not a better literal: the needle is **derived by minifying the rule through
  the build's own esbuild**, out of `browser/dist/.build-config.json`, and the scanner must FIND it
  in that fixture before it is believed about the bundle. *When a check greps an ARTEFACT for
  something it knows as SOURCE, the toolchain between them is a thing under test.*
- **AN ASSERTION OVER THE NUMBER OF ARGUMENTS THE CHECK ITSELF PASSED.**
  `e2e_browser_container_opcodes_match_native` advertises "the exclusion list is EMPTY" as its
  strongest sentence, and asserted it as `excluded == 0` — where `_m29_record_compare.py` prints
  `len(sys.argv[3:])` and the call site passes no excluded fields. It reported a property of its own
  invocation. The exclusion machinery was never run in either direction. It is exercised now: the
  size is asserted `1` when one field IS named, the field is named back, and excluding the field a
  planted corruption lives in is shown to HIDE that corruption — so the empty list is a measurement
  by an instrument seen to produce a non-empty one.
- **A RUN-TIME KEY-SET CHECK OVER KEYS THE FUNCTION HAD JUST BUILT FROM THAT VERY SET.**
  `patchFieldsFor` — the one edit M29's whole unblocking rests on — built its object by iterating
  `Object.keys(PATCH_REQUIRED_CONFIG_FIELDS)` and then compared `Object.keys(out)` against
  `Object.keys(PATCH_REQUIRED_CONFIG_FIELDS)`, so `produced === declared` for every input that
  exists and the `throw` was unreachable. The milestone advertises it as "asserts the key set
  unchanged at run time". *The property was never in doubt — it is guaranteed by construction, which
  is stronger than an assertion — and that is exactly why the assertion looked fine: a tautology
  written beside a true statement reads as its proof.* The check is over the CALLER's option keys
  now, which is the half nothing covered: TypeScript's excess-property rule reaches object literals
  only, so `patchFieldsFor(opts)` with a misspelled `collectExecutionStep` compiled, silently
  produced `false`, and the page failed four layers away with `ExecutedStepsUnavailable`.

- **A CONTROL OVER A SECOND COPY OF THE MECHANISM IT CONTROLS, WITH THE COMMENT ABOVE THE LINE
  STATING THE LINE'S NEGATION.** M32's third headline measurement is "the `.ct` container was
  TRANSFERRED, and `detached` is `ArrayBuffer.prototype.detached` — the platform's own answer, not an
  inference from a zero length". The worker shipped
  `detached: buffer === null ? false : buffer.byteLength === 0` — *the inference* — with that sentence
  as the comment directly above it, and in `WORKER-NODE.md` §4, and in the milestone section twice,
  and in the check's own §5 header. The milestone had ALREADY seen the hazard and answered it with a
  `zeroLengthControl`: a zero-length buffer that was never transferred, `{0, false}`, "the one
  combination an inference cannot produce". **But the control was a SECOND EXPRESSION over a SECOND
  buffer** — `empty.detached === true` — so it constrained its own code and not the container's, and
  the only zero-length buffer the container path produces IS the transferred one, so the inference
  and the platform agreed at every reading the check takes. Confirmed in the BUILT bundle
  (`detached:e===null?!1:e.byteLength===0`), not only in the source. *A control has to run through the
  instrument, not beside it*: the fix is one `read(b)` used for the container and for the control
  alike, so one edit moves both. **The substantive claim survived on two legs the defect does not
  touch** — `byteLength` 196608 -> 0 IS the platform reporting detachment, and the second take is
  refused by a guard that does read `buffer.detached` — which is why this is on the list rather than
  in the section above it.

**AND THE PUREST INSTANCE OF ALL IS NOT ON THAT LIST, BECAUSE THERE WAS NO ASSERTION TO BE WRONG.**
Not counted in the running total above; it is the family the total keeps pointing at.
**M29 found that M27's demo transaction reverted at its first instruction, closed four causes of
it, and shipped nothing that would notice a fifth.** Measured by M29's review: remove `isStaticCall`
from the `#[view]` call — *seeding gap 4, the last one M29 itself found* — and the demo transaction
executes 471 instructions across two AVM contexts, ends on `REVERT_8`, reports `processed`, and
produces a 192,512-byte container the reference reader parses. Over that transaction,
`just verify-m29` is **105 of 105 green**, `smoke_browser_token_transfer` is 37/0 and the
product-claim check is 36/0. Every floor M29 added is satisfied by a transaction that runs and then
reverts: 471 clears the `>= 100`, two contexts clears the `>= 2`, no record carries the sentinel,
342 steps are positioned. **Every assertion was correct and none of them asked whether the subject
did what it was for.** `outcome` cannot answer it and is not wrong to be unable to — `processed` is
UPSTREAM's word for "the public processor turned it into a `TxEffect`", and `@aztec/stdlib`'s
`ProcessedTx` carries `revertCode` and `revertReason` beside it precisely because the two facts are
different, with `FailedTx` (the processor THROWING) a third thing again. Nothing was masking a
failure; the revert dimension simply never reached the demo path, because
`orchestration/src/chain.ts`'s `TxOutcomeRecord` does not carry one. It is read off upstream's
`ProcessedTx` in the sealed block now and asserted zero, with the parity arm's own `revertCode` of
**1** — a number `native_parity.ts` had been computing and no check had been reading — as the
control that the field is not a constant. *The general form: when a milestone's headline is "the
subject was not doing anything", the assertion that has to be written is the one that says it is
doing something now.*

**And `check-drift` cannot be the backstop for this, by construction.** It compares every vendored
file against `git show <anchor>:<path>` and asserts only the DIRECTION of the result: a file
`PROVENANCE.md` declares `none` must be byte-identical, a file it declares with an edit class must
differ. **It never pins what the difference IS.** So for every vendored file recorded as modified,
the content pin is whatever named check happens to own it and nothing else — verified by mutation,
both ways, on all five of M22's modified copies.

**Rule:** anything asserted must be read from the artefact, never printed as a
constant by the thing under test; any comparison whose sides could both be
absent needs a non-emptiness assertion beside it.

### Needles come from the artefact, matched on word boundaries
Twenty-one instances. `honk` ⊂ `chonk`. `world_state` ⊂ `world_state_reference`.
`"DEPENDENCIES vm2"` ⊂ `vm2_sim` — **it asserted the opposite of its intent**.
`[A-Z_]+` never matched `L1_TO_L2_MESSAGE_TREE`. `([A-Za-z_]+::)*` found seven
where the truth is eight, because `avm2` has a digit. LLVM spells it
`(defualt)`. `"barretenberg"` matched a path component of every include dir.
An anchored `\.test\.ts$` applied to `path:line:content` never matches.
A `^`-anchored needle without `MULTILINE`.
**A fixed-string search for a function's NAME, used to mean "this check calls it".** Prose
satisfies it. Measured by M21's review: delete every `require_complete_transcript` call from a
comparer and leave one mention of the name in a comment, and
`verify_transcript_truncation_detection_uniform` reports 36 assertions, 0 failures — the comparer
has stopped refusing, the census has not noticed, and the milestone is green. Deleting the name
outright IS caught, so the needle worked exactly until somebody wrote the word down. **A citation
is the opposite of a dependency**, and this campaign has now written that sentence into one check
while the check beside it counted a citation as a call. Strip whole-line comments and require the
name to begin a command.

**A CHARACTER CLASS THAT EXCLUDED THE NEWLINE, IN A CENSUS WHERE THE DERIVATION *IS* THE NUMBER.**
M25's import-closure walker matched `import … from '…'` with `[^;\n]*?` between the two keywords.
Every MULTI-LINE import clause — the shape prettier produces past 120 columns, and the shape
upstream writes constantly — became invisible. It returned **47 files / 8,083 lines** against the
true **65 / 10,421**: an 18-file, 2,338-line undercount, *in the direction that reads as good
news*, in the one measurement the whole milestone's unblocking decision rests on. Caught only
because two independent walks of the same closure disagreed, which is the only reason it was not
published. `verification/_import_closure.py` uses `[^;]` now, prints its residue and has the count
asserted at zero. **The lesson is the census one, one level up from the `mktemp -d` count: when the
derivation IS the number, run the derivation twice, differently, before believing it.**

**A RESIDUE SCANNER ASKED OF THE WHOLE FILE, IN THE CHECK WHOSE COMMENT DECLARES THE OPPOSITE.**
M32's `_m32_doc_ops.py` exists so that "a document that states '19 operations' and lists eighteen of
them passes a size comparison and fails this one, naming the missing one" — and it asked whether
`` `name` `` occurred **anywhere in `WORKER-NODE.md`**. Measured by M32's review: delete
`containerBufferState` from §2's LIST and the residue is empty, because §4 mentions the operation in
prose. So the document could lose an entry, keep the number, and pass both comparisons. It is
"anchor the needle to the row, not to the file" — M24's OQ-6 finding — in the instrument written to
enforce the row-level version of it. Scoped to one bullet now, with the region's own SIZE asserted so
"both residues are empty" cannot be "the region is empty", and with the OTHER direction added: a name
the list carries that the bundle does not declare. **And the first draft of the fix was too wide** —
it ended the region at the next blank line, and §2's bullets are not blank-separated, so it swallowed
three neighbouring bullets and reported their subjects as undeclared names. A region that is too wide
is the same defect one notch smaller; calibrate a region by running it, not by reading it.

**A CHARACTER CLASS WITHOUT A DOT.** M22's vendored-diff classifier matched a relative `.ts`
import specifier with `[A-Za-z0-9_/]+`, so `'../../telemetry.ts'` — a path with dots in it — fell
through as "unclassified". It failed loudly here because the classifier reports what it cannot
place, which is the safe shape for a scanner: **write scanners that PRINT the residue rather than
counting the matches**, and a class that is too narrow becomes a red line instead of a silent
undercount.

**THE DIGIT ONE CAME BACK, IN THE SECTION WHOSE SUBJECT WAS THE TWO METHODS WITH A DIGIT IN THEM.**
M23's facade-mapping check counted `AztecNodeDebug`'s method declarations with
`^  [a-zA-Z]+\(.*\): Promise<` and found **three of five**, because `warpL2TimeAtLeastTo` and
`warpL2TimeAtLeastBy` have a `2` in them — and those two methods are the entire point of that
section, which exists to record that the interface has five methods at the anchor and three at the
installed pin. `avm2` again, two years of `[A-Za-z_]+` later. Caught on the check's own first run,
because the assertion was `assert_eq 5`.

**A NEEDLE THAT SPANNED A LINE BREAK.** Three of M23's document assertions matched a SENTENCE
against a markdown file that wraps at 100 columns, so the needle contained a newline the file spells
as `\n  ` and matched nothing. All three went red for a reason with nothing to do with their
subject, which is the cheap direction — but a needle that stops matching the day somebody reflows a
paragraph is a needle that will eventually be *deleted* rather than fixed. **Match a fragment of one
line, never a sentence.**

**A TABLE'S HEADER ROW READ AS DATA.** The same check extracted a mapping table with
`grep '^| \`'`, which matches the header row too, so the literal column titles `TXE` and
`AztecNodeDebug` entered the set of "claimed counterparts" and were then looked up as method names.
The header is excluded by name now. A scanner over a human-written table has to know which row is
not a row.

**`Date.now(` IS NOT THE ONLY WAY TO READ A CLOCK, AND THE SECTION THAT SAID SO WAS THE SECTION
ABOUT READING CLOCKS.** M23 recorded, in `CHAIN-LOOP.md`, in the milestone's own deliverables table
and as the HEADING of a block of assertions, that *"TXE never reads a wall clock for block time"* —
resting it on three counts: `Date.now(` four times and all diagnostic, `setInterval(` once behind
an environment variable, `setTimeout(` zero. All three counts are correct. All three are blind to
`new Date().getTime()`, which is the spelling `txe_session.ts:349` uses to **seed every session's
block timestamp from the host clock**. Found by M23's review. The claim was not merely unproven, it
was false, and the evidence offered for it was three true measurements of the wrong needle. The
count of that spelling is asserted now — it is one, and it is that line — so the fact is a
measurement rather than an absence nobody looked for. **An absence claim is only as wide as the
spellings you enumerated; write down which spellings those were.**

**And the scanner around the needle counts too.** The import-graph walker stripped comments by
scanning for `//` unconditionally, so a `//` inside a *string literal* began a comment and ate the
rest of the line: `const u = 'http://host'; import 'koa';` reported no imports. Every assertion
written against that walker is an *absence*, so the failure pointed the dangerous way — a package
that is reached looks like a package that is not. Reproduced directly against the old scanner
before fixing it.

### Never depend on state you did not produce
Four checks once passed against an **empty build directory**, because every
predicate returned 0 over a missing path. A check was 6/6 in one work directory
only. `m6_prepare_tree` reused any directory with a `.git` and asserted only the
*commit count* — seven trees were silently stale, one carrying a pre-review
patch. A mutated **artefact** outlived its restored source.

Assert artefacts present *first*. `require_work_dir` takes an `flock` whose fd is
**inherited by children** — respect the liveness check.

**AND THE ENGINE IS THE AGENT'S TO PIN TOO, NOT ONLY THE CHECK'S.** M25 ran a regression with
`direnv exec <workspace-root>` instead of `direnv exec <aztec-avm-runtime>` — a *different* dev
shell — and two things came out of it, both predicted by the rule below. `verify_ct_writer_wasm_zero_imports`
read **57 with one failure**, `tsc is not on PATH`, against its reference 58; and the OQ-6
benchmark ran on the **system node, v25.9.0 / V8 14.1**, when `TRACE-ABI.md` §2 says in as many
words that the authoritative measurement is the one taken in the engine the checks run in.
Rendering the document from that `arms.tsv` would have put a system-node measurement into a
document that says it must not be one. **The repository's own `.envrc` is the shell; the workspace
root's is not it.**

**And the SHELL is state you did not produce.** M19's review ran the sweep through
`direnv exec .` — this repository's own dev shell, the one `.envrc` exists to provide and the one
CI's `dev-exec` uses — and M4 went red on `the flagged module emits the standardised try_table
expected [21], got [19]` with nothing in the tree changed. Clang's WebAssembly driver runs
`wasm-opt` after `wasm-ld` at `-O2` **if it finds one on PATH**; every earlier sweep had run from a
plain shell that had none, so the pinned 21 was the count of an *unoptimised* module. Reproduced
byte-for-byte both ways. **A check that compiles must pin its PATH, not only its toolchain and its
flags** — and the two sweeps to compare are the dev-shell one and the plain one, because CI only
ever runs the first.

### A PIN THAT IS NOT PUBLISHED IS NOT A PIN, IT IS A LOCAL FILE

**One instance, and it made a whole milestone unreproducible while every check reported green.**
(The rule held on its first test: the `trace_format` anchor move on 2026-08-26 pushed
`592fa42cbf` to `origin/wasm/ctfs-writer` and confirmed it reachable from a `refs/remotes` ref
**before** `pins.json` named it.)
M24 added the first two non-aztec-packages anchors to `pins.json` — `trace_format` and
`trace_format_nim` — and both pointed at commits that existed only on local branches in worktrees
on this machine. `pins.json` recorded that ("the branch is LOCAL-ONLY"), but recorded it as *the
reason a commit is pinned rather than a branch followed*, which is not the consequence. The
consequence is that `build_ct_writer_wasm.sh` and `build_ct_print.sh` do `git archive <rev>` out of
an object store nobody else has: **they resolve here and fail everywhere else, including CI**, and
the milestone is 292/0 either way. `check-drift` cannot see it — it resolves only the anchors the
`PROVENANCE` mapping names — and neither can `verify_pinned_nightly_single_source`, which asserts
the anchor *count*.

Reproduced deliberately by M24's review with a dangling commit (`git commit-tree`, no ref
pointing at it): `git archive` of it produced 1,873,920 bytes locally and zero remote refs
contained it. **Publication is a checked property now** — `m24_published_refcount` in
`lib_m24_ct_writer.sh` asks whether any `refs/remotes/*` ref contains the commit, which is exactly
what a fresh clone or a CI checkout would have, and the counter carries its own negative control so
it is not an assertion that can only pass.

**Rule:** every commit `pins.json` names must be reachable from a published remote ref, and the
check that says so must be able to say no. Push the branch before you pin off it.

### "IT DOES NOT BUILD HERE" IS A CLAIM AND NEEDS THE SAME EVIDENCE AS ANY OTHER

**One instance, and it was the load-bearing sentence of a milestone's most dangerous artefact.**
M26 updated the Noir tracer's own fixture expectations for OQ-4's `Field` rendering and recorded
that they were *"not executed: `noir_tracer` on `blocktracer` links the Nim FFI writer, whose
static library this environment does not build"*. Measured by M26's review: it builds. The failure
is `nimble` not being on `PATH`, and `codetracer_trace_writer_nim/build.rs`'s **own doc comment**
names the escape (`CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1`); the repository's other
route is a sibling's dev shell, because **`noir` has no `.envrc` of its own**. Either way `nargo`
builds in 1m32s and the suite runs in under a second.

**In this workspace the first hypothesis for "it does not build" is a missing `direnv exec <repo>`
— and the repo whose shell you need may be a SIBLING**, because a path dependency's `build.rs`
runs in the *dependent's* environment while needing the *dependency's* toolchain. This is the same
family as "the repository's own `.envrc` is the shell; the workspace root's is not it", one level
out: there, the wrong shell was too high; here, the right shell was next door.

**And updated-but-unexecuted expectations are the artefact this rule exists to prevent.** Executed,
M26's own expectations turned out to be *correct* and they now PASS — but only after six unrelated
pins were sorted out, because they fire *earlier in each test*, so the new assertions were not
merely unrun, they were unreachable. **If you cannot run a test you changed, say what you tried,
and put it in the test file rather than in a milestone document in another repository.**

**AND THE FIRST BASELINE OF THAT SUITE WAS WRONG, IN THE DIRECTION THAT INVENTS AN INNOCENT PARTY.**
The review reverted the two changed files in the LIVE checkout, re-ran `cargo test`, got the same
six failures, and concluded all six predated the change. **`cargo test -p noir_tracer` does not
rebuild `nargo`**, and these tests SPAWN it — so that run measured the OLD expectations against the
NEW recorder. Re-taken in a separate `git worktree` at the parent commit, with `nargo` rebuilt,
**three of the six are the change's own doing**: rendering a `Field` as a `String` instead of an
`Int` removes a nameless companion type from the type TABLE, which nobody had declared. A stale
binary is state you did not produce, and a baseline taken in the tree you are changing is the
easiest place in this campaign to produce one. **Take baselines in a worktree, and rebuild every
artefact the test spawns.**

### A CONTENT STAMP THAT HASHES SOURCE WHOLESALE MAKES A COMMENT EXPENSIVE

**One instance, and it reddened a milestone nobody had touched.** `_m24_oq6_stamp` hashes the
module plus `ct-host/src/{writer,abi,config}.ts` and `tools/run_oq6_arms.mjs` **by file content**,
so M26's review correcting one sentence of a docstring in `abi.ts` — a change that cannot move a
measurement — invalidated the stamp, re-ran the twelve-session OQ-6 benchmark inside the sweep, and
left `TRACE-ABI.md` §2 quoting run 9 against an `arms.tsv` holding run 10: **M24 exit 1, fifteen
failing assertions, and the assertion COUNT unchanged at 350**. The check behaved perfectly — it
re-derives §2 from the data and compares — so this is a fact about the stamp, not about the check.

**There is no way back except forward.** Reverting the comment does not restore green: the stamp on
disk now names the post-edit inputs, so a revert is another mismatch and another benchmark, and the
document is stale either way. The remedy is to re-render the document from the new data
(`scratchpad/campaign/m24-render-trace-abi.py`, fed by `verification/_oq6_compare.py`) and add the
run to §8's retained table. Run 10 came out **+1.21 %, [+0.58, +1.85] %, within-noise** — a third
replicate of runs 8 and 9 on the same module, which is evidence §8 did not have.

**Rule:** before editing a comment in `ct-host/src` or `tools/run_oq6_arms.mjs`, know that you are
buying a benchmark and a document re-render. Loosening the stamp is not obviously right — a stamp
that tries to tell a comment from code is harder to get right than a re-render is to run — so the
cost is documented rather than removed.

### A SUB-WORKSPACE INSIDE A PINNED BUILD RESOLVES ITS OWN DEPENDENCIES, AND NOTHING SAYS SO

**One instance, and the comment beside it asserted the opposite.** M31 builds the transpiler two
ways from two pinned revisions and compares the outputs byte for byte. The NATIVE binary builds
against upstream's pinned `avm-transpiler/Cargo.lock`. The WASM module builds in
`avm-transpiler-wasm/`, a shim crate with a `path` dependency on it — **and a `path` dependency
does not make you a member of the other crate's workspace.** The shim is its own workspace root, so
cargo resolves it a `Cargo.lock` of its own, from crates.io, at build time; nothing passes
`--locked` and no lock for it is committed. Measured by M31's review out of the two builds' own
`.d` files: `getrandom` 0.4.1 vs **0.4.3**, `serde_json` 1.0.149 vs **1.0.151**, `flate2` 1.1.9 vs
**1.1.10**, `chrono` 0.4.43 vs **0.4.45**, `base64` 0.23.0 vs **0.23.1**.

Three consequences and they do not point the same way. The result is **stronger** than claimed —
two different JSON writers and two different DEFLATE implementations producing the same bytes. The
crate's own manifest comment said *"the two builds differ in target and in nothing else"*, which is
**false**, and it is the kind of sentence a reader trusts because it sits beside the code. And the
module is **not reproducible**: a cold build a week later resolves something else, which is why the
same milestone recorded 4,970,171 bytes in one section and 5,196,936 in another for "the" module.
The build's own content stamp did not catch it either — it hashed `.rs`, `Cargo.toml`,
`config.toml` and one unrelated lock, and **neither lock that decides the build was in it**.

**Rule:** if a build has more than one workspace root, it has more than one resolution. Say which
lock decides which artefact, put every one of them in the content stamp, and if two artefacts are
going to be compared, measure the difference between their resolutions rather than asserting there
is none. This is "a pin that is not published is not a pin" one level out: here there was no pin.

### A COUNT INSIDE A WINDOW IS NOT PRODUCTION DURING IT, AND THE SPAN YOU MEASURE IS PART OF THE CLAIM

**One instance, and the check's own header named the alternative it could not see.** M32's headline
2x2 counts blocks in `(busyOpen, busyClose]` with the runtime in a worker and on the main thread.
Sixteen blocks between two readings is equally true of a chain that stalled for 3.8 seconds and
delivered sixteen in a burst the moment the thread came back — a **backlog draining at the window's
right-hand edge** — and the check's header says in as many words that the warm window is what rules
that out, which it is not: the warm window says nothing about WHERE INSIDE the busy window the blocks
landed. The spacing does, and nothing measured it.

**And the first fix was the wrong shape, which is the part worth carrying.** M32's review asserted
that no consecutive pair of IN-WINDOW blocks is more than three ticker intervals apart. Calibrated by
doctoring the arm report — every block moved into the last 200 ms, count unchanged — the check
reported **82 assertions, 0 failures**: a tight cluster looks like *perfect* cadence, because the
stall in front of it lies between the window's OPENING and the first block, outside the span
measured. With the window's opening as the first point the same report gives **3,812 ms** and two
failures. *A control that is not run is a control that is the wrong shape* — this one was written,
read, and wrong, and only running it said so. **When you assert over a range, ask what falls between
its edge and your first data point.**

### A CONFIG-LEVEL ASSERTION IS NOT A BEHAVIOURAL ONE, AND A METAFILE RECORDS IMPORTS

**One instance, and it was measured rather than argued.** M33 ships a browser entry point whose
whole browser-shape claim was read off the esbuild **metafile** — no `@aztec/native`, no
`@aztec/world-state`, no `@aztec/pxe`, no Node builtin IMPORT — over a control build where the
forbidden packages are planted and resolvable, which is the right remedy for the defect this file
records twice. The handshake itself was measured in Node against the BUILT bundle, which is also
right: a `MessagePort` and WebCrypto are the same thing in both engines.

**What nothing covered is that a page can EVALUATE the file.** A free identifier is not an import,
and a metafile only records imports. Measured by M33's review with
`const _nodeOnlyProbe = setImmediate;` at the top of a module the entry reaches — a Node global read
at module-evaluation time, and neither `Buffer` nor `process`, so `browser/src/globals.js`'s
injection does not supply it and `verify_browser_bundle_builds`'s free-identifier scan does not name
it. The rebuilt bundle imported cleanly in Node and died in Chromium with
`ReferenceError: setImmediate is not defined`, while `just verify-m33` reported **224 assertions,
4/4, exit 0**, `verify_browser_bundle_no_node_builtins` **64 / 0**,
`verify_browser_bundle_no_native_deps` **44 / 0** and `smoke_browser_headless_full_flow` **50 / 0** —
that last one DOES drive Chromium, over a different entry point. **Nothing in the repository
referenced the wallet entry from a page**, which is why nobody would have noticed.

**Rule:** if a milestone ships something a browser is meant to load, something must load it in one.
The smallest closing claim is enough — it evaluates, and it exports what it declares — and it needs
a control that does NOT evaluate, run through the same probe, the same server and the same browser.
`verify_provider_half_dd9_clean` §10 is the shape to copy; it reuses M27's harness unchanged.

**AND WHEN THE THING SHIPPED IS BEHAVIOUR RATHER THAN A MODULE, LOADING IT IS NOT ENOUGH EITHER.**
M33 shipped a protocol and its review's remedy — a probe page that `import()`s the bundle — is the
right size for a protocol. M34 ships a WALLET, so every one of its seven arms runs in Chromium: the
handshake, the ECDH, the AES-256-GCM session, the deterministic key derivation through `avm.wasm`'s
own grumpkin, M26's vendored transaction builder, the AVM and the `.ct` writer all execute there,
and the container the page downloads is read back through the pinned reader. The ladder is
*asserted browser-shaped* → *observed to evaluate* → *observed to do the thing*, and a milestone
owes the rung its deliverable is on. **Three defects that only the third rung finds, all from M34's
first browser run:** a `ZodError` with two union issues at an EMPTY path and no method name, from
one of nine calls (a failure that cannot name its subject); CDP's `Object couldn't be returned by
value`, its entire diagnosis, once a return carried a class instance; and a refusals arm measuring
UPSTREAM'S CODEC rather than the wallet — called across the wire with the wrong arity, a refused
method never reaches the wallet at all, because `parseWithOptionals` rejects the ARGUMENTS first
with a `too_small` error naming no method. All six "refusals" in that run were somebody else's.

### THE INSTALLED PIN IS THE AUTHORITY, AND IT DISAGREES WITH THE ANCHOR

**Second instance; the first was M23's `AztecNodeDebug` — five methods at the anchor, three at the
pin.** M34 read `WalletSchema` at the `cpp` anchor and built against it. Two of upstream's own zod
schemas differ at the PUBLISHED pin this repository depends on, and both differences are silent
until something runs:

- `WalletSchema.registerContract`'s output is `z.void()` at the anchor and an **intersection** of
  the instance preimage with `{address}` at the pin. Returning `undefined` fails.
- `FunctionCall` carries `returnType?: AbiType` at the anchor, with a transform accepting either
  spelling, and `returnTypes: z.array(AbiTypeSchema)` — **required** — at the pin.

Measured with `getSchemaReturnType(WalletSchema[k]).parseAsync(undefined)` over all sixteen methods:
`registerContractClass` is the ONLY one that accepts `undefined` at the pin. So upstream's own
worked example — `end-to-end/src/test-wallet/worker_wallet.test.ts`, whose whole subject is that
void-returning methods serialise as `undefined` — is testing a property that holds for one of the
two methods it names. **Rule:** read the anchor to understand the design; read the INSTALLED PIN to
know what will parse. They are two different questions and this campaign has now paid for both.

### A SCANNER THAT CANNOT TELL A CALL FROM A SENTENCE, IN THE INSTRUMENT RATHER THAN IN A CHECK

**One instance, caught by its own first run.** `test_wallet_keys_deterministic` asserts that no
ambient-randomness spelling is reachable from the dev wallet's key path — seven spellings, written
down, which is the "an absence is only as wide as the spellings you enumerated" rule. It reddened
immediately, on `dev_keys.ts`'s own HEADER: the paragraph that says the file uses none of those
names contains all three of `Fr.random()`, `crypto.getRandomValues` and `Math.random`.

That is *"a citation is the opposite of a dependency"* — this file's own rule, which it records for
a check that counted a mention of a function's name as a call to it — one level up, in the
instrument. The remedy is the same one: **strip comments before scanning, with a string-aware
stripper** (`_import_closure.py`'s, whose naive predecessor let a `//` inside a string literal eat
the rest of a line and made a reached package look unreached), and then assert BOTH that the
stripper left code behind and that it removed the prose. Three assertions where there was one, and
the file whose comment caused the failure is the fixture that proves the stripper works.

### Conjunctions need a negative case per conjunct
A four-tree conjunction whose only negative case exercised one tree: dropping any
of the other three passed all twelve cases.

### A MUTATION THAT CRASHES HAS NOT EXERCISED THE ASSERTION IT WAS WRITTEN FOR
**M24 declared three "hang" mutations; exactly one hangs.** Re-run by its review, all three do
produce `0 assertion(s), 1 failure(s)` — so the precondition family they were written to catch
really is fixed — but only **M6** (a spin inside wasm) exceeds its bound and gets the diagnostic
naming the command and the bound. **M5** makes the driver `await` a promise that never settles, and
node prints `Detected unsettled top-level await` and exits **13** in seconds. **M7** is worse than
mis-labelled: it was supposed to be the silent one — "the container is still correct; only the
crossing identity and the buffer bound can see it" — and instead it writes past the end of the
wasm-side buffer on the *first* arm, so the driver dies with `RangeError: offset is out of bounds`
in two seconds and **not one assertion of the check under test runs**. The mutation was recorded as
detected, and it was; what it did not do is exercise the thing it was written to exercise.

The review wrote the mutation M7 was meant to be — events held host-side and drained in one
crossing, container unchanged — and the check caught it properly, with five failures on the
crossing identity, the non-degeneracy and the heap ratio. **Rule:** when a mutation reddens, read
*which* assertions went red. "The check failed" and "the check saw what I broke" are different
statements, and only the second is coverage.

**AND THERE IS A THIRD STATE: A MUTATION THAT GOES GREEN BECAUSE IT WAS SILENTLY UNDONE, PRINTED
AS THE ARM'S RESULT.** M30's M11 arm hollows the shared browser arm report to exercise the
die-before-summary path. Run alone it produces the 1 / 2 it is written for; run as `M10 M11` —
which is how a full matrix runs — M30's review measured **67 / 0 and 44 / 0, rc 0, with nothing
saying the mutation had been undone**. The cause is a race the arm cannot win: every preceding arm
leaves the module's content stamp naming ITS mutated sources, `m30_require_modules` runs BEFORE
the staleness predicate, so the first check rebuilds the module, the fresh module is newer than
the report the arm just `touch`ed, and the harness helpfully re-measures over the hollow. **This
is worse than a mutation that reddens for the wrong reason, because a green arm reads as absent
coverage of a property that is in fact covered — or, if the author happened to run it in a
working order, as coverage that is in fact fragile.** The remedy generalises to any arm that
mutates a *cached measurement* rather than a source: bring the cache's producer current BEFORE
mutating it, and then assert after the run that the mutation is STILL THERE — if it is not, fail
naming the cause instead of printing a result.

**AND A FOURTH STATE, WHICH IS THE WORST YET BECAUSE THE ARM PRINTS THE RESULT IT PREDICTED: A
MUTATION THAT NEVER APPLIED.** M32's arm M2 — "`detached` computed from the length instead of read
from the platform" — is two substitutions. The FIRST one's needle was not in the file, because the
source already carried the inference the mutation claims to introduce (above). `sub` printed
`MUTATION MISS in browser/src/entry_worker.ts: '… buffer.detached === true,'` and **returned**; the
harness runs `set -uo pipefail` without `-e`, so the arm rebuilt, ran the check, and reported
`71 assertion(s), 1 failure(s)` — its predicted result, produced by the SECOND substitution, which
mutated the CONTROL alone. The matrix recorded it as "the most precise arm in the matrix: one
failure, the one assertion written for it", over a subject it had never touched. The miss is twelve
lines above the result in the same log.

This is one step past "a mutation that crashes has not exercised the assertion it was written for" —
here nothing crashed, and one step past M30's "a mutation silently undone and printed as the arm's
result" — here it was never applied. **Rule: a substitution that does not find its needle must abort
the run, restore, and say so.** And the arm's PREDICTION agreeing with the arm's RESULT is not
evidence the arm ran: it is the condition under which nobody re-reads the log.

**AND THE FIRST STATE IS STILL THE COMMONEST: M34's M5 CRASHED THE ARM RUN.** Written to break the
wallet's report of a registration, it skipped the node call entirely — so the contract class never
reached the module, the transaction could not execute, the ARM RUN exited 1, and the check died at
its precondition with **`0 assertion(s), 1 failure(s)`**. That is the die-before-summary path
working exactly as built, and **not one assertion of the section the arm was written for ever ran**.
Rewritten so the write still happens and only the RECORD lies, it is 33 / 1 on precisely that
assertion — which is also the more dangerous of the two defects, because a ledger that reports work
nobody did is worse than one that reports nothing.

**AND A BACKUP IS ONLY AS GOOD AS THE TREE IT WAS TAKEN FROM.** The residue above is how M32's own
stale-backup defect (below) ended: the harness's two remedies — wipe and re-take every run, and an
in-progress marker — are both right and neither covers a source left mutated by an EARLIER session
and then backed up. `git status --porcelain` over the mutated file set, before the backup, is the
guard, with the tracked-ness of each path asserted rather than inferred from empty output.

### Exit status *and* the specific failure mode
Counts alone miss a binary printing `132 ran / 132 PASSED` while exiting 7.
Exit status alone misses a discriminator failing for the wrong reason.
`-Wfatal-errors` makes `': error: '` count **zero** on a failed build, and
`grep ' error: '` matches `fatal error:` as a substring.
A CI job piping into `tee` under `bash -e {0}` **cannot fail** — use `shell: bash`.

### Timing measurements assert their own preconditions
Exit with a distinct code rather than returning a wrong number on a loaded box.
The session is the unit of replication; page placement is the dominant nuisance
and is re-drawn by a copy. A same-bytes control must not be able to swallow a
measured regression.

### Prose drifts from measurement
It has happened to an implementation agent, a review agent, **and a reviewer
reviewing that very defect**. A corrected `PR.md` shipped beside a stale commit
message three times. Bind claims to data, or expect them to rot.

**AND A NUMBER RE-DERIVED WITHOUT ITS ATTRIBUTION IS NOT RE-DERIVED.** M24's OQ-6 check re-computes
every figure `TRACE-ABI.md` §2 quotes from `arms.tsv` on every run — and matched each one as
`| <number> |`, *anywhere in the file*. Measured by M24's review: swap the median and the minimum
between the `batched` and `perEvent` rows, so the document states that the per-event arm is the
faster one when the data says the opposite, and the check reports **91 assertions, 0 failures**.
Every figure was present, every figure was re-derived, and the table said the reverse of the
measurement. Anchor the needle to the row, not to the file.

**AND A FIGURE NOBODY RE-DERIVES ROTS EVEN WHEN THE MILESTONE KNOWS IT IS WRONG.** The same review
found `245,724 bytes` in two places in M24's own section — the *mutated* artefact's size, which
that same section's defect list explains — sitting beside the corrected 246,527 in a third place,
with the paragraph declaring the difference's cause "not established" two screens below the
paragraph establishing it. Setting `TRACE-ABI.md` §7 back to 245,724 passed the whole milestone.
If a document states a measurement, something must take that measurement again and compare.

**AND A NUMBER A MILESTONE PUBLISHES ABOUT ITS OWN OPEN HOLE IS THE LEAST LIKELY TO BE RE-DERIVED
AND THE MOST LIKELY TO ROT.** M29's new `SOURCE-MAPPING.md` §6 gave §2.4's residual hole 2 its first
figures — 516 executed steps, 389 positioned, 127 not, 24.6% — and nothing re-derived any of them,
in a document TWO checks already open. The hole closes the day upstream re-keys
`brillig_procedure_locs`, so the document would go on publishing a share of a hole that is not
there. The sentence also wrapped between `516 executed` and `instructions, of which 389`, which is
the line-break family waiting for the next reflow. §6 is a TABLE now, one figure per row, each row
naming its subject, and `test_browser_steps_are_executed_not_mapped` matches **each row by its own
subject** rather than each figure anywhere in the file — with the percentage COMPUTED from the other
two, so three consistent numbers and a share belonging to a different transaction fails on the
share alone. Swapping the positioned and unpositioned figures gives two failures, one per row.

**And a GENERATED document can drift too, if it derives a number from a sentence.**
`CARRY-LEDGER.md`'s *Upstream changes* column was rendered by
`re.search(r"at base lines ([0-9]+\.\.[0-9]+)", entry["reason"])` over the acknowledgement's prose.
With one acknowledgement, worded to suit it, nobody noticed; the moment M21's review added a second
and a third, two of the three rows rendered `lines see below` while the check had computed the exact
ranges seconds earlier. The region is a declared field now and the check asserts the declared value
equals the measured one. **Rendering from data is not the same as rendering from a file** — ask
what, inside the file, the number actually comes from.

**A MILESTONE THAT MOVES ANOTHER MILESTONE'S COUNT MUST UPDATE THAT MILESTONE'S SECTION.**
M21 took `verify_carry_set_complete` 37 → 43 and `verify_block_level_gap_audit_complete` 130 → 131,
re-ran both milestones, wrote the new totals into its own section — and left M11's and M14's
Verification headers saying 246 and 459, and left four facts about upstream's tip stated twice each
in M11's prose. Grep the status file for the check's name, not only for your own milestone.

### A harness that counts is a thing under test too
The sweep counter summed every line matching `[0-9]+ assertion(s)`. One check prints a NOTE —
`  --   repin: 175 assertion(s), 0 problem(s)` — reporting a *sub-tool's* internal count, and the
counter added it to the milestone total. **M1 came out at 316 when it is 141**, and it was
reported as "consistent with the references" before anyone looked. Nothing in M1 had moved; all
six of its checks were identical to the reference. 141 + 175 = 316 exactly.

**AND THERE IS A THIRD STATE, WORSE THAN EITHER: A CHECK THAT HANGS.** M21's review established
that a check which DIES prints no summary and reads as a smaller milestone rather than a red one,
and M22 built the abnormal-exit trap for it. M23's review found the state the trap cannot reach.
Mutating the chain so that every block is numbered 1 makes M23's hundred-block arm wait on a `block`
subscription for `b.number >= 100` forever; `m23_require_arms` ran `node run_chain_arms.mjs` with
**no timeout**, the run sat at zero bytes of output, and each of the nine arm-reading checks would
have done the same in turn — reporting nothing at all and blocking the sweep behind it. A trap
fires on exit; a process that never exits has no exit. **Every subprocess a check waits on needs a
bound, and exceeding it must be a named failure rather than a hang.**

**Rule:** a summary line is at column 0 and ends `assertion(s), N failure(s)`; a note is indented.
Count only summary lines, and when a total moves, get the **per-check split** before believing any
story about why — the split is what distinguishes "a check grew" from "the counter is wrong",
and those are indistinguishable from the total alone.

**And the summariser is a thing under test too.** M21's read `^([A-Za-z_0-9]+):` as the check name
and therefore DROPPED `just check-repo-hygiene: 28 assertion(s), 0 failure(s)` — the one check whose
printed name contains a space — so m0 came out 128 against a reference of 156. The M1 316-versus-141
shape again, in the opposite direction, in the tool written to guard against it. The needle is
`^([A-Za-z_0-9][A-Za-z_0-9 .-]*): (\d+) assertion\(s\), (\d+) failure\(s\)$`, still anchored at
column 0.

### A SWEEP IS A MEASUREMENT OF THE TREE AT THE MOMENT IT RAN
**Three instances, and all three were read as regressions first.** M19 committed a pin-carrying
fixture after its own sweep and M1 went red. M20 committed the phase splitter after its own sweep
and M1 went **149 → 151** (`PROVENANCE.md` 70 rows → 71; `verify_provenance_complete` loops per
vendored file, so one row is +2 — confirmed by deleting that one row and re-measuring at 41). M20
committed a sixth candidate contribution to `codetracer-specs` after its own sweep and **M11 and
M14 both went red**, neither for anything in the repository the checks live in.

So: **run your sweep after your last commit, not before it**, and when a milestone you did not
touch moves, look for a commit that landed between the reference sweep and yours — in *either*
repository — before writing a story. Both attributions above were re-derived independently by the
review and both held; that is the standard, not the presumption.

Current per-milestone counts. Measured **M0-M29, on 2026-08-28**, by M29's review, one milestone at
a time with nothing else running, `setsid`-detached, **inside this repository's own dev shell**
(`direnv exec` — the engine and the PATH the checks and CI use), `TMPDIR` and the log under
`~/.cache`, no hole in the log, **28 of 30 exit 0** — the two reds being M11's ninth upstream move
and M9's TRUNCATION flake, both of them conditions this brief already names:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127
                                                       CAMPAIGN TOTAL 10,178
```

**M34 TOOK IT TO 11,514, AND MOVED EXACTLY ONE OTHER MILESTONE — M33'S, BY ONE, DECLARED BEFORE THE
SWEEP RAN.** Measured M0-M34 on 2026-08-29 by M34's implementation, after its last edit,
`setsid`-detached in this repository's own dev shell (node v24.19.0), one milestone at a time with
nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (70 markers for
35 milestones), **33 of 35 exit 0**, on the tree rebased onto `origin/dev` `410d76c`:

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 246  m34 210
                                                       CAMPAIGN TOTAL 11,514
```

**Every one of M0-M32 came out at its reference value TO THE ASSERTION**, and 11,303 + 1 + 210 =
11,514 exactly, `delta +0` against a reference table naming both moves in advance. **M33 245 -> 246**
is one non-emptiness assertion in `verify_provider_half_dd9_clean`, and the reason is worth the
sentence: its `cpp_` byte scan was asked of `wallet.js` ALONE, M34's eighth entry point made esbuild
hoist the wallet's modules into a shared chunk, `wallet.js` became a 0.69 KB re-export stub, and the
scan's PAIRED positive-control needle went red. **That is what a paired needle is for, and it is the
only reason anybody noticed.** The scan is over the whole eager SET now, which is also the question
DD-11 means. **M34's own 210** is 83 / 49 / 33 / 45.

**M9 DID NOT FLAKE** — 807, rc 0, 1,282 s, immediately after m8's run, which is D19's standing
condition and it did not fire. **The two non-zero exits are M11 at 262 with nine failing assertions**
(the recorded ninth-upstream-move signature, split 5 / 2 / 2, count unchanged, `carry/` left at HEAD)
**and M28 at 353 with one failing assertion that is L0's** (`verify_npm_pack_no_optional_native` pins
the tracked `package.json` list and `replay/package.json` is a fifth tree; recorded, not fixed).
**L0's and L1's six check names appear ZERO times in the whole sweep log** — they live in
`just verify-l0` and `just verify-l1`, which no `verify-m<N>` recipe invokes — so none of their
assertions is in the 11,514. **A sweep is a writer**: `carry/rebase.json` and `carry/exposure.json`
came out `79f597b2…` / `3836c2b6…` and were restored from HEAD, `sha256sum -c`, all four OK.

**AND M34'S SWEEP WAS ABORTED TWICE ON PURPOSE, WHICH IS THE RULE WORKING TWICE.** The first run went
red at m0 thirty-seven seconds in, on `verify_workspace_repos_registered`'s "the workspace checkout
shares history with the fresh clone", because `origin/dev` had moved seven L1 commits while the work
was written — killed, rebased, restarted. The second was killed twenty-five minutes in because a
comment in the subject had been improved after it started; the rebuild was confirmed to produce
identical eager figures for every entry point, so the restart was procedural rather than necessary,
and it was still the right call. *Run your sweep after your last edit — a comment is an edit.*

**M33'S REVIEW TOOK IT TO 11,303, AND MOVED EXACTLY ONE MILESTONE — M33'S OWN.** Re-measured
M0-M33 on 2026-08-29 by M33's review, **after the rebase onto `origin/dev` and after its last
commit**, `setsid`-detached in this repository's own dev shell (node v24.19.0), one milestone at a
time with nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (68
markers for 34 milestones), **31 of 34 exit 0**:

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 245
                                                       CAMPAIGN TOTAL 11,303
```

**Every one of M0-M32 came out at its reference value TO THE ASSERTION**, and 11,282 + 21 = 11,303
exactly, with the summariser reporting `delta +0` against a reference table naming the move in
advance. **M33's own 245** is 33 / 105 / 40 / 67, declared at 224, and all 21 are in
`verify_provider_half_dd9_clean` — itemised in M33's Verification section, in two places and nothing
else. Nothing else moved: `verify_provenance_complete` 68, `verify_pinned_nightly_single_source` 28,
`verify_no_pipeline_predicates` 69, `verify_named_checks_exist` 9, `check-drift` 22,
`check-repo-hygiene` 28, `verify_reuse_inventory_complete` 19, M27 345 and M28 353.

**THE PARALLEL L0 TRACK CONTRIBUTES ZERO TO THIS TOTAL, AND THAT IS A MEASUREMENT.** `origin/dev`
had moved four commits ahead with the L0 live-chain-replay track; M33's work was rebased onto it
(both textual conflicts — `Justfile`, `REUSE-INVENTORY.md` — are pure appends and both appends were
kept). L0's three checks live in `just verify-l0`, which no `verify-m<N>` recipe invokes: grepped,
their names appear **zero** times in the whole sweep log. Its own **188** is a separate figure and
is not part of the campaign total — and it was RE-TAKEN rather than quoted: after `npm ci` in
`replay/` (whose `node_modules` is gitignored, so the tree stays clean), `just verify-l0` is
**188, 3/3, exit 0, split 74 / 52 / 62**, its declared split to the assertion. Without that install
the recipe exits 1 on `ERR_MODULE_NOT_FOUND: '@aztec/stdlib'`, which is L0's own documented
precondition and not a defect. The inventory ids do not collide either —
`REUSE-INVENTORY.md` carries 93 headings, RI-01..RI-93, all distinct, none missing, none repeated,
with RI-86/RI-87 L0's, RI-88..RI-91 M33's and RI-92/RI-93 L1's.

L1 appended RI-88/RI-89 and M33 landed the same two ids first, so L1's were renumbered to
RI-92/RI-93 on the rebase — the same append-and-renumber the M33 review performed against L0.
Two campaigns writing one file is the ordinary case here, not the exception, and the id is
assigned when the work lands rather than when it is written.

**AND IT HAPPENED A THIRD TIME, TO M34, MID-MILESTONE, AND THE RULE IS NOW A PROCEDURE RATHER THAN
AN INCIDENT.** M34 fetched and rebased at Step 0 (`HEAD == origin/dev == 0902fa9`, nothing to do),
wrote its work, and started its sweep — and **m0 went red at the first milestone**, on
`verify_workspace_repos_registered`'s "the workspace checkout shares history with the fresh clone",
because `origin/dev` had moved seven commits while the work was being written. That check is the
instrument that catches this, and it caught it thirty-seven seconds in.

*The sweep was killed and restarted rather than finished and explained*, which is what M33 did for
the same reason one milestone earlier: a run whose first eighteen milestones measure a different
tree from its last sixteen is not a measurement. The fast-forward produced **exactly one textual
conflict, `Justfile`, a pure append at EOF**, and both appends were kept with L1's first. L1 had
taken RI-92 and RI-93, so M34's three entries — written as RI-92..RI-94 — became **RI-94..RI-96**,
renumbered in the inventory, `DEV-WALLET.md`, `dev_wallet.ts` and the milestone section, and verified
mechanically rather than read.

**AND THE CONFLICT RESOLUTION HAS A HAZARD WORTH THE SENTENCE, because `origin/dev`'s own head
commit is `fix: strip two diff3 base markers left by the L1 rebase`.** This checkout's merge
conflict style is **diff3**, so a conflicted region has FOUR markers and not three:
`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`. A resolver that assumes three keeps the `|||||||` line
and the base region as if they were content — which is what L1 shipped and had to fix, and what
M34's first resolution did too, caught immediately because `just --list` refuses to parse a `|||||||`
line. **Grep for all four markers after resolving, not for three.**

**THREE NON-ZERO EXITS AND ONLY ONE OF THEM IS THIS REPOSITORY'S OWN WORK.**
**M9 is 807 with FOUR failing assertions and the count is the reference split exactly**
(140/143/113/73/126/83/129) — because this time the V8/WASI stdout truncation hit the **fallback
EVENT stream** and not the step transcript, so both comparers ran and neither refused:
`truncated-after-10617-lines-last-key-events.burn.10412`. That is the second sighting on the events
stream (M29's review recorded 15,306) beside the seven on `steps`. Re-run alone: **807, 7/7, exit 0**,
the reference split exactly. Not a regression.
**M11 is 262 with NINE failing assertions**, the recorded ninth-upstream-move signature; the count is
the signature and it is unchanged. Not repaired, `carry/` left at HEAD.
**M28 is 353 with ONE failing assertion AND IT IS L0'S, NOT M33'S.**
`verify_npm_pack_no_optional_native` pins the tracked `package.json` list EXACTLY — "the three
shipped plus the four harness trees" — and `replay/package.json` is a fifth tree, added by L0's
`541bf5f`. The COUNT is unchanged at 353, which is what says it is a pinned list and not a structure.
L0's own log enumerates the repo-wide checks it re-took and this one is not among them. **It is
recorded here and deliberately NOT fixed**: a second track editing the first track's expectations is
the collision this campaign has already paid for three times.

**A sweep is a writer**: `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…`
before, came out `79f597b2…` / `3836c2b6…` — the same two post-sweep digests every run since M30 has
recorded — and were restored, confirmed by `sha256sum -c`, all four OK.

**M33 TOOK IT TO 11,282, AND MOVED EXACTLY ONE OTHER MILESTONE — M1's, BY FOUR, DECLARED BEFORE
THE SWEEP RAN.** Measured M0-M33 on 2026-08-29 by M33's implementation, after its last edit,
`setsid`-detached in this repository's own dev shell (node v24.19.0), one milestone at a time with
nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (68 markers for
34 milestones), **32 of 34 exit 0**:

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 224
                                                       CAMPAIGN TOTAL 11,282
```

**Every one of M0-M32 came out at its reference value TO THE ASSERTION**, and 11,054 + 224 + 4 =
11,282 exactly, with the summariser reporting `delta +0` against a reference table naming both moves
in advance. **M33's own 224** is 33 / 84 / 40 / 67. **M1 175 -> 179** is
`verify_provenance_complete` 64 -> 68: three new single-file `PROVENANCE.md` rows (F25..F27, the
vendored wallet protocol) at one `is tracked` assertion each, plus one for `RI-88`, an inventory id
no row had cited before — 3 + 1, exact in both parts, and M1's section is updated. Nothing else
moved: `verify_pinned_nightly_single_source` 28 (M33 declares no pin; `@aztec/aztec.js` goes in at
the `deletion_era` pin this file already names), `verify_no_pipeline_predicates` 69, `check-drift`
22, `verify_named_checks_exist` 9, `check-repo-hygiene` 28, `verify_reuse_inventory_complete` 19,
M27 345 and M28 353.

**M9 DID NOT FLAKE** (807, 7/7, 1,283 s, immediately after M8's build, which is D19's standing
hypothesis) and neither did M15 (537, 382 s). **M11 is 262 with SIX failing assertions**, the
recorded ninth-upstream-move signature — the count is the signature and it is unchanged; the failure
count is not, and it read nine in M32's sweep at the same condition. **M32 read 234 with TWO failing
assertions and that one was M33's**: `WORKER-NODE.md` §5's demo row carried the BUILD's `290.13`
where the check computes Python's `290.12` — the exact rounding tie this file records at 281.125,
whose rule is that the document carries the CHECK's value. Corrected and re-run: 234, 4/4, exit 0.
**A sweep is a writer**: `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` /
`ec959b84…` before, came out `79f597b2…` / `3836c2b6…`, and were restored from HEAD.

**AND M33's FIRST SWEEP WAS ABORTED ON PURPOSE, WHICH IS THE RULE WORKING RATHER THAN FAILING.** It
reached m18 and found `verify_orchestration_reuse_enumerated` red — that check pins the
orchestration's dependency list EXACTLY and M33 adds a fifth entry. The fix was made *while the
sweep was still running*, which makes the remaining milestones a measurement of a different tree
from the first eighteen, so the run was **killed and restarted** rather than finished and explained.
The aborted log is kept. Before restarting, the four milestones most likely to be moved by a new
`@aztec` dependency were run individually (m18 283, m21 325, m27 345, m28 353) — and m28 found three
more document figures that had moved. *The lesson is the one already written above: run your sweep
after your last edit. The instrument that caught the violation was the sweep itself.*

**M32'S REVIEW TOOK IT TO 11,054, AND MOVED EXACTLY ONE MILESTONE — M32'S OWN.** Re-measured
M0-M32 on 2026-08-29 by M32's review, **after its last commit** (`07d3055`, pushed),
`setsid`-detached in this repository's own dev shell, node v24.19.0, one milestone at a time with
nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (66 markers for
33 milestones), **31 of 33 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234
                                                       CAMPAIGN TOTAL 11,054
```

**Every one of M0-M31 came out at its reference value TO THE ASSERTION**, and 10,820 + 234 = 11,054
exactly. **M32's own 234** is 82 / 71 / 38 / 43 — declared at 229, and the five the review added are
all in `smoke_worker_chain_survives_main_thread_block`, itemised in M32's Verification section: three
because §2's operation-list residue was asked of the whole document rather than of the list, and two
because a COUNT inside the busy window cannot tell production from a backlog draining at its edge.
Nothing else moved: `verify_provenance_complete` 64, `verify_pinned_nightly_single_source` 28,
`verify_reuse_inventory_complete` 19, `just check-repo-hygiene` 28, M27 345 and M28 353 with the
browser bundle rebuilt four times and three of their figures corrected.

**M9 FLAKED, AT A SEVENTH DISTINCT TRUNCATION POINT, AND PASSED ALONE.** In the sweep: 524, rc 1,
twelve failing assertions — `807 - 524 = 283 = 140 + 143`, the two comparers that correctly refuse
and print no summary while doing it — at
`truncated-after-4051-lines-last-key-steps.burn.3777`. The sightings are now
**39,113 / 16,719 / 14,572 / 17,866 / 3,943 / 15,688 / 4,051**; same input, same module, same host,
so a content-dependent defect stays ruled out and the trigger stays unestablished. The twelve reds
are 11 in `test_observer_fires_on_exceptional_halt` and 1 in
`test_existing_event_emitter_path_still_available` — **the two checks `m9_completeness` is still not
wired into**, which is this file's own outstanding item. **M15 did NOT flake** (537, 382 s).
**A sweep is a writer**: `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` /
`ec959b84…` before, came out `79f597b2…` / `3836c2b6…` and were restored, confirmed by
`sha256sum -c`.

**AND THE M32 SWEEP THE PARAGRAPH BELOW REPORTS WAS RE-VERIFIED RATHER THAN INHERITED.** Both of
M32's sweep logs are still on disk and were re-parsed by the review with an independent summariser:
the first reads **11,047 / m32 227**, the second **11,049 / m32 229**, 66 markers each, `m11` the
only non-zero exit in both, m9 807 in both. The `-> **8,163.43**` figure below is the review's
**8,163.44** after its one-line fix to `containerBufferState`, and the milestone section had said
**8,163.38** — a third value nothing re-derived, found because `verify_browser_chunk_budget` DOES
re-derive it and went red.

**M32 TOOK IT TO 11,049, AND MOVED NO OTHER MILESTONE'S COUNT.** Measured M0-M32 on 2026-08-28 by
M32's implementation, after its last edit, `setsid`-detached in this repository's own dev shell, one
milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in
the log** (66 markers for 33 milestones), **32 of 33 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 229
                                                       CAMPAIGN TOTAL 11,049
```

**Every one of M0-M31 came out at its reference value TO THE ASSERTION**, and 10,820 + 229 = 11,049
exactly, with `delta +0` against a reference table naming M32's 229 in advance. **M11 is the one red
and it is still the ninth upstream move** — 262 with nine failing assertions and the count
unchanged, not repaired, `carry/` left at HEAD. **M9 did NOT flake** (807, 7/7, 1,290 s, immediately
after M8's build, which is D19's standing hypothesis) and neither did M15 (537, 382 s).
**A sweep is a writer**: `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…`
before, came out `79f597b2…` / `3836c2b6…` — the same two post-sweep digests M31's review recorded —
and were restored.

**M32 moved no COUNT and three document FIGURES**, all three of them figures a check re-derives from
the artefact on every run, which is how they were found. It adds two entry points to the SAME esbuild
pass, so esbuild's splitting re-partitioned the shared chunks: `BROWSER-PACKAGING.md` §1's four eager
rows (`browser.js` 255.79 -> **255.87 KB**, 7 -> **8** files; `testing.js` 279.77 -> **279.93**,
8 -> **10**; the demo 280.97 -> **281.12**, 8 -> **10**; `node/node.js` unmoved, because the Node
pass is a separate one) and its total 8,155.19 -> **8,163.43**; §6's request accounting, 13 -> **15**
requests and 7 -> **9** shared chunks; and `BROWSER-GATE.md` §3's browser metafile input count,
1,064 -> **1,068**. M27 re-measured at **345** and M28 at **353**, both to the assertion.

**AND AN EXACT ROUNDING TIE PUT THE BUILD AND THE CHECK ONE HUNDREDTH APART.** `browser/build.mjs`
prints `+(gzip/1024).toFixed(2)` and both `_m27_doc_figures.py` and M32's own check use Python's
`round(gzip/1024, 2)`. The demo entry landed on exactly **281.125 KB**: JavaScript rounds half away
from zero and printed **281.13**, Python is banker's and gives **281.12**, and a document carrying
the build's figure is red against the check that re-derives it. The document must carry the CHECK's
value. Recorded because the next figure that lands on a tie will do this again.

### A STALE BACKUP OUTLIVING ITS SOURCE — "a mutated artefact outlived its restored source", INVERTED

**One instance, in M32's own mutation harness, and it read as a defect in the subject.** The harness
took its backup with `[ -f "$BACKUP/$f" ] || cp "$f" "$BACKUP/$f"` — copy only if one is not already
there. That is right within one run and wrong across sessions. Measured: the backup was taken during
a two-arm trial run; two of the five backed-up files were IMPROVED afterwards; and the next run's
very first `restore_all` **reverted both improvements in the working tree**. The check then reported
`MISSING` for a field whose source had been silently undone — which reads as a defect in the thing
under test rather than in the instrument.

It is the same family as the artefact that outlives its restored source, with the arrow reversed, and
the remedy is the same rule — never depend on state you did not produce in this run. The backup
directory is wiped and re-taken at the start of every run, and an **in-progress marker** is left
while mutations are live so a run that died mid-mutation is refused (with an explicit
`--restore-previous`) rather than having a fresh backup taken *of a mutated tree*, which is the same
defect with the sign flipped.

### A WORKER'S FETCHES ARE NOT IN ITS PAGE'S NETWORK LOG

**One instance, caught on the first run of M32's arms, before anything was asserted on it.** The
boot arm's page log carries `/worker.js` and **not** `/assets/avm.wasm`, because the worker fetched
the module. So DD-11's question — "no request contained 'barretenberg'" — asked of the PAGE's log
would have been an absence measured against a log from which the subject is excluded by
construction, which this brief already lists twice as a defect that shipped, in a third disguise.
The runner attaches to the worker's own CDP target with `Target.setAutoAttach`, enables `Network`
there, and the absence is asserted over the WORKER's log with `avm.wasm` present in it as the
positive control. `Runtime.evaluate` on that same session is also what lets the worker be *asked*
whether it has a `document` rather than having it inferred from the file it was built into.

**And `Emulation.setCPUThrottlingRate` is refused on a worker target** — `Operation is only supported
for pages, not workers` — so the only real throttling this repository can apply to a dedicated worker
is `Page.setWebLifecycleState('frozen')`. That is a fact about Chromium, it is measured on every run
rather than believed, and whether the freeze *reached* the worker is measured by the worker: a gap in
`producedAtMs`, stamped inside the worker at block-seal time, against the median gap between blocks.

**M31'S REVIEW TOOK IT TO 10,820, AND MOVED EXACTLY ONE MILESTONE — M31'S OWN.** Re-measured
M0-M31 on 2026-08-28 by M31's review, after its last commit, `setsid`-detached in this
repository's own dev shell, one milestone at a time with nothing else running, `TMPDIR` and the log
under `~/.cache`, **no hole in the log** (64 markers for 32 milestones), **31 of 32 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421
                                                       CAMPAIGN TOTAL 10,820
```

**Every one of M0-M30 came out at its reference value TO THE ASSERTION**, and 10,396 + 421 + 3 =
10,820 exactly. **M31's own 421** is 130 / 59 / 135 / 97 across four checks — declared at 376, and
the 45 the review added are itemised in M31's Verification section, in three checks and nothing
else. **M11 is 262 with rc=1 and NINE failing assertions**, which is the recorded signature of the
ninth upstream move (`7471a61f1a`) and unchanged; `verify_carry_set_complete` reads **46**, which
is the whole of the +3 and is M31's doing, verified mechanically (three assertions per declared
`not_carried` entry, and `codetracer-specs` carries six `aztec-*` directories at HEAD and seven
with M31's).

**TWO MILESTONES FLAKED IN THE SWEEP AND BOTH PASSED ALONE, WHICH IS THE SETTLED PROCEDURE.**
**M9 read 524, rc 1, twelve failing assertions** — `807 - 524 = 283 = 140 + 143`, the two comparers
that correctly refuse and print no summary while doing it — with the V8/WASI stdout truncation at a
**SIXTH distinct point**: `truncated-after-15688-lines-last-key-steps.burn.15414`. The sightings are
now **39,113 / 16,719 / 14,572 / 17,866 / 3,943 / 15,688**; same input, same module, same host, so a
content-dependent defect stays ruled out and the trigger stays unestablished. Re-run alone:
**807, 7/7, exit 0 in 1,433 s**, the reference split 140/143/113/73/126/83/129 exactly.
**AND M15 WENT RED FOR THE FIRST TIME IN THIS CHAIN, AT ONE ASSERTION, AND IT IS THE OTHER FAMILY.**
`test_checkpoint_cost_characterised` reported 90/1: one half of an ABBA pair at population 100 read
**-36 µs** where the five-tree arm should cost ~5 µs, while the other half of the same pair read
+8 µs and the check's own note recorded a run-to-run spread of **41 µs** at that population — a
measurement whose noise exceeds its effect, on a box that had been building wasm modules and
running headless Chromium all session. **The COUNT was unchanged at 537**, which is what says it is
not structural. Re-run alone: **537, 6/6, exit 0 in 385 s**. A timing measurement on a loaded
machine is not a regression, and the two conditions are not to be conflated.

**A SWEEP IS A WRITER**: `carry/rebase.json` and `carry/exposure.json` were checksummed before
(`aaeb6877…`, `ec959b84…`), came out as `79f597b2…` / `3836c2b6…`, and were restored to the
pre-sweep digests.

**M31 WAS DECLARED AT 10,775, AND MOVED EXACTLY ONE OTHER NUMBER — M11's, BY THREE, DECLARED BEFORE THE
SWEEP RAN.** Re-measured M0-M31 on 2026-08-28 by M31's implementation, after its last edit,
`setsid`-detached in this repository's own dev shell, one milestone at a time with nothing else
running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (64 markers for 32
milestones), **31 of 32 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 376
                                                       CAMPAIGN TOTAL 10,775
```

**Every one of M0-M30 came out at its reference value TO THE ASSERTION except M11**, and 10,396 +
376 + 3 = 10,775 exactly, with the summariser reporting `delta +0` against a reference table that
names both moves in advance. **M31's own 376** is 123 / 59 / 114 / 80 across four checks.

**M11 262, AND THE TWO FACTS ABOUT IT ARE SEPARATE.** The count moved 259 -> 262 because M31 adds
a **seventh** `aztec-*` directory under `codetracer-specs/upstream-bugs/` and declares it
`not_carried`
in `carry/series.json`; `verify_carry_set_complete` makes exactly three assertions per declared
entry (it exists on disk, its reason is stated, it is not also in the carry set) and reads 46
where it read 43. That is M31's doing. The **rc=1 with nine failing assertions** is not: it is the
recorded signature of the ninth upstream move (`7471a61f1a`), unchanged, and `carry/` is left at
HEAD rather than half-repaired. **M9 DID NOT FLAKE** — 807, 7/7, exit 0 in 1,282 s, the third
consecutive sweep in which D19's standing hypothesis had its condition and did not fire. **A sweep
is a writer**: `carry/rebase.json` and `carry/exposure.json` were checksummed before
(`aaeb6877…`, `ec959b84…`), came out as `79f597b2…` / `3836c2b6…`, and were restored to the
pre-sweep digests.

**M31 vendors nothing** (`verify_provenance_complete` 64), **declares no new pin**
(`verify_pinned_nightly_single_source` 28 — its two revisions are READ, one from `pins.json` and
one from `git ls-tree <anchor> noir/noir-repo`), adds no `| grep -q` predicate
(`verify_no_pipeline_predicates` 69), and its four `REUSE-INVENTORY.md` entries add no assertion
(the entry-count check is `>= 20`, so it stays 19). `verify_named_checks_exist` stays 9 and
`just check-repo-hygiene` stays 28.

(Both this paragraph and M31's own log said "a **sixth**" directory. Measured by M31's review:
`codetracer-specs` HEAD carries **six** `aztec-*` directories and M31 adds the **seventh**, of
which two are now `not_carried`. The +3 mechanism and the 43 -> 46 / 259 -> 262 attribution are
right; only the ordinal was wrong, and it is corrected here because this file is where the campaign
states such things once.)

**M30's REVIEW TOOK IT TO 10,396, AND MOVED NOTHING ELSE.** Re-measured M0-M30 on 2026-08-28 by
M30's review, after its last commit, `setsid`-detached in this repository's own dev shell, one
milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in
the log** (62 markers for 31 milestones), **30 of 31 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218
                                                       CAMPAIGN TOTAL 10,396
```

**Every one of M0-M29 came out at its reference value TO THE ASSERTION**, and 10,381 + 15 = 10,396
exactly. The fifteen are M30's own, in two checks: `test_vfs_multifile_compiles` 67 -> **80** (+3
for the decoy calibration turned from a pair of numbers into an arm, +10 for `[package].entry`
measured IN THE BROWSER, which M5 had shown only the native suite could see) and
`test_vfs_compile_errors_carry_positions` 41 -> **43** (the `Diagnostic` envelope pinned beside its
label, because the header claimed "no line and no column anywhere" and only the label half was read
out of the file). **M9 did not flake** — 807, 7/7, exit 0 in 1,281 s, immediately after M8's build,
D19's standing hypothesis, twice in a row now. **M11 is the one red and it is still the ninth
upstream move** at `7471a61f1a`: 259 with nine failing assertions and the count unchanged, not
repaired, `carry/` left at HEAD. The two files `verify-m11` rewrites were checksummed before
(`aaeb6877…`, `ec959b84…`), came out as `79f597b2…` / `3836c2b6…`, and were restored to the
pre-sweep digests.

**M30 WAS DECLARED AT 10,381, AND MOVED NOTHING ELSE.** Re-measured M0-M30 on 2026-08-28 by M30's
implementation, `setsid`-detached in this repository's own dev shell, one milestone at a time with
nothing else running, `TMPDIR` and the log under `~/.cache`, **no hole in the log** (62 markers for
31 milestones), **30 of 31 exit 0**:

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 203
                                                       CAMPAIGN TOTAL 10,381
```

**Every one of M0-M29 came out at its reference value TO THE ASSERTION**, and 10,178 + 203 = 10,381
exactly. M30 added four checks and moved no other milestone's count: it vendors nothing
(`verify_provenance_complete` 64), declares no pin (`verify_pinned_nightly_single_source` 28), adds
no `| grep -q` predicate (`verify_no_pipeline_predicates` 69), and its two new `REUSE-INVENTORY.md`
entries add no assertion (`verify_reuse_inventory_complete` is `>= 20` on the entry count, so it
stays 19). `verify_named_checks_exist` stays 9 and `just check-repo-hygiene` stays 28.
**The one non-zero exit is M11's and it is the ninth upstream move** — 259 with **nine** failing
assertions and the count unchanged, which is the recorded signature; `carry/` is left at HEAD, and
the two files `verify-m11` rewrites were checksummed before the sweep (`aaeb6877…`, `ec959b84…`)
and restored to those exact digests after it. **M9 did NOT flake**: 807, 7/7, exit 0 in 1,281 s,
immediately after M8's build, which is D19's standing hypothesis and it did not fire.

**M29'S REVIEW MOVED EXACTLY ONE MILESTONE AND IT IS M29'S OWN.** 105 -> **127**, in two checks and
nothing else: `test_browser_steps_are_executed_not_mapped` 52 -> **69** (+4 for the revert
assertion, its non-emptiness partner and the parity arm's own non-zero code as the control; +6 for a
bundle scan whose needle can match, one of them the measurement that the OLD needle could not; and
+7 for §6's coverage table re-derived row by row) and `e2e_browser_container_opcodes_match_native`
30 -> **35** (+3 for the exclusion machinery exercised in both directions, +2 for the residue read).
4 + 6 + 7 = 17, 3 + 2 = 5, 17 + 5 = 22, and 10,156 + 22 = **10,178** exactly.
**Every one of M0-M28 came out at its reference value TO THE ASSERTION** in the review's own sweep,
including M27 at 345 with `token_transfer.ts` edited and the browser bundle rebuilt three times,
M21 at 325, M25 at 272, M24 at 350 (`ct-host/src` untouched, so `_m24_oq6_stamp` did not fire),
M1 at 175 and M20 at 237 with `shipped_module_config.ts` changed — `e2e_form_a_external_tx_roundtrip`
stays 62, so Part 8's encoding-delta comparison is unmoved by `patchFieldsFor`'s new guard.

**M9 FLAKED IN THE REVIEW'S SWEEP, AT A FIFTH DISTINCT TRUNCATION POINT.** 524, rc 1, 15 failing
assertions: `807 - 524 = 283 = 140 + 143`, the two comparers that correctly refuse and print no
summary while doing it. The truncation is `truncated-after-3943-lines-last-key-steps.burn.3669` —
the sightings are now **39,113 / 16,719 / 14,572 / 17,866 / 3,943**, five points, same input, same
module, same host, and the newest is a quarter the length of the shortest before it. A
content-dependent defect stays ruled out and the trigger stays unestablished; D19's ledger gains a
row. **AND A SECOND TRANSCRIPT TRUNCATED IN THE SAME RUN** — the fallback event stream, at
`truncated-after-15306-lines-last-key-events.burn.15101` — which is where 15 of the failing
assertions come from rather than the recorded 12: `test_existing_event_emitter_path_still_available`
reads that second transcript and has a completeness assertion on it, so it reports 4 rather than 1.
That is the check behaving correctly and it is the same fact about the run.
**AND `test_observer_disabled_is_free` CAME OUT 126 / 0 IN THAT SAME SWEEP** — the timing arm M29
recorded red at `+1.29% CI [+0.52%, +2.05%]` passed, on a box that had been running headless
browsers and wasm builds all session, which is the second measurement saying that red was the
machine and not the patch.

**M29 MOVED THREE NUMBERS AND EVERY UNIT OF ALL THREE IS ACCOUNTED FOR IN BOTH DIRECTIONS.** Its own
**105** (52 / 30 / 23), which its review took to 127; **M27 343 -> 345**, all of it
`e2e_browser_downloads_ct_container_and_ct_print_parses` 34 -> 36, which is *minus three plus five*
— the two assertions that could not fail (`every step at a resolved SOURCE position` and `none
unpositioned`, true by construction while the steps WERE the artifact's mapped pcs) and the rung-1
assertion they rested on, replaced by the positioned/unpositioned identity, a non-degeneracy floor,
the artifact's own rung, the declared rung's implication and the declared reason's split; and
**M21 324 -> 325**, all of it `verify_transcript_truncation_detection_uniform` 43 -> 44, because
M29's differential is the sixth comparer on that check's own list. 10,048 + 105 + 2 + 1 = **10,156**
exactly, and with the review's 22 it is **10,178**. **M25 is unchanged at 272** even though M29 retired one of its verification entries: that
entry was `pending` and a `pending` entry has no assertions. Every other milestone came out at its
reference value **to the assertion**, including M24 at 350 (`ct-host/src` was not touched, so
`_m24_oq6_stamp` did not fire and no benchmark re-ran), M4 at 218 in the dev shell, M12 at 691 and
M20 at 237.

**M11 WENT RED FOR THE NINTH UPSTREAM MOVE** — `7471a61f1a92f5b2f474db714f34430253892d99` — with
nine failing assertions and **the count unchanged at 259**, which is the recorded signature. It is
not repaired: the seventh move's `barretenberg/cpp` conjunct is still open and `carry/` is left at
HEAD rather than half-repaired. **M9 flaked in the sweep at 524 / rc 1 / 12 failures** — `807 - 524
= 283 = 140 + 143`, the two checks that correctly refuse to compare and print no summary while doing
it — and was re-run alone, which is the settled procedure: **807 in 1,291 s, the reference split
140/143/113/73/126/83/129, with the truncation NOT recurring** (both comparers ran, 140/0 and
143/0). One assertion failed and it is the OTHER M9 condition: `test_observer_disabled_is_free`'s
timing arm, `+1.29% CI [+0.52%, +2.05%]` against a `+2%` budget — the point estimate inside it and
the CI's upper bound over it by 0.05 percentage points, on a box that had been running headless
browsers, wasm builds and a thirty-milestone sweep all session. A timing measurement on a loaded
machine, not a regression, and the two conditions are not to be conflated.

**M28 MOVED EXACTLY ONE NUMBER AND IT IS ITS OWN.** 9,695 + 353 = 10,048 exactly, and 353 is the sum
of M28's six checks and nothing else — `just ci-browser-gate` 104, `verify_browser_bundle_no_node_builtins`
64, `verify_browser_bundle_no_native_deps` 44, `verify_npm_pack_no_optional_native` 54,
`verify_verification_code_unreachable_from_browser` 37, `smoke_browser_headless_full_flow` 50. The
GATE is **393** because it also runs M27's `verify_browser_entry_points_are_dd5_shaped`, which came
out at **40** inside M27 where it is counted; `just verify-m28` deliberately excludes it, and
`ci_browser_gate.sh` asserts the two lists differ by exactly that one name so they cannot drift.

**M28 WAS DECLARED AT 348 AND ITS REVIEW TOOK IT TO 353, IN TWO CHECKS AND NOTHING ELSE.**
`just ci-browser-gate` **101 -> 104**: the closure's optional-manifest count re-derived on a line of
its own (§5 carried 268 and 3 on ONE line with only the 268 re-derived, and swapping them left the
document stating the reverse of D22 with 101 assertions and 0 failures), plus the §2 composition
table compared as a SET against the recipe's — a size is not a composition, and replacing one row
with a different check that exists also passed 101/0 — with a non-emptiness assertion beside the
read. `verify_npm_pack_no_optional_native` **52 -> 54**: the extraction non-emptiness moves INSIDE
the per-package loop, because `pack_binaries` re-fills one directory per tarball so a single check
after the loop only ever judged the last package. 3 + 2 = 5, exact in both parts.

**Every one of M0-M27 came out at its reference value TO THE ASSERTION** in the review's own sweep,
including M9 at **807 in 1,282 s with no flake** — immediately after M8's build, which is D19's
standing hypothesis, on a box carrying a foreign build, and it did not fire — M4 at 218 in the dev
shell, M24 at 350 and M27 at 343. Nothing outside M28 moved: `verify_provenance_complete` stays 64
(M28 vendors nothing), `check-drift` 22, `verify_named_checks_exist` 9, `verify_pinned_nightly_single_source`
28, `verify_reuse_inventory_complete` 19, `just check-repo-hygiene` 28, M0 156, M1 175, M20 237.

**THE ONE NON-ZERO EXIT IS M11's AND IT IS THE SIXTH AND SEVENTH UPSTREAM MOVES — see the bullet
below, which is the one place the chain is stated.** m11 reads **259 with TEN failing assertions and
the count unchanged** — the count is the recorded signature; the failure count is not, and M28's own
sweep read eight because it ran m11 BETWEEN the sixth and seventh moves. It is NOT repaired: the
seventh move breaks the conjunct no acknowledgement can excuse, and `carry/` is left at HEAD rather
than half-repaired. **And a sweep is a WRITER here**: `verify-m11` rewrites `carry/rebase.json` and
`carry/exposure.json` to the current tip on every run, so a sweep leaves two tracked files modified
and they must be restored afterwards.

**M26 MOVED THREE NUMBERS AND EVERY UNIT OF ALL THREE IS ACCOUNTED FOR IN BOTH DIRECTIONS.**
Its own **313** (133 / 65 / 36 / 79) after its review — **declared at 293** (117 / 65 / 36 / 75), and
the twenty its review added are itemised in M26's Verification section, in two checks and nothing
else; **M1 169 -> 175**, which is `verify_provenance_complete`
58 -> 64 — five new single-file `PROVENANCE.md` rows at one `is tracked` assertion each, plus one
for `RI-72`, an inventory id no row had cited before (5 + 1, exact in both parts); and **M25
266 -> 272**, which is `test_fr_rendering_matches_noir_tracer` 50 -> 56, because M26 landed
`SOURCE-MAPPING.md` §4.4's option 1 and the check was repointed at the rendering that is now there
plus the absence of the one that is not. 9,027 + 313 + 6 + 6 = **9,352** exactly.
**Every other milestone came out at its reference value TO THE ASSERTION**, including M4 at 218 in
the dev shell (M19's review's PATH pin still holds), M11 at 259 (upstream has not moved a sixth
time) and M24 at 350 — unmoved even though M26 changed the module under it three times, because
M24's checks re-derive `TRACE-ABI.md` from the artefact rather than pinning literals.

**M9 DID NOT FLAKE IN THE REVIEW'S SWEEP — 807, 7/7, exit 0 in 1,341 s, IN the sweep**, split
140/143/113/73/126/83/129, immediately after M8's build as always. That is worth as much as a
sighting: "a build finished seconds earlier" is D19's standing hypothesis and this run had that
condition and did not truncate. **And the four sightings of `burn` truncate at FOUR DIFFERENT
points** — 39,113 / 16,719 / 14,572 / 17,866 — same input, same module, same host, so the cause is
NOT a particular record and a content-dependent defect is ruled out. `steps.burn.17592` is M26's
sighting's truncation POINT, not a trigger; the trigger is still not established. `DRIFT.md` D19
carries the ledger now, which it had asked for and not been given three times.

**M9 FLAKED IN M26's OWN SWEEP AND PASSED ALONE, WHICH IS THE SETTLED PROCEDURE.** In the sweep: 524,
exit 1, twelve failing assertions, the V8 step transcript truncated after 17,866 lines at
`steps.burn.17592` with the `avmSteps.done` sentinel never arriving — the recorded signature
exactly. `807 - 524 = 283 = 140 + 143`, so the whole shortfall is the two checks that correctly
REFUSED to compare and printed no summary line while doing it; the other twelve red assertions are
in the two checks `m9_completeness` is still not wired into, which is this file's own outstanding
item and not a finding about the interpreter.

**M25'S REVIEW MOVED EXACTLY ONE MILESTONE AND IT IS M25'S OWN.** Every one of M0-M24 came out at
its reference value **to the assertion**, including M9 at 807 in 1,313 s with its
140/143/113/73/126/83/129 split and no flake, M11 at 259 (upstream has not moved a sixth time), M4
at 218 in the dev shell (M19's review's PATH pin still holds) and M24 at 350 with
`verify_trace_event_abi_batched_faster` at 91 — the OQ-6 content stamp matched, so no benchmark
re-ran. 8,761 + 266 = 9,027 exactly.

M25 was DECLARED at 236 (61 / 50 / 83 / 42) and its review took it to **266** (71 / 50 / 92 / 53),
in three checks and nothing else: `verify_oq5_source_mapping_verdict_recorded` +10 (a stride census
the document stated wrongly and nothing re-derived, and the `@aztec` nightly line the artifact
actually came from), `test_trace_metadata_declares_mapping_rung` +9 (§7's corrected 4/60, pinned in
the host and in the document rather than only in Rust), and
`verify_transaction_builder_closure_measured` +11 (one assertion that could not fail, replaced by
ten that can, plus two on the retraction it was propping up).

**THE ANCHOR MOVE'S REVIEW MOVED EXACTLY ONE NUMBER AND IT IS TWO ASSERTIONS.** M24 348 -> 350,
all of it `verify_ct_writer_wasm_zero_imports` 56 -> 58, and the reason is a family this brief
already names one level up. **`ct-writer/src/lib.rs` carries five `#[test]`s over the trace event
ABI and NOTHING IN THE REPOSITORY EVER RAN THEM** — `build_ct_writer_wasm.sh` runs them only
behind `--native-tests` and no check, recipe or script passed it. So when the anchor moved,
`a_column_request_is_recorded_as_dropped` — asserting `ct_dropped_column_awareness() == 1` —
became **false of the writer the crate links** and sat in the tree looking green; run by hand it
fails `left: 0, right: 1`. The module doc said the same false thing in prose. *An assertion that
cannot fail is one shape of this; a whole test file that nothing executes is another, and it is
harder to see, because the file is full of assertions that look fine.* The test now asserts what
the writer does, the doc is corrected, and the check EXECUTES the suite — one assertion that it
passes and one that it is **not empty**, because `cargo test` exits 0 over zero tests.

**And a property of the artefact came out of fixing that doc.** The first draft added 13 lines to
the module header; the rebuilt module was **253,122 bytes, sha256 `df1177f1…`** — same size,
different hash — because the release module embeds panic `Location`s from `ct-writer/src/lib.rs`.
The fix is written in the SAME NUMBER OF LINES and reproduces `5eef4b11…` exactly. So §7's sha256
is stable in the source *including its comments*, and "two clean builds are byte-identical" is a
weaker statement than it sounds.

Every other milestone came out at its reference value **to the assertion**, including M9 at 807 in
1,284 s with its 140/143/113/73/126/83/129 split and no flake, and M11 at 259 with the fifth
upstream move committed.

**THE ANCHOR MOVE ITSELF MOVED EXACTLY ONE NUMBER AND EVERY UNIT OF IT IS ACCOUNTED FOR IN BOTH
DIRECTIONS.** M24 300 -> 348: `verify_ct_writer_wasm_zero_imports` 55 -> 56 (the module must be
newer than the materialisation stamp — `git archive` stamps files with the COMMIT's timestamp and
cargo fingerprints on mtime, so `--force` alone did not invalidate the build);
`test_ct_container_roundtrip_ct_print` 48 -> 86 (the split streams, through the reference reader,
which nothing had ever read — see M24's "What the anchor move changed"); and
`test_dropped_column_awareness_asserted` 39 -> 48 (the writer honours a column request now, so the
gate that asserted a throw asserts the module's answer, the refusal's reason is re-pinned, and the
bypass that rested on `dropped_column_awareness()` is closed by freezing instead). 1 + 38 + 9 = 48,
and 8,711 + 48 = 8,759; with the review's two, **8,761**. **Every other milestone came out at its
reference value TO THE ASSERTION**, including M9 at 807 in 1,303 s with no flake.

**The 24-failure demonstration was reproduced by the review rather than accepted.** With
`pins.json` put back to `9cbc127ef8` and the module rebuilt, the repaired check gives **86
assertions, 24 failures, exit 1** — and the 38 assertion names the working-tree diff ADDS were
extracted and every one of the 86 output lines classified: all 24 failures are among the 38 new
ones and **all 48 pre-existing assertions pass over that same container**. That is what says the
old check was green over a container whose `steps.dat`, `values.dat` and `calls.dat` the reference
reader cannot read. The old-anchor module rebuilt to **246,527 bytes / `75626c72…`**, §7's
pre-move figure to the byte, and the restore to **253,122 / `5eef4b11…`**, so the harness is
calibrated in both directions.

**M11 WENT RED IN THAT SWEEP FOR THE FIFTH TIME, AND FOR THE FIFTH TIME IT IS UPSTREAM MOVING.**
`upstream/next` went `142dfcf4b2` -> `9df414ec0e` (twelve commits past the base to fourteen), by a
fetch in the sibling `aztec-packages` checkout, while this work was running. Five failing
assertions, **the assertion COUNT unchanged at 259** — the stale recorded tip, the stale exposure
hash and the stale ledger. The decision half needed nothing: the three acknowledged overlaps
outside `barretenberg/cpp` still hold at the new tip and the check's own conjunct printed
`transfers`. Repaired mechanically (`carry/exposure.json` and `carry/rebase.json` re-measured by
the checks themselves, `just carry-ledger` re-rendered) and re-run alone: **259, 7/7, exit 0**.

**M24's review moved exactly one number and every unit of it is accounted for.** M24 292 -> 300:
`verify_ct_writer_wasm_zero_imports` 49 -> 55 (the trace-format checkout is present; the pinned
commit is on a published remote ref; the counter's own negative control; `TRACE-ABI.md` exists;
§7's byte count and its sha256 prefix, both re-derived from the built module) and
`test_ct_container_roundtrip_ct_print` 46 -> 48 (both pinned reader commits published). The OQ-6
check stayed at **91** while getting strictly stricter — the §2 arm table is matched row by row
now, whole row, so median, minimum, crossings and container bytes are each attributed to the arm
they belong to; ten needles replaced by ten better ones, none added. **Every other milestone came
out at its reference value TO THE ASSERTION**, including M4 at 218 measured in the dev shell (so
M19's review's PATH pin holds) and M11 at 259 (upstream has not moved a fifth time). 8,703 + 8 =
8,711 exactly.

**M9 flaked in that sweep and passed alone, which is the settled procedure and it worked.** In the
sweep: 524, exit 1, 12 failing assertions, the V8 step transcript truncated after 14,572 lines at
`steps.burn.14298` with the `avmSteps.done` sentinel never arriving. Re-run alone on an idle box:
**807, 7/7, exit 0 in 1,283 s**, split 140/143/113/73/126/83/129, the reference exactly. Not a
regression. **But the flake exposed two things that are not the flake** — see the next section.

**M24 moved exactly one thing and it is accounted for in both directions.** Its own **292**
(49 / 46 / 39 / 37 / 30 / 91 across six checks) and **nothing else**: every one of M0-M23 came out
at its reference value **to the assertion**, and 8,411 + 292 = 8,703 exactly. M9 reproduced its
140/143/113/73/126/83/129 split in 1,294 s. Three changes M24 made to shared machinery were
checked for movement and moved nothing: two new `pins.json` anchors (`verify_pinned_nightly_single_source`
asserts `>= 3` on the anchor count, not `==`), `ct-host/src` added to `verify_named_checks_exist`'s
scanned roots (every assertion there is an `assert_ge` or an emptiness comparison, so it stays at
9), and RI-42's `confidence` moving `reasoned` -> `settled` (`verify_reuse_inventory_complete`
stays at 19).

**M23 moved exactly two things and both are accounted for in both directions.** Its own **509**
(fourteen checks, of which thirteen are its entries and the fourteenth is M22's
`test_block_seal_updates_archive`, which M23 closed); and **M1 166 -> 169**, which is
`verify_pinned_nightly_single_source` 25 -> 28 because `orchestration/src/disclosure.ts` is now a
declared `npm_pin_witness` and the check makes exactly THREE assertions per witness — it is
tracked, it carries a literal at all, and the literal equals the declared pin. 509 + 3 = 512, and
7,899 + 512 = 8,411. **Every other milestone came out at its reference value to the assertion**,
including M22 at 260 with `block_e2e_driver.ts` edited and M14's archive patch now carried into a
module — nothing repoints M22 at that module — and M9 reproducing its 140/143/113/73/126/83/129
split exactly in 1,279 s.

**M23 was DECLARED at 491 and its review took it to 509**, in six checks: an increase is exactly as
much a thing to account for as a decrease, and every one of the eighteen is a claim that was made
and not pinned. `verify_txe_reuse_verdict_recorded` +4 (the `new Date().getTime()` seed three
wall-clock needles could not see); `test_receipt_declares_no_proving` +5 (the erased-`private`
constructor route, which was open); `test_timestamps_strictly_monotonic_subsecond` +2 (the declared
deviation, asserted where it is non-zero); `e2e_chain_snapshot_export_import_roundtrip` +3 (a
refusal that was read rather than run); `verify_facade_surface_compared_against_txe` +3 (a summary
sentence wrong in both its numbers); `test_block_seal_updates_archive` +1 (four assertions that
vanished silently when a worktree was absent).

**M22's sweep took TWO passes and the reason is worth carrying**, because it produced two instances
of the campaign's most dangerous shape in one run. `/tmp` on this host FILLED twice while the sweep
was running — a 32 GB tmpfs shared with every build and every agent, NOT a per-user quota; that is
the review's correction and it matters because the wrong mechanism licenses the wrong remedy — and the sweep's own LOG is in `/tmp`: appends were lost, taking with
them M2's last two check outputs and M17's `########` start line the first time, and M3's `rc=`,
M4's, M5's and M6's markers entirely and M7's start line the second. **The campaign total was
preserved across both holes while the per-milestone attribution was destroyed** — M2 read 475
(its own 178 plus all of M17's 297) and M17 read 0. M21's summariser CRASHED on it, which is how it
was found; `m22-sweep-sum.py` reports holes as findings and REFUSES TO PRINT A TOTAL while one is
open, which is the property a summariser needs.

The same exhaustion also made `verify_merkle_lmdb_split_native_neutral` report **19 failures** whose
signatures are `signal-BUS` and `signal-ABRT-after-heap-corruption` — LMDB writes through an
**mmap**, and a store that cannot grow faults on the mapping. **It does not report
the quota as a message, it reports it as a signal**, so grepping the log for `Disk quota exceeded`
found zero and would have licensed the wrong conclusion. Re-run after 6 GB was freed: **199, 0
failures**, and M2/M4/M5/M6/M7 likewise back at their reference values to the assertion.

M9's split is **140/143/113/73/126/83/129** and it reproduced on a box that was NOT idle — a foreign
build was running when the sweep started, and the flake did not appear.

Every move since the M0-M19 reference of 7,019, with the reason and the per-check split taken:
M20 added its own 237 and moved M1 141 -> 149 and M19 176 -> 180. Then, across M21 and its review:
**M1 149 -> 151** (M20's phase-splitter vendoring, `PROVENANCE.md` 70 rows -> 71 — the review
deleted that one row and re-measured `verify_provenance_complete` at 41, so the +2 is that row);
**M8 515 -> 516** (the truncation refusal is `lib.sh`'s and BOTH transcripts are asserted);
**M9 804 -> 807** (three transcript preconditions before the comparator);
**M11 246 -> 259** (`verify_carry_set_complete` 37 -> 43 for `not_carried`, and
`verify_carry_set_applies_to_upstream_head` 45 -> 52: +4 for the two overlaps upstream's fourth move
added, +3 for the declared line ranges the ledger now renders from);
**M14 459 -> 460** (the carry count reads the manifest instead of a directory listing);
**M17 295 -> 297** (two assertions that had never existed — see the pipe bullet above);
**M21 324** (new). 2 + 1 + 3 + 13 + 1 + 2 + 324 = 346, and 7,273 + 346 = 7,619.
Then M22: **M1 151 -> 166** (`verify_provenance_complete` 43 -> 58 — ten new single-file
`PROVENANCE.md` rows F10..F19 give one `is tracked` assertion each, and five inventory ids the
mapping had not cited before give one each: 10 + 5 = 15, exact in both parts);
**M18 278 -> 283** (`verify_orchestration_reuse_enumerated` 61 -> 66, because M22 carried out four
of the six RI-19..RI-23 vendorings that check had PINNED AS NOT DONE, exactly as its own header
said would happen, and the census is re-pinned per subject and EXACTLY rather than `>=`);
**M22 247** (new). 15 + 5 + 247 = 267, and 7,619 + 267 = **7,886**. Twenty of the twenty-three
milestones came out at their reference value to the assertion.
Then M22's review: **M22 247 -> 260**, in two checks and nothing else.
`verify_public_processor_vendored_not_reimplemented` **59 -> 71**: +2 for the two unpinned
classifier shapes, +3 for a non-emptiness assertion on each of the three pinned sets, and +7 for the
`upstream/tsavm` precondition block that turns "vendor from the object store, not the worktree" from
an unenforceable instruction into a checked precondition (the worktree's revision, its control, the
ten paths compared with the residue PRINTED, the count of them, and RI-65's own `acir_callback.ts`
instance run rather than cited). `test_failed_tx_leaves_no_state` **43 -> 44**: the f3 balance
comparison had no non-emptiness partner, and a mutation that stops the driver emitting
`balancesAfter.f3` made it pass on `MISSING == MISSING` — one assertion, and it was the ONLY
failure the mutation produced, so without it the corruption was invisible. Nothing else the review
changed is an assertion: the `lib.sh` `$TMPDIR` repoint, five stale counter citations retired, the
`gen_aztec_constants.sh` repoint, five stale Justfile comments and prose. 7,886 + 13 = **7,899**.

---

## M9 is FLAKY, not broken — SETTLED, and the check still reports the flake as findings

**Settled by M19's review**: run alone on a machine verified idle first, `verify-m9` is
**804 assertions, 7/7, exit 0** in 21 minutes, every per-check number equal to the reference
(137 / 143 / 113 / 73 / 126 / 83 / 129), including
`verify_observation_hook_step_records_identical` back at 137/0. So 798 / 3-pass-4-fail was the
CHECK and not the subject, and the fix that is still outstanding is `m9_completeness`'s, not the
AVM's. The account below stands as the record of what the flake looked like.

`verify-m9` came out **798 assertions, 3 pass / 4 FAIL, 32 failing assertions** inside a full
sweep (last green reference 804, 7/7). **Re-run alone on an idle machine at the same commit, it
passes** — `verify_observation_hook_step_records_identical` back to 137/0, matching the reference
exactly. So it is not a regression in the subject and not a code defect: **it is a flaky check.**

All 32 failures had one cause: the **V8 step transcript stopped inside `burn` at record 16,719 of
38,915**, `oob` produced no records, and the terminal `avmSteps.done` sentinel never arrived.
Native and wasmtime produced the full 39,086 records in the same run. **stderr was complete and
included `oob`'s output**, so the guest ran every program to the end — only stdout was short. Not
a timeout (`M7_RUN_TIMEOUT` is 900 s; the block ran in under four minutes) and not stale artefacts.

What is established: the loss is on the guest's WASI `fd_write` path, which does not go through
`process.stdout` and so is not covered by the `exitAfterFlush` drain `93d8255` added to the host —
that drain does not truncate for the host's own writes (reproduced at 40,000 lines, through a pipe
and to a file). What is **not** established is the trigger. No other run of mine overlapped M9's
window; the run began seconds after M8's build finished, so writeback or memory pressure is
plausible and unproven. **Do not attribute this to `93d8255`** — I did, on the reasoning that M9
had not been re-run since that commit, and the idle-machine control refuted it.

**This is a fourth defect in that check, not a finding about the AVM.** An incomplete transcript
is a fact about the RUN. The check has `m9_completeness`, added exactly for this, and its own
comment records an earlier instance (39,113 of 39,115 lines). It must **refuse to compare** on an
incomplete transcript — one precondition failure naming the truncation — instead of emitting 32
assertion failures with names like "oob recorded no steps" and "burn's last record is not the
instruction that exhausted the gas", each of which reads like a discovery about the interpreter
and none of which is.

**Two lessons, and the second is mine.** Sweeps must not overlap other work: this brief already
said so, and I ran M18 checks alongside the sweep earlier in the same session. And a check that
can produce 32 red assertions from one truncated pipe will eventually be believed.

### THE FLAKE CAME BACK IN M24'S REVIEW, AND WHAT IT EXPOSED IS NOT THE FLAKE

**`m9_completeness` WORKS NOW — this section's "outstanding fix" is done, for two checks.**
`verify_observation_hook_step_records_identical` and `test_observer_does_not_perturb` both refused
to compare, and both named the truncation exactly: *"the v8 step transcript … is INCOMPLETE:
truncated-after-14572-lines-last-key-steps.burn.14298 (expected sentinel 'avmSteps.done')"*. That
is the right behaviour and it is what this section asked for.

**Two things are still wrong, and each is a shape this brief already names.**

1. **A refusal that `die`s prints NO SUMMARY LINE.** Those two checks contributed **0** where they
   contribute 140 and 143, so `verify-m9` read **524** against 807 — a **283-assertion silent
   shrink with no failure attributable to it**, which is "a missing check reads as a smaller
   milestone, not as a red one" exactly. M22's abnormal-exit trap fixes this and lives in three
   milestone libraries (`lib_m22_block.sh`, `lib_m23_chain.sh`, `lib_m24_ct_writer.sh`); M9's
   checks do not have it. M22 said a third milestone wanting it is when it moves into `lib.sh`, and
   M24 recorded declining to move it for M22's own reason. **M9 is a fourth caller and a
   retrospective one: the trap would have turned this into a red milestone instead of a small one.**
2. **The completeness precondition is wired into TWO of the FOUR checks that read that transcript.**
   `test_observer_fires_on_exceptional_halt` produced **11 red assertions** — "[v8] oob recorded a
   step for every one of them, expected [3], got []", "[v8] burn's last record is the instruction
   that exhausted the gas" — and `test_existing_event_emitter_path_still_available` one more. Every
   one reads like a discovery about the interpreter and none of them is. That is the precise
   misattribution `m9_completeness` was written to prevent, still happening, in the checks it was
   not wired into. **A precondition installed in some of the places that need it is a precondition
   that will be believed in the others.**

---

## The reuse discipline

**The campaign has been wrong TEN times about whether something needed
building — or, the ninth time, about whether it EXISTS.** Every miss was a *parallel subdirectory*
to the one being searched:

Seven of the ten, the ones with a location crisp enough to be worth memorising:

| believed absent | actually at |
|---|---|
| chain loop, timer, facade | `sequencer-client/src/sequencer/automine/` |
| a shippable contract DB | `avm_fuzzer/common/interfaces/` (and upstream's is **TypeScript**) |
| a chatty merkle DB | `barretenberg/vm2_wsdb/` |
| a TypeScript msgpack encoder | `@aztec/stdlib/avm` — upstream calls it on the same type |
| a telemetry no-op | `telemetry-client/src/noop.ts` + 16 stubs in `txe/esbuild/stubs/` |
| **`aztec-nr` itself, and real contracts written against it** | **`noir-projects/labs/aztec-nr` (265 files) and `noir-projects/labs/noir-contracts/contracts/`, present at BOTH the anchor and the fork's HEAD** |
| **a wallet package with a declared BROWSER entry point** | **`yarn-project/wallets/` (17 files) — `@aztec/wallets`, one level up from the `wallet-sdk/` the plan named** |

**The ninth is worth its own sentence because it was written as a REASON in an Outstanding task.**
M31's fixtures are hand-written Noir rather than aztec-nr contracts, which is a fair limitation —
but the milestone gave as its reason *"which is not in `aztec-packages` at either revision"*, and
that is false: `git ls-tree 233d8e0993 noir-projects/labs/aztec-nr/` returns 265 files, and
`noir-projects/labs/noir-contracts/contracts/app/` holds `simple_token_contract`,
`private_token_contract` and `token_blacklist_contract`. The search had looked at
`noir-projects/fnd/` and at the repository root; `labs/` is the parallel subdirectory. *A
limitation stated with a false reason is worse than one stated with none, because the false reason
closes the search.*

**THE TENTH WAS FOUND BY ENUMERATING FIRST, AND IT IS THE FIRST OF THE TEN THAT COST NOTHING.**
M33's plan named `yarn-project/wallet-sdk/` and nothing else. Before reading it, M33 enumerated
every path in the fork with `wallet` in it at the `cpp` anchor and found **seven** locations
totalling 183 files — among them `yarn-project/wallets/` (17 files: `@aztec/wallets`, an EMBEDDED
wallet with a declared `browser` entry point, an encrypted store and a wallet DB) and
`docs/examples/webapp-tutorial/` (68 files: a worked dApp with an embedded wallet, a test extension
and e2e tests). Neither is in the plan. `@aztec/wallets` is recorded as RI-91 with a measured
rejection rather than discovered by M34 halfway through writing one. *The instrument that found it
is two `git ls-tree` invocations; the nine before it were found by a reviewer.*

**Enumerate across the whole fork and the published `@aztec/*` packages, by
subdirectory, before concluding anything is ours to write.** An entry marked
"build" needs a specific rejection reason: does-not-exist, does-not-cover, or
cannot-reach-target. "We didn't find one" is not a reason.

---

## Status-file conventions

Format spec: `~/ah/dev/agent-harbor/ah-lib/specs/Milestones-Files.md`.

- Every non-`pending` entry needs a `file:` that **exists and contains the named
  test**.
- Prose goes in `description:`, **never** in `status:` — four entries using
  `status: pending — <prose>` broke the campaign's own validator.
- `Implementation Details`, `Key Source Files`, `Outstanding Tasks` required once
  started.
- Header counts and entry counts must agree — they have diverged twice.
- **No time or effort estimates anywhere.** Sequencing is `:depends_on:` only.
- `partially_completed` is a legitimate outcome. Three agents refused to flip a
  status while a criterion was measurably unmet, and each was right.

---

## Environment

- `direnv exec /home/zahary/m/blocktracer nix shell nixpkgs#rustup --command bash -c 'cd <repo> && …'`
- **`/tmp` IS RAM, AND THE MECHANISM MATTERS BECAUSE IT DECIDES THE FIX.** Measured on this host by
  M22's review: `/tmp` is a **32 GB tmpfs** (20 GB used, 12 GB free at the time), `/home` is a
  953 GB disk with 220 GB free, and there is **no per-user quota** — `quota` is not even installed.
  Every earlier account in this brief says "the per-user quota", which is the right observation with
  the wrong cause, and the wrong cause licenses the wrong remedy: "free 6 GB and re-run" restores
  headroom until the next big build, while "put build and scratch directories on `/home`" is
  durable. One session's scratchpad here is 1.4 GB. `df` reporting free gigabytes is still not
  evidence that a write will succeed, and the write probe is still the only evidence — the tmpfs is
  shared with every build and every other agent, so it can fill between the probe and the write.
- `~/.cache` work dirs — **never** `$TMPDIR`. Do a **write probe**, not `statvfs`.
  **And this rule applies to the CHECKS, not only to your probes.** A bare `mktemp -d` lands in
  `$TMPDIR`. M21's review hit it live: with another agent's build occupying `/tmp`,
  `verify_vendor_drift_clean` — which stages the whole tracked tree (1,427 files) as a template and
  again per negative control — died mid-`cp` with `Disk quota exceeded`, printed **no summary line
  at all**, and took **M1 from 151 to 141 with no failure reported**. A missing check reads as a
  smaller milestone, not as a red one. Re-run with `TMPDIR` under `~/.cache` it is 10/0; that check
  now owns `~/.cache/aztec-m1-vendor-drift`. **M22 met this THREE more times in one milestone**:
  `check_drift.sh:112` died mid-`render_drift` with `OSError: [Errno 122] Disk quota exceeded` over
  153 files (it owns `~/.cache/aztec-check-drift` now); the sweep log lost two regions, above; and
  the agent's own shell became unusable because every command writes a cwd file to `/tmp`. On this
  host **`$TMPDIR` is not storage**.
  **THE CENSUS IS CLOSED, AND IT WAS RIGHT BY ACCIDENT — TWO ERRORS OF EQUAL SIZE IN OPPOSITE
  DIRECTIONS.** The published figure was **29 sites across 28 files**, measured with
  `grep -rn 'mktemp -d' verification/*.sh | grep -v '\-p \|mktemp -d "'`. Re-measured by M22's
  review, the true figure is also **29 across 28** — and *not one step of the derivation was right*:

  - **Two of the counted 29 are COMMENT LINES**, `check_drift.sh:114` and
    `verify_vendor_drift_clean.sh:53` — the two sites that were FIXED, described in the comments
    that record the fix. The census counted its own remedy as remaining exposure. *A needle that
    cannot tell a call from a sentence is the campaign's "a citation counted as a call", one level
    up, in the instrument rather than in a check.*
  - **The needle could not see two REAL sites**, because `verification/*.sh` globs one directory
    and does not recurse: `verification/m14/verify.sh:56` is in a subdirectory and
    `tools/gen_aztec_constants.sh:60` is outside `verification/` entirely. Widened to
    `grep -rI 'mktemp -d' --include='*.sh' .` they appear.

  **So the number agreed with itself for two milestones while being derived wrongly twice.** That
  is the exact hazard this brief already names for prose — a figure that is never re-derived stops
  being a measurement — and it is worse in a census, because a census IS the derivation. Widen the
  needle before you trust the count, and count what a scanner CANNOT place rather than only what it
  can.

  Coverage, stated per site rather than as a total: **27 of the 29 are in `verification/*.sh` and
  every one of those 26 files either sources `lib.sh` or is a `lib_*.sh` sourced after it**, so all
  27 are repointed. `tools/gen_aztec_constants.sh` repoints for itself on the same terms, because
  `just gen-constants` invokes it with nothing above it. **`verification/m14/verify.sh` is
  deliberately NOT covered**: it is a prepared upstream contribution meant to run standalone inside
  Aztec's own repository, where `/tmp` is ordinary storage, and making it source our `lib.sh` would
  destroy the property that makes it shippable. 28 of 29 closed, 1 out of scope with a reason.

  And counting them one milestone at a time was never going to finish: five incidents, three
  one-line fixes, and the number kept being republished. **`lib.sh` now repoints `$TMPDIR` at
  `$HOME/.cache/aztec-verification-scratch` when — and only when — it points at a RAM-backed
  filesystem (`/tmp`, `/var/tmp`, `/dev/shm`) or is unset**, which covers every bare `mktemp -d` in
  every check at once, and every one added later. An explicit `$TMPDIR` elsewhere is a decision and
  is left alone, and a directory that cannot be created leaves the old behaviour rather than
  refusing to start a hundred and fifty checks. **Verified to reach every mechanism a check
  actually uses**, not just the sourcing shell: a bare `mktemp -d`, a `mktemp -d` in a subshell,
  Python's `tempfile.mkdtemp()`, Node's `os.tmpdir()`, and `TMPDIR` in a child's environment all
  land under `~/.cache`, while `mktemp -d -p <somewhere>` is untouched. Confirmed on the real
  workload too — the review's own sweep ran with `TMPDIR` unset and accumulated its scratch there
  while `/tmp` never moved. The per-milestone `M<N>_WORK` directories already
  defaulted to `$HOME/.cache/aztec-m<N>-*`; several Justfile comments still say
  `$TMPDIR/aztec-m<N>-…` and are stale.
- Do not clean by prefix; prefixes have twice matched another agent's directories.
- Do not edit a shell script while a run is reading it — it kills the run.
- `ccache` is wired via `CMAKE_{C,CXX}_COMPILER_LAUNCHER` in both dev shells.
  It must **not** make two different trees produce identical artefacts; that
  property is asserted separately and underpins every base-versus-patched claim.
- Ambient **all-lowercase exported** names (`out`, `name`, `phases`…) turn a large
  assignment into an over-long environment and every `exec` fails `E2BIG`.
  `lib.sh` de-exports them at source time.

---

## Load-bearing facts

- **Neutrality harness stays on the patch stack.** M3–M10 compare pristine
  `233d8e0993` against base-plus-patches as *separate trees*. Never repoint it at
  the `codetracer` branch — that would turn base-versus-patched into
  patched-versus-patched and make every claim a tautology while staying green.
- **Upstream moves — NINE times now, and it is M11's work every time. THIS BULLET IS THE ONE PLACE
  THE CHAIN IS STATED; everything else points here.** `upstream/next` has gone `233d8e0993`
  (base) → three commits → `44a57f8c4a` (seven) → `9487ed3e9b` (nine) → `142dfcf4b2` (twelve,
  2026-08-26) → `9df414ec0e` (fourteen, 2026-08-26) → `9d9523b973` (**2026-08-27 20:28**) →
  `703d896149` (**2026-08-27 20:59**, seventeen) → `7df97dce1b` (**2026-08-27 22:29**, eighteen
  commits past the base, 10,933 changed paths) → `7471a61f1a` (**2026-08-28**, measured by M29's
  sweep). **FIVE MOVES IN THIRTY HOURS, THREE OF THEM INSIDE TWO HOURS**, all by fetches in the sibling checkout; M28's sweep ran M11 between the sixth
  and the seventh, and its review's sweep started M11 in the minute the eighth landed. **This chain
  has now gone stale four times, and it will keep going stale**: the "one place states it" remedy
  fixes duplication, not the fact that the number is a property of a moving target rather than of
  this repository. Anything that must be TRUE rather than merely current has to be re-measured, and
  the checks do that; the prose cannot. **THE SEVENTH IS A NEW CLASS AND IS OPEN.** For six
  moves upstream changed nothing under `barretenberg/cpp`; `703d896149`
  (*chore!: delete the in-tree labs components*) changes **five** paths there —
  `barretenberg/cpp/bootstrap.sh`, `docs/Fuzzing.md`, `scripts/chonk_inputs.sh`,
  `scripts/ci_benchmark_ultrahonk_circuits.sh`, `scripts/pinned_chonk_inputs.sh` — and
  `_carry_overlap.py` rejects that class BEFORE it reads `carry/overlap.json`, which is the design.
  What IS established, so the remedy is not guessed at: **the carry set still applies** (5 of 5,
  p1..p5, replayed at the new tip) and **the intersection is still the same three paths**, none of
  them under `barretenberg/cpp`. The five upstream touched are one provisioning script, one document
  and three benchmark scripts — **no CMake file and no translation unit** — so the substance is very
  likely unaffected and the conjunct is correctly conservative. Narrowing it is a DECISION and needs
  M6's and M10's builds re-run; M28 did not take it and left `carry/` at HEAD rather than pinning an
  acknowledgement to a tip that had already moved (it tried, at `9d9523b973`, and the seventh move
  made the repair stale mid-write). Each move can turn `verify_carry_set_applies_to_upstream_head` red
  without anything of ours changing. Distinguish that from a regression, and then FIX it rather
  than recording it — M21 measured the third move and left the red for the review to find.
  **The repair is half mechanical and half a decision.** Mechanical: `just carry-exposure`
  re-measures `carry/exposure.json` at the new tip, `just carry-ledger` re-renders
  `CARRY-LEDGER.md`, and the replay rewrites `carry/rebase.json` on every run — those three are
  committed together or the ledger and the data disagree, and `carry/overlap.json` joins them as a
  fourth **whenever the decision half is non-empty**. The decision: every overlap OUTSIDE
  `barretenberg/cpp` needs an entry in `carry/overlap.json` with a reason, a
  why-it-does-not-reach-the-build, a consequence, the declared line ranges, and the blob ids at
  both ends so it expires when upstream touches the path again. Read the check's own output first
  — it tells you whether conjunct 1 (nothing under the build tree) and conjunct 3 (disjoint
  regions) still hold, and if conjunct 1 has failed no acknowledgement can help and M6 and M10 owe
  a rebuild.

  **AFTER FIVE OCCURRENCES, FOUR OF THEM NEEDED NO DECISION AT ALL, AND THAT IS THE MECHANISATION.**
  Only move 4 added overlaps (`build-images/src/Dockerfile`, `scripts/setup-container.sh`); moves
  1, 2, 3 and 5 needed nothing, because acknowledgements are pinned to blob ids and expire by
  themselves. So the judgement is not "re-acknowledge", it is *"is there anything new to
  acknowledge"* — and `verify_carry_set_applies_to_upstream_head` already computes exactly that
  and printed `transfers` at `9df414ec0e` before anybody looked. What is missing is a **writer**
  that runs when the check says `transfers`: a `just carry-reacknowledge` that records the new
  tip, runs the three regenerations, runs `verification/_carry_overlap.py` against the new tip,
  and **refuses, non-zero, naming the paths**, if an overlap is new, is under `barretenberg/cpp`,
  or has stale blob ids — the three cases a human must decide — otherwise reporting "no decision
  needed" and leaving three files for one commit. It adds no predicate; it runs the check's own
  conjuncts *before* the write instead of after it.

  **And the prose is the half that actually went stale.** The fifth move repaired all three data
  files and left FOUR sites naming `142dfcf4b2` as current — this bullet, two in
  `codetracer-specs`' M11 section, and one in a verification description that also quoted
  "78 paths" where the new tip measures **79**. `CARRY-LEDGER.md` did not go stale, because it
  renders the tip from `carry/rebase.json`. Same remedy as the running total above: one place
  states it, the rest point here.
- **The CI is published and scheduled, and every job dies at one step.** The
  workflow *is* on `origin`, *is* picked up by a `garm-*` runner, and *does* run
  on schedule — then every job aborts at `Generate CI token` with
  `Input required and not supplied: app-id`. **There are TWELVE jobs now**: M28 added
  `browser-gate`, which invokes `just ci-browser-gate` by recipe name and gets chromium from
  `nix shell nixpkgs#chromium` rather than from the runner image (that line was executed locally —
  Chromium 151.0.7922.137 from the store, both work directories cold, the whole gate green — so the
  step is known to be runnable even though the job is not). "It has never run" invites the wrong
  first hypothesis (runner availability); the cause is scoped to this repository.
  `codetracer-ci` is private, same org, same runner group, same label, same `@v1`
  action, same `vars.` spelling, and its token step **succeeds** — so plan and
  variable visibility are ruled out. Never imply a gate exists: no job has ever
  reached a check.
- **Nothing is filed upstream.** Five patches prepared and **six** branches published — five
  `pr/*` plus the downstream **`codetracer`**, which is `fork.downstream_branch` in `series.json`
  and is the sixth identity `verify_pr_branches_match_patches` compares. (This bullet said
  `aztec-avm-runtime` for several milestones. That is `fork.downstream_base_branch`; it is also
  published, and it is NOT one of the six the check reads. Corrected by M28's review, measured
  against `series.json` and `git ls-remote`.) Submission is the user's
  manual step via `submit/pr<N>-*.sh`; there are five such scripts.
- **PR #22815** (Emscripten migration) is open and would delete what patch 2
  changes. Patches 1, 3, 4 are unaffected but for one shared file.
