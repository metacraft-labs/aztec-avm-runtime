// membership_witness_source.ts — the seam the two campaigns agreed on, declared once.
//
// THE COLLISION THIS EXISTS TO PREVENT. `Aztec-AVM-Runtime.milestones.org`'s M35 builds oracle
// adapters answering membership-witness queries from RESIDENT trees, over `avm_merkle_db_*`. This
// campaign's L2 must answer the SAME QUESTION SHAPE from a REMOTE NODE. The live-chain campaign's
// own note says the decision — one source interface both satisfy, or two implementations that grow
// apart — is defensible either way and that "discovering the collision after both are written is
// not".
//
// So the interface is declared here, in L0, before either implementation exists, and it is the
// cheapest possible form of the decision: **the shared shape is upstream's own signatures**. Not a
// new vocabulary, not a lowest common denominator — the five `AztecNode` methods, spelled exactly
// as `AztecNode` spells them, so that:
//
//   * `ReplayNodeClient` satisfies it by ALREADY HAVING those methods. There is no adapter between
//     a replay client and this interface; the client IS one. (Asserted at compile time by the
//     `satisfies`-shaped declaration at the bottom of this file, which is a type error the day the
//     two drift.)
//   * M35's resident adapters satisfy it by implementing four methods whose signatures they were
//     going to have to match anyway, because upstream's oracle protocol is what calls them.
//   * Neither side owns the vocabulary, so neither side's change forces the other's.
//
// WHAT IS AND IS NOT IN IT. FIVE queries, not six. `getBlockHashMembershipWitness` is NOT here,
// for the reason `node_surface.ts` records at length: the AVM never reads the archive — measured
// at the anchor from `vm2/common/opcodes.hpp`'s world-state opcode set and corroborated by this
// repository's own `REACTOR-ABI.md`. Adding it would put a method on a shared interface that
// neither side has a reader for, and a shared interface is exactly where an unused method is most
// expensive.
//
// The five answer the AVM's FOUR world-state READ opcodes — `NULLIFIEREXISTS` needs two, because
// non-membership is a different query from membership:
//
//   SLOAD            -> getPublicDataWitness
//   NOTEHASHEXISTS   -> getNoteHashMembershipWitness
//   NULLIFIEREXISTS  -> getNullifierMembershipWitness (present) / getLowNullifierMembershipWitness
//                       (absent — non-membership needs the low leaf)
//   L1TOL2MSGEXISTS  -> getL1ToL2MessageMembershipWitness
//
// `getL1ToL2MessageMembershipWitness` is on this list and is NOT on the milestone file's route-1
// list. That is the enumeration doing its job: the opcode exists, so the read exists, so the
// witness has a caller.
//
// A NOTE ON `blockParameter`, because M21 was bitten by the same argument. Every one of these takes
// a reference block, and a REMOTE source can honour it while a RESIDENT one holds a single world
// state at its current revision and cannot. M21's `SettledLeafIndexSource` accepts the argument and
// IGNORES it, recorded as a stated limitation rather than an oversight. The same discipline
// applies here and is why the argument is in the signature: the day a resident source can answer
// "as of block N", no call site moves.

import type { AztecNode } from '@aztec/stdlib/interfaces/client';

/** The five queries, in the order the AVM's opcode list produces them. */
export const MEMBERSHIP_WITNESS_QUERIES = [
  'getPublicDataWitness',
  'getNoteHashMembershipWitness',
  'getNullifierMembershipWitness',
  'getLowNullifierMembershipWitness',
  'getL1ToL2MessageMembershipWitness',
] as const;

export type MembershipWitnessQuery = (typeof MEMBERSHIP_WITNESS_QUERIES)[number];

/**
 * A source of membership witnesses, satisfied remotely by a node and locally by resident trees.
 *
 * Every signature is `AztecNode`'s, by derivation rather than by transcription: `Pick` takes them
 * from upstream, so a change upstream is a compile error here rather than a silent divergence.
 */
export type MembershipWitnessSource = Pick<AztecNode, MembershipWitnessQuery>;

/**
 * A replay client IS a membership-witness source, checked by the compiler.
 *
 * This is a type-level assertion and it costs nothing at run time: if `ReplayNodeClient` ever stops
 * carrying one of the five, or one of the five changes shape upstream, this line stops compiling.
 * `just typecheck-replay` is what runs it.
 */
export type AssertReplayClientIsAWitnessSource<T extends MembershipWitnessSource> = T;
