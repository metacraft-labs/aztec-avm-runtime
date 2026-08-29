#!/usr/bin/env bash
# lib_l1_settled_tx.sh — shared machinery for L1's three checks.
#
# L1 is the second milestone of the LIVE-CHAIN REPLAY campaign
# (codetracer-specs/Planned-Work/Aztec-Live-Chain-Replay.milestones.org).
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS FILE DELIBERATELY SOURCES L0's LIB AND REUSES ITS PROBE RUNNER.
#
# `l0_probe`, `l0_run_probe` and `l0_field` are not L0-specific: they are a bounded `node` run, an
# exit-status assertion, a transcript-completeness refusal through `lib.sh`'s ONE implementation,
# and a `key value` reader. CAMPAIGN-BRIEF.md's rule about transcript checks is that "three
# implementations are three chances for the next transcript check to be written without one", and
# `verify_transcript_truncation_detection_uniform` asserts that every comparer reaches
# `require_complete_transcript`. Writing a second copy here would be the fourth spelling.
#
# What IS L1's own is the work directory: `L0_WORK` is set BEFORE the source so the probes land in
# `~/.cache/aztec-l1-settled-tx` and not in L0's directory. Two milestones sharing one work
# directory is state you did not produce, and this campaign has paid for that more than once.
# (`require_work_dir`'s flock is per directory, so this also means an L0 check and an L1 check can
# never contend for the same lock.)

L0_WORK="${L1_WORK:-$HOME/.cache/aztec-l1-settled-tx}"
export L0_WORK
L1_WORK="$L0_WORK"
export L1_WORK

. "$VERIFY_DIR/lib_l0_node_client.sh"

L1_SRC="$REPO_ROOT/replay/src"
L1_TOOLS="$REPO_ROOT/replay/tools"
L1_FIXTURE_DIR="$REPO_ROOT/replay/fixtures"
L1_CAPTURE_SCRIPT="$REPO_ROOT/replay/tools/capture_settled_fixture.mjs"
export L1_SRC L1_TOOLS L1_FIXTURE_DIR L1_CAPTURE_SCRIPT

# The fixtures this milestone committed. Named here so a check can assert the SET rather than
# whichever files happen to be on disk — a fixture that vanished must be a failure, and a fixture
# that appeared without being declared must be one too.
L1_FIXTURES=(testnet_settled_tx.json testnet_private_only_tx.json)
export L1_FIXTURES

l1_prepare() {
  l0_prepare

  assert_file "L1's fetch of a settled transaction" "$L1_SRC/settled_transaction.ts"
  assert_file "…its private-half declaration" "$L1_SRC/private_half.ts"
  # In `tools/` and not in `src/`, because L0's schema check refuses a hand-built wire type inside
  # `replay/src` and a fixture player is one. The module's header records that measurement.
  assert_file "…and the fixture format, recorder and player" "$L1_TOOLS/settled_fixture.ts"
  assert_eq "…which is NOT in replay/src, so L0's 'no wire types here' invariant is intact" "0" \
    "$(ls -1 "$L1_SRC" | grep -c '^settled_fixture.ts$' || true)"
  # "with the capture script committed beside them" — the deliverable's own words.
  assert_file "the capture script that produced the fixtures is committed" "$L1_CAPTURE_SCRIPT"
  assert_true "…and it is TRACKED, not merely present" \
    git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/capture_settled_fixture.mjs"

  assert_dir "the fixtures directory" "$L1_FIXTURE_DIR"
  local f
  for f in "${L1_FIXTURES[@]}"; do
    assert_file "…the declared fixture $f" "$L1_FIXTURE_DIR/$f"
    assert_true "…and $f is TRACKED, so the suite runs from a clean checkout" \
      git -C "$REPO_ROOT" ls-files --error-unmatch "replay/fixtures/$f"
  done
  # The set, not just the members: an undeclared fixture is as much a finding as a missing one.
  assert_eq "the fixtures on disk are exactly the ones declared here" \
    "$(printf '%s\n' "${L1_FIXTURES[@]}" | sort | tr '\n' ' ')" \
    "$(cd "$L1_FIXTURE_DIR" && ls -1 ./*.json 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')"
}

# l1_json <file> <python-expression over `d`> — read one datum out of a fixture.
#
# Used for the assertions that compare a fixture's DECLARED provenance against what the probe
# re-derives from the recorded RESPONSES. The two must never be read from the same place, which is
# why this reads the file and the probe reads the client.
l1_json() { # <file> <expr>
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
value = eval(sys.argv[2], {'d': d, 'len': len, 'sorted': sorted})
print(value)
PY
}

# The import prologue every L1 probe shares. L0's exports plus L1's, from the one index.
l1_imports() {
  cat <<EOF
import { readFileSync } from 'node:fs';

import {
  CONTRACT_RESOLUTION_METHODS,
  CONTRACT_RESOLUTION_REFERENCE_BLOCK,
  MISSING_ARTIFACT_STAGES,
  MissingContractArtifact,
  NodeUnreachable,
  PINNED_PROTOCOL_VERSION,
  PRIVATE_HALF_AVAILABLE,
  PRIVATE_HALF_AVAILABLE_REASON,
  PRIVATE_HALF_UNAVAILABLE,
  PRIVATE_HALF_UNAVAILABLE_REASON,
  ProtocolVersionMismatch,
  ReplayNodeSurfaceExceeded,
  SettledTransactionNotFound,
  SettlingBlockUnavailable,
  createReplayNodeClient,
  declarePrivateHalf,
  declarePublicHalf,
  fetchSettledTransaction,
  measureLocalPrivateExecution,
  publicCallTargets,
  resolvePublicContracts,
  resolvePublicContractsUnguardedForControls,
} from '$L1_SRC/index.ts';

// THE FIXTURE FORMAT IS IMPORTED FROM \`replay/tools/\`, NOT FROM THE PACKAGE'S INDEX, and that is
// L0's own check's doing: \`verify_client_uses_upstream_schema\` asserts that nothing in
// \`replay/src\` declares a wire type, and a fixture player assembles a JSON-RPC envelope by hand.
// The module's header records the measurement that moved it.
//
// (THE BACKTICKS ABOVE ARE ESCAPED AND THAT IS NOT COSMETIC. This heredoc is \`<<EOF\` and not
// \`<<'EOF'\` because it must expand \$L1_SRC and \$L1_TOOLS — so an unescaped backtick in PROSE is
// command substitution. Found by L1's review in the N9 arm's log: three names in this very
// paragraph were being EXECUTED on every run of every L1 check, printing
// \`replay/src: Is a directory\` and \`verify_client_uses_upstream_schema: command not found\` to
// stderr and substituting their empty output back in, so the emitted probe carried the sentence
// with its three subjects deleted. Harmless only because the wreckage landed inside a \`//\`
// comment and none of the three names is a real command. Escape backticks in prose here.)
import {
  FixtureMiss,
  MalformedFixture,
  REQUIRED_PROVENANCE_FIELDS,
  SETTLED_FIXTURE_FORMAT,
  fixtureCallKey,
  fixtureFetch,
  loadSettledFixture,
} from '$L1_TOOLS/settled_fixture.ts';

const line = (k, v) => console.log(\`\${k} \${v}\`);

const FIXTURE_DIR = '$L1_FIXTURE_DIR';

/** Read a committed fixture and validate it through the module's own loader. */
const readFixture = (name) =>
  loadSettledFixture(JSON.parse(readFileSync(\`\${FIXTURE_DIR}/\${name}\`, 'utf8')), name);

/** A client that talks to nothing but the fixture. The url is recorded so refusals can name it. */
const fixtureClient = (fixture, options = {}) =>
  createReplayNodeClient({
    url: fixture.provenance.endpoint,
    fetchImpl: fixtureFetch(fixture, options),
  });

/**
 * A copy of a fixture with ONE recorded answer replaced.
 *
 * The mutation arms below are "the same fixture, one entry changed" on purpose: an arm built from a
 * hand-written fixture would be measuring a file somebody typed, while this one is measuring the
 * real recording with a single, named hole in it. \`edit\` returns the number of entries it
 * changed so a probe can assert the needle was FOUND — a substitution that does not find its needle
 * must not be printed as a result.
 */
const edit = (fixture, method, params, result) => {
  const key = fixtureCallKey(method, params);
  let hits = 0;
  const calls = fixture.calls.map((c) => {
    if (fixtureCallKey(c.method, c.params) !== key) {
      return c;
    }
    hits += 1;
    return { ...c, result };
  });
  return { hits, fixture: { ...fixture, calls } };
};

/** Reduce a thrown value to one word: its own \`kind\`, or \`foreign:<ctor>\`, or \`returned\`. */
const classify = async (label, thunk) => {
  try {
    const value = await thunk();
    line(\`\${label}.outcome\`, 'returned');
    return { outcome: 'returned', value };
  } catch (e) {
    const kind = e?.kind ?? \`foreign:\${e?.constructor?.name ?? 'unknown'}\`;
    line(\`\${label}.outcome\`, kind);
    line(\`\${label}.class\`, e?.constructor?.name ?? 'none');
    return { outcome: kind, error: e };
  }
};
EOF
}
