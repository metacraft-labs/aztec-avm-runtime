#!/usr/bin/env bash
# verify_l5_artifact_sources_live — L5 (Aztec-Live-Chain-Replay).
#
# **THIS CHECK REACHES THE NPM REGISTRY AND A BLOCK EXPLORER ON EVERY RUN AND IS NOT PART OF ANY
# FLOOR.** `verify-l4-net`'s rule, restated because it applies here for the same reason: a check
# that needs a live third party goes red on somebody else's schedule, and summing it into the
# offline floor makes the floor depend on somebody else's uptime.
#
# It exists because three of L5's load-bearing claims are about the WORLD rather than about this
# repository, and every one of them is the kind of figure that rots when nothing re-takes it:
#
#   §2  A REAL PUBLISHED RELEASE IS A DECOY. `@aztec/protocol-contracts@5.0.0-rc.2`'s FeeJuice ships
#       byte-identical public bytecode to the class deployed at `0x…03` under a different artifact
#       hash and a different `debug_symbols`. The offline check derives its decoy by renaming a
#       contract; this one did not have to derive anything, and it is the reason
#       `artifact_resolution.ts` treats a version string as a candidate generator and never as
#       evidence.
#   §3  THE EXPLORER SERVES TWO KEY SHAPES and the route that answers them exists — with its own
#       404 distinguishable from a missing route, which is what stops "the explorer holds nothing"
#       being reported forever by a check pointed at a moved URL.
#   §4  THE EXPLORER'S OWN VERIFICATION IS WEAKER THAN OURS, measured rather than asserted: its
#       camelCase artifacts do not reproduce the artifact hash IT RECORDS FOR THEM until their
#       JSON-serialised Buffers are revived, and it lists classes it holds no artifact for.
#
# ─────────────────────────────────────────────────────────────────────────────
# A RUN THAT FINDS NOTHING IS A DEATH, NOT A PASS.
#
# Every assertion below is over a set the network produced. `assert_ge … 1` before any property of
# that set is asserted — trap 4 — and where the size is knowable the COUNT is asserted, because an
# existential control is satisfied by one member of three.

set -uo pipefail
TEST_NAME="verify_l5_artifact_sources_live"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l5_artifacts.sh"

echo "== $TEST_NAME"
echo "== THIS CHECK NEEDS THE NPM REGISTRY AND api.testnet.aztecscan.xyz. It is NOT in the floor."
summary_on_abnormal_exit
l5_prepare

LIVE="$L5_WORK/live-arms.json"
timeout "${L5_LIVE_TIMEOUT:-1800}" node --experimental-strip-types \
  "$REPO_ROOT/tools/run_l5_live_source_arms.mjs" "$L5_FIXTURE" \
  >"$LIVE.tmp" 2>"$L5_WORK/live-arms.log" \
  || { cat "$L5_WORK/live-arms.log" >&2
       die "the live arms run failed. That may be the network rather than this repository — read
     $L5_WORK/live-arms.log before concluding anything. It is a DEATH and not a skip: a check that
     skips reads as a smaller milestone rather than a red one."; }
mv "$LIVE.tmp" "$LIVE"
live() { l5_arm "$LIVE" "$1"; }

# ── §1 the three releases were all fetched ──────────────────────────────────────────────────────
note "§1 the set the network produced, sized before anything is asserted about it"
assert_eq "three @aztec/protocol-contracts releases were fetched, and the COUNT is asserted rather
  than 'at least one' — the membership is written literally in the arms runner" "3" \
  "$(live 'len(d["npm"]["releases"])')"
assert_eq "…and they are the three named" "5.0.0-rc.2,5.2.0,5.3.0-nightly.20260819" \
  "$(live 'sorted(d["npm"]["releases"].keys())')"

# ── §2 the published decoy ──────────────────────────────────────────────────────────────────────
note "§2 5.0.0-rc.2 — a REAL release with the right bytecode and the wrong artifact"
assert_eq "5.0.0-rc.2's public_dispatch is byte-equal to the DEPLOYED class's packedBytecode" \
  "true" "$(live 'd["npm"]["releases"]["5.0.0-rc.2"]["bytecodeEqualsChain"]')"
assert_eq "…all 1947 bytes of it" "$(live 'd["npm"]["chainBytecodeBytes"]')" \
  "$(live 'd["npm"]["releases"]["5.0.0-rc.2"]["bytecodeBytes"]')"
assert_eq "…and it is REFUSED, on the artifact hash" "artifact-hash-mismatch" \
  "$(live 'd["npm"]["releases"]["5.0.0-rc.2"]["fault"]')"
assert_false "…because its artifact hash is not the chain's" \
  [ "$(live 'd["npm"]["releases"]["5.0.0-rc.2"]["artifactHash"]')" \
    = "$(live 'd["npm"]["chainArtifactHash"]')" ]
# THE HALF THAT MAKES IT DANGEROUS RATHER THAN MERELY WRONG: its debug map differs, so a resolver
# that took it would produce real-looking source lines from the wrong compilation.
assert_false "…and its debug_symbols differ from the release that DOES verify, so taking it would
  have produced plausible line numbers out of a different compilation" \
  [ "$(live 'd["npm"]["releases"]["5.0.0-rc.2"]["debugSymbolsChars"]')" \
    = "$(live 'd["npm"]["releases"]["5.3.0-nightly.20260819"]["debugSymbolsChars"]')" ]

note "§2b the two releases that DO reproduce the deployed class — the positive twin"
assert_eq "5.2.0 verifies" "true" "$(live 'd["npm"]["releases"]["5.2.0"]["verified"]')"
assert_eq "5.3.0-nightly.20260819 verifies" "true" \
  "$(live 'd["npm"]["releases"]["5.3.0-nightly.20260819"]["verified"]')"
assert_eq "…and both carry the SAME debug digest, so they agree about the source too" \
  "$(live 'd["npm"]["releases"]["5.2.0"]["debugDigest"]')" \
  "$(live 'd["npm"]["releases"]["5.3.0-nightly.20260819"]["debugDigest"]')"
# THAT AGREEMENT IS *NOT* CORROBORATION AND THIS ASSERTION IS WHY THE DISTINCTION EXISTS: two
# releases of one registry are one distributor's account of itself. `SOURCE_CORROBORATION` counts
# distributors precisely so this cannot be mistaken for independent attestation.
assert_eq "…which is agreement between two RELEASES of one registry and is NOT corroboration:
  corroboration counts DISTRIBUTORS, and npm is one" "single-distributor" \
  "$(l5_res 'd["subject"]["corroboration"]' 2>/dev/null || printf 'MISSING\n')"

# ── §3 the explorer's route and its two shapes ──────────────────────────────────────────────────
note "§3 the explorer — the route exists, and its 404 is not a missing route"
assert_eq "a hash the explorer does not hold answers 404" "404" \
  "$(live 'd["explorer"]["deployedFeeJuice"]["status"]')"
assert_eq "…with an EMPTY body, which is the route answering" "0" \
  "$(live 'd["explorer"]["deployedFeeJuice"]["bodyLength"]')"
assert_eq "…while a URL the service does not route answers 404 too" "404" \
  "$(live 'd["explorer"]["wrongRoute"]["status"]')"
assert_eq "…but with Express's route-not-found page, so the two are distinguishable and the
  provider raises on the second rather than reporting 'no artifact'" "true" \
  "$(live 'd["explorer"]["wrongRoute"]["isExpressNotFound"]')"
note "§3b so the deployed FeeJuice is served by npm and by NOTHING else — the single-source case"
assert_eq "the explorer holds no artifact for the class deployed at 0x…03" "404" \
  "$(live 'd["explorer"]["deployedFeeJuice"]["status"]')"

note "§3c the two key shapes, in the wild"
assert_ge "the explorer listed at least one class" 1 "$(live 'd["explorer"]["classesListed"]')"
assert_ge "…and holds an artifact for at least one of them, so the set below is not empty" 1 \
  "$(live 'd["explorer"]["classesWithAnArtifactName"]')"
assert_eq "…and every one of those was fetched" \
  "$(live 'd["explorer"]["classesWithAnArtifactName"]')" \
  "$(live 'len(d["explorer"]["artifacts"])')"
# BOTH SHAPES MUST APPEAR. If only one did, the "we handle both" claim would be untested against
# the wild and the check would be asserting a property of a set with one kind in it.
assert_ge "at least one artifact arrived in the snake_case NoirCompiledContract shape" 1 \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "snake_case"])')"
assert_ge "…and at least one in the camelCase ContractArtifact shape" 1 \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "camelCase"])')"
assert_eq "…and NONE in a shape neither branch places" "0" \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") is None])')"

# ── §4 what the explorer's own verification is worth ────────────────────────────────────────────
note "§4 our check is strictly stronger, measured on the explorer's own stored artifacts"
assert_eq "every snake_case artifact the explorer serves VERIFIES against the class it records" \
  "0" "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "snake_case" and not a.get("verified")])')"
# THE camelCase ONES NEEDED THE REVIVAL, and that is the measured content of the two-shapes caveat:
# the explorer stores them JSON-round-tripped, so the artifact hash it RECORDS for a class is not
# the hash of the bytes it SERVES for it until the Buffers are put back.
# THE COUNT AND NOT "at least one": the camelCase set's size is known from the line above, and
# EVERY member of it must have needed the revival — one that did not would mean the explorer had
# started storing that shape differently, which is a finding rather than a convenience.
assert_eq "EVERY camelCase artifact needed its Buffers revived before it hashed to the artifact
  hash the explorer itself records for it" \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "camelCase"])')" \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "camelCase" and a.get("revivalWasNeeded") is True])')"
# AND THE QUESTION IS NOT ASKED OF THE OTHER SHAPE, which is a correction rather than an omission:
# `computeArtifactHash` over a raw `NoirCompiledContract` answers a number about nothing, and the
# first version of this arm asked it anyway — so all six artifacts reported "revival was needed"
# and the measurement discriminated nothing.
assert_eq "…and no snake_case artifact was asked the question, because it is meaningless for that
  shape — `null` rather than a `false` that would read as 'revival was not needed'" "0" \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "snake_case" and a.get("revivalWasNeeded") is not None])')"
assert_eq "…and after revival, every camelCase artifact verifies too" "0" \
  "$(live 'len([a for a in d["explorer"]["artifacts"] if a.get("shape") == "camelCase" and not a.get("verified")])')"

note "§4b the third-party class this campaign's captures actually call"
assert_eq "the explorer knows the class" "200" \
  "$(live 'd["explorer"]["thirdPartyTokenClass"]["status"]')"
assert_eq "…and records NO artifact name for it" "MISSING" \
  "$(live 'd["explorer"]["thirdPartyTokenClass"]["artifactContractName"]')"
assert_eq "…so its artifact endpoint answers 404, which is why four of this campaign's six frozen
  testnet containers stay at rung 3" "404" \
  "$(live 'd["explorer"]["thirdPartyToken"]["status"]')"

finish
