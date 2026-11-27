#!/usr/bin/env bash
# lib_historical_replay.sh — which replay/ tree the Live-Chain-Replay floors execute, and the proof
# that it is the declared one.
#
# THE FLOORS GUARD THE COMMITTED v5 CORPUS ON THE PINNED HISTORICAL RUNTIME. That is the operator's
# decision of 2026-11-26 (codetracer-pm issues/2026-11-26-aztec-replay-aztec-labs-6-rename-reached-
# agents-and-breaks-the-replay-floors.md, "Decision"), and DRIFT.md D36 records the measurement that
# forces it: the working tree's `replay/` is on `@aztec-labs/*` 6.0.0, whose `BlockHeader` cannot
# decode a single fixture in `replay/fixtures/` (every one was captured from a node-5.2.0 chain).
# So the subject a floor EXECUTES — `replay/src`, `replay/tools`, its install, and the `ct-host/`,
# `node-host/` and `browser/` sources it imports by relative path — is `pins.json` →
# `historical_runtimes.replay_v5`, materialised by `tools/historical_replay.py`. The FIXTURES, the
# check logic and every other artefact (avm.wasm, ct_writer.wasm, ct-print) stay the working tree's.
#
# WHAT THIS DOES NOT COVER, SAID SO IT IS NOT DISCOVERED: the v6 `replay/` the follower ships has
# no offline floor here. A v6 floor needs fixtures captured from a v6 chain; that is follow-up work
# recorded against the campaign, not something a redirection can supply.
#
# A REDIRECTION THAT CAN SILENTLY POINT ELSEWHERE IS WORSE THAN NONE, so `historical_replay_prepare`
# asserts, on every run, that the directory IS the declared commit — every tracked blob re-hashed
# from disk against the object store, nothing untracked in the runtime source directories, and the
# install on the declared npm pin — and runs the verifier's two negative controls, so a verifier
# that answers "verified" to anything cannot pass. It never fetches or installs: a floor that is
# missing its runtime DIES naming `just materialize-historical-replay`, the recipe every floor
# recipe already depends on.
#
# `REPLAY_RUNTIME=live` (set by a caller BEFORE sourcing) keeps the working tree's `replay/`. It
# exists for the two checks that talk to a LIVE third party rather than replay the committed corpus
# (`e2e_replay_block_range`, `verify_l5_artifact_sources_live`); neither is part of the offline
# floor, and their behaviour is unchanged. `smoke_browser_shows_noir_source_lines` is not in the
# floor either, but it records the committed v5 FeeJuice artifact, so it runs the historical runtime.

REPLAY_RUNTIME="${REPLAY_RUNTIME:-historical}"
HIST_REPLAY_NAME="replay_v5"
HIST_REPLAY_TOOL="$REPO_ROOT/tools/historical_replay.py"

HIST_REPLAY_COMMIT="$(python3 - "$REPO_ROOT/pins.json" "$HIST_REPLAY_NAME" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")).get("historical_runtimes", {}).get(sys.argv[2], {})
print(d.get("commit", ""))
PY
)"
HIST_REPLAY_NPM_VERSION="$(python3 - "$REPO_ROOT/pins.json" "$HIST_REPLAY_NAME" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
d = p.get("historical_runtimes", {}).get(sys.argv[2], {})
print(p.get("npm", {}).get(d.get("npm_pin", ""), {}).get("version", ""))
PY
)"
HIST_ROOT="$(python3 "$HIST_REPLAY_TOOL" path --name "$HIST_REPLAY_NAME" 2>/dev/null)"
export HIST_REPLAY_COMMIT HIST_REPLAY_NPM_VERSION HIST_ROOT

case "$REPLAY_RUNTIME" in
  historical) REPLAY_RUNTIME_ROOT="$HIST_ROOT" ;;
  live) REPLAY_RUNTIME_ROOT="$REPO_ROOT" ;;
  *) die "REPLAY_RUNTIME is '$REPLAY_RUNTIME'; it must be 'historical' or 'live'" ;;
esac
# The replay tree the checks EXECUTE. Fixtures are NOT read from here: they are the working tree's.
REPLAY_DIR="$REPLAY_RUNTIME_ROOT/replay"
# Read by tools/run_l5_*_arms.mjs and verification/test_offline_compressed_proof_replay.mjs, which
# refuse to run without it rather than defaulting to the working tree.
AZTEC_REPLAY_RUNTIME_ROOT="$REPLAY_RUNTIME_ROOT"
export REPLAY_RUNTIME REPLAY_RUNTIME_ROOT REPLAY_DIR AZTEC_REPLAY_RUNTIME_ROOT

# hist_field <report> <key> — one `key value` line out of a verifier report.
hist_field() { printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1; }

# historical_replay_prepare — assert the executed tree is the declared one. Idempotent per process.
historical_replay_prepare() {
  [ -n "${_HIST_REPLAY_PREPARED:-}" ] && return 0
  _HIST_REPLAY_PREPARED=1
  if [ "$REPLAY_RUNTIME" = live ]; then
    note "REPLAY_RUNTIME=live: this check executes the working tree's replay/, not the historical runtime"
    return 0
  fi
  [ -n "$HIST_REPLAY_COMMIT" ] || die "pins.json declares no historical_runtimes.$HIST_REPLAY_NAME.commit"
  [ -n "$HIST_ROOT" ] || die "tools/historical_replay.py could not name the historical runtime's directory"
  local out rc
  out="$(python3 "$HIST_REPLAY_TOOL" verify --name "$HIST_REPLAY_NAME" 2>&1)"; rc=$?
  if printf '%s\n' "$out" | grep -q '^problem not materialised at '; then
    die "the historical replay runtime ($HIST_REPLAY_COMMIT) is not materialised at $HIST_ROOT.
     The Live-Chain-Replay floors execute it, not the working tree's replay/ (DRIFT.md D36).
     Remedy: just materialize-historical-replay"
  fi
  note "historical runtime: $HIST_REPLAY_COMMIT at $HIST_ROOT"
  assert_eq "the floors execute the historical runtime pins.json declares" \
    "$HIST_REPLAY_COMMIT" "$(hist_field "$out" declared)"
  assert_eq "…and the directory was materialised from that commit" \
    "$HIST_REPLAY_COMMIT" "$(hist_field "$out" stamp_commit)"
  assert_ge "…the verifier re-hashed the whole commit, not a sample" 1000 \
    "$(hist_field "$out" tracked_files)"
  assert_eq "…and every tracked file on disk is byte-identical to the commit's blob" \
    "0" "$(hist_field "$out" mismatched_files)"
  assert_eq "…and the runtime source directories hold nothing the commit does not track" \
    "0" "$(hist_field "$out" untracked_runtime_files)"
  assert_eq "…and its install is on the npm pin it declares" \
    "$HIST_REPLAY_NPM_VERSION" "$(hist_field "$out" installed_stdlib)"
  assert_eq "…and the verifier reports no problem at all" "0" "$rc"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed -n 's/^problem /  verifier: /p' >&2
    die "the historical replay runtime at $HIST_ROOT is not the declared commit.
     Remedy: just materialize-historical-replay (it re-materialises a tree that does not verify)"
  fi

  # THE VERIFIER'S OWN NEGATIVE CONTROLS. Without them, "it verified" cannot be told apart from a
  # verifier that verifies anything. Both compare the SAME directory; only the claim changes.
  local parent ctl ctl_rc
  parent="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$HIST_REPLAY_COMMIT^")" \
    || die "the historical runtime's parent commit is not in the object store"
  ctl="$(python3 "$HIST_REPLAY_TOOL" verify --name "$HIST_REPLAY_NAME" --expect-commit "$parent" 2>&1)"
  ctl_rc=$?
  assert_false "control: the same directory does NOT verify as its parent commit" test "$ctl_rc" -eq 0
  assert_contains "…and the refusal names the commit it was materialised from" \
    "materialised from $HIST_REPLAY_COMMIT, not $parent" "$ctl"
  ctl="$(python3 "$HIST_REPLAY_TOOL" verify --name "$HIST_REPLAY_NAME" --tamper replay/src/index.ts 2>&1)"
  ctl_rc=$?
  assert_false "control: one changed byte in replay/src/index.ts does NOT verify" test "$ctl_rc" -eq 0
  assert_eq "…and exactly that one file is reported" "1" "$(hist_field "$ctl" mismatched_files)"
}

# hist_committed <path> — the file is in the declared historical commit (the historical runtime's
# equivalent of "it is TRACKED": the executed source is committed, not a scratch file).
hist_committed() {
  if [ "$REPLAY_RUNTIME" = live ]; then
    git -C "$REPO_ROOT" ls-files --error-unmatch "$1" >/dev/null 2>&1
  else
    git -C "$REPO_ROOT" cat-file -e "$HIST_REPLAY_COMMIT:$1" 2>/dev/null
  fi
}

# hist_assert_resolves_into <description> <dir to resolve from> <specifier>
# The RUN-TIME half of "the redirection cannot point elsewhere": ask node itself where a bare
# specifier resolves from the directory a probe runs in, and require the answer to be inside the
# executed tree's install.
hist_assert_resolves_into() {
  local desc="$1" from="$2" spec="$3" got
  # An `-e` module's own URL is `<cwd>/[eval1]`, so it resolves exactly as a probe in <from> does.
  got="$( cd "$from" && node --input-type=module -e "
    import { realpathSync } from 'node:fs';
    import { fileURLToPath } from 'node:url';
    process.stdout.write(realpathSync(fileURLToPath(import.meta.resolve('$spec'))));
  " 2>/dev/null )"
  assert_prefix "$desc" "$(realpath "$REPLAY_DIR/node_modules")/" "$got"
}
