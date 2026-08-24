// NEGATIVE: a switch over the failure kinds that forgets one.
//
// `unreachableKind` takes `never`, so an arm left out makes the residual union reach it and the
// compiler refuses. Expected: TS2345 — AvmInstancePoisoned is not assignable to never.
import { unreachableKind, type AvmFailure } from '../../src/errors.ts';

export function describe(f: AvmFailure): string {
  switch (f.kind) {
    case 'trap':
      return 'trap';
    case 'host-error':
      return 'host error';
    default:
      return unreachableKind(f);
  }
}
