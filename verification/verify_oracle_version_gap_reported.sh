#!/usr/bin/env bash
# verify_oracle_version_gap_reported
#
# Every run prints the pinned-oracle-to-upstream version gap, and fails when the gap crosses the
# recorded threshold.
#
# WHY. The differential's C++ oracle is the in-process NAPI AVM in the 5.0.0 npm line. Upstream cut
# over to an out-of-process `bb-avm-sim` IPC service on 2026-07-17 and has kept moving. As the pin
# ages the arm stays green while proving less: agreement with a SNAPSHOT, not correctness against
# current consensus. DRIFT.md D6 accepts that with two mitigations rather than a fix, and this is
# the first — the gap reported as a NUMBER, every run, so the decay is visible instead of silent.
#
# THE THING TO GET RIGHT HERE is that the numbers are MEASURED from the fork's history rather than
# restated. A version-gap report whose numbers are typed into a document is exactly the artefact
# that goes stale while looking authoritative, which is the failure it exists to prevent.
#
# Run: just verify-m19

TEST_NAME="verify_oracle_version_gap_reported"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
TOOL="$REPO_ROOT/tools/version_gap.py"
assert_file "the version-gap tool is present" "$TOOL"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"

work="$M19_WORK/gap"
rm -rf "$work"; mkdir -p "$work"

# ---- 1. it runs, and it prints the gap as numbers ---------------------------
out="$(python3 "$TOOL" --json "$work/gap.json" 2>&1)"
rc=$?
assert_eq "the version-gap tool exits 0 within the threshold" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" >&2
assert_contains "it names itself" "ORACLE VERSION GAP (DD-12)" "$out"
assert_file "it wrote the machine-readable report" "$work/gap.json"

# ---- 2. the numbers are derived, not restated -------------------------------
# Each figure is recomputed here from git, independently of the tool, so a tool that printed
# constants would fail. That is the specific defect this pattern has produced before: a printed
# literal beside an assertion that therefore could not move.
ts_commit="$(m19_json "$REPO_ROOT/pins.json" 'd["anchors"]["ts"]["commit"]')"
cpp_commit="$(m19_json "$REPO_ROOT/pins.json" 'd["anchors"]["cpp"]["commit"]')"
tip="$(git -C "$FORK_ROOT" rev-parse upstream/next)"
independent_commits="$(git -C "$FORK_ROOT" rev-list --count "$ts_commit..$tip")"
independent_avm="$(git -C "$FORK_ROOT" diff --name-only "$ts_commit" "$tip" -- \
  barretenberg/cpp/src/barretenberg/vm2 | grep -c . || true)"

assert_eq "the reported commit gap is the one git reports" \
  "$independent_commits" "$(m19_json "$work/gap.json" 'd["oracleToUpstreamTip"]["commits"]')"
assert_eq "the reported AVM file count is the one git reports" \
  "$independent_avm" "$(m19_json "$work/gap.json" 'd["oracleToUpstreamTip"]["avmFilesChanged"]')"
assert_eq "the reported upstream tip is the fork's actual tip" \
  "${tip:0:10}" "$(m19_json "$work/gap.json" 'd["upstreamTip"]')"
assert_eq "the reported oracle anchor is pins.json's TypeScript anchor" \
  "${ts_commit:0:10}" "$(m19_json "$work/gap.json" 'd["oracleAnchor"]')"
assert_eq "the reported module anchor is pins.json's C++ anchor" \
  "${cpp_commit:0:10}" "$(m19_json "$work/gap.json" 'd["moduleAnchor"]')"
assert_ge "the gap is a real gap, not zero — which is the whole reason DD-12 exists" 1 \
  "$(m19_json "$work/gap.json" 'd["oracleToUpstreamTip"]["days"]')"
assert_ge "and the AVM itself moved inside it, which is what makes it a semantic gap" 1 \
  "$(m19_json "$work/gap.json" 'd["oracleToUpstreamTip"]["avmFilesChanged"]')"

# The qualitative half. Past the out-of-process cutover the oracle is not merely older, it is a
# different architecture, and that is a fact about the gap that a day count cannot carry.
assert_eq "the out-of-process cutover is inside the gap" "True" \
  "$(m19_json "$work/gap.json" 'd["outOfProcessCutover"]["insideTheGap"]')"
assert_true "and DRIFT.md D6 records it" grep -q '^## D6 — ' "$REPO_ROOT/DRIFT.md"

# The gap that explains D15 is the ORACLE-TO-MODULE one, not the oracle-to-tip one, and the tool
# must report it separately or the reader has no way to connect the report to the divergence.
assert_ge "the oracle-to-module gap is reported and is non-zero" 1 \
  "$(m19_json "$work/gap.json" 'd["oracleToModule"]["days"]')"
assert_ge "and the AVM moved across it, which is what D15 attributes the gas divergence to" 1 \
  "$(m19_json "$work/gap.json" 'd["oracleToModule"]["avmFilesChanged"]')"
assert_true "and DRIFT.md D15 records that" grep -q '^## D15 — ' "$REPO_ROOT/DRIFT.md"

# ---- 3. THE THRESHOLD BITES -------------------------------------------------
# A threshold never observed to fire is not a threshold.
python3 "$TOOL" --fail-over-days 1 >"$work/over.out" 2>&1
assert_eq "a threshold the gap exceeds makes the tool exit non-zero" "3" "$?"
assert_contains "and it says the gap is over" "OVER" "$(cat "$work/over.out")"
python3 "$TOOL" --fail-over-days 100000 >/dev/null 2>&1
assert_eq "and a threshold the gap is within is accepted, so the exit status discriminates" "0" "$?"

# ---- 4. CI prints it every run, as a step ----------------------------------
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
if command -v yq >/dev/null 2>&1; then YQ="yq"; else YQ="nix shell nixpkgs#yq-go --command yq"; fi
step_names="$($YQ -r '.jobs["differential-oracle"].steps[].name' "$WF" 2>/dev/null)"
[ -n "$step_names" ] || die "the workflow could not be parsed; a job named in a comment is not a job"
assert_contains "the differential job prints the version gap" "THE VERSION GAP (DD-12)" "$step_names"
runs="$($YQ -r '.jobs["differential-oracle"].steps[].run // ""' "$WF" 2>/dev/null)"
assert_contains "and that step invokes the tool" "version-gap" "$runs"
# BEFORE the comparison, not after: a gap report printed after a failure is a report nobody reads.
gap_idx="$(printf '%s\n' "$step_names" | grep -n 'THE VERSION GAP' | cut -d: -f1)"
run_idx="$(printf '%s\n' "$step_names" | grep -n 'run the three-way differential' | cut -d: -f1)"
assert_true "and it is printed BEFORE the comparison runs" test "$gap_idx" -lt "$run_idx"

finish
