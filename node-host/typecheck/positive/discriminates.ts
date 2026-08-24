// THE POSITIVE CONTROL for the negative compile tests beside it.
//
// Everything here is the CORRECT use of the trap/revert types, and it must compile with the same
// compiler and the same flags that reject `../negative/*.ts`. Without it, "the negative cases fail
// to compile" would be a claim about the compiler invocation rather than about the types: a
// misspelled flag, a wrong path or a missing file all make `tsc` exit non-zero too.

import { AvmHostError, AvmInstancePoisoned, AvmTrap, unreachableKind, type AvmFailure, type TxOutcome } from '../../src/errors.ts';

/** A revert is an OUTCOME. It is returned, and `reverted` is true. */
export function readRevert(o: TxOutcome<{ revertCode: number }>): number {
  return o.reverted ? o.revertCode : 0;
}

/** A failure is one of three, and the switch is exhaustive — `unreachableKind` proves it. */
export function describeFailure(f: AvmFailure): string {
  switch (f.kind) {
    case 'trap':
      return `trap in ${f.exportName}`;
    case 'host-error':
      return `status ${f.status} from ${f.exportName}`;
    case 'poisoned':
      return `poisoned before ${f.exportName}`;
    default:
      return unreachableKind(f);
  }
}

/** Each failure type is constructible and is an Error; none of them is a TxOutcome. */
export const samples: AvmFailure[] = [
  new AvmTrap('avm_simulate', new Error('out of bounds memory access')),
  new AvmHostError('avm_simulate', 1, 'not decodable'),
  new AvmInstancePoisoned('avm_abi_version'),
];

/** An outcome is a plain object with the discriminant `'tx-outcome'`. */
export const outcome: TxOutcome<{ revertCode: number }> = {
  kind: 'tx-outcome',
  revertCode: 1,
  reverted: true,
  result: { revertCode: 1 },
};
