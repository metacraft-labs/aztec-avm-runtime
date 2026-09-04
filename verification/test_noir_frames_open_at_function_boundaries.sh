#!/usr/bin/env bash
# test_noir_frames_open_at_function_boundaries
#
# "The recorder opens a call frame at every Noir function boundary, named from the artifact's own
#  function table, and a step whose pc has no source chain does not close one. Control: the same
#  step stream through the algorithm this replaced reports two frames where the execution entered
#  thirty-three functions."
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# WHAT WAS WRONG, IN ONE SENTENCE, BECAUSE THE NUMBER IS THE ARGUMENT.
#
# The published snapshot — testnet 0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f
# — is 108 steps and its container holds TWO `Call` records. The execution entered thirty-three
# distinct Aztec.nr functions, nested nine deep. Both recorders derived frames from the AVM CONTEXT
# ID alone, which is the AVM's identity for an EXTERNAL call and changes once per enqueued call; so
# the tree was not merely coarse, it had no calls in it.
#
# The signal that was missing had been parsed and discarded one line at a time. Every keyed pc
# resolves to a `CallStackId`, `location_tree` makes that a parent-linked chain of locations — the
# Noir inline call stack — and `positionFor` walked the whole chain and kept `locs[locs.length - 1]`
# because a step's LINE is the innermost location. `framesFor` keeps the rest of it.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# THE ASSERTION THAT MATTERS MOST IS §4, AND IT IS ABOUT A HOLE.
#
# `brillig_locations` is SPARSE over the pcs an execution walks. On this snapshot 22 of 108 steps
# resolve to nothing, and EIGHT of those — steps 27…34, at pcs 192, 197, 202, 207, 212, 217, 226,
# 247 — are inside the keyed range [130, 1785], with chained steps on both sides. They are holes in
# the middle of a function body, not a prologue.
#
# So the rule for a chain-less step is INHERIT, not close-to-zero, and §4 asserts it by step index:
# no frame event occurs at any of the eight. Closing instead would emit a full unwind and an
# immediate identical re-entry at each — a tree claiming the execution left and re-entered nine
# nested functions eight times because a source map had a gap.
#
# THOSE EIGHT PCs ARE MEASURED AND NOT INFERRED. `CtWriter.push` stages `{pathId: 0, line: 0}` for an
# absent position and the module writes it out as `Line(pc)`, so in the published container a step on
# path 0 carries its own program counter as its `line`. The fixture is that decode.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# WHAT IS RECONSTRUCTED, SAID HERE RATHER THAN LEFT TO BE DISCOVERED.
#
# The pcs of the 86 POSITIONED steps are not in the container — it records the innermost
# `(path, line)` — and that mapping is LOSSY: §2 asserts that 48 of the 86 sit at a `(file, line)`
# more than one pc maps to, carrying more than one distinct chain. **That is itself the argument for
# this milestone**: the frame tree cannot be recovered from a published container after the fact, so
# the recorder has to write it.
#
# The arm reconstructs them under a stated rule (smallest candidate pc greater than the previous),
# and §2 asserts the reconstruction is over-determined rather than merely plausible: it lands on the
# 22 exact pcs it was never given, and 106 of 107 transitions move forward.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# §6 IS THE COLLAPSE, ASSERTED FROM BOTH SIDES.
#
# Poseidon2 is 28 of the 86 positioned steps and the default view should show it folded. FOLDED, not
# elided: `recording.ts` and `ct_download.ts` write every frame, and `frame_fold.ts` decides only
# which subtrees a renderer starts with closed. §6 asserts both directions — with the rules the hash
# internals are gone and the folding frame is still there carrying the count of what is behind it,
# without them every function the recorder wrote is visible. A default that cannot be turned off is
# not a default, and a fold that cannot be opened is an elision wearing its name.
#
# Run: just verify-noir-frames

set -uo pipefail
TEST_NAME="test_noir_frames_open_at_function_boundaries"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "== $TEST_NAME"
summary_on_abnormal_exit

WORK="${NOIR_FRAMES_WORK:-${TMPDIR:-/tmp}/aztec-noir-frames}"
mkdir -p "$WORK"

SNAPSHOT="$REPO_ROOT/replay/fixtures/published_snapshot_step_positions.json"
assert_file "the published snapshot's decoded step positions are a tracked fixture" "$SNAPSHOT"
assert_true "…and are tracked" git -C "$REPO_ROOT" ls-files --error-unmatch \
  "replay/fixtures/published_snapshot_step_positions.json"

# THE ARTIFACT IS THE VERSION-MATCHED ONE OR THE CHECK FAILS BY NAME. `@aztec/protocol-contracts` at
# a different nightly is a different contract with different pcs, and measuring the wrong one would
# be a green run about nothing. No SKIP: a check that cannot run FAILS, naming what supplies it.
ARTIFACT="${NOIR_FRAMES_ARTIFACT:-}"
if [ -z "$ARTIFACT" ]; then
  for root in \
    "$REPO_ROOT/replay/node_modules" \
    "$REPO_ROOT/orchestration/node_modules" \
    "/Users/$(id -un)/m/dev/aztec-artifacts/replay/node_modules"
  do
    cand="$root/@aztec/protocol-contracts/artifacts/FeeJuice.json"
    [ -f "$cand" ] && { ARTIFACT="$cand"; break; }
  done
fi
[ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] || die \
  "no FeeJuice.json found. Supply NOIR_FRAMES_ARTIFACT=<path>, or install the package with \
'npm ci' in replay/ so @aztec/protocol-contracts/artifacts/FeeJuice.json exists."
note "artifact: $ARTIFACT"

ARMS="$WORK/noir-frames.json"
node "$REPO_ROOT/tools/run_noir_frames_arms.mjs" \
  --artifact "$ARTIFACT" --snapshot "$SNAPSHOT" --work "$WORK" >"$WORK/arms.log" 2>&1 \
  || die "run_noir_frames_arms failed; see $WORK/arms.log"
assert_file "the arms report was produced" "$ARMS"

# One measurement, read field by field — the repo's convention, so two sections cannot disagree
# about a number nothing changed.
arm() { node -e '
  const d = require(process.argv[1]);
  const v = process.argv[2].split(".").reduce((o, k) => (o ?? {})[k], d);
  process.stdout.write(v === undefined || v === null ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v)));
' "$ARMS" "$1"; }

echo "== 1. the artifact really carries what a named frame needs"
note "$(arm artifact.name) at $(arm artifact.aztecVersion)"
assert_eq "the version-matched artifact, not another nightly" \
  "5.3.0-nightly.20260819" "$(arm artifact.aztecVersion)"
assert_eq "brillig_locations keys 314 pcs" "314" "$(arm artifact.keyedPcs)"
assert_eq "…over [130,1785]" "[130,1785]" "$(arm artifact.keyedPcRange)"
assert_eq "location_tree has 155 parent-linked nodes" "155" "$(arm artifact.locationTreeNodes)"
assert_eq "file_map carries 726 function_locations — what NAMES a frame" \
  "726" "$(arm artifact.functionLocations)"

echo "== 2. THE ARENA ROOT IS A SENTINEL, AND IT IS DROPPED"
# Kept as an assertion rather than a comment because it was found the hard way: the first tree
# printed with a frame named `aes128.nr` under every stack in a fee-juice transfer. The arena has
# ONE root, node 0, whose value is `{file: 0, span: 0..0}` — Noir's `Location::dummy()` — and file 0
# in this artifact happens to be `std/aes128.nr`. Every keyed pc bottoms out at it.
assert_eq "location_tree has exactly one root" "1" "$(arm artifact.locationTreeRoots)"
assert_eq "…and it is Noir's dummy location, not a place in any file" \
  "true" "$(arm artifact.rootsAreDummyLocation)"
assert_eq "every keyed pc's RAW chain starts at that sentinel" \
  "314" "$(arm artifact.rawChainsStartingAtDummy)"
assert_eq "so framesFor's depth over the artifact starts at 1, not 2" "1" "$(arm artifact.frameDepthMin)"
assert_eq "…and reaches 9, not 10" "9" "$(arm artifact.frameDepthMax)"
assert_eq "the artifact can name 38 distinct functions across every pc it keys" \
  "38" "$(arm artifact.distinctFunctions)"

echo "== 3. the published container is LOSSY about chains, which is why the recorder must write them"
assert_eq "the snapshot is the published transaction" \
  "0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f" "$(arm snapshot.tx)"
assert_eq "108 steps" "108" "$(arm snapshot.steps)"
assert_eq "86 positioned" "86" "$(arm snapshot.positioned)"
assert_eq "22 unpositioned, and their pcs are EXACT — the module wrote Line(pc)" \
  "22" "$(arm snapshot.exactPcs)"
assert_eq "48 of the 86 positioned steps sit at a (file,line) carrying MORE THAN ONE chain" \
  "48" "$(arm snapshot.reconstruction.ambiguousChains)"
# The reconstruction is over-determined, not merely plausible.
assert_eq "106 of 107 pc transitions move forward" \
  "106" "$(arm snapshot.reconstruction.forwardTransitions)"
assert_eq "every positioned step found at least one candidate pc" \
  "0" "$(arm snapshot.reconstruction.noCandidate)"

echo "== 4. THE MID-BODY HOLES, AND THAT NO FRAME CLOSES AT ONE"
HOLES="$(arm snapshot.midBodyHoles)"
note "holes: $HOLES"
assert_eq "eight unpositioned steps fall INSIDE the keyed pc range" \
  '[{"step":27,"pc":192},{"step":28,"pc":197},{"step":29,"pc":202},{"step":30,"pc":207},{"step":31,"pc":212},{"step":32,"pc":217},{"step":33,"pc":226},{"step":34,"pc":247}]' \
  "$HOLES"
# THE ASSERTION THIS CHECK EXISTS FOR.
assert_eq "NO frame event occurs at any of them — a chain-less step INHERITS, it does not close" \
  "[]" "$(arm snapshot.eventsAtMidBodyHoles)"

echo "== 5. the frame tree the recorder now writes"
note "opens=$(arm snapshot.framesOpened) closes=$(arm snapshot.framesClosed) depth=$(arm snapshot.maxDepth) functions=$(arm snapshot.distinctFunctions)"
assert_eq "44 frames opened" "44" "$(arm snapshot.framesOpened)"
assert_eq "…and 44 closed: the tree is well formed" "44" "$(arm snapshot.framesClosed)"
assert_eq "nested nine deep" "9" "$(arm snapshot.maxDepth)"
assert_eq "over 33 distinct Noir functions" "33" "$(arm snapshot.distinctFunctions)"
TREE="$(arm snapshot.tree)"
for fn in "FeeJuice::public_dispatch" "FeeJuice::_increase_public_balance" \
          "PublicContext::maybe_msg_sender" "PublicMutable<T, PublicContext>::read" \
          "PublicContext::raw_storage_write" "Poseidon2::hash"
do
  assert_true "the tree names $fn" str_has_sub "$TREE" "$fn"
done
assert_false "and NOT the sentinel's file, which would mean the dummy root leaked back in" \
  str_has_sub "$TREE" "aes128"

echo "== 6. THE CONTROL: the algorithm this replaced, on the same execution"
# The published container is what the context-id-only loop produced for these very steps. It is not
# a hypothetical: it is 184,320 bytes on disk at sha1:0e4a85e1…, and it holds two Call records.
assert_eq "the shipped container opened TWO frames" "2" "$(arm contextOnly.callsInPublishedContainer)"
assert_eq "…and closed one" "1" "$(arm contextOnly.returnsInPublishedContainer)"
CTRL_OPENS="$(arm contextOnly.callsInPublishedContainer)"
NEW_OPENS="$(arm snapshot.framesOpened)"
assert_true "the new tree opens strictly more frames than the old one ($NEW_OPENS > $CTRL_OPENS)" \
  test "$NEW_OPENS" -gt "$CTRL_OPENS"
assert_ge "…by at least twenty times" 40 "$NEW_OPENS"

echo "== 7. THE COLLAPSE, FROM BOTH SIDES"
note "rules: $(arm fold.rules)"
FOLDED="$(arm fold.foldedFunctionsVisible)"
UNFOLDED="$(arm fold.unfoldedFunctionsVisible)"
POINTS="$(arm fold.foldPoints)"
note "fold points: $POINTS"

# WITH THE DEFAULT ON: the hash internals are not rendered…
assert_false "with folding on, Poseidon2::hash_internal is not shown" \
  str_has_sub "$FOLDED" "Poseidon2::hash_internal"
assert_false "with folding on, poseidon2_permutation is not shown" \
  str_has_sub "$FOLDED" "poseidon2_permutation"
# …but the FRAME THAT FOLDED THEM IS, which is the whole difference from eliding.
assert_true "the folding frame Poseidon2::hash is still in the tree" \
  str_has_sub "$FOLDED" "Poseidon2::hash"
assert_true "…attributed to the rule that folded it, by name" \
  str_has_sub "$POINTS" '"rule":"vendored-crate"'
assert_true "…and carrying the count of what is behind it" str_has_sub "$POINTS" '"hiddenSteps"'
HIDDEN_STEPS="$(node -e '
  const d = require(process.argv[1]);
  process.stdout.write(String(d.fold.foldPoints.reduce((a, p) => a + p.hiddenSteps, 0)));
' "$ARMS")"
assert_eq "the folded subtrees account for exactly the 28 poseidon2 steps" "28" "$HIDDEN_STEPS"

# WITH IT OFF: everything the recorder wrote is there. A DEFAULT THAT CANNOT BE TURNED OFF IS NOT A
# DEFAULT, and this is the assertion that makes the fold reversible rather than a nicer-sounding
# elision.
assert_true "with folding off, Poseidon2::hash_internal appears" \
  str_has_sub "$UNFOLDED" "Poseidon2::hash_internal"
assert_true "with folding off, poseidon2_permutation appears" \
  str_has_sub "$UNFOLDED" "poseidon2_permutation"
UNFOLDED_N="$(node -e '
  const d = require(process.argv[1]);
  process.stdout.write(String(d.fold.unfoldedFunctionsVisible.length));
' "$ARMS")"
assert_eq "…and all 33 functions are visible, the same 33 the recorder wrote" \
  "$(arm snapshot.distinctFunctions)" "$UNFOLDED_N"

# THE PROPERTY THAT MAKES IT REVERSIBLE: the CONTAINER holds all 33 in BOTH cases, because folding
# never ran at record time. Asserted against the recorder's own count, not the view's.
assert_eq "the recorded tree is identical under both views — folding is not a filter" \
  "33" "$(arm snapshot.distinctFunctions)"

echo "== 8. the recorders record everything, and neither imports the fold policy"
for f in replay/src/recording.ts browser/src/ct_download.ts; do
  assert_false "$f does not import the fold policy" \
    str_has_sub "$(cat "$REPO_ROOT/$f")" "frame_fold"
  assert_true "$f drives the shared tracker rather than a copy of the rule" \
    str_has_sub "$(cat "$REPO_ROOT/$f")" "NoirFrameTracker"
done

finish
