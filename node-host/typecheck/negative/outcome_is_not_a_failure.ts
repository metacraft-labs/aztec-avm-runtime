// NEGATIVE: the other direction — a transaction outcome passed where a failure is expected.
//
// A reverted transaction is not an error and must not be thrown as one. Expected: TS2345 —
// TxOutcome is not assignable to AvmFailure.
import type { AvmFailure, TxOutcome } from '../../src/errors.ts';

declare function report(f: AvmFailure): void;

export function reportOutcome(o: TxOutcome<unknown>): void {
  report(o);
}
