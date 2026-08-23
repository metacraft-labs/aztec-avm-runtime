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
- decision: Open, with the fix prepared rather than only described:
  `codetracer-specs/upstream-bugs/aztec-wasi-sdk-33/` is a `git format-patch` against `233d8e0993`
  that moves the pin, demonstrated native-neutral (1,009 native translation units, byte-identical
  compile commands) and artefact-neutral (identical imports and C-ABI exports, 1.02% smaller). It is
  **not filed**; M11 owns submission. This entry closes when upstream's pin moves, and not before —
  the downstream carry (our own preset and nix shell) is the fallback, not the resolution.

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

<!-- END:drift -->

---

## What is deliberately not here

**Gaps are not drift.** A component upstream does not have (CodeTracer trace output, the timer-driven
block loop) belongs in `REUSE-INVENTORY.md` with a rejection reason, and its missing fixtures belong
in `fixtures/CORPUS.md`'s Gaps section. Drift is disagreement between two things that both exist.

**Staleness of reference material is not drift either.** How old each vendored document is, and which
ones must not be trusted, is `reference/PROVENANCE.md`'s job.
