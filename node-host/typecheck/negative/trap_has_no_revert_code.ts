// NEGATIVE: reading a revert code off a trap.
//
// A trap has no revert code — there is no transaction outcome to have one — and a host that
// reached for `.revertCode` here would get `undefined` at run time and report "reverted with 0",
// i.e. SUCCESS, for a runtime bug. Expected: TS2339 — property does not exist on type AvmTrap.
import { AvmTrap } from '../../src/errors.ts';

export function revertCodeOf(t: AvmTrap): number {
  return t.revertCode;
}
