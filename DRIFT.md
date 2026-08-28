# The drift ledger

Every place where something we pin disagrees with something else we pin — or with current upstream —
gets an entry here, **before** it is resolved. An entry is opened when the divergence is observed,
not when it is fixed, so that a green suite can never be mistaken for an absence of divergence.

Seeded before a line of runtime code was written, deliberately: the first entry (D1) is a live
semantic divergence that every test in the tree passes over in silence, and it is the archetype the
whole drift discipline exists for.

Pins are in [`pins.json`](pins.json); the policy for moving them is [`PINS.md`](PINS.md). A re-pin
must open an entry here for **every** behavioural difference it surfaces, including the ones that
were absorbed silently.

## Status vocabulary

| status | meaning |
|---|---|
| `open` | observed, not resolved, and the tree currently behaves in the divergent way |
| `accepted` | we know, we have decided to live with it, and the decision names what it costs |
| `withdrawn` | it was reported as a divergence and measurement showed it is not one. The entry stays, with the evidence, so the claim is not silently dropped |
| `closed` | resolved — upstream landed a fix, or we changed our side. Names what changed |

---

<!-- BEGIN:drift -->

## D1 — AND / OR / XOR lost their dynamic L2 gas upstream; the published constant did not

- id: D1
- status: open
- opened: 2026-08-21
- milestone: M1 (recorded), M19 (`test_bitwise_dyn_gas_divergence_detected`)
- design-question: OQ-13
- sides: C++ at anchor `cpp` vs the published `@aztec/constants` at pin `npm.current` and the
  vendored TS gas table at anchor `ts`
- what: Upstream removed the dynamic L2 gas from `AND` / `OR` / `XOR` and deleted
  `AVM_BITWISE_DYN_L2_GAS` and `AVM_DYN_GAS_ID_BITWISE` from the protocol constants
  (`vm2/common/instruction_spec.cpp` is the authority on gas, not the markdown spec). The published
  `@aztec/constants` nightly **still ships `AVM_BITWISE_DYN_L2_GAS = 3`**, so the revived TypeScript
  gas table still charges it (`spike/src/public/avm/avm_gas.ts:135-140`).
- why it matters: This is *exactly* the failure mode the differential oracle exists to catch, and it
  currently does not catch it — code depending on the stale constant compiles, passes every test in
  the tree, and meters differently from production. A green suite is not evidence of agreement here.
- decision: Recorded, not resolved. The TS gas table is **not** silently corrected: correcting it
  would make the divergence disappear from the tree without making it disappear from the world, and
  the point of the vendored TS side is to be a faithful snapshot of what upstream shipped at anchor
  `ts`. It is resolved at M19, where the divergence is deliberately reintroduced and the harness is
  required to report it (`test_bitwise_dyn_gas_divergence_detected`) — the archetype test for
  silent semantic drift.
- evidence: `reference/vm2-common/instruction_spec.cpp` (the gas table at anchor `cpp`) versus
  `@aztec/constants` at `npm.current`; `fixtures/CORPUS.md` "Risks" item 3.

## D2 — the opcode-spam differential arm is blind to gas divergence

- id: D2
- status: accepted
- opened: 2026-08-21
- milestone: M1 (recorded), M2 (Tier A accounting), M19 (comparison-count reporting)
- design-question: —
- sides: the `opcode_spam` differential arm versus the rest of Tier A
- what: The opcode-spam arm adds 142 differential transactions, taking the differential surface from
  74 to 216. **Those 142 cannot detect a gas divergence.** The reason is structural: every
  opcode-spam transaction runs until it exhausts its gas limit, so both simulators consume exactly
  the limit no matter what the per-opcode cost is, and the four gas assertions compare two identical
  saturated totals.
- why it matters: Gas is the single most valuable thing Tier A checks — D1 is a gas divergence — so
  the added 142 are materially weaker than the original 74. **The 74→216 expansion must never be
  quoted as 216 equally strong comparisons.** A headline number that overstates coverage has already
  been propagated once in this campaign (756 "differential tests" that were 77 comparisons), which
  is why this is a ledger entry rather than a footnote.
- decision: Accepted. The arm is kept — it is still the cheapest coverage available anywhere in the
  corpus, and it does catch the three other mutation classes below — but the accounting is recorded
  wherever the number is quoted (`fixtures/CORPUS.md` Tier H), and M19 makes CI report the
  *comparison count* separately from the test count so this cannot recur by accident.
- evidence: Mutation-tested, 2026-08-21. Adding **+1 L2 gas to every opcode** in the TS gas table is
  caught in `custom_bc` and `token` at the `totalGas` assertion, and is **not caught anywhere** in
  `opcode_spam`. Three mutations that *are* caught, so the arm is not vacuous: a shifted TS noir
  call stack (11 failures in `custom_bc`), a changed TS out-of-gas message (fires on every spam
  case), and the gas mutation itself in the non-spam suites.

## D3 — REVERT_8: no C++ revert reason. Withdrawn — a metadata-collection artefact

- id: D3
- status: withdrawn
- opened: 2026-08-21
- milestone: M1
- design-question: —
- sides: the C++ AVM at pin `npm.deletion_era` versus the vendored TS AVM at anchor `ts`
- what: Narrowing the differential oracle's revert-reason exemption surfaced two `opcode_spam` cases
  where TS produced a revert reason and C++ produced none. `REVERT_8` was the more alarming of the
  two: its reason is `Assertion failed: `, produced by `revertReasonFromExplicitRevert` — an
  **explicit REVERT opcode**, not an exceptional halt at all, and therefore outside upstream's
  documented "revert metadata is not plumbed for exceptional halts" limitation.
- decision: **Withdrawn. It is not a C++/TS divergence, and it is not an upstream report.** Neither
  is D4, and they have the same single cause.
- evidence, in three parts:
  1. **The C++ AVM does set the message.** `vm2/simulation/gadgets/execution.cpp`'s `Execution::revert`
     sets `.halting_message = "Assertion failed: "` — the identical string — and it does so at
     anchor `cpp` *and* at anchor `ts`. It has never not set it.
  2. **The comparison could not see it.** `PublicTxResult.findRevertReason()` derives the **C++**
     reason exclusively from `callStackMetadata`, while the **TS** result carries `revertReason`
     directly on its call-stack object through the legacy
     `TODO(fcarreiro): Remove this after migration to the C++ simulator` branch of the same
     function. `opcode_spam.test.ts` ships `COLLECT_META_CHECK_RET = false` — upstream's own
     constant — so `collectCallMetadata` is off, the C++ side carries no metadata, and it therefore
     reports no reason **for any halt in that suite**, out-of-gas included.
  3. **Flipping the constant makes it pass.** With `COLLECT_META_CHECK_RET = true`,
     `REVERT_8` passes the reason comparison outright: `1 failed → 3 passed` for the `-t REVERT`
     selection, in 3.3 s.
- consequence, and it is the part that mattered: the *stated justification* for the narrowed
  exemption was wrong. It attributed the missing C++ reason to out-of-gas halts specifically; the
  real cause is metadata collection being disabled. The guard has been re-conditioned on the real
  cause — it now fires only when the C++ result has **no call-stack metadata at all**, and asserts
  exactly that. That is strictly tighter where it matters: in any suite that *does* collect metadata
  the exemption can no longer fire, so a C++ AVM that genuinely dropped a reason fails loudly
  instead of being excused by a plausible-looking out-of-gas message.

## D4 — SENDL2TOL1MSG: withdrawn as a divergence; an upstream fixture gap remains

- id: D4
- status: open
- opened: 2026-08-21
- milestone: M1 (recorded), M11 (candidate for the upstream submission set)
- design-question: —
- sides: upstream's `testSideEffectOpcodeSpam` expectations versus what the `SENDL2TOL1MSG` spam
  case actually does
- what: The second of the two surfaced cases. TS produced
  `SENDL2TOL1MSG: Recipient address is too large`; C++ produced no reason.
- decision: In two parts. **The C++/TS divergence is withdrawn**, for D3's reason and with the same
  evidence: with `collectCallMetadata` on, the two simulators agree on the reason and the comparison
  passes. **What remains is a genuine gap in upstream's own test fixture**, and that is why this
  entry stays `open` while D3 is `withdrawn`.
- evidence: `testSideEffectOpcodeSpam` (`fixtures/opcode_spammer.ts`) asserts the halt reason is one
  of `['assertion failed', 'out of gas', 'not enough l2gas']`. The `SENDL2TOL1MSG` case halts for
  none of them. Measured with metadata collection on: the inner call's reason is
  `"sendl2tol1msg: recipient address is too large"` while the outer call's C++ halting message is
  `"Out of gas: total L2 used 6549936 of 6540000, total DA used 786432 of 786432"` — so the outer
  expectation holds and the inner one does not. The list is missing the address-bound error the
  opcode raises when the spam loop drives the recipient past the ETH address bound.
- why upstream has not seen it: the assertion is `expectToBeTrue`, which is a **no-op** unless
  `COLLECT_META_CHECK_RET` is true, and upstream ships it false. The gap is unreachable in a default
  run.
- disposition: a candidate for the upstream submission set, prepared and submitted under **M11**,
  not now — the campaign's rule is that preparing a patch and submitting it are separate milestones,
  and this is a test-expectation gap behind a disabled constant rather than a product defect, so it
  ranks below the five prepared patches. Recorded here so it cannot be lost, with the exact strings
  a reproduction needs.
- **reachable in OUR tree since M2, and turned into a tripwire.** M2 set
  `COLLECT_META_CHECK_RET = true` (see D7), which makes `expectToBeTrue` a real assertion and this
  gap a real failure. It is not skipped and upstream's `allowedReasons` list is not widened — that
  would weaken an upstream assertion. Instead `opcode_spam.test.ts` asserts the known-wrong
  behaviour exactly: the inner halt reason must be `sendl2tol1msg: recipient address is too large`,
  upstream's three-item list must not contain it, and upstream's three assertions for this case must
  come out exactly `[true, false, true]` — reverted, wrong reason, outer frame out of gas. So the
  arm is 142/142 green *and* the divergence cannot be resolved by accident: if upstream fixes the
  list, or the opcode's message changes, or the outer frame stops running out of gas, the test fails
  and this entry has to be re-decided. That is the D1 discipline applied to a fixture gap.
- **and the tripwire is now wired into the verification set, which it was not when it was written.**
  Found in M2 review by mutation rather than by reading: the comparison counter emits its record
  from inside the simulator, *before* the suite's own post-hoc expectations run, and
  `tools/measure_differential.py` does not fail on a red suite. So breaking the tripwire — the exact
  simulation of "upstream fixed it" — left the measured counts at 142 / 142 / 0 and
  `verify_differential_arm_counts_recorded` still reported *26 assertions, 0 failures, PASS*. A
  tripwire nothing runs as a gate is a note. The check now asserts `totalFailed == 0` for **both**
  arms and pins D4's four constants and the not-contained assertion textually, with two negative
  controls, so a red arm and a weakened pin both go red.

## D5 — the cross-language golden `minimal_tx.testdata.bin` is a one-way pin

- id: D5
- status: accepted
- opened: 2026-08-21
- milestone: M1 (recorded), M2 (Tier B)
- design-question: —
- sides: the TS msgpack encoder at anchor `ts` versus the C++ fixtures at anchor `cpp`
- what: `avm_minimal.test.ts` serializes `AvmCircuitInputs(hints, publicInputs)` with msgpack and
  byte-compares against `vm2/testing/minimal_tx.testdata.bin`. Against the contemporaneous file from
  anchor `ts` (188,945 bytes, md5 `e1f17c71a3917a913de63dedf2f71a11`) it **passes**; against the
  file at anchor `cpp` (190,671 bytes, md5 `369ae621886f3d0f0d4867bcbe7419f3`) it **fails** — eight
  weeks of upstream movement showing up as a hard byte mismatch and a 1,726-byte size change.
- why it matters: this is the widest serialization surface in the system pinned by one assertion, and
  it is the thing M12's msgpack reuse (RI-06) rests on.
- decision: Accepted as a **one-way pin**. At anchor `cpp`, `vm2/testing/fixtures.cpp`'s
  `get_minimal_proving_inputs()` builds these inputs on the fly and **nothing in the C++ tree reads
  `minimal_tx.testdata.bin` by name any more** (grep over all `*.cpp`/`*.hpp`/`CMakeLists.txt` finds
  no reader). The TS test is now the producer and the C++ side has moved on, so the golden must be
  regenerated against whichever oracle we keep rather than treated as a contract. A second golden,
  `tx_result_0x02440a89…testdata.bin`, has no reader anywhere and is ignored.

## D6 — the C++ oracle is the in-process NAPI AVM, and it has an expiry date

- id: D6
- status: accepted
- opened: 2026-08-21
- milestone: M1 (recorded), M19 (`verify_oracle_version_gap_reported`, DD-12)
- design-question: —
- sides: the oracle at pin `npm.deletion_era` versus current upstream at anchor `cpp`
- what: The differential's C++ side is `@aztec/bb.js`'s prebuilt `nodejs_module.node` from the 5.0.0
  npm line, which still carries the **in-process** `CppPublicTxSimulator`. Upstream cut over to an
  out-of-process `bb-avm-sim` IPC service on 2026-07-16 (`96082e32ec`).
- why it matters: as the pin ages, Tier A stays green while meaning progressively less. It proves
  agreement with a snapshot, not correctness against current consensus, and it never says which side
  should move.
- decision: Accepted, with two mitigations rather than a fix. The gap is **reported as a number**
  every run (DD-12) and CI fails when it crosses a recorded threshold, so decay is visible instead of
  silent. And the successor oracle is named rather than hoped for: the AVM↔Brillig differential
  fuzzer (RI-34), which drives the pure-TypeScript simulator against Noir's own reference VM and
  needs no C++ AVM at all, so it does not expire. Building `bb-avm-sim` IPC infrastructure for the
  differential is explicitly rejected (OQ-15).

## D7 — the opcode-spam arm compared no revert reasons at all: 142 of 142 were exempted. CLOSED in M2

- id: D7
- status: closed
- opened: 2026-08-21 (M1 review)
- closed: 2026-08-21 (M2)
- milestone: M1 (recorded), M2 (decided and closed), M19 (comparison-count reporting)
- design-question: —
- sides: what the `opcode_spam` differential arm is quoted as comparing versus what it compares
- what: The differential oracle's revert-reason exemption fires when the C++ result carries no
  call-stack metadata. `opcode_spam.test.ts` ships upstream's `COLLECT_META_CHECK_RET = false`, so
  the C++ side carries no metadata for **any** case in that suite. Measured directly, by
  instrumenting the exemption and running the full arm: **142 of 142 cases take the exemption**
  (`exempt=true cfgMeta=false cppMetaLen=0 cppAbsent=true tsPresent=true`, 142 occurrences, 156 s).
  So the arm's 142 transactions contribute **zero** revert-reason comparisons. This is a second
  blindness on the same arm as D2's gas blindness, and it is recorded separately because an earlier
  revision of the milestone described the arm as running "with the revert reason genuinely compared
  rather than exempted", which is the exact opposite of what it does.
- why it matters: The exemption is narrow *where it can fire at all* — verified: across `custom_bc`,
  `amm`, `token` and `deployments` it fired 0 times in 38 transactions, and three injected
  divergences (C++ drops the reason, C++ reports a different one, C++ reports one where TS reports
  none) are all caught there. But "narrow" is a statement about the other four suites, not about
  this one. In `opcode_spam` the comparison is switched off completely, and the 142 green results
  must never be read as 142 revert-reason agreements.
- decision: **M2 took the flip.** `COLLECT_META_CHECK_RET` is `true` in this tree, the exemption is
  unreachable in the suite, and the arm now contributes **142 genuine revert-reason comparisons**.
  Recorded here rather than in a commit message because the reasoning is what a later reader needs:

  1. It turns 142 vacuous exemptions into 142 real comparisons. That alone is the trade M1 costed.
  2. It makes our **only assertion-relaxing deviation to the oracle dead across the whole corpus**.
     The exemption already fired 0 times in the four metadata-collecting suites; with this flip it
     fires 0 times in the fifth as well, so all **216** differential transactions now run with the
     revert reason asserted. `verify_differential_arm_counts_recorded` asserts the measured
     exemption count is **0**, so a future edit that reintroduces one goes red.
  3. It revives two dimensions this arm did not compare at all. `MAX_CALL_STACK_ITEMS` and
     `MAX_CALL_STACK_DEPTH` go from 0 to 10000, so call-stack metadata is collected and compared;
     and the app-logic RETURN-VALUE comparison in `cpp_vs_ts_public_tx_simulator.ts`, guarded by
     `if (this.config?.collectCallMetadata)`, becomes live for all 142.
  4. It makes upstream's own `expectToBeTrue` assertions real rather than the no-op they are while
     the constant is false — two or three per case, on 142 cases.

- correction to this entry's own numbers, made by re-measuring rather than by re-reading: the
  figure above said "141 real reason comparisons". **It is 142.** 141 was the passing *test* count;
  `SENDL2TOL1MSG` does pass the reason comparison and then fails later, in upstream's own
  `allowedReasons` expectation. The distinction is the same test-count-versus-comparison-count
  confusion this entry exists to stop, so it is corrected here rather than quietly. Runtime is also
  not the predicted +9 s: measured 142.0 s flipped versus 141.6 s unflipped, i.e. inside the noise.

- what the one failure cost, and how it is handled: not with a skip and not by widening upstream's
  list. `opcode_spam.test.ts` now asserts the D4 case's known-wrong behaviour **exactly** — the
  inner reason must be `sendl2tol1msg: recipient address is too large`, upstream's `allowedReasons`
  must NOT contain it, and upstream's three assertions must come out exactly `[true, false, true]`.
  If upstream fixes the list, or the opcode's error text changes, or the outer frame stops running
  out of gas, that goes red and D4 has to be re-decided. Same discipline as D1.

- measured after the flip, 2026-08-21, by `tools/measure_differential.py`:
  `opcode_spam` 142 comparisons / 142 revert-reason comparisons / 0 exemptions, 142/142 tests
  passing; whole corpus 216 / 216 / 0. Recorded in `fixtures/differential-arm-counts.json`.
- evidence: Measured 2026-08-21 in review. Tripwire instrumentation of `cppReasonExemptNoMetadata`
  in `cpp_vs_ts_public_tx_simulator.ts`: `opcode_spam` 142/142 exempt; `custom_bc`+`amm`+`token`+
  `deployments` 0/38 exempt with `cfgMeta=true` and `cppMetaLen>=1` throughout. Negative control:
  forcing the exemption's condition false makes `opcode_spam` fail **142/142**, which is what
  establishes that every one of the 142 depends on it. Counter-controls in the metadata suites:
  `cpp_drops_reason` → 12 failures, `cpp_wrong_reason` → 12 failures, `cpp_extra_reason` → 7
  failures. Flip control: `COLLECT_META_CHECK_RET = true` → 141 passed / 1 failed, the failure at
  `opcode_spammer.ts:1698` (`expectToBeTrue` on `allowedReasons`), i.e. D4.

## D8 — we build wasm with wasi-sdk 33; upstream pins 27, and 27's binaries do not terminate

- id: D8
- status: open
- opened: 2026-08-22
- milestone: M4 (`verify_wasi_33_existing_wasm_targets_unchanged`), M11 (submission)
- design-question: —
- sides: our `nix/wasi-sdk.nix` (33.0) versus current upstream at anchor `cpp`
  (`bootstrap.sh`: `expected_abs_wasi_version=27.0`, and the same version in
  `build-images/src/Dockerfile` and `scripts/setup-container.sh`)
- what: Every wasm artefact in this project is built with wasi-sdk **33**, because 27's sysroot
  ships a libc++abi with `cxa_noexception.cpp.o` and neither `cxa_exception.cpp.o` nor
  `cxa_personality.cpp.o`, no `libunwind*` at all and no `eh/` multilib — a C++ program that throws
  cannot be linked. The AVM signals reverts by throwing. Upstream still pins 27 and works around it
  with `BB_NO_EXCEPTIONS` and `common/try_catch_shim.hpp`'s `#define try if (true)` /
  `#define catch(...) if (false)`.
- and, found while measuring the bump: **the 27-built `wasm`-preset `ecc_tests` never terminates.**
  After an identical, complete, green `[  PASSED  ] 924 tests.` summary it spins in the guest —
  measured at 458 CPU ticks over 5 s wall (CLK_TCK=100), i.e. ~92% of one core — and was still
  spinning when SIGKILLed at **20 minutes**; the 33-built binary from the same sources returns from
  `main` and exits 0 in under a second. Not a host artefact: it reproduces on wasmtime as well as on
  V8, on copies whose memory import was satisfied statically with `wasm-merge`, where no host code
  of ours runs.
- and it is the **exit path**, not a test: with `--gtest_filter=-*` — *zero* tests executed — both
  binaries print the same empty-but-complete summary, 33 exits 0 and 27 still hangs. So nothing a
  test leaves behind explains it.
- and its blast radius is **the single-threaded `wasm` preset only**: the `wasm-threads` `ecc_tests`
  built with wasi-sdk 27 runs 1,104 tests from 78 suites and **exits 0**, identically to the 33
  build. Root cause not chased.
- why it matters: while the two disagree, *every* wasm result in this tree is produced by a
  toolchain upstream does not use, so a green run here says nothing about upstream's own wasm CI —
  and, in the other direction, upstream's wasm builds silently compile every `catch` block to
  `if (false)`, including in header-only third-party code that was never audited for it. The one
  place the two toolchains have now been compared on upstream's *own* CI binary — the
  `wasm-threads` `ecc_tests`, run under wasmtime 21 (`nix shell nixpkgs/nixos-24.05#wasmtime`,
  the last release with `-Sthreads`) — they agree exactly: 1,104 tests from 78 suites, 1,010
  passed, exit 0, transcripts identical line for line on both toolchains.
- and, found by M11's tracker search rather than by a build: **upstream may be leaving wasi-sdk
  altogether.** [AztecProtocol/aztec-packages#22815](https://github.com/AztecProtocol/aztec-packages/pull/22815),
  `feat(bb): migrate WASM toolchain from wasi-sdk to Emscripten`, is open — 71 files,
  +1,962 / −1,068 — replacing the `wasm32-wasi` CMake toolchain with an Emscripten one, deleting
  `scripts/wasmtime.sh` for a Node runner, and removing `-fno-exceptions` from the wasm
  `add_compile_options` line. That would resolve this divergence in a third direction: not "upstream
  moves to 33" and not "we carry the bump", but "the pin this entry is about stops existing". It has
  had no activity since 2026-05-16 and its own description says the author has not built or tested
  it, so it is recorded as a live possibility rather than a plan. The knock-on is real and is priced
  in the carry ledger: our `wasm-avm` preset, its configure-time exceptions probe and the exception
  flags in the AVM_WASM patch are all wasi-sdk-shaped and would need rewriting against Emscripten.
  The 2026-08-21 search missed this and reported "no upstream issue found tracking the wasi-sdk
  version"; that statement was wrong and is corrected in the contribution's `PR.md`.
- decision: Open, with the fix prepared rather than only described:
  `codetracer-specs/upstream-bugs/aztec-wasi-sdk-33/` is a `git format-patch` against `233d8e0993`
  that moves the pin, demonstrated native-neutral (1,009 native translation units, byte-identical
  compile commands) and artefact-neutral (identical imports and C-ABI exports, 1.02% smaller). It is
  **not filed**; M11 prepared the branch and the submission script and left the filing to a person.
  This entry closes when upstream's pin moves, and not before — the downstream carry (our own preset
  and nix shell) is the fallback, not the resolution. **Before filing, #22815's status is worth
  asking about**: if it is going to land, the prepared patch is redundant and should be withdrawn
  rather than argued for.

## D9 — the public bytecode commitment is a different number on a 32-bit target

- id: D9
- status: open
- opened: 2026-08-22
- milestone: M5 (`test_bytecode_commitment_correct_on_32bit`), M6 (the wasm AVM build), M11 (submission)
- design-question: —
- sides: upstream at anchor `cpp`
  (`vm2/simulation/lib/contract_crypto.cpp:61`, `bytecode_size << 32` evaluated in `size_t`)
  versus the prepared patch this project builds with
  (`codetracer-specs/upstream-bugs/aztec-bytecode-size-shift-32bit/`, `(uint256_t(bytecode_size) << 32)`)
- what: `compute_public_bytecode_first_field` shifts a `size_t` by 32 before widening it to
  `uint256_t`. On x86_64 and arm64, where `size_t` is 64 bits, that is well defined and the
  commitment is correct — so **upstream has no live defect**, and their
  `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)` means they never build the AVM anywhere else.
  Our runtime is that "anywhere else": for `wasm32-wasip1`, `size_t` is 32 bits and the expression
  is undefined behaviour. Executed on wasmtime with barretenberg's own `uint256_t`, the current
  form agrees with x86_64 on **0 of 13** bytecode sizes and the widened form on **13 of 13**.
- and "undefined" is three different numbers, measured rather than predicted: with the shift count
  in a `volatile`, so a real `i32.shl` is emitted, wasm masks the count to its low five bits and
  the field becomes `DOM_SEP + bytecode_size`; with the literal 32 at `-O0`, `0x0f8411f1`, the bare
  domain separator; with the literal 32 at the `default` preset's `-O3`, LLVM folds the poisoned
  shift and the field collapses to **`0`**, the domain separator folding away with it.
- why it matters: this is the first field of the **public bytecode commitment**, a
  consensus-critical hash — `compute_public_bytecode_commitment` is poseidon2 over it and the
  packed bytecode, and `compute_contract_class_id` hashes that. A wasm AVM built from unpatched
  sources would derive different contract class IDs from the same bytecode, silently, with no
  crash and no assertion. It is also the divergence M8's native-versus-wasm differential would
  otherwise attribute to something else.
- decision: Open, with the fix prepared rather than only described: a one-line `git format-patch`
  against `233d8e0993`, demonstrated to change no native value — upstream's own
  `compute_public_bytecode_first_field` and `compute_public_bytecode_commitment` called from a
  patched and an unpatched build of `vm2_sim` give identical transcripts over nine sizes — at a
  measured cost of one instruction and 16 bytes of `.text`. It is **not filed**; M11 owns
  submission. This entry closes when upstream takes the patch; carrying it downstream is the
  fallback, not the resolution. Until then, every wasm result in this tree is produced from a
  source line upstream does not have.

## D10 — every wasm gtest binary barretenberg builds is an ODR violation across the gtest boundary

- id: D10
- status: open
- opened: 2026-08-22
- milestone: M7 (`verify_vm2_tests_pass_under_v8`, negative control `odr`), M10 (the AVM_WASM
  CMake patch, which is where a fix would ride upstream), M11 (submission)
- design-question: —
- sides: upstream at anchor `cpp` (`barretenberg/cpp/cmake/gtest.cmake` and googletest v1.13.0's
  own `googletest/cmake/internal_utils.cmake`) versus this project's overlay
  (`aztec-avm-runtime/verification/m7/0001-test-vm2-AVM_SIM_TESTS-…patch`, which sets
  `gtest_disable_pthreads` and makes the macros `PUBLIC`)
- what: googletest's CMake puts `-DGTEST_HAS_PTHREAD=1` into `cxx_base_flags` whenever
  `find_package(Threads)` succeeds, and under wasi-sdk it does — the sysroot ships pthread
  **stubs**, so the probe compiles and links. That macro is applied to gtest's own four
  translation units and is **not** propagated to consumers, who fall back to `gtest-port.h`'s own
  default, which for wasi is **0**. `internal::MutexBase` is therefore a different type on the two
  sides of the library boundary — `{pthread_mutex_t, bool, pthread_t}` inside `libgtest.a`, an
  empty struct in every test translation unit — and `Mutex`, `GTestMutexLock`, `ThreadLocal` and
  `GTEST_IS_THREADSAFE` all change with it. barretenberg's own `cmake/gtest.cmake` has the same
  shape twice more, setting `GTEST_HAS_EXCEPTIONS=0` and `GTEST_HAS_STREAM_REDIRECTION=0`
  `PRIVATE` on `gtest` under `WASM` — and the first of those is simply wrong for an `AVM_WASM`
  build, which compiles with `-fwasm-exceptions`. Measured in an unmodified wasm configure:
  4 translation units carry `-DGTEST_HAS_PTHREAD=1` and 0 carry `=0`.
- and it is not theoretical: with the correction reverted in an otherwise identical tree, the wasm
  `vm2_sim_tests` binary dies on the FIRST test with
  `[ FATAL ] gtest-port.h:1660:: Condition has_owner_ && pthread_equal(owner_, pthread_self())
  failed`, and with the death-named suite filtered out, with
  `[ FATAL ] gtest-port.h:1642:: pthread_mutex_lock(&mutex_) failed with error 16` (EBUSY) inside
  gmock's global expectation registry — **0 of 391 tests pass**. With the correction it is
  391 of 391. That is the negative control in `verify_vm2_tests_pass_under_v8.sh`.
- and it is the DISAGREEMENT and not the stubs, which the negative control cannot show on its own
  (reverting the whole hunk is consistent with either diagnosis). Two further variants were built
  and run on review, 2026-08-22, each a one-hunk edit of `cmake/gtest.cmake` in the same tree:
  - **consistent `=1` on both sides** — `gtest_disable_pthreads` left off, so `cxx_base_flags`
    keeps `-DGTEST_HAS_PTHREAD=1` on gtest's own four units, plus
    `target_compile_definitions(gtest PUBLIC GTEST_HAS_PTHREAD=1 …)` so every consumer matches:
    337 command lines at `=1`, 0 at `=0` — **391 of 391 pass, exit 0**. wasi-libc's pthread stubs
    are sufficient for gtest and gmock in a single-threaded program *provided both sides agree*.
    Either consistent value works; the mismatch is the defect.
  - **`PUBLIC` alone, without `gtest_disable_pthreads`** — 4 command lines at `=1`, 333 at `=0`,
    and it passes **0 of 391** on the same `gtest-port.h:1660` condition. The compile command is
    `$DEFINES $INCLUDES $FLAGS` and googletest puts `cxx_base_flags` in `COMPILE_FLAGS`, so the
    `=1` arrives **after** anything `target_compile_definitions` emits and wins on gtest's own
    units. This is why "rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` did not help" — not
    because the setting failed to reach consumers. The load-bearing half of the correction is
    `set(gtest_disable_pthreads ON … FORCE)`; `PUBLIC` fixes only the consumers. **Any upstream
    form of this fix has to change `cxx_base_flags`, not only the target's definitions.**
- why it matters: this is the whole of the "gmock does not work under wasm" finding the vm2-wasm
  spike recorded as a permanent test-framework limitation (`fixtures/CORPUS.md` Tier J: 24 of 59
  suites, 141 tests). It is not a limitation, it is a two-line CMake defect — and it silently
  affects **every** wasm test binary barretenberg builds, not only ours. Upstream does not notice
  because the wasm test binaries they run (`ecc_tests` and friends) use no gmock and never take
  the paths where the two layouts disagree observably.
- decision: Open, with the fix carried downstream rather than filed. The correction is in M7's
  `AVM_SIM_TESTS` overlay and is **gated on `WASM AND AVM_SIM_TESTS`**, so no configuration
  upstream has today changes — deliberately, because M4's and M6's measurements of the existing
  wasm test binaries were taken with the mismatch in place and must stay reproducible. M7 does
  **not** prepare a sixth `upstream-bugs/` entry for it: `SERIES.md` indexes four AVM_WASM patches,
  M10 owns the final shape of the CMake changes that go upstream and M11 owns submission, so
  folding this into one of them is that milestone's decision rather than this one's. Two things
  M10/M11 need are recorded here rather than left to be re-derived: the upstream-facing form
  **cannot carry the `AVM_SIM_TESTS` gate** (upstream has no such option), and nobody has yet
  measured whether the ungated form is neutral for the wasm test binaries M4 and M6 measured — that
  measurement is the precondition for upstreaming it, not a formality. This entry closes when
  upstream's `cmake/gtest.cmake` stops applying those three macros privately, and not before.

  **M10 took the decision this entry left to it, and the answer is no.** The fix does *not* ride
  upstream on the `AVM_WASM` patch. Two reasons, and the second is the one that decides it. First,
  patch 5 is already the only patch in the series with no independent merit, and attaching a
  test-framework change to it would make both harder to review and give a maintainer one reason to
  decline two things. Second and decisively, the precondition above is still unmet: the ungated
  form changes **every** wasm gtest binary barretenberg builds, including the `ecc_tests` that
  patch 2's entire neutrality argument was measured with (998 ran / 924 passed, transcripts
  identical line for line, on both toolchains), and nobody has re-measured those with the macro
  made consistent. M10 did not make that measurement either and does not claim to have — it is
  recorded as M10's outstanding task and as M11's precondition. If the correction is offered at
  all it should go **first and alone**, since its merit is entirely independent of anything AVM:
  it is a defect in how googletest's `cxx_base_flags` reaches consumers, and it affects upstream's
  builds whether or not an AVM ever compiles to wasm. `SERIES.md`'s "Considered and not filed"
  section carries the same verdict for a reader who never opens this ledger.
- evidence: `aztec-avm-runtime/verification/verify_vm2_tests_pass_under_v8.sh` (the `odr` control);
  `aztec-avm-runtime/verification/m7/0001-test-vm2-AVM_SIM_TESTS-the-simulation-side-test-suit.patch`
  (the `cmake/gtest.cmake` hunk and its reasoning);
  `aztec-avm-runtime/fixtures/wasm-parity/EXCLUSIONS.md` ("Supersedes").

## D11 — the wasm AVM logs at VERBOSE and the native AVM at INFO, unconditionally

- id: D11
- status: open
- opened: 2026-08-22
- milestone: M8 (found while separating the differential's streams), M9
  (`test_observer_fires_on_exceptional_halt`, where it is established by moving it), M10 (the
  AVM_WASM CMake patch, if a fix ever rides upstream)
- design-question: should a wasm build of barretenberg narrate its own progress by default, when
  the equivalent native build does not?
- sides: upstream at anchor `cpp` (`barretenberg/cpp/src/barretenberg/common/log.cpp`) versus
  itself — this is an inconsistency *inside* upstream, not between upstream and this project. No
  patch of ours touches it and none is proposed.
- what: `common/log.cpp` initialises the global log level in two arms. Under `#ifndef __wasm__` it
  reads `BB_VERBOSE` from the environment and defaults to `LogLevel::INFO`; under `#else` it is
  `LogLevel::VERBOSE`, with no environment check and no way to turn it down. So every `vinfo` call
  in the AVM — `vm2/simulation/gadgets/tx_execution.cpp`'s "Simulating tx …", "[APP_LOGIC]
  Executing enqueued call to …", "halted via RETURN", the exception handlers' "Out of gas
  exception" and "Instruction fetching error" — fires in a wasm build and is compiled past in a
  native one. Measured, on the same driver built for both targets from the same translation unit:
  the native run's stderr is **0 bytes** and the wasm run's carries 45 lines on the M8 transcript
  and several hundred on M9's. Re-run natively with `BB_VERBOSE=1`, the **same lines appear**, and
  the stdout transcript is byte-identical either way — so the difference is the log level and not
  the target, and it touches no result. A **second** asymmetry falls out of the same run and is
  recorded here rather than left to be rediscovered: the native lines carry a real resident-set
  figure (`(mem: 6.29 MiB)`) and every wasm line says `(mem: N/A)`, because the memory probe has
  no wasm implementation. Two differences on fd 2; neither is a difference in a value.
- why it matters: it is a trap for exactly the kind of comparison this project is built out of. M8
  reused M7's runners, which capture `2>&1`, and the differential came back reporting 229 differing
  lines — a real difference in the artefacts and a completely uninteresting one. Measured properly,
  a merged comparison mismatches on **231 of 1,308** positions against wasmtime and on **all
  1,308** against node, whose host also prints two `ExperimentalWarning` lines before the guest
  starts. Anyone who compares a native and a wasm barretenberg run on a merged stream will meet
  this, and the failure looks like a divergence rather than like a log level. It also means a
  browser embedding the AVM gets VERBOSE logging it did not ask for and cannot switch off.
- decision: Open, and deliberately **not** patched. The fix is one line — give the `__wasm__` arm
  the same `BB_VERBOSE` check the native arm has — but changing it would alter the observable
  behaviour of every existing wasm build of barretenberg, and M4's, M6's, M7's and M8's
  measurements were all taken with it in place and must stay reproducible. What this project does
  instead is *never merge the two streams*: M8's and M9's runners keep the transcript on stdout
  exactly and stderr in its own file, where the checks that want the AVM's own account of an
  exceptional halt read it. This entry closes when upstream's `log.cpp` treats the two targets
  alike, and not before. If M10's CMake patch grows a wasm-facing logging change, it is the natural
  place for the one line.
- evidence: `aztec-avm-runtime/verification/test_observer_fires_on_exceptional_halt.sh` (the
  `BB_VERBOSE=1` run, the byte-identical transcript, and the `(mem: N/A)` versus `(mem: 6.29 MiB)`
  assertions); `aztec-avm-runtime/verification/lib_m8_differential.sh` and
  `lib_m9_observer.sh` (the runners' header comments, and `m9_run_native_verbose`);
  `aztec-avm-runtime/verification/verify_observation_hook_step_records_identical.sh` (no AVM log
  line in either transcript, at least twenty in the wasm stderr).

## D12 — the AVM fuzzer's contract-instance log decoder reads the wrong field order

- id: D12
- status: open
- opened: 2026-08-24
- milestone: M13 (found while enumerating the contract DB implementations; used as the negative
  control in `e2e_deploy_call_revert_roundtrip`)
- design-question: the published-event field layout is defined in TypeScript and consumed in C++;
  which side is the authority, and what checks that they agree?
- sides: upstream at anchor `cpp` versus itself — `FuzzerContractDB::from_logs(const PrivateLog&)`
  in `barretenberg/cpp/src/barretenberg/avm_fuzzer/common/interfaces/dbs.cpp` against
  `ContractInstancePublishedEvent.fromLog` in
  `yarn-project/protocol-contracts/src/instance-registry/contract_instance_published_event.ts`, the
  file that decoder's own comment cites as its source.
- what: The TypeScript reader skips the tag and then reads, in order, **address, version, salt,
  contractClassId, initializationHash, immutablesHash, the seven `PublicKeys` fields, deployer** —
  fifteen fields. The C++ decoder's comment says the layout is "tag (index 0), version (index 1),
  contract address (index 2)" and it takes `log.fields[2]` as the contract address, which is the
  **version**. Having started three fields in, it reads salt, contractClassId and
  initializationHash correctly by coincidence of offset, then walks straight into the public keys
  and takes `immutablesHash` for `npkMHash` — so `immutablesHash` is dropped entirely and the last
  two keys, `mspkMHash` and `fbpkMHash`, are never read at all. Five of the seven keys are shifted
  by one field.
- why it matters: it is invisible from inside the fuzzer, which is the whole shape of the hazard.
  The fuzzer publishes its own logs and consumes them with this decoder, so its encoder and its
  decoder are wrong *together* and every round trip closes. Nothing else in upstream's C++ decodes
  a deployment log — in production the decoding happens in TypeScript, in `PublicContractsDB`
  — so there is no second implementation for it to disagree with. Anyone who reuses this decoder
  against a log a real deployment produced gets a contract instance at the wrong address with two
  unset keys, and no error.
- decision: Open, and **not** reported upstream from here. It is in a `FUZZING_AVM`-gated module we
  do not build and do not ship, and this campaign's posture is to contribute on merit rather than
  to file drive-by findings in code it does not exercise. What M13 does instead is refuse to
  inherit it: `MemoryContractDB::decode_instance_log` is written from the TypeScript reader, with
  the divergence named in a comment at the decode site, and
  `e2e_deploy_call_revert_roundtrip` applies the fuzzer's field order to the same bytes as a
  **negative control** — it must disagree with upstream's reader on the address for all seven
  corpus programs, or the agreement the check asserts would hold for any layout at all. If the
  store is ever filed upstream this entry is the note that goes with it. It closes when the fuzzer
  reads the layout the TypeScript publisher writes.
- evidence: `aztec-avm-runtime/verification/e2e_deploy_call_revert_roundtrip.sh` (112 field
  comparisons against upstream's own two readers, and the fuzzer-layout control);
  `aztec-avm-runtime/diffsim/decode_deployment_logs.mjs` (the upstream readers, driven from the
  pinned npm packages); `aztec-avm-runtime/CONTRACT-DB.md` "Why each candidate is or is not fit".

---

## D13 — the reference world state's genesis prefill is the protocol's, and its comment says it is the fuzzer's

- id: D13
- status: open
- opened: 2026-08-24
- milestone: M14 (found while settling the genesis-prefill question the milestone asks for by
  comparison; the comparison is `test_reference_genesis_roots_versus_real_world_state`)
- design-question: where does the in-memory reference's genesis come from, and does a change to a
  protocol constant move it together with the production world state's?
- sides: upstream at anchor `cpp` versus itself —
  `barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp`'s comment on
  `DEFAULT_NULLIFIER_TREE_PREFILL` / `DEFAULT_PUBLIC_DATA_TREE_PREFILL` against
  `yarn-project/world-state/src/world-state-db/merkle_tree_db.ts`'s `INITIAL_NULLIFIER_TREE_SIZE`
  and `INITIAL_PUBLIC_DATA_TREE_SIZE`.
- what: The reference declares both prefills as the literal `128` with the comment "These match the
  values the WorldState is initialized with **in the fuzzer**." They match considerably more than
  that: the production world state defines `INITIAL_NULLIFIER_TREE_SIZE = 2 * MAX_NULLIFIERS_PER_TX`
  and `INITIAL_PUBLIC_DATA_TREE_SIZE = 2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX`, and both
  protocol constants are 64 — themselves derived, in
  `noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr`, as `1 << 6` from the
  nullifier and public-data subtree heights. The fuzzer passes 128 because the protocol says 128,
  not because it chose it. Measured three ways on this run: the generated header the C++ compiled
  against carries 64 for both, Tier D's capture of the production `NativeWorldStateService` reports
  genesis sizes of 128 for both indexed trees, and the reference executed reports 128 for both.
- why it matters: it is a comment that is TRUE and NARROW, which is the shape that survives review.
  Read literally it says the reference is configured to agree with a test harness, so a reader who
  changed the fuzzer's configuration would expect to change this, and a reader who changed
  `NULLIFIER_SUBTREE_HEIGHT` would not expect to have to. The second is the one that matters: a
  protocol change would move the production world state's genesis and leave the reference's behind,
  and the fidelity gate under `world_state/` would then be comparing two genesis states that were
  never meant to be the same.
- decision: Open, and fixed in M14's prepared patch rather than reported separately. The patch
  restates both constants as `2 * MAX_NULLIFIERS_PER_TX` and
  `2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX` and rewrites the comment to say where the
  numbers come from, so the derivation is in the source rather than in prose beside it. It closes
  when that patch lands, or when upstream states the derivation some other way. It is deliberately
  NOT filed on its own: it is two lines inside a change that has its own argument, and splitting it
  out would be a drive-by.
- evidence: `aztec-avm-runtime/verification/test_reference_genesis_roots_versus_real_world_state.sh`
  section A (the generated header, the protocol source, the probe and Tier D compared four ways);
  `aztec-avm-runtime/verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch`;
  `aztec-avm-runtime/WORLD-STATE.md` section 4.

## D14 — our own observation-hook patch made a msgpack field REQUIRED, so the patched module cannot decode upstream-encoded inputs

- id: D14
- status: open
- opened: 2026-08-25
- milestone: M19 (found by building the three-way arm; enforced per transaction by
  `e2e_differential_wasm_vs_native_cpp`)
- design-question: —
- sides: `avm.wasm` as this campaign builds it (anchor `cpp` **plus** M9's observation-hook patch)
  versus upstream's own `PublicSimulatorConfig` msgpack schema, which is what `@aztec/stdlib`'s
  `serializeWithMessagePack` produces
- what: M9's patch adds `bool collect_execution_steps` to `PublicSimulatorConfig` **and to its
  `MSGPACK_CAMEL_CASE_FIELDS` list**. bb's msgpack reader treats a listed field as required, so the
  patched module refuses any input map that lacks it: `avm_simulate failed with status 1: Missing
  field collectExecutionSteps`. Every encoder that follows upstream's schema — including upstream's
  own — produces exactly such a map.
- why it matters: the patch is additive in C++ and M9 asserts that it is
  (`verify_observation_hook_step_records_identical` pins the defaulted declaration line). **Nothing
  asserted that it is additive ON THE WIRE**, and it is not. The reason the gap survived eight
  milestones is structural and is the same shape as D12: until M19 nothing encoded these inputs
  from TypeScript, so every host read a blob the same patched C++ had written. Encoder and decoder
  were wrong together and every round trip closed. It matters for M19 specifically because the
  differential's premise is that both arms were handed the same transaction, and a patch that
  changes one arm's accepted wire format puts that premise at risk.
- decision: Open, and handled by measurement rather than by a shrug. The three-way arm encodes
  TWICE — once exactly as `CppPublicTxSimulator` would for the native arm, once with the declared
  extra keys for the patched module — and asserts on EVERY transaction that the difference between
  the two encodings is exactly the declared set (`PATCH_REQUIRED_CONFIG_FIELDS`, one boolean). The
  delta is recomputed from the two encodings by a full recursive walk, not checked against the
  expected list, so a second divergence appearing later fails the run instead of widening quietly.
  It closes when M9's patch keeps the field out of the msgpack field list — which is a change to
  that patch and a wasm rebuild, and belongs to the milestone that owns the patch.
- evidence:
  `aztec-avm-runtime/diffsim/src/public/public_tx_simulator/differential/encode_inputs.ts`
  (`PATCH_REQUIRED_CONFIG_FIELDS`, `encodeForPatchedModule`, `encodingDifferences`);
  `~/.cache/aztec-m18-orchestration/m12/barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp:455,467`
  (the field and its presence in the msgpack list, in the tree the shipped `avm.wasm` was built
  from); `aztec-avm-runtime/verification/m9/0001-*.patch` (the patch that consumes it).

## D15 — the wasm AVM and the NAPI oracle meter L2 gas differently: the two-month gap, measured

- id: D15
- status: open
- opened: 2026-08-25
- milestone: M19 (`e2e_differential_wasm_vs_native_cpp`, `e2e_differential_wasm_vs_ts_interpreter`)
- design-question: OQ-15 (rejected: do not build `bb-avm-sim` IPC for the oracle), DD-12
- sides: `avm.wasm` at anchor `cpp` `233d8e0993` (2026-08-19) versus the in-process NAPI AVM in
  `@aztec/native` at pin `npm.deletion_era` `5.0.0-nightly.20260626`, which is anchor `ts`
  `3a68d68ac2` (2026-06-25) — and, transitively, versus the TypeScript interpreter vendored from
  the same anchor
- what: over 30 transactions driven through all three implementations from a proved-identical
  pre-transaction state, **17 disagree on metered L2 gas** and on everything downstream of it:
  `gasUsed.totalGas`, `gasUsed.publicGas`, `gasUsed.billedGas`, `publicTxEffect` (which carries the
  fee) and the resulting tree roots (which carry the fee-juice write). The wasm arm charges MORE in
  every case. The measured deltas are +6, +9, +12, +15, +21, +54, +90, +387 and +3732 — **every one
  an exact multiple of 3**.
  What AGREES on all 30: `revertCode`, `gasUsed.teardownGas`, every app-logic return value, the
  structured revert reason, and the AVM circuit public-inputs buffer byte for byte wherever both
  sides built one. **12 of the 30 — the custom-bytecode unhappy paths — agree on every field of the
  `wasm ↔ native-cpp` pair, including tree roots.** Scoped to that pair deliberately: those 12 still
  differ from the TypeScript arm on `publicInputs.presence`, which is D16 and a configuration
  asymmetry rather than a semantic one, and the generated
  `fixtures/three-way-arm-counts.json` therefore records `transactionsAgreeingOnEveryField: 1` — the
  one transaction in the `collectPublicInputs: true` arm, where D16 does not fire. "Twelve agree on
  everything" unscoped is contradicted by that fixture; scoped to the pair the swap's safety turns
  on, it is exact.
- why it matters: this is DD-12's decay, no longer a prediction. It also means
  `e2e_differential_wasm_vs_native_cpp` cannot be green *against this oracle* while the pins stand,
  and the reason is the ORACLE, not the subject. M8 compares the wasm AVM against a native C++ AVM
  built from the SAME tree and they agree byte for byte including tree roots; that is a much
  narrower claim than "the wasm AVM agrees with the native C++ AVM", and the two must not be quoted
  as one.
- decision: Open, recorded, **not fixed and not worked around**. The obvious attribution is wrong
  and is ruled out here rather than left available: 3 is `AVM_BITWISE_DYN_L2_GAS`, so D1 looks like
  the cause, but D1's change (AND / OR / XOR losing their dynamic L2 gas) is present in the wasm's
  anchor and absent from the oracle's, which makes the wasm arm charge LESS, not more.

  **THE PER-OPCODE ATTRIBUTION IS ESTABLISHED, and M19's review established it.** Two earlier
  sentences here were wrong and are corrected rather than softened: this entry said "about twenty
  `AVM_*_GAS` constants differ" (it is THREE) and that "the exact per-opcode attribution is NOT
  established" (a two-command diff establishes it). Measured over all 208/209 `AVM_*` globals in
  `noir-projects/.../crates/types/src/constants.nr` at the two anchors, the only GAS-COST constants
  that differ are:

  | constant | anchor `ts` `3a68d68ac2` | anchor `cpp` `233d8e0993` |
  |---|---|---|
  | `AVM_BITWISE_DYN_L2_GAS` | 3 | removed (D1 — wasm charges LESS) |
  | `AVM_CALLDATACOPY_DYN_L2_GAS` | 3 | **6** (wasm charges MORE, per word) |
  | `AVM_RETURNDATACOPY_DYN_L2_GAS` | 3 | **6** (wasm charges MORE, per word) |

  (plus `AVM_DYN_GAS_ID_BITWISE`, an id rather than a cost, and four non-gas constants.)
  `vm2/common/gas.{cpp,hpp}` are BYTE-IDENTICAL between the anchors, and both anchors bind those
  names at the same sites in `instruction_spec.cpp`. So the wasm arm charges **+3 per copied word**
  of calldata and returndata. That accounts for the direction, for the granularity (and it also
  demystifies "a multiple of 3": the whole anchor-`cpp` L2 schedule is denominated in threes, since
  addressing resolution alone is 3 per operand, so ANY total-gas difference is), and for WHICH
  transactions agree — the 13 that agree are the ones that halt exceptionally before copying
  anything.

  Confirmed by experiment rather than left as arithmetic. Giving the vendored TypeScript
  interpreter the anchor-`cpp` values for exactly those three costs and changing nothing else makes
  its metered L2 gas **byte-identical to the wasm arm's**: 1,152,536 = 1,152,536 (twice) and
  2,446,917 = 2,446,917, the last being the +3,732 outlier, `daGas` equal in all three. (Only three
  transactions reach the probe, because the parent harness's now-failing ts-vs-cpp assertion aborts
  each test at its first transaction — the oracle is still anchor `ts`, which is the point.)

  So an INDEPENDENT implementation, given the module's own anchor's gas schedule, reproduces the
  wasm arm's number to the unit. The wasm build meters exactly what anchor `cpp` specifies; it is
  the oracle that is two months behind. Corroborating, from inside M19's own run: upstream's
  `CppVsTsPublicTxSimulator` asserts all four gas dimensions equal between the NAPI C++ AVM and the
  TypeScript interpreter — two independent implementations, both at anchor `ts` — and that assertion
  passes on every one of the 30 transactions. With M8's same-tree wasm-versus-native-C++ agreement
  that is a complete 2x2: the difference tracks the ANCHOR, not the implementation and not the build.

  What is still NOT decided is which side is RIGHT, and nothing here decides it. The three-way arm
  enforces a measured ledger keyed on (pair, field): these fields are
  in it under this entry, every other field is not, and a divergence in `revertCode`,
  `publicInputs`, `appLogicReturnValues` or `revertReason` fails the run. It closes when the oracle
  and the module are pinned to the same AVM, or when the per-opcode delta is attributed and either
  side is shown to be wrong.
- evidence: `aztec-avm-runtime/fixtures/differential-wasm-divergences.json` and
  `fixtures/three-way-arm-counts.json` (both generated by `tools/measure_three_way.py`);
  `aztec-avm-runtime/diffsim/src/differential/three_way.test.ts`; the constant diff, which is
  `git show 3a68d68ac2:noir-projects/noir-protocol-circuits/crates/types/src/constants.nr` against
  `git show 233d8e0993:noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr`
  restricted to `pub global AVM_` — note the PATH MOVED between the anchors, so a diff of one path
  reports the whole file as added and says nothing.

## D16 — the TypeScript interpreter builds the AVM circuit public inputs unconditionally; the C++ and wasm AVMs honour `collectPublicInputs`

- id: D16
- status: accepted
- opened: 2026-08-25
- milestone: M19 (`e2e_differential_wasm_vs_ts_interpreter`)
- design-question: —
- sides: the vendored TypeScript `PublicTxSimulator` at anchor `ts` versus both C++ AVMs
- what: with `collectPublicInputs: false` — the setting every apps-test in the corpus but
  `avm_minimal` uses — the TypeScript arm still returns a populated `publicInputs`, and both C++
  arms return `undefined`. Observed on **29 of 29** transactions.
- why it matters: on its own it is a configuration asymmetry rather than a semantic divergence. It
  matters because of what it would have done to the *byte-for-byte* assertion. Upstream's own
  comparison is `if (cppResult.publicInputs !== undefined) assert(...)`, which silently skips; if
  the three-way arm had folded presence into the same field, the one assertion M19 states as "byte
  for byte" would have been satisfiable by an absence in almost every transaction in the corpus.
- decision: Accepted, and split into two fields rather than excused. `publicInputs` is a real buffer
  comparison that runs only when both sides built one — so it fires wherever `collectPublicInputs`
  is set — and `publicInputs.presence` is a separate ledger entry. Neither can stand in for the
  other. It closes if the TypeScript simulator is made to honour the flag, which is a change to
  vendored code the campaign deliberately does not make (see D1's decision for the same reasoning).
- evidence: `aztec-avm-runtime/diffsim/src/public/public_tx_simulator/differential/three_way_public_tx_simulator.ts`
  (`COMPARED_FIELDS`, the two entries and the comment on the split);
  `fixtures/differential-wasm-divergences.json`.

## D17 — the shipped package's import graph reaches bb.js's native-addon loader, through upstream's own crypto

- id: D17
- status: open
- opened: 2026-08-25
- milestone: M19 (`verify_differential_containment`), and it is M27/M28's problem before it is
  anyone else's
- design-question: DD-9
- sides: `orchestration/`'s static import graph versus DD-9's requirement that no reachable path of
  ours defaults to a native AVM, and versus M19's containment deliverable ("the published package
  has zero optional native dependencies")
- what: MEASURED, walking `orchestration/src/index.ts` with `tools/import_graph.mjs`: **1,027
  modules, 41 packages**. `@aztec/native` is NOT among them — that half of the requirement holds.
  But `@aztec/bb.js` IS, 33 of its modules, and **five** of those are its Node backend —
  `bb_backends/node/{index.js,native_shm.js,native_shm_async.js,native_socket.js,platform.js}` —
  of which three locate and load `build/<platform>/nodejs_module.node`. (Five and not three: the
  first count taken here was of the modules whose text mentions the addon, which is a different
  question from which modules are reached. The check caught it.) The reaching import is not ours and not the AVM's: it is
  `BarretenbergSync` in `@aztec/foundation`'s Poseidon, Pedersen, Grumpkin and AES, which
  `@aztec/stdlib` needs and which the orchestration needs for hashing.
- why it matters: M19's deliverable is phrased as "the published package has zero optional native
  dependencies", and that is true of the MANIFEST — four dependencies, no `optionalDependencies` —
  while being false of the GRAPH. The distinction is the whole reason both are measured here. It
  matters most for M27 and M28: a browser bundle cannot contain a `.node` loader, and the fact that
  a Node-condition resolution reaches one means the browser build's correctness rests on
  `@aztec/bb.js`'s `browser` export condition rather than on anything this repository asserts.
- decision: Open, and NOT worked around. The load is behind upstream's own platform detection with
  a wasm fallback, so the package works today in Node without the addon present; that is a runtime
  observation and not a containment property, and it is not written down here as if it were one.
  What M19 does is pin it: `verify_differential_containment` asserts the reached bb.js
  native-loader module count EXACTLY, so the surface cannot grow unnoticed, and asserts that the
  reaching path is upstream's crypto rather than anything of ours. It closes when the browser
  bundle is measured (M28) and either shows the loader absent under the `browser` condition, or the
  dependency on `BarretenbergSync` is replaced.
- evidence: `aztec-avm-runtime/verification/verify_differential_containment.sh` section 3;
  `orchestration/node_modules/@aztec/foundation/dest/crypto/{pedersen/pedersen.wasm.js,grumpkin/index.js,aes128/index.js}`
  (the `import { BarretenbergSync } from '@aztec/bb.js'` sites);
  `@aztec/bb.js`'s `package.json` exports map, whose `.` has separate `require`, `browser` and
  `default` conditions.

## D18 — upstream's published `RevertCode` narrows the AVM's four-valued revert code to two, so "which phase reverted" does not survive `PublicTxResult`

- id: D18
- status: open
- opened: 2026-08-25
- milestone: M20 (found by running Form A's teardown pair; pinned in both directions by
  `e2e_form_a_teardown_revert_still_pays_fee`)
- design-question: —
- sides: the C++ `RevertCode` compiled into `avm.wasm` (anchor `cpp`) versus the published
  `@aztec/stdlib` `RevertCode` at the `deletion_era` nightly, which is what
  `PublicTxResult.fromPlainObject` constructs
- what: the AVM distinguishes `OK`, `APP_LOGIC_REVERTED`, `TEARDOWN_REVERTED` and `BOTH_REVERTED`,
  and `TxExecution::simulate` sets the third or fourth depending on whether app logic had already
  reverted. The published TypeScript declares `RevertCodeEnum` with only `OK = 0` and
  `REVERTED = 1`, and `toRevertCodeEnum` is literally `return value >= 1 ? 1 : 0`. Measured on one
  call, on the same result buffer: the raw msgpack field reads **3**, M17's `TxOutcome.revertCode`
  reads **3**, and `PublicTxResult.revertCode.getCode()` reads **1**.
- why it matters: M20's asymmetric revert model is about WHICH phase reverted, and a check reading
  upstream's typed value cannot tell a teardown revert from an app-logic one — the two arms of the
  teardown pair, identical but for the teardown request, are indistinguishable through it. That is
  the "printed literal" shape: an assertion beside a value that cannot move. It is also the reason
  M17's `TxOutcome` earns its keep as a separate type rather than as a staging post on the way to
  `PublicTxResult`.
- decision: Open, and now also a PREPARED CONTRIBUTION —
  `codetracer-specs/upstream-bugs/aztec-revert-code-four-values/` (`PR.md`, `verify.sh`, one patch
  against the `cpp` anchor). `verify.sh` is **18 assertions, 0 failures** and it EXECUTES the
  narrowing rather than reading it: the extracted `toRevertCodeEnum` answers `0,1,1,1` before the
  patch and `0,1,2,3` after. The gating fact that makes it offerable at all is that **the protocol
  already reserves the room** — the tx blob start marker packs the revert code with
  `REVERT_CODE_BIT_SIZE = 8` and constrains it with `assert_max_bit_size::<8>()`
  (`noir-projects/fnd/noir-protocol-circuits/crates/types/src/blob_data/tx_blob_data.nr`), so all
  four values are already circuit-legal, `toBuffer` already writes a byte, and the wire width does
  not move. It is deliberately NOT enrolled in the five-patch carry set: that set is closed, this
  is unrelated to the wasm work, and taking a sixth is the user's decision. Meanwhile, and
  independently, this is A DELIBERATE DEPARTURE FROM UPSTREAM'S PUBLISHED TYPE, recorded here as
  one. **This runtime reports the module's four-valued code as its own outcome** — `FormAProcessed`
  carries `revertCode` (0..3) and `revertedIn` (`none` / `appLogic` / `teardown` / `both`) — and
  carries upstream's collapsed `RevertCode` on `result` only for consumers that demand that type.
  The reason is the deliverable's own wording: M20 must preserve the asymmetric revert model
  *exactly*, and a two-valued code cannot express which phase reverted, so honouring upstream's
  type as the runtime's outcome would silently destroy the property the milestone exists to
  preserve. Nothing of ours RE-IMPLEMENTS `RevertCode`; the four-valued value is the module's own,
  read off the boundary and passed through.

  The departure is bounded and stated: `result` is untouched and remains the authority for gas,
  the public tx effect and the transaction fee; only the revert code has a second, wider spelling
  beside it, and the wider one is documented as this runtime's.

  An earlier revision captured the raw code in a closure the *driver* hung on the boundary. That
  made "which phase reverted" a property of the test harness rather than of the runtime — a
  consumer of `executeExternallySettledTx` still could not tell a teardown revert from an
  app-logic one. `WasmAvmPublicTxSimulator` keeps it now and `form_a.ts` reports it, so the
  assertions are about the shipped path.

  Pinned in both directions, so the day the published type widens the entry closes rather than
  drifting: the teardown check asserts raw 3 versus raw 1, typed 1 versus typed 1, the NAMED
  phases `both` versus `appLogic`, that the named phase discriminates the pair where the typed
  code cannot, and that upstream's `toRevertCodeEnum` is still `value >= 1 ? 1 : 0` with only two
  enum members. Whether the narrowing is deliberate upstream is upstream's question; the
  four-valued code is what a block builder needs, so it is worth asking.
- evidence: `orchestration/node_modules/@aztec/stdlib/dest/avm/revert_code.js` (`RevertCodeEnum`,
  `toRevertCodeEnum`); `barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/tx_execution.cpp`
  at anchor `cpp` (`RevertCode::BOTH_REVERTED` in the teardown catch);
  `aztec-avm-runtime/verification/e2e_form_a_teardown_revert_still_pays_fee.sh` part 3;
  `aztec-avm-runtime/orchestration/src/form_a.ts` (`FormAProcessed.revertCode`,
  `FormAProcessed.revertedIn`, `TxRevertPhase`, `RAW_REVERT_PHASES`);
  `aztec-avm-runtime/orchestration/src/wasm_avm_public_tx_simulator.ts` (`rawRevertCode`).

## D19 — the V8/WASI guest stdout truncates, twice, on runs that exit 0 and whose stderr is complete

- id: D19
- status: open
- opened: 2026-08-25
- milestone: M21 (the detection made uniform; the trigger is not established)
- design-question: —
- sides: what the guest WROTE to fd 1 versus what the transcript file CONTAINS, on the same run —
  so it is a disagreement between two things that both exist, which is what makes it drift rather
  than a gap
- what: **FIVE SIGHTINGS ACROSS FIVE MILESTONES**, on two different programs, both under Node's V8
  with `node:wasi`. This entry said "TWO SIGHTINGS" and asked for a third to record the line count
  and the last key that arrived; **three more have happened since and none was carried back here**,
  which is this campaign's prose-drifts-from-measurement in the one place that exists to hold the
  measurement. M26's review collected them:

  | # | when | check | transcript | last key |
  |---|---|---|---|---|
  | a | pre-M21 | `verify_observation_hook_step_records_identical` | 39,113 lines of 39,115 | recorded in `m9_completeness`'s own comment |
  | b | M9's original flake | same | 16,719 records of 38,915 | inside `burn`; `oob` produced none |
  | c | M20's review | `test_revert_program_does_not_trap_module` (M8) | 259 lines of 1,318 | first 259 byte-identical, then stops mid-record |
  | d | M24's review sweep | `verify_observation_hook_step_records_identical` + `test_observer_does_not_perturb` | 14,572 lines | `steps.burn.14298` |
  | e | M26's sweep | same two | 17,866 lines | `steps.burn.17592` |
  | f | M29's review sweep | same two | **3,943 lines** | `steps.burn.3669` |
  | g | M29's review sweep, SAME RUN | `test_existing_event_emitter_path_still_available` | 15,306 lines | `events.burn.15101` — the FALLBACK EVENT transcript, not the step one |

  **AND SIGHTING f IS A QUARTER THE LENGTH OF THE SHORTEST BEFORE IT**, which is worth more than
  another row: 3,943 lines against a previous minimum of 14,572. A truncation that can happen at
  10% of the transcript and at 99.995% of it in the same week is not a buffer that fills at a
  particular size, and the spread of the five points is now nearly the whole range.

  **AND g IS A SECOND TRANSCRIPT TRUNCATING IN THE SAME RUN, WHICH IS NEW.** Every earlier sighting
  is of the STEP transcript; g is the fallback EVENT transcript, from a different writer on the same
  guest's `fd_write` path, truncated in the same process invocation series. That is evidence for the
  path (WASI `fd_write` under V8) and against anything specific to the step encoder — and it is why
  M29's review's flake reads **15 failing assertions rather than the recorded 12**:
  `test_existing_event_emitter_path_still_available` has a completeness assertion on that second
  transcript and correctly reports 4 rather than 1.

  **THE LEDGER NARROWS IT, WHICH IS THE FIRST NARROWING SINCE THIS ENTRY OPENED — AND IT IS NOT A
  TRIGGER.** FIVE sightings of the SAME program (`burn`) truncate at FIVE DIFFERENT points —
  39,113 / 16,719 / 14,572 / 17,866 / 3,943 — with the same input, the same module and the same
  host. So
  the cause **is not a particular record**: a content-dependent defect in the writer, the encoder
  or the decoder would stop in the same place every time, and this does not. That rules out the
  hypothesis a reader reaches for first. `steps.burn.17592` is sighting e's truncation POINT and
  must not be read as a trigger; it is the fourth different answer to the same question, and
  `steps.burn.3669` is the fifth.

  **AND M26'S REVIEW SWEEP DID NOT REPRODUCE IT.** M9 ran IN the sweep, immediately after M8's
  build, and came out **807, 7/7, exit 0 in 1,341 s**, split 140/143/113/73/126/83/129 — the
  reference exactly. So "a build finished seconds earlier" is not sufficient, which is the one
  standing hypothesis this entry could test for free and had not.

  The original two sightings, in full:

  1. M9, `verify_observation_hook_step_records_identical`: the V8 step transcript stopped inside
     `burn` at record **16,719 of 38,915**, `oob` produced no records at all, and the terminal
     `avmSteps.done` sentinel never arrived. Native and wasmtime produced the full 39,086 records
     in the same run. An earlier instance of the same shape in the same check is recorded in its
     own comment at 39,113 lines of 39,115.
  2. M8, `test_revert_program_does_not_trap_module` (found during M20's review): the re-run
     transcript held **259 lines of 1,318**, its first 259 BYTE-IDENTICAL to the reference and
     then simply stopping mid-record. The very next run of the same command on the same idle
     machine produced all 1,318.

  Common to both: the process **exited 0**, the guest's **stderr was complete** and included the
  output of the programs whose stdout was missing, so the guest ran every program to the end. It is
  not a timeout (`M7_RUN_TIMEOUT` is 900 s; the block ran in under four minutes) and not stale
  artefacts. What is established is that the loss is on the guest's WASI `fd_write` path, which
  does not go through `process.stdout` and is therefore NOT covered by the `exitAfterFlush` drain
  `93d8255` added to the host — that drain does not truncate for the host's own writes, reproduced
  at 40,000 lines through a pipe and to a file.
- why it matters: a truncated transcript compared against a complete one produces a page of
  differences that read as findings about the interpreter. M9's sighting produced **32 red
  assertions** with names like "oob recorded no steps" and "burn's last record is not the
  instruction that exhausted the gas"; M8's produced "the module does not reproduce its own
  transcript". None of those sentences is true of the AVM. The campaign's own note: a check that
  can produce 32 red assertions from one truncated pipe will eventually be believed.
- decision: Open. **THE TRIGGER IS NOT ESTABLISHED** and nothing here should be read as a fix.
  What M21 did is make the DETECTION uniform, because the question was being asked in seven
  different spellings — `m9_completeness`, `m17_completeness`, two `tail -1` comparisons, an
  `assert_contains` on a sentinel line, and two `assert_eq`s on a field accessor — of which only
  two REFUSED and five merely asserted. All seven now reach one implementation,
  `transcript_completeness` in `lib.sh`, and every check that goes on to compare transcripts calls
  `require_complete_transcript` first, which DIES naming the truncation, the line counts and where
  stderr will be. One precondition failure instead of thirty-two assertion failures.
  What was RULED OUT rather than assumed: the host's own `process.stdout` drain (reproduced
  complete at 40,000 lines both through a pipe and to a file), a timeout, and stale artefacts. What
  was NOT tested and remains the open question: whether the loss depends on the sink being a pipe
  rather than a file, on writeback or memory pressure from a build finishing seconds earlier (M9's
  run began seconds after M8's build), or on a short `uv_fs_write` on a non-blocking fd 1. A third
  sighting should record the sink, the line count, the last key that arrived and what else the
  machine was doing, which is what the refusal now prints.
  **Do NOT attribute this to `93d8255`** — M9's review did, on the reasoning that M9 had not been
  re-run since that commit, and the idle-machine control refuted it.
- evidence: `aztec-avm-runtime/verification/lib.sh` (`transcript_completeness`,
  `require_complete_transcript`);
  `aztec-avm-runtime/verification/verify_transcript_truncation_detection_uniform.sh`;
  `aztec-avm-runtime/verification/verify_observation_hook_step_records_identical.sh` (the
  three-transcript precondition); `aztec-avm-runtime/verification/lib_m9_observer.sh`
  (`m9_completeness`'s comment, which records the 39,113-of-39,115 instance);
  `aztec-avm-runtime/verification/test_revert_program_does_not_trap_module.sh`.

## D20 — `timeout_race.test.ts` tests a race this runtime cannot have, and upstream has since deleted it

- id: D20
- status: closed
- opened: 2026-08-26
- milestone: M22 (`test_block_limits_respected`)
- design-question: —
- sides: upstream's `public_processor/apps_tests/timeout_race.test.ts` at anchor `ts` (391 lines)
  versus **its absence at anchor `cpp` and at upstream HEAD**, and versus this runtime's abort
  semantics
- what: M22's deliverable asks for that test to be "reshaped into a test of *our* abort semantics,
  with the reasoning recorded rather than the file quietly deleted". The reasoning has three parts
  and only the first was anticipated.

  1. **Its subject does not exist here.** Its own header says what it is for: "When a timeout fires
     during C++ AVM simulation: 1. The C++ simulation continues running on a libuv worker thread
     2. It directly accesses WorldState via the native handle 3. TypeScript calls checkpoint revert
     operations 4. Both paths operate on the same WorldState concurrently", and "the key issues
     were: `GuardedMerkleTreeOperations` does not guard C++ access; nothing stops C++ simulation on
     `PublicProcessor` deadline". There is no libuv worker thread in this runtime and no native
     handle: `avm.wasm` runs to completion on the caller's stack, which is exactly why
     `WasmAvmPublicTxSimulator` declares no `cancel` — see its class comment. A test whose bug
     cannot arise is not a test, it is a fixture that always passes.
  2. **It is unrunnable here for a second, independent reason.** Its imports are
     `NativeWorldStateService` and `ForkCheckpoint` from `@aztec/world-state`,
     `CppPublicTxSimulator`, `PublicTxSimulationTester` and `SimpleContractDataSource` — the NAPI
     AVM and the LMDB world state, both forbidden by DD-9 and asserted against in three places by
     `verify_differential_containment`. So even the arrangement of the race is out of reach.
  3. **UPSTREAM DELETED IT ITSELF**, and this is the part the deliverable does not mention. The
     file exists at the `ts` anchor `3a68d68ac2` and at NEITHER the `cpp` anchor `233d8e0993` nor
     upstream HEAD; `git log --diff-filter=D` names the commit that removed it —
     `96082e32ec5 feat: cut simulator over to generated bb-avm-sim IPC service`. Upstream moved the
     AVM out of process, so the shared-handle race stopped being reachable for them too. Our reason
     and theirs are not the same reason, but they are the same shape: the worker thread and the
     handle went away.
- why it matters: a deleted test is invisible, and "we removed a test because it could not fail" is
  indistinguishable in a diff from "we removed a test because it did fail". The two properties the
  original was really about — a deadline stops block building, and an abort signal stops block
  building — are properties of ANY block builder and are not about threads at all. Those are what
  is kept.
- decision: **Closed, and reshaped rather than deleted.** The file is not vendored. What replaces
  it is `test_block_limits_respected`'s deadline and signal arms, run against the real module
  through upstream's own `PublicProcessor.process`: a past deadline and a pre-aborted signal each
  stop the block, each with a control (a future deadline, an open signal) in which all four
  transactions process — because an arm that stops is satisfied by a processor that stops for any
  reason at all. The corruption half of the original is covered from the other end by
  `test_guarded_merkle_tree_blocks_post_seal_access`, which asserts what the guard does now that
  its thread-related reason has gone: refuse world-state access after the block is sealed, with the
  unguarded database beside it as the control.
- evidence: `git show 3a68d68ac2:yarn-project/simulator/src/public/public_processor/apps_tests/timeout_race.test.ts`;
  `aztec-avm-runtime/verification/test_block_limits_respected.sh` (the four limits and the
  reshaping assertions); `aztec-avm-runtime/verification/test_guarded_merkle_tree_blocks_post_seal_access.sh`;
  `aztec-avm-runtime/orchestration/src/wasm_avm_public_tx_simulator.ts` (why there is no `cancel`);
  `aztec-avm-runtime/orchestration/src/block_assembly.ts` (DD-3, why the guard is kept).

## D21 — `REACTOR-ABI.md` says `avm.wasm` imports eleven WASI functions and asserts `random_get`'s absence by name; M27's module imports twelve

- id: D21
- status: closed
- opened: 2026-08-27
- milestone: M27 (observed and recorded; the document is not re-rendered here)
- design-question: —
- sides: `REACTOR-ABI.md`'s import table, which says ELEVEN `wasi_snapshot_preview1` functions and
  records the ABSENCE of `random_get` among four names it enumerates, versus the module
  `verification/build_avm_wasm_m27.sh` produces, which declares TWELVE. Both exist; both are pinned;
  they disagree.
- what: The document is **right about M12's, M13's and M23's artefacts and wrong about M27's**, and
  the difference is M27's own thirteenth overlay. Exporting `avm_grumpkin_mul` / `avm_grumpkin_add`
  makes `bb::numeric::RandomEngine` reachable, and its `get_random_uint{64,128,256}()` are VIRTUAL —
  so the call sites are `call_indirect` through a vtable and `--gc-sections` cannot prove them dead
  however unreachable they are in practice. Traced through the unstripped module's disassembly
  rather than inferred:

  ```
  wasi_snapshot_preview1.random_get  <-  __wasi_random_get  <-  __getentropy
                                     <-  RandomEngine::get_random_uint{64,128,256}()
  ```

  **AND IT IS CALLED, ONCE, WHICH IS NOT WHAT THE FIRST DRAFT OF THE SHIM SAID.** The counter in
  `browser/src/wasi.ts`, read at four points in one process: 0 after `_initialize`, 0 after a
  poseidon2 hash, **1 after the first `avm_grumpkin_mul`**, 1 after an add. `mul_const_time` blinds
  and barretenberg's engine seeds itself once, lazily. The blinding is internal and does not move
  the result — `test_browser_crypto_matches_bb_js` gets identical points from bb.js over the whole
  corpus — so this is a fact about the linker and about wasi-libc, not about determinism. It is
  recorded because the alternative was a comment asserting an absence nobody had measured.
- closed-by: **M27's REVIEW, in the shape this entry itself prescribed, and it cost no
  assertion.** The reasoning below is sound about the CHECKS and was wrong about the price: making
  the import surface a property of a TREE — the way M23 made the export count one — requires no
  check to move, because nothing pins the sentence being corrected. `REACTOR-ABI.md` now carries a
  four-row table (M12 39/11, M13 49/11, M23 51/11, **M27 55/12**) with the vtable reason, the
  disassembly chain and the note that `verify_avm_wasm_import_surface` is right to assert
  `random_get`'s absence because it measures M12's artefact. Nothing is repointed and no earlier
  milestone's number moves. **And the review found the false sentence still in the shipped source**:
  `browser/src/wasi.ts`'s header carried the corrected four-point reading while the `randomBytes`
  option ninety lines below still said the import is "never called".
- decision: **Taken by M27 as "open, and deliberately not fixed by re-rendering the document"; CLOSED by its review, which took the cheaper half of the same prescription.** M27's reasoning, retained because it is right about the checks: `REACTOR-ABI.md`'s
  import table is pinned by M12's checks, which measure M12's module; changing the document without
  changing what pins it would move a number nothing re-derives, which is this campaign's
  prose-drifts-from-measurement defect in the file that exists to prevent it. The correct shape is
  the one M23 used for the EXPORT count — a property of a TREE (39 / 49 / 51 / 55) rather than of
  "the module" — and it belongs in the milestone that repoints those checks. Until then the
  per-artefact statement lives in `BROWSER-PACKAGING.md` §4 and in `browser/src/wasi.ts`'s header,
  both with the disassembly behind them, and M27's own `WASI_IMPORT_NAMES` carries all twelve so the
  loader cannot fail to supply one.
- evidence: `REACTOR-ABI.md` (the eleven-name table and the `random_get` absence claim);
  `aztec-avm-runtime/verification/m27/0001-test-vm2-export-poseidon2-and-grumpkin-from-the-reac.patch`;
  `aztec-avm-runtime/browser/src/wasi.ts` (the twelve names, the counter, and the four-point
  reading); `aztec-avm-runtime/BROWSER-PACKAGING.md` §4;
  `wasm-objdump -x -j Import` over `bin/avm-reactor-debug.wasm` from the M27 tree, which prints
  `Import[13]` — twelve WASI functions plus `env.memory`.

## D22 — the shipped package declares no optional native dependency; three manifests in its declared closure do

- id: D22
- status: open
- opened: 2026-08-27
- milestone: M28 (measured while writing `verify_npm_pack_no_optional_native`)
- design-question: DD-9 — no public export of this runtime may reach the native AVM or a native addon
- sides: `orchestration/package.json`, which declares four `@aztec/*` dependencies and no
  `optionalDependencies` at all — and which `verify_differential_containment` (M19) and
  `verify_npm_pack_no_optional_native` (M28) both assert — versus the 268-package closure an
  `npm install` of it would resolve, in which **three** manifests declare `optionalDependencies`
  and all three are native-addon families.
- what: `msgpackr` -> `msgpackr-extract`; `msgpackr-extract` -> six
  `@msgpackr-extract/msgpackr-extract-<platform>` prebuilt `.node` packages; and
  `@crate-crypto/node-eth-kzg` -> six more of its own. So "the published package declares no
  optional native dependency" is **true of the package's own manifest and false of what installing
  it pulls**, and the narrower true statement must not be allowed to stand in for the wider one.
  Measured, not inferred: 3 of the 427 manifests installed under `orchestration/node_modules`
  declare `optionalDependencies`, and the closure walk from the four declared dependencies reaches
  268 packages of which those three are the only ones.
- decision: **Recorded rather than removed, because the consequence DD-9 is about does not follow
  and that is measurable.** An optional dependency is optional: `npm install --omit=optional`
  resolves the whole closure without any of them, and `msgpackr` falls back to its JavaScript
  decoder — which is exactly what the browser bundle does. Both halves are asserted rather than
  argued: the **browser** pass of `browser/build.mjs` reaches `msgpackr` (4 files) and reaches
  `msgpackr-extract` **zero** times, while the **node** pass of the same build, over the same
  installed tree, reaches `msgpackr-extract` and `node-gyp-build-optional-packages`. Nothing in the
  browser bundle's emitted bytes contains `nodejs_module`, `msgpackr-extract` or a `.node`
  specifier, and the same greps over the node bundle's bytes find all three. Removing the
  dependency edge is upstream's to do (`@aztec/stdlib` imports `msgpackr`), so what is owned here
  is the gate: `verify_browser_bundle_no_native_deps` fails if the browser bundle ever reaches
  either loader.
- evidence: `aztec-avm-runtime/verification/verify_npm_pack_no_optional_native.sh` §6 (the closure
  walk, the three names pinned exactly, and the browser bundle's zeroes);
  `aztec-avm-runtime/verification/verify_browser_bundle_no_native_deps.sh` §4-§5 (the graph and the
  emitted-byte controls, both directions); `orchestration/node_modules/msgpackr/package.json`;
  `orchestration/node_modules/@crate-crypto/node-eth-kzg/package.json`.


<!-- END:drift -->

---

## What is deliberately not here

**Gaps are not drift.** A component upstream does not have (CodeTracer trace output, the timer-driven
block loop) belongs in `REUSE-INVENTORY.md` with a rejection reason, and its missing fixtures belong
in `fixtures/CORPUS.md`'s Gaps section. Drift is disagreement between two things that both exist.

**Staleness of reference material is not drift either.** How old each vendored document is, and which
ones must not be trusted, is `reference/PROVENANCE.md`'s job.
