#!/usr/bin/env bash
# lib_l5_artifacts.sh — shared by L5's checks (Aztec-Live-Chain-Replay).
#
# Not to be executed directly: sourced by verification/*artifact*.sh and *source_level*.sh.
#
# ─────────────────────────────────────────────────────────────────────────────
# L5's TWO ARMS RUNS, AND WHY THEY ARE TWO.
#
#   `run_l5_artifact_arms.mjs`    the RESOLVER. No wasm, no writer, no container — just artifacts,
#                                 classes and three hashes. It answers "is this artifact the one the
#                                 chain committed to", which is a question about cryptography.
#   `run_l5_recording_arms.mjs`   the WIRING. Real `CtWriter`, real `buildSettledRecording`, four
#                                 containers. It answers "does a proved artifact reach the
#                                 declaration and the steps", which is a question about this code.
#
# Splitting them is not tidiness. The first needs no build at all and therefore cannot be made to
# `die` by a missing wasm; folding it into the second would put the campaign's central measurement
# behind a toolchain, and a check that dies before printing its summary reads as a SMALLER milestone
# rather than a red one.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOTH ARE OFFLINE, AND THE ONE THAT IS NOT IS A SEPARATE RECIPE THAT SAYS SO.
#
# The classes come from `replay/fixtures/chain_contract_classes.json` — captured from both live
# chains through `getContract` + `getContractClass`, with the date in it — and the artifacts come
# from the installed `@aztec/protocol-contracts`. The measurements that genuinely need a network
# (npm's other releases, and Aztecscan's two key shapes) live in
# `verify_l5_artifact_sources_live.sh`, which is NOT summed into the floor. `verify-l1`'s header
# states the rule: a check that needs a live third party is a check that goes red on somebody
# else's schedule.

set -uo pipefail

L5_WORK="${L5_WORK:-$HOME/.cache/aztec-l5-artifacts}"
L5_FIXTURE="$REPO_ROOT/replay/fixtures/chain_contract_classes.json"
L5_RESOLVER_ARMS="$L5_WORK/resolver-arms.json"
L5_RECORDING_ARMS="$L5_WORK/recording-arms.json"
L5_ARMS_TIMEOUT="${L5_ARMS_TIMEOUT:-600}"
export L5_WORK L5_FIXTURE L5_RESOLVER_ARMS L5_RECORDING_ARMS L5_ARMS_TIMEOUT

# The modules L5 added, named as a SET so a check asserts the set rather than whichever files
# happen to exist. `verify_no_pipeline_predicates`'s sibling rule: a scanner over a glob is a
# scanner that reports a moved file as a clean tree.
L5_SOURCES=(artifact_resolution.ts artifact_providers.ts)
L5_TOOL_SOURCES=(artifact_sources.mjs await_resolvable_transaction.mjs)
L5_ARM_RUNNERS=(run_l5_artifact_arms.mjs run_l5_recording_arms.mjs)
export L5_SOURCES L5_TOOL_SOURCES L5_ARM_RUNNERS

l5_prepare() {
  local f
  mkdir -p "$L5_WORK" || die "could not create $L5_WORK"
  for f in "${L5_SOURCES[@]}"; do
    assert_file "L5's source $f" "$REPO_ROOT/replay/src/$f"
    assert_true "…and $f is TRACKED" \
      git -C "$REPO_ROOT" ls-files --error-unmatch "replay/src/$f"
  done
  for f in "${L5_TOOL_SOURCES[@]}"; do
    assert_file "L5's tool $f" "$REPO_ROOT/replay/tools/$f"
    assert_true "…and $f is TRACKED" \
      git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/$f"
  done
  for f in "${L5_ARM_RUNNERS[@]}"; do
    assert_file "L5's arms runner $f" "$REPO_ROOT/tools/$f"
  done
  assert_file "the contract-class fixture, captured from the live chains" "$L5_FIXTURE"
  assert_true "…and it is TRACKED" \
    git -C "$REPO_ROOT" ls-files --error-unmatch "replay/fixtures/chain_contract_classes.json"

  # NEITHER `replay/src` FILE MAY READ A FILE OR REACH `node:`. L4 bundles this directory into a
  # browser page and `verify_browser_replay_dd9_clean` walks the graph of what it built, so a
  # `node:fs` import here is a build failure four layers from the line that caused it. Asserted
  # over the SET above, and asserted NON-EMPTY first, which is trap 4's rule.
  assert_ge "the L5 source set is non-empty before anything is asserted about its contents" 2 \
    "${#L5_SOURCES[@]}"
  for f in "${L5_SOURCES[@]}"; do
    assert_eq "…and $f imports no node: builtin, so L4's browser bundle still builds" "0" \
      "$(grep -c "from 'node:" "$REPO_ROOT/replay/src/$f" || true)"
  done
}

# l5_require_resolver_arms — run the resolver arms if anything they read is newer than their output.
l5_require_resolver_arms() {
  local stale=0 src
  if [ ! -f "$L5_RESOLVER_ARMS" ]; then
    stale=1
  else
    for src in "$REPO_ROOT/tools/run_l5_artifact_arms.mjs" \
               "$REPO_ROOT/replay/src/artifact_resolution.ts" \
               "$REPO_ROOT/replay/src/artifact_providers.ts" \
               "$REPO_ROOT/replay/tools/artifact_sources.mjs" \
               "$REPO_ROOT/ct-host/src/source_map.ts" "$L5_FIXTURE"; do
      [ -f "$src" ] || continue
      [ "$src" -nt "$L5_RESOLVER_ARMS" ] && stale=1
    done
  fi
  if [ "$stale" = 1 ]; then
    timeout "$L5_ARMS_TIMEOUT" node --experimental-strip-types \
      "$REPO_ROOT/tools/run_l5_artifact_arms.mjs" "$L5_FIXTURE" \
      >"$L5_RESOLVER_ARMS.tmp" 2>"$L5_WORK/resolver-arms.log" \
      || { cat "$L5_WORK/resolver-arms.log" >&2
           die "tools/run_l5_artifact_arms.mjs failed; log at $L5_WORK/resolver-arms.log"; }
    mv "$L5_RESOLVER_ARMS.tmp" "$L5_RESOLVER_ARMS"
  fi
  [ -s "$L5_RESOLVER_ARMS" ] || die "the resolver arms run produced no $L5_RESOLVER_ARMS"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$L5_RESOLVER_ARMS" >/dev/null 2>&1 \
    || die "$L5_RESOLVER_ARMS is not valid JSON — the run was interrupted; delete it and re-run"
}

# l5_require_recording_arms — same, plus the writer module, which is a `die` and never a skip.
l5_require_recording_arms() {
  local stale=0 src
  L5_CT_WRITER="$(l3_find_ct_writer)"
  export L5_CT_WRITER
  if [ ! -f "$L5_RECORDING_ARMS" ]; then
    stale=1
  else
    for src in "$REPO_ROOT/tools/run_l5_recording_arms.mjs" \
               "$REPO_ROOT/replay/src/artifact_resolution.ts" \
               "$REPO_ROOT/replay/src/artifact_providers.ts" \
               "$REPO_ROOT/replay/src/recording.ts" \
               "$REPO_ROOT/replay/tools/artifact_sources.mjs" \
               "$REPO_ROOT/ct-host/src/source_map.ts" "$REPO_ROOT/ct-host/src/writer.ts" \
               "$L5_CT_WRITER" "$L5_FIXTURE"; do
      [ -f "$src" ] || continue
      [ "$src" -nt "$L5_RECORDING_ARMS" ] && stale=1
    done
  fi
  L5_CONTAINERS="$L5_WORK/containers"
  export L5_CONTAINERS
  if [ "$stale" = 1 ]; then
    rm -rf "$L5_CONTAINERS"
    mkdir -p "$L5_CONTAINERS" || die "could not create $L5_CONTAINERS"
    timeout "$L5_ARMS_TIMEOUT" node --experimental-strip-types \
      "$REPO_ROOT/tools/run_l5_recording_arms.mjs" "$L5_CT_WRITER" "$L5_FIXTURE" "$L5_CONTAINERS" \
      >"$L5_RECORDING_ARMS.tmp" 2>"$L5_WORK/recording-arms.log" \
      || { cat "$L5_WORK/recording-arms.log" >&2
           die "tools/run_l5_recording_arms.mjs failed; log at $L5_WORK/recording-arms.log"; }
    mv "$L5_RECORDING_ARMS.tmp" "$L5_RECORDING_ARMS"
  fi
  [ -s "$L5_RECORDING_ARMS" ] || die "the recording arms run produced no $L5_RECORDING_ARMS"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$L5_RECORDING_ARMS" >/dev/null 2>&1 \
    || die "$L5_RECORDING_ARMS is not valid JSON — the run was interrupted; delete it and re-run"
}

# l5_arm <arms-file> <python-expression-over-`d`> — one value, or the loud string `MISSING`.
#
# `MISSING` rather than an empty string, because `assert_eq "" ""` passes and an empty haystack
# turns every comparison beneath it into an assertion about nothing.
l5_arm() { # <file> <expr>
  python3 - "$1" "$2" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    v = eval(sys.argv[2], {"d": d, "len": len, "sorted": sorted, "sum": sum, "str": str,
                           "set": set, "any": any, "all": all})
except Exception:
    print("MISSING"); raise SystemExit(0)
if v is None:
    print("MISSING")
elif isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, (list, tuple)):
    print(",".join(str(x) for x in v))
else:
    print(v)
PY
}

l5_res() { l5_arm "$L5_RESOLVER_ARMS" "$1"; }
l5_rec() { l5_arm "$L5_RECORDING_ARMS" "$1"; }
