// M36 — THE BOUNDARY, STATED IN THE RUNTIME AND NOT ONLY IN A DOCUMENT.
//
// ===========================================================================================
// WHAT THE EIGHT NOTE-DISCOVERY ORACLES ACTUALLY SERVE
// ===========================================================================================
//
// `getNotes`, `getPendingTaggedLogsV2`, `getLogsByTagV2`, `validateAndStoreEnqueuedNotesAndEvents`
// and the four tagging oracles are ARCHIVER-SHAPED queries: on a real network a PXE answers them by
// syncing an archive it did not produce, over an `AztecNode` client, from blocks somebody else
// built. **This runtime answers them from the dev node's OWN history, which it has in full because
// it produced every block.**
//
// That is a genuinely different claim, and the difference is not a detail:
//
//   * a self-produced chain has NO REORGS, so a note is never de-nullified and the block-hash
//     bookkeeping upstream's `NoteDao` carries for exactly that case is unexercised here;
//   * a self-produced chain has NO FOREIGN LOGS, so every tag in the index was emitted by a
//     transaction this process sealed;
//   * there is NO ARCHIVER CLIENT and no L1 — a block number this node did not produce is
//     `LocalHistoryOnly`, refused BY NAME, rather than fetched;
//   * and so nothing here demonstrates that a real-chain sync works. **That is the separate L0/L1
//     live-chain-replay track's job**, and this file exists so that nobody reads M36's green checks
//     as evidence for it.
//
// `LOCAL-HISTORY.md` says the same thing where a reader arrives first, and
// `verify_local_history_boundary_declared` asserts that BOTH say it — the document AND this module —
// because the milestone's own words are *"the claim is asserted rather than only written"*.
//
// THE DECLARATION IS ONE STRING AND EVERY CONSUMER READS IT FROM HERE. A sentence copied into a
// document, a refusal message and a check is three things to keep in step, which is the family
// `CAMPAIGN-BRIEF.md` calls *"a correction filed in a neighbouring file is not a correction"*. The
// document quotes this constant, the refusal carries it, and the check compares them.

/** The one sentence. Quoted by `LOCAL-HISTORY.md`, carried by `LocalHistoryOnly`, compared by the check. */
export const LOCAL_HISTORY_BOUNDARY =
  'these queries serve a chain this node PRODUCED, not a chain it SYNCED: there is no archiver ' +
  'client, no L1 and no reorg handling, and a block this node did not produce is refused by name ' +
  'rather than fetched';

/** The short name a reader greps for. */
export const LOCAL_HISTORY_BOUNDARY_LABEL = 'local-history-only';

/**
 * Raised when something asks this wallet about history the dev node did not produce.
 *
 * **A REFUSAL AND NEVER AN EMPTY RESULT.** An archiver-shaped query answered with `[]` over a block
 * range this node never had is indistinguishable from the same query answered over a range that
 * genuinely held nothing — and the first is a missing capability while the second is a fact about
 * the chain. This campaign's oldest rule, applied to a range instead of to an oracle.
 */
export class LocalHistoryOnly extends Error {
  constructor(
    readonly what: string,
    readonly requested: string,
    readonly available: string,
  ) {
    super(
      `LocalHistoryOnly: ${what} asked for ${requested}, and this wallet's block source holds ${available}. ` +
        `${LOCAL_HISTORY_BOUNDARY}. Real-chain sync is a separate milestone and needs an archiver client.`,
    );
    this.name = 'LocalHistoryOnly';
  }
}
