#!/usr/bin/env bash
# lib_l2_replay.sh — shared by L2's three checks (Aztec-Live-Chain-Replay).
#
# Not to be executed directly: sourced by verification/*replay*.sh.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ONE THING THAT MAKES L2'S CHECKS DIFFERENT FROM L0'S AND L1'S: THEY NEED A BUILT MODULE.
#
# L0 and L1 run entirely on TypeScript and a committed recording. L2 executes, so it needs
# `avm.wasm` — and not just any build. Two ways to have the wrong one, both of which this file
# turns into a named refusal rather than a smaller check:
#
#   * `vm2wasm/avm.wasm` is M6's early spike artefact and OWNS ITS MEMORY. `node-host`'s loader
#     refuses it by name (`AvmToolchainRegression`), because that host is for `--import-memory`
#     modules, which is how barretenberg links every wasm artefact.
#   * A build WITHOUT M9's execution-observer patch refuses the encoding with
#     "Missing field collectExecutionSteps" — DRIFT D14, recorded in `replay/src/replay_inputs.ts`.
#
# SO A MISSING MODULE IS A `die`, NEVER A SKIP. `CAMPAIGN-BRIEF.md`: "a check that dies before
# printing its summary reads as a SMALLER milestone, not a red one" — and a check that SKIPS is the
# same failure wearing a friendlier word. If L2 cannot run, that must be loud.

set -uo pipefail

# L2 GETS ITS OWN WORK DIRECTORY, for L1's reason and one more of its own.
#
# L1's header: "two milestones sharing one work directory is state you did not produce, and this
# campaign has paid for that more than once", and `require_work_dir`'s flock is per directory, so a
# separate one also means an L1 check and an L2 check can never contend for the same lock. That
# matters more here than for L1: an L2 check RUNS THE AVM and takes minutes, so it is exactly the
# kind of long holder that would block a fast L1 check behind it.
#
# It is set BEFORE the source, because `lib_l1_settled_tx.sh` reads `L1_WORK` to decide `L0_WORK`
# and `lib_l0_node_client.sh` reads `L0_WORK` at source time. Setting it afterwards would put L2's
# probes in L1's directory with every line of this comment still true and none of it in effect.
L1_WORK="${L2_WORK:-$HOME/.cache/aztec-l2-replay}"
export L1_WORK

. "$VERIFY_DIR/lib_l1_settled_tx.sh"

L2_WORK="$L0_WORK"
export L2_WORK

L2_SRC="$REPO_ROOT/replay/src"
L2_TOOLS="$REPO_ROOT/replay/tools"
L2_FIXTURE="$REPO_ROOT/replay/fixtures/testnet_replay_tx.json"
export L2_SRC L2_TOOLS L2_FIXTURE

# The modules L2 added, named so a check asserts the SET rather than whichever files exist.
L2_SOURCES=(historical_state.ts replay_execution.ts replay_inputs.ts)
L2_TOOL_SOURCES=(node_avm_host.ts replay_settled_transaction.mjs)
export L2_SOURCES L2_TOOL_SOURCES

# THE CPP ANCHOR, out of `pins.json`, for the route-disposition check. Read here so two checks
# cannot come to disagree about which upstream tree they are quoting.
l2_cpp_anchor() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
    "$REPO_ROOT/pins.json"
}

# A file at the anchor, out of the OBJECT STORE rather than out of a worktree. M22's review's rule,
# and it matters more here than usual: the two files below are the whole evidence that L2's two
# route closures are still true, and a worktree somebody rebased would quietly answer for a
# different tree.
l2_anchor_show() { # <path under the aztec-packages tree>
  git -C "$FORK_ROOT" show "$(l2_cpp_anchor):$1" 2>/dev/null
}

# l2_find_module — the built AVM, or a `die` that says how to get one.
#
# `AVM_WASM_PATH` first, so a caller with a build elsewhere is not second-guessed. Then the
# locations this repository's own recipes produce. `vm2wasm/avm.wasm` is DELIBERATELY NOT in the
# list: it is present in every checkout and it is the wrong build, so searching it would turn a
# clear refusal into a confusing one.
l2_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    [ -s "$AVM_WASM_PATH" ] || die "AVM_WASM_PATH is set to '$AVM_WASM_PATH' and there is no
     non-empty file there. A path that was set and is wrong is worse than one that was not set."
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  for candidate in \
    "$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m13-contractdb/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m18-orchestration/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m17-node-host/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  die "no built avm.wasm was found, and L2 cannot run without one — it EXECUTES, which is what
     makes it different from L0 and L1.
     This is a refusal and NOT a skip: a check that skips reads as a smaller milestone rather
     than a red one, which is this campaign's most-repeated defect wearing a friendlier word.
     Remedy: \`just ci-browser-gate\` (which builds it), or set AVM_WASM_PATH to a build that
     carries M9's execution-observer patch. \`vm2wasm/avm.wasm\` is NOT it — that is M6's spike
     artefact, it owns its memory, and node-host's loader refuses it by name."
}

l2_prepare() {
  l1_prepare

  local f
  for f in "${L2_SOURCES[@]}"; do
    assert_file "L2's source $f" "$L2_SRC/$f"
    assert_true "…and $f is TRACKED" \
      git -C "$REPO_ROOT" ls-files --error-unmatch "replay/src/$f"
  done
  for f in "${L2_TOOL_SOURCES[@]}"; do
    assert_file "L2's tool $f" "$L2_TOOLS/$f"
    assert_true "…and $f is TRACKED" \
      git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/$f"
  done
  # THE HOST IS IN `tools/` AND NOT IN `src/`, for L0's reason: it declares the msgpack SHAPES the
  # resident databases take, which are C++ struct field names, and
  # `verify_client_uses_upstream_schema` refuses a hand-built wire type inside `replay/src`.
  assert_eq "…and node_avm_host.ts is NOT in replay/src, so L0's 'no wire types here' holds" "0" \
    "$(ls -1 "$L2_SRC" | grep -c '^node_avm_host.ts$' || true)"

  assert_file "L2's own fixture" "$L2_FIXTURE"

  L2_MODULE="$(l2_find_module)"
  export L2_MODULE
  assert_file "a built avm.wasm was found, so L2 can execute at all" "$L2_MODULE"
  # It is the SHIPPED module and not M6's spike, measured by size rather than by path: the two
  # differ by ~360 KB and a path assertion would pass for any file somebody had put there.
  assert_ge "…and it is not M6's memory-owning spike artefact (that one is 1,259,737 bytes)" \
    1400000 "$(wc -c <"$L2_MODULE" | tr -d ' ')"
}

# The import prologue every L2 probe shares.
l2_imports() {
  cat <<EOF
import { readFileSync } from 'node:fs';

import {
  ANSWERABLE_TREES,
  DEFAULT_MAX_ROUNDS,
  HYDRATION_METHODS,
  HydrationDidNotConverge,
  IntraBlockPredecessorsUnavailable,
  ModuleRefusedReplay,
  PATCH_REQUIRED_CONFIG_FIELDS,
  REPLAY_COLLECTION_FLAGS,
  ROUTE_DISPOSITIONS,
  SEED_SKIP_REASONS,
  STATE_REFERENCE_TREES,
  TREE_ROOTS_DIVERGE_REASON,
  UNANSWERABLE_TREES,
  compareToPublishedEffects,
  createReplayNodeClient,
  declareTreeRoots,
  encodeReplayInputs,
  fetchSettledTransaction,
  queriesFrom,
  replaySettledTransaction,
  replaySimulatorConfig,
} from '$L2_SRC/index.ts';

import { fixtureFetch, loadSettledFixture } from '$L2_TOOLS/settled_fixture.ts';
import { createNodeAvmHost } from '$L2_TOOLS/node_avm_host.ts';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';

const line = (k, v) => console.log(\`\${k} \${v}\`);

const L2_FIXTURE_PATH = '$L2_FIXTURE';
const L2_MODULE_PATH = '$L2_MODULE';

const readL2Fixture = () =>
  loadSettledFixture(JSON.parse(readFileSync(L2_FIXTURE_PATH, 'utf8')), L2_FIXTURE_PATH);

const l2Client = (fixture) =>
  createReplayNodeClient({
    url: fixture.provenance.endpoint,
    fetchImpl: fixtureFetch(fixture),
  });

/** The fetch every L2 probe starts from, with the reference block pinned as L2 requires. */
const l2Settled = async (fixture) =>
  fetchSettledTransaction(l2Client(fixture), TxHash.fromString(fixture.provenance.txHash),
    { pinToSettlingBlock: true });

/** Reduce a thrown value to one word: its own \`kind\`, or \`foreign:<ctor>\`, or \`returned\`. */
const classify = async (label, thunk) => {
  try {
    const value = await thunk();
    line(\`\${label}.outcome\`, 'returned');
    return { outcome: 'returned', value };
  } catch (e) {
    line(\`\${label}.outcome\`, e?.kind ?? \`foreign:\${e?.constructor?.name ?? 'unknown'}\`);
    line(\`\${label}.class\`, e?.constructor?.name ?? 'none');
    return { outcome: e?.kind ?? 'threw', error: e };
  }
};
EOF
}
