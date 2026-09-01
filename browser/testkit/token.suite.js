// token.suite.js — a real Aztec contract test, executing in a browser tab.
//
//   WHAT THIS IS A PORT OF, AND WHAT HAD TO CHANGE
//   -----------------------------------------------
// Upstream's smallest real contract test is
// `yarn-project/simulator/src/public/avm/apps_tests/token.test.ts` (vendored verbatim at
// `spike/src/public/avm/apps_tests/token.test.ts`, RI-24). Its imports are:
//
//     import { Fr } from '@aztec/foundation/curves/bn254';
//     import { TokenContractArtifact } from '@aztec/noir-contracts.js/Token';
//     import { AztecAddress } from '@aztec/stdlib/aztec-address';
//     import type { ContractInstanceWithAddress } from '@aztec/stdlib/contract';
//     import { NativeWorldStateService } from '@aztec/world-state';        <-- the ONLY blocker
//     import { AvmSimulationTester } from '../fixtures/avm_simulation_tester.js';
//
// Five of those six reach a browser unchanged — they are already inside the shipped bundle. The
// sixth, `NativeWorldStateService`, is the LMDB NAPI addon, and it is the whole of what stands
// between that file and a tab. This runtime replaced it: `ResidentMerkleWriteOperations` over
// `avm.wasm`'s in-module world state. So the port is a substitution of one object, not a rewrite —
// which is the scoping answer, expressed as code.
//
//   WHY IT DRIVES `runTokenTransfer` RATHER THAN RE-DERIVING THE LOOP
//   ----------------------------------------------------------------
// `browser/src/token_transfer.ts` is the shipped driver that registers the class and instance,
// seeds the two nullifiers an Aztec contract needs before its dispatch will run, derives both
// balance leaves from the artifact's own storage layout, submits and seals. Re-deriving it here
// would be a second implementation of the thing under test, and the campaign's rule is that a
// fixture which reimplements its subject proves the fixture works. The suite ASSERTS OVER what the
// shipped driver did.
//
//   THE FALSE PASS THIS AREA IS PRONE TO
//   ------------------------------------
// "a trace or a run that reports `ok` while carrying zero steps." `outcome === 'processed'` is the
// BLOCK's verdict and is true of a transaction that reverted at instruction one — M29 measured
// exactly that, a container full of fabricated opcodes over a transaction that had not run. So
// this suite asserts the executed-step stream separately and requires it to be large, and
// separately requires the module's own `total_instructions_executed` statistic to AGREE with the
// number of records drained. A count with nothing on the other side of it is not evidence.

const EXPECTED_SEEDED_BALANCE = '1000';
const EXPECTED_TRANSFERRED = '5';
const EXPECTED_SENDER_AFTER = '995';
// The receiver's leaf is deliberately not seeded, so `EMPTY` before is what says the amount
// ARRIVED rather than having been there all along. `EMPTY` and not `null`: the report accessor
// prints `MISSING` for a JSON null, which is the same word it prints for a key that is absent
// altogether, and two missing keys agreeing is not a measurement.
const EXPECTED_RECEIVER_BEFORE = 'EMPTY';

export default async function register({ describe, it }, ctx) {
  // ONE TRANSFER, RUN DURING REGISTRATION, ASSERTED BY MANY TESTS. It costs seconds; running it
  // per test would buy independence nobody needs and pay for it in a timeout. A throw here is a
  // `registration-failed` hard error in the runner — it cannot become an empty green suite.
  const report = await ctx.runTokenTransfer(ctx.opened, ctx.rawArtifact);
  const executed = ctx.opened.steps.last;

  describe('Token contract, in this tab', () => {
    it('registers exactly one contract class and one instance', ({ expect }) => {
      expect(report.artifactName).toBe('Token');
      expect(report.registeredClasses).toBe(1);
      expect(report.registeredInstances).toBe(1);
      expect(report.contractAddress).toBeDefined();
    });

    it('dispatches on an ABI-derived selector, not a typed-in one', ({ expect }) => {
      // The AVM dispatches on calldata field 0. If that is not the selector the ABI derives for
      // `transfer_in_public`, the transaction called something else and every balance below would
      // be about the wrong function.
      //
      // THE TWO SIDES ARE IN DIFFERENT WIDTHS, and the first draft of this test compared them raw
      // and went red over a real agreement: `FunctionSelector.toString()` is the four-byte form
      // (`0x8c9e5472`) and calldata field 0 is a field element, so the same selector reads
      // `0x0000…8c9e5472`. Padding here rather than truncating there, because truncating would
      // discard the leading bytes and a selector that differed only in them would compare equal.
      const asField = (selector) => `0x${selector.slice(2).padStart(64, '0')}`;
      expect(report.calldataSelectors).toContain(asField(report.transferSelector));
      expect(report.calldataSelectors).toContain(asField(report.balanceSelector));
      // TWO calls, not one: an assertion about the order of a one-element list cannot fail.
      expect(report.enqueuedPublicCalls).toBe(2);
    });

    it('carries debug symbols, so the AVM knew what it was running', ({ expect }) => {
      expect(report.debugFunctionNames).toContain('Token.transfer_in_public');
      expect(report.debugFunctionNames).toContain('Token.balance_of_public');
    });

    it('is accepted into a numbered block that names this transaction', ({ expect }) => {
      expect(report.outcome).toBe('processed');
      expect(report.blockNumber).toBeGreaterThan(0);
      expect(report.blockTxHashes).toContain(report.txHash);
    });

    it('does not revert', ({ expect }) => {
      // `revertCode` comes off upstream's own `ProcessedTx` in the sealed block. `outcome` above
      // says nothing about it — a reverting transaction is still `processed`.
      expect(report.revertCode).toBe(0);
      expect(report.revertReason).toBe(null);
    });

    it('moves the balance: sender 1000 -> 995, receiver EMPTY -> 5', ({ expect }) => {
      expect(report.balances.seeded).toBe(EXPECTED_SEEDED_BALANCE);
      expect(report.balances.transferred).toBe(EXPECTED_TRANSFERRED);
      expect(String(report.balances.before.sender)).toBe(EXPECTED_SEEDED_BALANCE);
      expect(String(report.balances.before.receiver)).toBe(EXPECTED_RECEIVER_BEFORE);
      expect(String(report.balances.after.sender)).toBe(EXPECTED_SENDER_AFTER);
      expect(String(report.balances.after.receiver)).toBe(EXPECTED_TRANSFERRED);
    });

    it('is a simulation and says so, every time', ({ expect }) => {
      // §8.4. There is no arrangement of arguments that turns this off, and a test suite is
      // exactly the place a future caller would try.
      expect(report.simulated).toBe(true);
      expect(report.proving).toBe('none');
      expect(report.protocolVersion).toBeDefined();
    });
  });

  describe('the AVM actually ran', () => {
    it('crossed into avm.wasm during this transaction', ({ expect }) => {
      expect(report.moduleCalls).toBeGreaterThan(0);
      // poseidon2 comes out of avm.wasm (DD-11), so a page that hashed anything crossed too.
      expect(report.poseidonCalls).toBeGreaterThan(0);
    });

    it('produced a non-trivial executed step stream', ({ expect }) => {
      // THE FALSE PASS THIS SUITE EXISTS TO REFUSE. `1` is M29's exact signature for
      // "read_instruction threw before the opcode was known" — a transaction that was `processed`
      // and executed nothing. `> 20` is well past it and well under the real figure.
      expect(executed).toBeDefined();
      expect(executed.count).toBeGreaterThan(20);
      expect(executed.steps.length).toBe(executed.count);
    });

    it('agrees with the module about how many instructions it executed', ({ expect }) => {
      // A drained count with nothing to check it against is the thing M29 exists to stop
      // shipping. `total_instructions_executed` is the module's own statistic, on the other side.
      expect(executed.instructionsExecuted).toBeDefined();
      expect(executed.instructionsExecuted).toBe(executed.count);
    });

    it('executed across more than one call context', ({ expect }) => {
      // Two enqueued calls means at least two contexts. One context would mean the second call
      // never started, which every field above is compatible with.
      const contexts = new Set(executed.steps.map((s) => s.contextId));
      expect(contexts.size).toBeGreaterThan(1);
    });
  });
}
