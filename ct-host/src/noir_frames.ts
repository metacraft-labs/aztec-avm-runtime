// noir_frames.ts — OPENING AND CLOSING NOIR FUNCTION FRAMES AS A STEP STREAM MOVES.
//
// ===============================================================================================
// WHY THIS IS A MODULE AND NOT A LOOP INSIDE EACH RECORDER.
//
// There are two recorders — `replay/src/recording.ts` for a settled chain transaction and
// `browser/src/ct_download.ts` for a transaction executed in a page — and before this file they
// carried two copies of the same frame loop, both driven off the AVM context id alone. Two copies
// of a rule is two places for it to drift, and the interesting rule here (what to do with a step
// that has no source chain) is one sentence that has to be the same sentence in both. So the rule
// lives here, once, and both recorders drive it.
//
// ===============================================================================================
// THE RULE.
//
// Per step the caller supplies the Noir inline call stack for that step's pc, outermost first, as
// `ContractSourceMap.framesFor` returns it — or `null` when the pc has no chain.
//
//   * WITH A CHAIN: diff it against the open stack by LONGEST COMMON PREFIX of frame KEYS. Close
//     the divergent suffix, then open the rest. A frame key is the CONTAINING FUNCTION and not the
//     location (see `NoirFrame.key`), so moving between the statements of one function matches on
//     every frame and writes nothing — which is what makes this a call tree rather than one frame
//     per instruction.
//
//   * WITH NO CHAIN: **INHERIT.** The open stack is left exactly as it stands and neither a call
//     nor a return is written.
//
// ===============================================================================================
// THE INHERIT RULE IS THE ONE THAT NEEDED PROVING, AND HERE IS WHAT IT WAS PROVED AGAINST.
//
// It would be reasonable to guess that a step with no chain is a step outside any Noir function, and
// should therefore close to depth 0. That guess is wrong, and it is wrong in a way that only shows
// up on a real container.
//
// `brillig_locations` is SPARSE over the pcs an execution actually walks — it keys 314 pcs over
// [130, 1785] for FeeJuice, and an execution walks pcs it does not key. On the campaign's published
// snapshot (testnet 0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f, 108 steps)
// 22 steps resolve to nothing. Fourteen of those are the prologue, below the keyed range, where
// closing and inheriting agree because nothing is open yet.
//
// The other EIGHT are at pcs 192, 197, 202, 207, 212, 217, 226 and 247 — steps 27 through 34 of the
// stream, INSIDE the keyed range, with chained steps on both sides (step 26 at fee_juice main.nr
// line 223, step 35 at avm.nr line 85). They are holes in the middle of a function body, not the
// edge of one. Closing to depth 0 across them would write a full unwind and an immediate, identical
// re-entry at each: a tree asserting the execution left and re-entered its whole nested stack eight
// times in a straight-line body, because a source map had a gap. Inheriting writes nothing, which
// is what happened. `test_noir_frames_open_at_function_boundaries` asserts exactly that, by step
// index, over the published container's own pcs.
//
// ===============================================================================================
// NOTHING IS ELIDED HERE. Every frame derived is written. Which subtrees a reader sees CLOSED is a
// separate question, answered at render time by `frame_fold.ts`, and answered over a complete tree
// precisely so that it can be answered the other way.

import type { NoirFrame } from './source_map.ts';

/**
 * The part of `CtWriter` this needs. Structural, so the tracker can be driven by a recorder, by a
 * measurement arm collecting a tree in memory, or by a test double, with no writer instantiated.
 */
export interface FrameSink {
  call(
    name: string,
    opts: { pathId?: number; line?: number; contractAddress?: Uint8Array },
  ): void;
  returnFrame(): void;
}

/**
 * The open Noir stack, and the calls and returns that keep it in step with the execution.
 *
 * One tracker per AVM context is NOT required — `closeAll` is the context boundary, and the caller
 * uses it because an external call is not inside the previous call's inline stack.
 */
export class NoirFrameTracker {
  private readonly sink: FrameSink;
  private readonly open: NoirFrame[] = [];
  private opened = 0;
  private maxDepth = 0;
  private readonly names = new Set<string>();

  constructor(sink: FrameSink) {
    this.sink = sink;
  }

  /** How many Noir frames are open right now. */
  get depth(): number {
    return this.open.length;
  }

  /** Frames opened over this tracker's life. `0` means the tree has no Noir frames in it at all. */
  get framesOpened(): number {
    return this.opened;
  }

  /** The deepest the Noir stack ever got. */
  get deepest(): number {
    return this.maxDepth;
  }

  /** Distinct Noir function names written. */
  get functionNames(): ReadonlySet<string> {
    return this.names;
  }

  /**
   * Advance to a step whose chain is `frames` — or `null` for a step with no chain, which INHERITS
   * the open stack and writes nothing. See the file header for why that is the rule.
   */
  step(frames: readonly NoirFrame[] | null, contractAddress?: Uint8Array): void {
    if (frames === null) return;
    let common = 0;
    while (
      common < this.open.length
      && common < frames.length
      && this.open[common]!.key === frames[common]!.key
    ) {
      common += 1;
    }
    this.closeTo(common);
    for (let k = common; k < frames.length; k++) {
      const f = frames[k]!;
      this.sink.call(f.name, {
        pathId: f.pathId,
        line: f.line,
        ...(contractAddress !== undefined ? { contractAddress } : {}),
      });
      this.open.push(f);
      this.names.add(f.name);
      this.opened += 1;
      if (this.open.length > this.maxDepth) this.maxDepth = this.open.length;
    }
  }

  /**
   * Close every open Noir frame.
   *
   * The caller does this before leaving an AVM context and at the end of the stream, because a
   * frame cannot outlive the frame it is nested in and the container's calls have to nest.
   */
  closeAll(): void {
    this.closeTo(0);
  }

  private closeTo(depth: number): void {
    while (this.open.length > depth) {
      this.sink.returnFrame();
      this.open.pop();
    }
  }
}
