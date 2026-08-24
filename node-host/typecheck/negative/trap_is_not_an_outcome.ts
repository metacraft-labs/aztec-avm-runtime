// NEGATIVE: a trap returned where a transaction outcome is expected.
//
// This is the confusion the whole error surface exists to prevent, written down as code so the
// compiler is what refuses it. AvmTrap is not assignable to TxOutcome, because `kind: 'trap'` and
// `kind: 'tx-outcome'` are disjoint string literals — and because AvmTrap has none of TxOutcome's
// other three members either, which is why the code tsc actually emits is TS2739 ("is missing the
// following properties") rather than the plain TS2322 an incompatible-but-complete shape gives.
// Expected: TS2739, and the check asserts that code rather than a non-zero status.
import { AvmTrap, type TxOutcome } from '../../src/errors.ts';

export function simulate(): TxOutcome<unknown> {
  return new AvmTrap('avm_simulate', new Error('out of bounds memory access'));
}
