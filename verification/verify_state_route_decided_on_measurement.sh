#!/usr/bin/env bash
# verify_state_route_decided_on_measurement — L2 (Aztec-Live-Chain-Replay).
#
# "Both routes measured against one transaction with the numbers recorded, and the implemented route
#  follows the measurement. If the measurement does not discriminate, the stated secondary criterion
#  is recorded instead."
#
# ─────────────────────────────────────────────────────────────────────────────
# THE MEASUREMENT DID NOT PRODUCE TWO NUMBERS, BECAUSE NEITHER ROUTE CAN BE BUILT.
#
# The milestone expected a speed comparison. The honest outcome is that there is nothing to compare:
# both of its routes are closed by the artefact, and each closure is a fact about a specific line of
# upstream C++ at the pinned `cpp` anchor.
#
#   route 1, per-read witnesses — `avm_simulate_with_hinted_dbs` builds
#     `const PublicSimulatorConfig config = {}` internally, so `collect_execution_steps` cannot be
#     reached through it: no step stream, no `.ct`.
#   route 2, seed from the state reference — `MemoryMerkleDB` has no root setter, no bulk import and
#     no construction from a `StateReference`. The only way to a root is every leaf.
#
# ─────────────────────────────────────────────────────────────────────────────
# SO THIS CHECK IS THE ONE THAT KEEPS THOSE TWO SENTENCES FROM ROTTING.
#
# `CAMPAIGN-BRIEF.md`: "a figure nobody re-derives rots." A prose claim about somebody else's source
# tree rots faster than a figure does, because upstream moves and nothing here notices. So both
# closures are re-read from the ANCHOR'S OBJECT STORE on every run — `git show <anchor>:<path>`, M22's
# review's rule, never from a worktree somebody may have rebased.
#
# THE TRAP THIS CHECK IS BUILT AROUND, AND IT IS THE ONLY ONE THAT MATTERS:
# **EVERY ASSERTION HERE IS AN ABSENCE, AND AN ABSENCE IS VACUOUSLY TRUE OVER AN EMPTY FILE.**
# If the fork checkout does not have the anchor commit, `git show` prints nothing, and "there is no
# root setter" passes for the same reason "there is no C++" would. This campaign has shipped that
# defect twice under its own name — "an absence asked of a tree that excluded its subject by
# construction".
#
# So §0 establishes the tree is real and is the pinned one, and every absence in §1 and §2 is paired
# with a PRESENCE from the same file: the methods `MemoryMerkleDB` DOES declare, the function
# `avm_sim_api.cpp` DOES define. A file that had gone empty would fail the presences first.
#
# Run: just verify-l2-routes

set -uo pipefail
TEST_NAME="verify_state_route_decided_on_measurement"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l2_prepare

SIM_API="barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp"
MERKLE_DB="barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"

ANCHOR="$(l2_cpp_anchor)"
SIM_SRC="$(l2_anchor_show "$SIM_API")"
DB_SRC="$(l2_anchor_show "$MERKLE_DB")"

# ---------------------------------------------------------------------------
echo "== 0. the tree is real, and it is the PINNED one"
#
# Every assertion below this line is an ABSENCE, and an absence over an empty file is vacuously
# true. This section is what stops that reading.
# ---------------------------------------------------------------------------
assert_eq "the cpp anchor is the one pins.json declares" \
  "$(python3 -c 'import json;print(json.load(open("pins.json"))["anchors"]["cpp"]["commit"])')" \
  "$ANCHOR"
# THE BACKTICKS IN THIS DESCRIPTION ARE ESCAPED AND THAT IS NOT COSMETIC. The first version of this
# line wrote the tool's name in plain backticks inside a double-quoted string, so every run EXECUTED
# `git show` with no arguments and substituted a screenful of commit log into the assertion's
# description. Harmless here only because the assertion still ran; L1's review found the same defect
# in `l1_imports` where the substituted output DELETED three words from a comment. Backticks in
# prose, in double quotes, are command substitution.
assert_true "…and the fork checkout HAS that commit, so \`git show\` is reading a real tree" \
  git -C "$FORK_ROOT" cat-file -e "$ANCHOR^{commit}"
assert_ge "the AVM sim API at the anchor is a real file and not an empty answer" 500 \
  "$(printf '%s' "$SIM_SRC" | wc -c | tr -d ' ')"
assert_ge "…and so is the memory merkle DB header" 5000 \
  "$(printf '%s' "$DB_SRC" | wc -c | tr -d ' ')"
# A NAME THAT IS NOT THERE, so "absent" is measured rather than assumed. If this passed as PRESENT
# the reader below is matching something other than what it is asked for.
assert_not_contains "a fabricated name is absent from the sim API, so absence is discriminating" \
  "avm_simulate_with_a_fabricated_name" "$SIM_SRC"
assert_not_contains "…and from the merkle DB header" \
  "import_whole_tree_from_a_fabricated_name" "$DB_SRC"

# ---------------------------------------------------------------------------
echo "== 1. ROUTE 1 IS CLOSED: the hinted entry point builds its own empty config"
# ---------------------------------------------------------------------------
# THE PRESENCES FIRST. If these fail, every absence below is meaningless.
assert_contains "the hinted entry point exists at the anchor" \
  "simulate_with_hinted_dbs" "$SIM_SRC"
assert_contains "…and the non-hinted one does too, so the file is the AVM's sim API" \
  "AvmSimAPI::simulate" "$SIM_SRC"
assert_contains "…and it names the config type this closure is about" \
  "PublicSimulatorConfig" "$SIM_SRC"

# THE CLOSURE ITSELF, quoted exactly.
assert_contains "the hinted path constructs an EMPTY PublicSimulatorConfig internally" \
  "const PublicSimulatorConfig config = {};" "$SIM_SRC"
assert_contains "…and upstream's own comment says so, which is why this is a limitation and not a bug" \
  "Placeholder for future use of config from inputs." "$SIM_SRC"

# AND THE CONFIG DOES NOT COME FROM THE INPUTS. This is the whole claim: a caller cannot ask for
# `collect_execution_steps` through this door.
HINTED_BODY="$(printf '%s\n' "$SIM_SRC" \
  | awk '/simulate_with_hinted_dbs\(const ProvingInputs/{f=1} f{print} f&&/^}/{exit}')"
assert_ge "the hinted function's body was located and is not empty" 5 \
  "$(printf '%s\n' "$HINTED_BODY" | wc -l | tr -d ' ')"
assert_contains "…and it is the body that builds the empty config" \
  "const PublicSimulatorConfig config = {};" "$HINTED_BODY"
assert_not_contains "…and it never reads a config off its inputs" \
  "inputs.config" "$HINTED_BODY"
assert_not_contains "…nor a collect_execution_steps flag" \
  "collect_execution_steps" "$HINTED_BODY"
# The CONTRAST that makes the above a measurement: the NON-hinted path takes real inputs, so
# "a function in this file does not read its inputs" is a fact about THIS function.
NONHINTED_BODY="$(printf '%s\n' "$SIM_SRC" \
  | awk '/AvmSimAPI::simulate\(/{f=1} f&&!/simulate_with_hinted_dbs/{print} f&&/^}/{exit}')"
assert_contains "the NON-hinted path, by contrast, does read its inputs" \
  "inputs." "$NONHINTED_BODY"

# ---------------------------------------------------------------------------
echo "== 2. ROUTE 2 IS CLOSED: the resident merkle DB has no way in"
# ---------------------------------------------------------------------------
# THE PRESENCES: the methods it DOES have. A header that had moved would fail here first.
assert_contains "the class is where the disposition says it is" "class MemoryMerkleDB" "$DB_SRC"
assert_contains "…it can insert one public-data leaf" \
  "insert_indexed_leaves_public_data_tree" "$DB_SRC"
assert_contains "…one nullifier" "insert_indexed_leaves_nullifier_tree" "$DB_SRC"
assert_contains "…append leaves" "append_leaves" "$DB_SRC"
assert_contains "…pad a tree" "pad_tree" "$DB_SRC"
assert_contains "…and report its roots" "get_tree_roots" "$DB_SRC"
# The constructor takes PREFILL COUNTS and nothing else — which is the shape of the closure.
assert_contains "the constructor takes a nullifier prefill count" \
  "MemoryMerkleDB(size_t nullifier_tree_prefill" "$DB_SRC"
assert_contains "…and a public-data prefill count" "public_data_tree_prefill" "$DB_SRC"

# THE ABSENCES, each one a way route 2 would have needed and does not have.
assert_not_contains "there is no root SETTER" "set_tree_roots" "$DB_SRC"
assert_not_contains "…none by any other spelling" "set_root" "$DB_SRC"
assert_not_contains "…no bulk import" "import_tree" "$DB_SRC"
assert_not_contains "…none by any other spelling" "load_from" "$DB_SRC"
assert_not_contains "…no construction from a StateReference" "StateReference" "$DB_SRC"
assert_not_contains "…and no revision or historical-block parameter" "block_number" "$DB_SRC"

# ---------------------------------------------------------------------------
echo "== 3. THE DISPOSITIONS SAY WHAT THE SOURCES SAY"
#
# The two sections above measure upstream. This one measures whether `historical_state.ts` still
# describes what was measured — the half that rots.
# ---------------------------------------------------------------------------
PROBE="$(l2_imports)
$(cat <<'EOS'

const d = ROUTE_DISPOSITIONS;
line('routes.count', Object.keys(d).length);
line('routes.names', Object.keys(d).sort().join(','));
line('routes.closed', Object.values(d).filter((r) => r.verdict === 'closed').length);
line('routes.implemented', Object.values(d).filter((r) => r.verdict === 'implemented').length);
line('routes.verdicts', Object.entries(d).map(([k, v]) => `${k}=${v.verdict}`).sort().join(' '));
line('routes.allHaveSources',
     Object.values(d).every((r) => typeof r.source === 'string' && r.source.length > 10) ? 'yes' : 'no');
line('routes.allHaveReasons',
     Object.values(d).every((r) => typeof r.because === 'string' && r.because.length > 100) ? 'yes' : 'no');
line('route1.source', d['per-read-witnesses'].source);
line('route2.source', d['seed-from-state-reference'].source);
line('route3.verdict', d['avm-named-reads'].verdict);
line('route1.mentionsTheConfig',
     d['per-read-witnesses'].because.includes('config = {}') ? 'yes' : 'no');
line('route2.mentionsNoBulkImport',
     d['seed-from-state-reference'].because.includes('no bulk import') ? 'yes' : 'no');
line('route3.mentionsCollectHints',
     d['avm-named-reads'].because.includes('collectHints') ? 'yes' : 'no');

// THE IMPLEMENTED ROUTE FOLLOWS THE MEASUREMENT — asserted against the config the encoder actually
// produces, not against the disposition's prose. A campaign that declared route 3 and shipped an
// encoder with collectHints off would hydrate nothing and be green on everything above.
const config = replaySimulatorConfig();
line('config.collectHints', config.collectHints === true ? 'yes' : 'no');
line('config.collectStatistics', config.collectStatistics === true ? 'yes' : 'no');
line('config.collectPublicInputs', config.collectPublicInputs === true ? 'yes' : 'no');
line('config.collectExecutionSteps', config.collectExecutionSteps === true ? 'yes' : 'no');
line('config.skipFeeEnforcement', config.skipFeeEnforcement === false ? 'false' : 'true');
line('flags.declared', Object.keys(REPLAY_COLLECTION_FLAGS).sort().join(','));
line('flags.allExplained',
     Object.values(REPLAY_COLLECTION_FLAGS).every((v) => typeof v === 'string' && v.length > 40)
       ? 'yes' : 'no');
line('patch.keys', Object.keys(PATCH_REQUIRED_CONFIG_FIELDS).join(','));
line('patch.defaultIsOff', PATCH_REQUIRED_CONFIG_FIELDS.collectExecutionSteps === false ? 'yes' : 'no');

// AND THE MODULE REALLY DOES REPORT ITS READS, which is route 3's whole premise. Measured, not
// assumed: a run whose hints came back empty would make the loop seed nothing and converge at once.
const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);
const real = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
const reported = real.rounds.reduce((a, r) => Math.max(a, r.queries), 0);
line('hints.maxQueriesInARound', reported);
line('hints.roundsThatSeeded', real.rounds.filter((r) => r.added > 0).length);
line('hints.rounds', real.rounds.length);
line('hints.seededTotal', real.seed.seeded.length);
line('hints.reproduced', real.verdict.reproduced ? 'yes' : 'no');
// The queries are read out of the AVM's own hint field by the module's own reader, and the reader
// finds them in the FINAL round's result too — so the loop stopped because nothing was NEW, not
// because the module stopped reporting.
line('hints.finalRoundQueries', real.rounds[real.rounds.length - 1].queries);
line('hints.finalRoundAdded', real.rounds[real.rounds.length - 1].added);
// …and `queriesFrom` over an empty result answers zero rather than throwing, so a module that
// reported nothing would be a measured zero and not a crash somebody reads as a hang.
line('hints.emptyResultGivesZero', queriesFrom({}).length === 0 ? 'yes' : 'no');

line('l2.done', 1);
EOS
)"

OUT="$L2_WORK/probes/l2routes.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-600}" l0_run_probe l2routes "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }

assert_eq "three routes are dispositioned" "3" "$(f routes.count)"
assert_eq "…by name" "avm-named-reads,per-read-witnesses,seed-from-state-reference" \
  "$(f routes.names)"
assert_eq "…two closed" "2" "$(f routes.closed)"
assert_eq "…and one implemented" "1" "$(f routes.implemented)"
assert_eq "…which is route 3, the one the artefact admits" "implemented" "$(f route3.verdict)"
assert_eq "every disposition cites a source" "yes" "$(f routes.allHaveSources)"
assert_eq "…and gives a substantive reason" "yes" "$(f routes.allHaveReasons)"

# THE CITATIONS ARE THE FILES THIS CHECK JUST READ. Without this the sources could name anything.
assert_prefix "route 1 cites the sim API this check read" "$SIM_API" "$(f route1.source)"
assert_prefix "route 2 cites the merkle DB header this check read" "$MERKLE_DB" \
  "$(f route2.source)"
assert_eq "route 1's reason quotes the empty config" "yes" "$(f route1.mentionsTheConfig)"
assert_eq "route 2's reason names the missing bulk import" "yes" "$(f route2.mentionsNoBulkImport)"
assert_eq "route 3's reason names collectHints" "yes" "$(f route3.mentionsCollectHints)"

# ---------------------------------------------------------------------------
echo "== 4. and the IMPLEMENTED route is the one that actually runs"
#
# A campaign that declared route 3 and shipped an encoder with `collectHints` off would hydrate
# nothing and be green on every assertion above.
# ---------------------------------------------------------------------------
assert_eq "the encoder asks for hints, which IS route 3" "yes" "$(f config.collectHints)"
assert_eq "…for statistics, which is L3's step-count control" "yes" "$(f config.collectStatistics)"
assert_eq "…for public inputs, which is what the effects comparison reads" "yes" \
  "$(f config.collectPublicInputs)"
assert_eq "…and for execution steps, which is DRIFT D14's required key" "yes" \
  "$(f config.collectExecutionSteps)"
assert_eq "…while fee enforcement stays upstream's default, ON" "false" \
  "$(f config.skipFeeEnforcement)"
assert_eq "the three upstream collection flags are declared with reasons" \
  "collectHints,collectPublicInputs,collectStatistics" "$(f flags.declared)"
assert_eq "…each explaining which deliverable needs it" "yes" "$(f flags.allExplained)"
assert_eq "the patch-required key set is exactly the one key" "collectExecutionSteps" \
  "$(f patch.keys)"
assert_eq "…whose declared default is OFF, which is upstream's own" "yes" "$(f patch.defaultIsOff)"

# ---------------------------------------------------------------------------
echo "== 5. THE PREMISE, MEASURED: the module really does report its own reads"
#
# Route 3 rests entirely on the AVM naming what it read. If the hints came back empty the loop would
# seed nothing, converge immediately, and every disposition above would still be green.
# ---------------------------------------------------------------------------
assert_ge "the module reported real world-state queries" 15 "$(f hints.maxQueriesInARound)"
assert_ge "…across several rounds that each seeded something" 3 "$(f hints.roundsThatSeeded)"
assert_eq "…converging in six" "6" "$(f hints.rounds)"
assert_ge "…having seeded fifteen leaves" 15 "$(f hints.seededTotal)"
assert_eq "…and reproducing the published effects, so the seeding was RIGHT" "yes" \
  "$(f hints.reproduced)"
# The loop stopped because nothing was NEW, not because reporting stopped.
assert_ge "the FINAL round still reported queries" 15 "$(f hints.finalRoundQueries)"
assert_eq "…and added nothing, which is why it stopped" "0" "$(f hints.finalRoundAdded)"
assert_eq "an empty result gives zero queries rather than throwing" "yes" \
  "$(f hints.emptyResultGivesZero)"

finish
