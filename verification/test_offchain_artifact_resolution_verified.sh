#!/usr/bin/env bash
# test_offchain_artifact_resolution_verified — L5 (Aztec-Live-Chain-Replay).
#
# "An artifact fetched off-chain is PROVED to be the one the contract class commits to, or it is
#  refused by name. Control: a class nobody publishes resolves to nothing and stays at rung 3."
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IS BEING VERIFIED IS A CONJUNCTION OF THREE CHECKS, AND EACH ONE IS SHOWN TO HAVE TEETH.
#
# §2 the subject: the FeeJuice class the chain serves at address 0x…03 is proved by the installed
#    `@aztec/protocol-contracts`, with all three of `computeArtifactHash`, byte-equal
#    `packedBytecode` and a recomputed class id agreeing.
# §3 the DECOY: the same bytecode under a different artifact hash is REFUSED — the case a
#    bytecode-only check accepts, which is what Aztecscan's own verification does.
# §4 the two key shapes, BOTH exercised, and the Buffer revival shown to be load-bearing.
# §5 the boundary of what `artifactHash` commits to, demonstrated by an artifact that PASSES all
#    three checks with a rewritten source map.
# §6 corroboration, both ways, and the strict policy refusing.
# §7 the CONTROL: the third-party token class, through the same resolver, resolves to nothing.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CONTROL IS §7 AND IT IS NOT OPTIONAL.
#
# Every assertion in §2 is satisfied by a resolver that answers `resolved: true` to everything.
# §7 runs THE SAME `resolveContractArtifact` over THE SAME providers against a class no registry
# publishes, and requires `resolved: false` with a counted zero candidates. Trap 4a's rule: a
# negative assertion with a positive twin through the same code path is self-controlling.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS CHECK DOES NOT CLAIM, SAID HERE RATHER THAN LEFT TO BE INFERRED.
#
# It says nothing about a REAL EXECUTION reaching rung 1 — that is
# `e2e_resolved_contract_records_at_source_level`'s subject, and even that one drives a synthetic
# step stream and says so. And it says nothing about the network sources: the npm release that
# nearly resolves and the explorer's two shapes are measured in
# `verify_l5_artifact_sources_live.sh`, which is not part of the offline floor.

set -uo pipefail
TEST_NAME="test_offchain_artifact_resolution_verified"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l5_artifacts.sh"

echo "== $TEST_NAME"
summary_on_abnormal_exit
l5_prepare
l5_require_resolver_arms

# ── §1 the arms ran over the artefacts they name ────────────────────────────────────────────────
note "§1 the arms run, and what it read"
assert_eq "the arms read the committed chain-class fixture" "$L5_FIXTURE" \
  "$(l5_res 'd["fixture"]')"
assert_prefix "…and resolved against the INSTALLED @aztec/protocol-contracts" \
  "@aztec/protocol-contracts@" "$(l5_res 'd["installedPackage"]')"
# THE PACKAGE'S ARTIFACT SET IS ASSERTED AS A COUNT, NOT AS "at least one". Trap 4b: an existential
# control is satisfied by one member of three, and this package ships exactly three.
assert_eq "…which ships exactly three contract artifacts" "3" \
  "$(l5_res 'len(d["installedArtifacts"])')"
assert_eq "…and they are the three protocol contracts, as a SET" \
  "ContractClassRegistry,ContractInstanceRegistry,FeeJuice" \
  "$(l5_res 'sorted(d["installedArtifacts"])')"

# ── §2 the subject: proved three ways ───────────────────────────────────────────────────────────
note "§2 the deployed FeeJuice class, proved against the installed package"
assert_eq "the class the chain serves at 0x…03 IS proved by an off-chain artifact" "true" \
  "$(l5_res 'd["subject"]["resolved"]')"
assert_eq "…by the installed protocol-contracts release, named" \
  "npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice" \
  "$(l5_res 'd["subject"]["origin"]')"
# CHECK 1 — the commitment.
assert_eq "check 1: computeArtifactHash over the artifact equals the class's artifactHash" \
  "$(l5_res 'd["subject"]["artifactHash"]')" \
  "0x1a57ff2a8e653094229bd15c028683e08b2086dfeadecac4c6b950c383b3ae1d"
# CHECK 2 — the code. Asserted as a LENGTH EQUALITY between two independently-sourced numbers: the
# artifact's own public_dispatch and the chain's packedBytecode. Byte-equality itself is enforced by
# the resolver; a length that disagreed would mean the resolver had stopped comparing.
assert_eq "check 2: the artifact's public_dispatch is the same length as the class's packedBytecode" \
  "$(l5_res 'd["subject"]["chainBytecodeBytes"]')" "$(l5_res 'd["subject"]["bytecodeBytes"]')"
assert_eq "…and that length is 1947 bytes" "1947" "$(l5_res 'd["subject"]["bytecodeBytes"]')"
# CHECK 3 — the identity.
assert_eq "check 3: the class id recomputed from the artifact equals the chain's" \
  "$(l5_res 'd["subject"]["chainClassId"]')" "$(l5_res 'd["subject"]["contractClassId"]')"
assert_eq "…and it is the class deployed at 0x…03" \
  "0x1f85d8b901a87b3fa9b93a44ab569ca2f5eb62412dfd58c894fdfff218be11a4" \
  "$(l5_res 'd["subject"]["chainClassId"]')"

note "§2b what the proved artifact is worth: rung 1, measured by rungFor and not asserted"
assert_eq "the artifact's own verdict is rung 1" "1" "$(l5_res 'd["subject"]["rung"]')"
assert_eq "…over 314 mapped program counters" "314" "$(l5_res 'd["subject"]["mappedPcs"]')"
assert_eq "…every one of which resolves to a (path, line, column)" \
  "$(l5_res 'd["subject"]["mappedPcs"]')" "$(l5_res 'd["subject"]["mappedPcsResolving"]')"
assert_eq "…keyed from pc 130" "130" "$(l5_res 'd["subject"]["pcRange"]["min"]')"
assert_eq "…to pc 1785, which is INSIDE the 1947-byte bytecode — the property that makes them AVM
  byte offsets rather than Brillig opcode indices" "1785" \
  "$(l5_res 'd["subject"]["pcRange"]["max"]')"
assert_eq "…over 32 source files" "32" "$(l5_res 'd["subject"]["sourceFiles"]')"
# TWELVE OF THIRTY-TWO, and the gap is the interesting figure: a Noir `file_map` carries every file
# the compilation READ, while the mapping only reaches the ones a pc lands in. Both are asserted,
# because "32 files are available" and "12 files are actually pointed at" are different claims and
# only the second is what a stepper walks.
assert_eq "…of which the mapping reaches 12 FILE IDS" "12" \
  "$(l5_res 'd["subject"]["fileIdsReached"]')"
assert_eq "…naming 12 DISTINCT paths, so no two of those ids share a path over the WHOLE map
  (the recording arms' 64-pc prefix reaches 9 of them, which is where that smaller figure comes
  from — the two are different measurements over different pc sets and are asserted separately)" \
  "12" "$(l5_res 'd["subject"]["distinctPathsReached"]')"
assert_eq "the first mapped pc is 130" "130" "$(l5_res 'd["subject"]["firstMappedPc"]')"
assert_eq "…and it is FeeJuice's own main.nr" "main.nr" \
  "$(l5_res 'd["subject"]["firstPositionBasename"]')"
assert_contains "…in the fee_juice_contract, by path" "fee_juice_contract/src/main.nr" \
  "$(l5_res 'd["subject"]["firstPosition"]["path"]')"
assert_eq "…at line 203" "203" "$(l5_res 'd["subject"]["firstPosition"]["line"]')"
assert_eq "…column 12, which only a rung-1 resolution has at all" "12" \
  "$(l5_res 'd["subject"]["firstPosition"]["column"]')"

# ── §3 the decoy: right bytecode, wrong artifact ────────────────────────────────────────────────
note "§3 the decoy — the shape a bytecode-only check accepts"
assert_eq "the decoy's public_dispatch is byte-identical to the real artifact's" "true" \
  "$(l5_res 'd["decoy"]["bytecodeIdenticalToReal"]')"
assert_eq "…and byte-identical to the CLASS's packedBytecode, so check 2 passes over it" "true" \
  "$(l5_res 'd["decoy"]["bytecodeIdenticalToChain"]')"
assert_eq "…and it is REFUSED anyway" "artifact-hash-mismatch" "$(l5_res 'd["decoy"]["fault"]')"
assert_true "…with the refusal naming both hashes" \
  str_has_sub "$(l5_res 'd["decoy"]["detail"]')" \
  "$(l5_res 'd["decoy"]["decoyArtifactHash"]')"
assert_true "…and saying WHY that combination is the dangerous one" \
  str_has_sub "$(l5_res 'd["decoy"]["detail"]')" "THE BYTECODE MATCHED AND THIS DID NOT"
# The two hashes must actually DIFFER, or the arm is asserting a refusal it could not have caused.
assert_false "the decoy's artifact hash is not the chain's, which is what makes it a decoy" \
  [ "$(l5_res 'd["decoy"]["decoyArtifactHash"]')" = "$(l5_res 'd["decoy"]["chainArtifactHash"]')" ]

# ── §4 the two key shapes ───────────────────────────────────────────────────────────────────────
note "§4 both key shapes, both exercised — the research's own first answer checked one"
assert_eq "npm's artifact is the snake_case NoirCompiledContract shape" "snake_case" \
  "$(l5_res 'd["shapes"]["snakeShape"]')"
assert_eq "…and the loaded-and-JSON-round-tripped form is camelCase, which is what the explorer
  stores for a protocol contract" "camelCase" "$(l5_res 'd["shapes"]["camelShape"]')"
assert_eq "the snake_case candidate verifies" "true" "$(l5_res 'd["shapes"]["snakeVerified"]')"
assert_eq "…and so does the camelCase one" "true" "$(l5_res 'd["shapes"]["camelVerified"]')"
assert_eq "…to the SAME artifact hash, because the spelling is not the artifact" \
  "$(l5_res 'd["shapes"]["snakeArtifactHash"]')" "$(l5_res 'd["shapes"]["camelArtifactHash"]')"
assert_eq "…and the same debug digest, so the two shapes carry the same source map" \
  "$(l5_res 'd["shapes"]["snakeDebugDigest"]')" "$(l5_res 'd["shapes"]["camelDebugDigest"]')"
assert_eq "…and that hash is the chain's" "$(l5_res 'd["shapes"]["chainArtifactHash"]')" \
  "$(l5_res 'd["shapes"]["snakeArtifactHash"]')"
note "§4b the Buffer revival is LOAD-BEARING, and this is the number that says so"
assert_eq "hashing the camelCase payload WITHOUT reviving its JSON-serialised Buffers gives a
  different answer" "true" "$(l5_res 'd["shapes"]["revivalChangesTheHash"]')"
assert_false "…specifically, one that is NOT the chain's — so a resolver without reviveBuffers
  reports every protocol artifact unverified, which reads exactly like an explorer with nothing" \
  [ "$(l5_res 'd["shapes"]["unrevivedArtifactHash"]')" \
    = "$(l5_res 'd["shapes"]["chainArtifactHash"]')" ]
assert_eq "…while reviving them gives the chain's" \
  "$(l5_res 'd["shapes"]["chainArtifactHash"]')" \
  "$(l5_res 'd["shapes"]["revivedArtifactHash"]')"

note "§4c a shape neither branch places is REPORTED rather than read as absence"
assert_eq "a bare object is refused as an unrecognised key shape" "unrecognised-key-shape" \
  "$(l5_res 'd["refusals"]["bareObjectFault"]')"
assert_eq "…and keyShapeOf itself answers null rather than guessing a spelling" "MISSING" \
  "$(l5_res 'd["shapes"]["unrecognisedShape"]')"
assert_true "…and the refusal says an unrecognised shape and an absent one are the same value" \
  str_has_sub "$(l5_res 'd["refusals"]["bareObjectDetail"]')" \
  "an unrecognised shape and an absent one are the same value"
assert_eq "a REAL artifact with public_dispatch removed is refused for that, and not for its shape" \
  "no-public-dispatch" "$(l5_res 'd["refusals"]["noDispatchFault"]')"
assert_eq "…and the removal really removed one function" "1" \
  "$(( $(l5_res 'd["refusals"]["functionsBefore"]') - $(l5_res 'd["refusals"]["functionsAfter"]') ))"

# ── §5 the boundary: what artifactHash does NOT commit to ───────────────────────────────────────
note "§5 the arm that PASSES, and it is the reason ct.source-provenance exists"
assert_eq "the honest artifact verifies" "true" "$(l5_res 'd["uncommitted"]["honestVerified"]')"
assert_eq "the artifact with a REWRITTEN SOURCE MAP verifies TOO" "true" \
  "$(l5_res 'd["uncommitted"]["tamperedVerified"]')"
assert_eq "…with the same artifact hash" "true" "$(l5_res 'd["uncommitted"]["sameArtifactHash"]')"
assert_eq "…and the same class id" "true" "$(l5_res 'd["uncommitted"]["sameClassId"]')"
assert_eq "…so all three checks are satisfied by a map that is a lie: artifactHash's preimage is
  the two function-tree roots and the artifact metadata, and debug_symbols is in none of them" \
  "MISSING" "$(l5_res 'd["uncommitted"]["tamperedFault"]')"
assert_eq "the ONE thing that differs is the debug digest, which is what corroboration counts" \
  "true" "$(l5_res 'd["uncommitted"]["differentDebugDigest"]')"

# ── §6 corroboration, both directions, and the strict policy ────────────────────────────────────
note "§6 corroboration is measured over DISTRIBUTORS and over the debug digest"
assert_eq "two distributors serving the SAME bytes corroborate" "corroborated" \
  "$(l5_res 'd["uncommitted"]["agreeingCorroboration"]')"
assert_eq "…and both are named" "a-second-registry,npm" \
  "$(l5_res 'sorted(d["uncommitted"]["agreeingDistributors"])')"
assert_eq "two distributors DISAGREEING about the source map do NOT corroborate" \
  "single-distributor" "$(l5_res 'd["uncommitted"]["disagreeingCorroboration"]')"
assert_eq "…although both candidates verified, which is the whole point" "2" \
  "$(l5_res 'd["uncommitted"]["disagreeingAgreeing"]')"
assert_true "…and the resolution NAMES the digest it did not use rather than dropping it" \
  str_has_sub "$(l5_res 'd["uncommitted"]["disagreeingReason"]')" \
  "carry a DIFFERENT debug digest and were not used"
note "§6b the real subject is single-distributor, and it says so"
assert_eq "the deployed FeeJuice is attested by one distributor" "single-distributor" \
  "$(l5_res 'd["subject"]["corroboration"]')"
assert_eq "…named" "npm" "$(l5_res 'd["subject"]["agreeingDistributors"]')"
assert_true "…and the resolution states the caveat in its own reason, so a container carries it" \
  str_has_sub "$(l5_res 'd["subject"]["reason"]')" \
  "artifactHash does NOT commit to debug_symbols or file_map"
note "§6c requireCorroboration is EXECUTABLE POLICY and this runs it"
assert_eq "with requireCorroboration set, the same subject is REFUSED" "false" \
  "$(l5_res 'd["strict"]["resolved"]')"
assert_true "…and the refusal says the artifact WAS proved, which is the distinction" \
  str_has_sub "$(l5_res 'd["strict"]["reason"]')" "WAS proved"
assert_true "…and names the single distributor" \
  str_has_sub "$(l5_res 'd["strict"]["reason"]')" "only 1 distributor (npm)"

# ── §7 the control ──────────────────────────────────────────────────────────────────────────────
note "§7 the CONTROL — the same resolver, a class nobody publishes"
assert_eq "the third-party token class resolves to NOTHING" "false" \
  "$(l5_res 'd["control"]["resolved"]')"
assert_eq "…with zero candidates even considered, because no installed artifact has its bytecode" \
  "0" "$(l5_res 'd["control"]["candidatesConsidered"]')"
assert_eq "…and it is a real class with real bytecode, not an empty subject" "23157" \
  "$(l5_res 'd["control"]["chainBytecodeBytes"]')"
assert_eq "…the one every other transaction in this campaign's frozen testnet capture calls" \
  "0x2b6749411979b61926b6f8836c3a1a28c39e9c0c3fb3322ed6e776f2f02cb6dc" \
  "$(l5_res 'd["control"]["chainClassId"]')"
assert_true "…and the refusal says the rung stays 3" \
  str_has_sub "$(l5_res 'd["control"]["reason"]')" \
  "THE RUNG STAYS 3 AND THE STEPS STAY UNPOSITIONED"
# THE POSITIVE TWIN, RESTATED AS A PAIR SO THE NEGATIVE CANNOT PASS ALONE (trap 4a).
assert_false "the control and the subject disagree, so the resolver is discriminating rather than
  answering one way to everything" \
  [ "$(l5_res 'd["control"]["resolved"]')" = "$(l5_res 'd["subject"]["resolved"]')" ]

finish
