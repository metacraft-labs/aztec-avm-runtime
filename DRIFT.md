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

## D7 — the opcode-spam arm compares no revert reasons at all: 142 of 142 are exempted

- id: D7
- status: accepted
- opened: 2026-08-21 (M1 review)
- milestone: M1 (recorded), M2 (Tier A accounting), M19 (comparison-count reporting)
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
- decision: Accepted, and the accounting recorded wherever the number is quoted. The arm is kept for
  the same reason as D2 — it still compares revert code, all four gas dimensions, `publicTxEffect`,
  the public-inputs buffer and the tree roots on all 142 — but it is quoted as **74 reason
  comparisons, not 216**. The alternative was measured rather than assumed and is left open for M2:
  flipping `COLLECT_META_CHECK_RET` to `true` makes the exemption unreachable in the suite and gives
  **141 real reason comparisons**, at 165 s instead of 156 s, with exactly one failure — and that
  failure is D4, upstream's own `allowedReasons` gap, not a C++/TS divergence. That trade (a
  recorded local deviation and one expected-fail, in exchange for 141 genuine comparisons) is a
  better bargain than it looks and M2 should take it or record why not.
- evidence: Measured 2026-08-21 in review. Tripwire instrumentation of `cppReasonExemptNoMetadata`
  in `cpp_vs_ts_public_tx_simulator.ts`: `opcode_spam` 142/142 exempt; `custom_bc`+`amm`+`token`+
  `deployments` 0/38 exempt with `cfgMeta=true` and `cppMetaLen>=1` throughout. Negative control:
  forcing the exemption's condition false makes `opcode_spam` fail **142/142**, which is what
  establishes that every one of the 142 depends on it. Counter-controls in the metadata suites:
  `cpp_drops_reason` → 12 failures, `cpp_wrong_reason` → 12 failures, `cpp_extra_reason` → 7
  failures. Flip control: `COLLECT_META_CHECK_RET = true` → 141 passed / 1 failed, the failure at
  `opcode_spammer.ts:1698` (`expectToBeTrue` on `allowedReasons`), i.e. D4.

<!-- END:drift -->

---

## What is deliberately not here

**Gaps are not drift.** A component upstream does not have (CodeTracer trace output, the timer-driven
block loop) belongs in `REUSE-INVENTORY.md` with a rejection reason, and its missing fixtures belong
in `fixtures/CORPUS.md`'s Gaps section. Drift is disagreement between two things that both exist.

**Staleness of reference material is not drift either.** How old each vendored document is, and which
ones must not be trusted, is `reference/PROVENANCE.md`'s job.
