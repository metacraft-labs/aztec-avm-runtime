// frame_fold.ts — WHICH SUBTREES OF THE NOIR CALL TREE START FOLDED.
//
// ===============================================================================================
// THIS IS A VIEW CONCERN AND IT IS NOT APPLIED WHEN RECORDING. THAT IS THE WHOLE POINT.
//
// A trace of an Aztec public function spends a large share of its steps inside poseidon2 — on the
// campaign's published snapshot, 28 of the 86 positioned steps, which is a third of everything the
// reader is shown, for a hash. The tree is more legible with that subtree closed.
//
// There are two ways to get there and they are not variations on one idea:
//
//   * ELIDE AT RECORD TIME — leave the frames out of the container. The trace then no longer says
//     what executed, and no reader, on any day, with any flag, can get it back. It is a lie of
//     omission baked into the bytes.
//
//   * FOLD AT RENDER TIME — record every frame, and let the default VIEW show one of them closed.
//     The frame is present, named, at its real depth, with its real child count. A reader who wants
//     the inside opens it, with the same gesture that opens any other node in any other tree.
//
// The second is strictly better and is what this module specifies. A collapsed frame is PRESENT,
// not absent: there is nothing to signal, nothing to apologise for, and no marker standing in for
// something missing, because nothing is missing. `folded` is a state readers already understand.
//
// So `recording.ts` and `ct_download.ts` write EVERY frame they derive, and nothing in this file is
// called from either. What lives here is the predicate a renderer applies afterwards.
//
// ===============================================================================================
// THE RULE IS NAMED, NOT THE INSTANCE.
//
// `name === 'poseidon2_hash'` would be the brittle version: it would break on a rename, miss
// `poseidon2_permutation` beside it, and say nothing about the next primitive that swamps a trace.
// The class these frames actually belong to is CODE THE CONTRACT AUTHOR DID NOT WRITE — the Noir
// standard library, and crates vendored in through `nargo`. Read against the published snapshot's
// twelve interned paths, that predicate selects `std/hash/mod.nr` and
// `nargo/github.com/noir-lang/poseidon/v0.3.0/src/poseidon2.nr` — which between them carry exactly
// the 28 poseidon2 steps — plus `std/cmp.nr`, `std/option.nr` and `std/ops/arith.nr`, another 7
// steps of operator and Option machinery that are noise for the same reason.
//
// It deliberately does NOT fold `aztec_sublib`, `noir-protocol-circuits` or the contract itself:
// those are Aztec's own code and are what a reader is usually looking at.
//
// Every rule carries an `id` and a `why`, and `foldRuleFor` returns the RULE rather than a boolean,
// so a renderer can show WHICH rule folded a given frame and a reader is never left guessing why a
// node came up closed. Extending the policy is adding an entry to one array in one file.

/** One reason a frame's subtree starts folded. */
export interface FoldRule {
  /** Stable identifier, for a renderer to attribute a fold to. */
  readonly id: string;
  /** Why this class of code is folded by default, in a sentence a reader can be shown. */
  readonly why: string;
  /** Does this rule claim a frame whose source file is `path`? */
  readonly matches: (path: string) => boolean;
}

/**
 * The default policy: library code the contract author did not write.
 *
 * ORDER IS SIGNIFICANT ONLY FOR ATTRIBUTION — the first matching rule is the one reported. A frame
 * matched by no rule is not folded.
 */
export const DEFAULT_FOLD_RULES: readonly FoldRule[] = [
  {
    id: 'noir-stdlib',
    why: "Noir's standard library — hashing, comparison, Option and operator machinery that the "
      + 'contract calls but does not contain',
    // `std/…` is how Noir spells its own library in a `file_map`, with no leading slash and no
    // package prefix. Anchored, so a contract at `…/my_std/…` is not swept up by a substring test.
    matches: (path) => path.startsWith('std/'),
  },
  {
    id: 'vendored-crate',
    why: 'a third-party crate vendored in through nargo — poseidon2 is here, and it is the single '
      + 'largest consumer of steps in a typical Aztec public call',
    // `/home/aztec-dev/nargo/github.com/noir-lang/poseidon/v0.3.0/src/poseidon2.nr` and its
    // siblings. The `/nargo/` segment is nargo's own dependency cache and is what makes a file
    // third-party regardless of which host or version it was fetched from.
    matches: (path) => path.includes('/nargo/'),
  },
];

/**
 * The rule that folds a frame in this file, or `null` when none does.
 *
 * Pass `rules: []` to turn folding off entirely. **A DEFAULT THAT CANNOT BE TURNED OFF IS NOT A
 * DEFAULT**, and the gate asserts both directions: with the rules, the hash internals are folded
 * away and the folding frame is still there with its count; without them, every function the
 * recorder wrote appears.
 */
export function foldRuleFor(
  path: string,
  rules: readonly FoldRule[] = DEFAULT_FOLD_RULES,
): FoldRule | null {
  for (const rule of rules) {
    if (rule.matches(path)) return rule;
  }
  return null;
}

/** A node of a Noir call tree, as a renderer holds it. */
export interface FrameNode {
  readonly name: string;
  /** The source file this frame's code is in. */
  readonly path: string;
  /**
   * Steps recorded directly in this frame, not counting its children's. Optional because a caller
   * that only wants the shape need not count them; supplied, it is what lets a folded node tell the
   * reader the SIZE of what they would be opening — "28 steps" rather than "2 frames", which is the
   * number that actually says how much of the trace is behind the triangle.
   */
  readonly steps?: number;
  readonly children: readonly FrameNode[];
}

/** What a reader is shown for one frame under a fold policy. */
export interface FoldedView {
  readonly name: string;
  readonly path: string;
  /**
   * `null` when the frame is expanded — `children` then holds the rendered subtree. When the frame
   * is FOLDED this names the rule, `children` is empty, and `hiddenDescendants` says how many
   * frames are inside it.
   */
  readonly foldedBy: string | null;
  /** Frames inside a folded node. `0` for an expanded one. */
  readonly hiddenDescendants: number;
  /** Steps inside a folded node, its own included. `0` for an expanded one, and `0` when the
   *  caller supplied no step counts. */
  readonly hiddenSteps: number;
  readonly children: readonly FoldedView[];
}

/**
 * Apply a fold policy to a tree.
 *
 * A folded frame KEEPS ITS PLACE: same name, same depth, same position among its siblings. Only its
 * children stop being rendered, and the count of what is inside it is carried so the reader can see
 * the size of what they would be opening. The fold applies at the OUTERMOST matching frame — once a
 * subtree is closed there is no reason to walk inside it looking for more reasons to close it.
 *
 * **A FRAME WITH NO CHILDREN IS NEVER MARKED FOLDED**, however well it matches. Folding is a claim
 * that there is something inside, and a leaf reported as folded would put a disclosure triangle on
 * an empty subtree — a reader opens it and nothing happens. `std/cmp.nr`'s `derive_eq` is the case
 * that showed this: it matches `noir-stdlib` and it is a leaf, and calling it folded would be
 * telling the reader something is hidden when nothing is.
 */
export function foldTree(
  nodes: readonly FrameNode[],
  rules: readonly FoldRule[] = DEFAULT_FOLD_RULES,
): FoldedView[] {
  const countFrames = (n: FrameNode): number =>
    n.children.reduce((acc, c) => acc + 1 + countFrames(c), 0);
  const countSteps = (n: FrameNode): number =>
    (n.steps ?? 0) + n.children.reduce((acc, c) => acc + countSteps(c), 0);
  return nodes.map((n) => {
    const rule = n.children.length > 0 ? foldRuleFor(n.path, rules) : null;
    if (rule !== null) {
      return {
        name: n.name,
        path: n.path,
        foldedBy: rule.id,
        hiddenDescendants: countFrames(n),
        hiddenSteps: countSteps(n),
        children: [],
      };
    }
    return {
      name: n.name,
      path: n.path,
      foldedBy: null,
      hiddenDescendants: 0,
      hiddenSteps: 0,
      children: foldTree(n.children, rules),
    };
  });
}
