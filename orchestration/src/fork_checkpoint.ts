// BEGIN VENDORED-PROVENANCE — hand-maintained; this file is a COPY, not a re-export.
// VENDORED — not our code. Re-vendor rather than editing here.
//   upstream-repo:   AztecProtocol/aztec-packages
//   upstream-path:   yarn-project/world-state/src/native/fork_checkpoint.ts
//   upstream-commit: 3a68d68ac29aaf04fc6251c80a8eb874043cb260
//   licence:         Apache-2.0
//   local-edits:     none to the body; this header and the note below are added
//   inventory:       REUSE-INVENTORY.md RI-26
// END VENDORED-PROVENANCE
//
// WHY A COPY RATHER THAN AN IMPORT, and what the milestone said about it that is not true.
//
// M18's deliverable says this is "the *only* production `@aztec/world-state/native` import in
// the whole non-test subtree, and it is 45 lines of pure TypeScript". Enumerated at the anchor
// over the WHOLE fork rather than over the simulator package:
//
//   * There are SIXTEEN `@aztec/world-state/native` import sites, of which THREE are production:
//     `simulator/src/public/public_processor/public_processor.ts` (ForkCheckpoint),
//     `txe/src/oracle/txe_oracle_top_level_context.ts` (ForkCheckpoint), and
//     `txe/src/state_machine/synchronizer.ts` (NativeWorldStateService).
//     So the claim holds of the SIMULATOR subtree, which is the orchestration we vendor, and
//     not of the non-test subtree as a whole. The other two are in `txe/`, which
//     REUSE-INVENTORY RI-39 has open for M23 — so this is a scope correction, not a new
//     dependency. THE COUNT DEPENDS ON ONE CLASSIFIER RULE and M18's review is where that was
//     said out loud: a fourth site, `prover-client/src/mocks/test_context.ts`, is not a
//     `.test.ts` file and is production under the narrow rule. `/mocks/` is what puts it on the
//     test side, the shared classifier in lib_m18_orchestration.sh carries that pattern, and the
//     check now probes it by name rather than leaving the number resting on an unexercised rule.
//   * AND THE PUBLISHED PACKAGE DOES SHIP ONE. An earlier revision of this note said no
//     published `@aztec` package has a `ForkCheckpoint`; that was measured against a
//     `node_modules` from which `@aztec/world-state` is deliberately absent, so it was true by
//     construction. `@aztec/world-state` ships it at `dest/native/fork_checkpoint.js` and
//     exports the subpath. That strengthens the case rather than weakening it: reaching the
//     class means taking the LMDB-backed native package RI-27 replaces and DD-9 forbids.
//   * It is 46 lines, not 45.
//
// Both of those make the case for copying it slightly weaker and it survives anyway, for the
// reason that actually decides it: the class's only import is an `import type`, so the copy has
// no runtime dependency at all, and severing the `@aztec/world-state/native` specifier is what
// lets RI-27's replacement of that package be total rather than partial. The constructor is
// `private`, so subclassing is not an option and a copy is the only shape available.
//
// THE ONE EDIT, AND WHY IT IS NOT OPTIONAL. Upstream declares the constructor with PARAMETER
// PROPERTIES (`private readonly fork`, `public readonly depth` in the parameter list). Node's
// type stripper REFUSES those — measured, not assumed: a file containing one fails at load with
//
//     SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]:
//       TypeScript parameter property is not supported in strip-only mode
//
// (an earlier revision of this comment said `TypeError`; it is a `SyntaxError`, corrected in
// M18's review), and `tsc --erasableSyntaxOnly` refuses them for the same reason (TS1294).
// This campaign's TypeScript shape, set by node-host, is to RUN THE .ts SOURCES rather than emit
// a build artefact, so a verbatim copy of these 46 lines is a copy that cannot be run. The two
// parameter properties are therefore desugared into two field declarations and two assignments,
// which is exactly what a compiler emits for them, and NOTHING ELSE is changed.
//
// That edit is not described here and left at that. `verify_orchestration_reuse_enumerated`
// diffs this file's body against upstream's at the anchor and asserts the difference is EXACTLY
// this desugaring, line for line — so a second edit, of any kind, turns the check red instead of
// hiding behind the sentence above.
//
// It is a COPY and not a re-implementation: every line below other than the desugaring is
// upstream's, and the check asserts that against the fork rather than trusting this sentence.

import type { MerkleTreeCheckpointOperations } from '@aztec/stdlib/interfaces/server';

export class ForkCheckpoint {
  private completed = false;

  private readonly fork: MerkleTreeCheckpointOperations;
  public readonly depth: number;

  private constructor(fork: MerkleTreeCheckpointOperations, depth: number) {
    this.fork = fork;
    this.depth = depth;
  }

  static async new(fork: MerkleTreeCheckpointOperations): Promise<ForkCheckpoint> {
    const depth = await fork.createCheckpoint();
    return new ForkCheckpoint(fork, depth);
  }

  async commit(): Promise<void> {
    if (this.completed) {
      return;
    }

    await this.fork.commitCheckpoint();
    this.completed = true;
  }

  async revert(): Promise<void> {
    if (this.completed) {
      return;
    }

    await this.fork.revertCheckpoint();
    this.completed = true;
  }

  /**
   * Reverts this checkpoint and any nested checkpoints created on top of it,
   * leaving the checkpoint depth at the level it was before this checkpoint was created.
   */
  async revertToCheckpoint(): Promise<void> {
    if (this.completed) {
      return;
    }

    await this.fork.revertAllCheckpointsTo(this.depth - 1);
    this.completed = true;
  }
}
