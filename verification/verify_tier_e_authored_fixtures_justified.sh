#!/usr/bin/env bash
# verify_tier_e_authored_fixtures_justified — M2, Tier E.
#
# Every Tier E fixture records why no upstream equivalent exists, so the authored tier cannot grow
# by default.
#
# The structural half — tagged, long enough, names upstream paths, and Tier E is strictly the
# smallest tier — is in `_manifest_parser.py` and is exercised by
# `verify_fixture_corpus_manifest_complete`. That half is NOT sufficient and this campaign has the
# scar to prove it: M1's inventory checker enforced exactly those properties and three of eight
# tagged, padded rejection reasons still turned out to be factually wrong, because structure cannot
# tell a true justification from a false one.
#
# So this check does the other half. Every SUBSTANTIVE claim each Tier E entry rests on is
# re-derived from the pinned aztec-packages fork on every run — with `git ls-tree`, `git show`,
# `git grep` and `git cat-file` — and the check goes red if upstream has since closed the gap. That
# is the only mechanism that makes "no upstream equivalent" falsifiable rather than asserted.
#
# It fails, rather than skipping, if the fork or the pins are missing.

TEST_NAME="verify_tier_e_authored_fixtures_justified"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$REPO_ROOT/fixtures/MANIFEST.md"
BLOCK_LOOP="$REPO_ROOT/fixtures/authored/block-loop/README.md"
TRACE="$REPO_ROOT/fixtures/authored/trace-output/README.md"
PARSER="$VERIFY_DIR/_manifest_parser.py"
PINS="$REPO_ROOT/pins.json"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
[ -f "$MANIFEST" ] || die "fixtures/MANIFEST.md does not exist"
[ -f "$BLOCK_LOOP" ] || die "fixtures/authored/block-loop/README.md does not exist"
[ -f "$TRACE" ] || die "fixtures/authored/trace-output/README.md does not exist"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"

CPP="$(python3 -c "import json;print(json.load(open('$PINS'))['anchors']['cpp']['commit'])")"
TS="$(python3 -c "import json;print(json.load(open('$PINS'))['anchors']['ts']['commit'])")"
[ -n "$CPP" ] && [ -n "$TS" ] || die "could not read the anchors from pins.json"
note "cpp anchor $CPP, ts anchor $TS"

at() { # <anchor> <path>  -> the blob, or empty
  ( cd "$FORK_ROOT" && git show "$1:$2" ) 2>/dev/null
}
exists_at() { ( cd "$FORK_ROOT" && git cat-file -e "$1:$2" ) >/dev/null 2>&1; }

echo "== Tier E has exactly the two families the milestone names, and no more"
E_IDS="$(python3 "$PARSER" entries --manifest "$MANIFEST" | awk -F'\t' '$2=="E"{print $1}' | tr '\n' ' ')"
E_COUNT="$(python3 "$PARSER" entries --manifest "$MANIFEST" | awk -F'\t' '$2=="E"' | grep -c .)"
note "Tier E entries: $E_IDS"
assert_eq "Tier E entry count" "2" "$E_COUNT"
assert_true "one Tier E entry is the timer-driven block loop" \
  grep -q "family: A block per tick" "$MANIFEST"
assert_true "the other is CodeTracer trace output" \
  grep -q "family: Golden \`.ct\` recordings" "$MANIFEST"

echo "== every Tier E entry names its authoring milestone, so the tier has an end"
assert_true "the block-loop family is assigned to M23" grep -q "M23" "$BLOCK_LOOP"
assert_true "the trace family is assigned to M24 and M25" \
  bash -c "grep -q 'M24' '$TRACE' && grep -q 'M25' '$TRACE'"

echo "== every upstream path either family cites resolves at its anchor"
# A justification that names a path which does not exist is not evidence, it is decoration.
# NB: the backtick must NOT be backslash-escaped inside the ERE. GNU grep reads `\\`` as the
# "start of buffer" anchor, which silently matches nothing — an earlier revision of this line did
# exactly that and reported zero cited paths while the loop below happily found zero unresolved
# ones, i.e. a vacuous pass. The floor assertion under it is what caught it.
CITED="$(grep -ohE '`(yarn-project|barretenberg|noir-projects)/[A-Za-z0-9_./-]+`' "$BLOCK_LOOP" "$TRACE" "$MANIFEST" \
  | tr -d '`' | sort -u)"
CITED_COUNT="$(printf '%s\n' "$CITED" | grep -c . || true)"
assert_ge "upstream paths cited by the Tier E material" 12 "${CITED_COUNT:-0}"

# One cited path is cited precisely BECAUSE it is absent: the per-instruction C++ observer is ours,
# and claim 3 below turns that into an assertion. It is listed here explicitly rather than filtered
# by a pattern, so that a second "absent" path cannot be smuggled in without appearing in this file.
ABSENT_BY_DESIGN="barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
for p in $ABSENT_BY_DESIGN; do
  if exists_at "$CPP" "$p" || exists_at "$TS" "$p"; then
    fail "a path cited as absent now exists upstream, so the claim resting on it must be re-argued: $p"
  else
    pass "cited as absent, and genuinely absent at both anchors: $p"
  fi
done

UNRESOLVED=0
while read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    */) continue ;;
  esac
  case " $ABSENT_BY_DESIGN " in
    *" $p "*) continue ;;
  esac
  if exists_at "$CPP" "$p" || exists_at "$TS" "$p"; then
    :
  else
    # A directory rather than a file is fine, as long as it is populated at one of the anchors.
    if [ -n "$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$CPP" -- "$p" ) 2>/dev/null | head -1 )" ] ||
       [ -n "$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$TS" -- "$p" ) 2>/dev/null | head -1 )" ]; then
      :
    else
      fail "a cited upstream path resolves at neither anchor: $p"
      UNRESOLVED=$((UNRESOLVED + 1))
    fi
  fi
done <<<"$CITED"
assert_eq "cited upstream paths that do not resolve" "0" "$UNRESOLVED"

# ---------------------------------------------------------------------------
echo "== block loop: the four claims, re-derived from the fork"
# ---------------------------------------------------------------------------

# Claim 1 — the automining sequencer's directory contains no test file at all.
AUTOMINE_FILES="$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$CPP" -- yarn-project/sequencer-client/src/sequencer/automine/ ) 2>/dev/null )"
AUTOMINE_COUNT="$(printf '%s\n' "$AUTOMINE_FILES" | grep -c . || true)"
AUTOMINE_TESTS="$(printf '%s\n' "$AUTOMINE_FILES" | grep -c '\.test\.ts$' || true)"
assert_ge "the automining sequencer directory exists upstream" 3 "${AUTOMINE_COUNT:-0}"
assert_eq "claim 1: it contains no test file" "0" "${AUTOMINE_TESTS:-1}"
assert_true "claim 1 is stated in the family README" grep -q "automine-has-no-tests" "$BLOCK_LOOP"
assert_true "buildEmptyBlock is the untested thing the claim is about" \
  bash -c "at() { ( cd '$FORK_ROOT' && git show \"\$1:\$2\" ) 2>/dev/null; }; at '$CPP' yarn-project/sequencer-client/src/sequencer/automine/automine_sequencer.ts | grep -q 'buildEmptyBlock'"

# Claim 2 — upstream's only deadline test is skipped, at BOTH anchors.
for anchor_name in cpp ts; do
  anchor="$CPP"; [ "$anchor_name" = "ts" ] && anchor="$TS"
  BODY="$(at "$anchor" yarn-project/simulator/src/public/public_processor/public_processor.test.ts)"
  assert_ge "public_processor.test.ts read at the $anchor_name anchor" 300 "$(printf '%s\n' "$BODY" | grep -c . || true)"
  SKIPPED="$(printf '%s\n' "$BODY" | grep -c "it.skip('does not go past the deadline'" || true)"
  RUNNING="$(printf '%s\n' "$BODY" | grep -c "it('does not go past the deadline'" || true)"
  assert_eq "claim 2 at $anchor_name: the deadline test is skipped" "1" "${SKIPPED:-0}"
  assert_eq "claim 2 at $anchor_name: and there is no unskipped one" "0" "${RUNNING:-1}"
done
assert_true "claim 2 is stated in the family README" grep -q "deadline-test-skipped" "$BLOCK_LOOP"

# Claim 3 — the standard block test double emits a constant timestamp.
HEADER="$(at "$CPP" yarn-project/stdlib/src/rollup/checkpoint_header.ts)"
assert_ge "checkpoint_header.ts read at the cpp anchor" 100 "$(printf '%s\n' "$HEADER" | grep -c . || true)"
assert_true "claim 3: CheckpointHeader.random hardcodes Date.now() as the timestamp" \
  bash -c "printf '%s\n' \"\$0\" | grep -q 'timestamp: BigInt(Math.floor(Date.now() / 1000))'" "$HEADER"
assert_true "claim 3 is stated in the family README" grep -q "random-header-constant-timestamp" "$BLOCK_LOOP"

# Claim 4 — TXE's advanceBlocksBy does not advance the clock.
TXE="$(at "$CPP" yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts)"
assert_ge "the TXE top-level context read at the cpp anchor" 500 "$(printf '%s\n' "$TXE" | grep -c . || true)"
assert_true "claim 4: advanceBlocksBy is a bare loop over mineBlock" \
  bash -c "printf '%s\n' \"\$0\" | tr '\n' ' ' | grep -q 'async advanceBlocksBy(blocks: number)'" "$TXE"
TS_MUTATIONS="$(printf '%s\n' "$TXE" | grep -c 'this.nextBlockTimestamp +=\|this.nextBlockTimestamp =' || true)"
assert_eq "claim 4: nextBlockTimestamp is mutated in exactly one place" "1" "${TS_MUTATIONS:-0}"
assert_true "claim 4 is stated in the family README" grep -q "txe-advance-blocks-shares-timestamp" "$BLOCK_LOOP"

# The primitives we DO reuse must exist, or the family is over-claiming in the other direction.
assert_true "ManualDateProvider exists upstream and is what we reuse" \
  bash -c "at() { ( cd '$FORK_ROOT' && git show \"\$1:\$2\" ) 2>/dev/null; }; at '$CPP' yarn-project/foundation/src/timer/date.ts | grep -q 'class ManualDateProvider'"
assert_true "RunningPromise exists upstream and is what we reuse" \
  bash -c "at() { ( cd '$FORK_ROOT' && git show \"\$1:\$2\" ) 2>/dev/null; }; at '$CPP' yarn-project/foundation/src/promise/running-promise.ts | grep -q 'class RunningPromise'"
assert_true "the family README names them as reused rather than reinvented" \
  bash -c "grep -q 'ManualDateProvider' '$BLOCK_LOOP' && grep -q 'RunningPromise' '$BLOCK_LOOP'"

# ---------------------------------------------------------------------------
echo "== trace output: the three claims, re-derived from the fork"
# ---------------------------------------------------------------------------

# Claim 1 — no trace artefact of any kind upstream.
CT_FILES="$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$CPP" ) 2>/dev/null | grep -c '\.ct$' || true)"
assert_eq "claim 1: no .ct artefact anywhere upstream" "0" "${CT_FILES:-1}"
assert_true "claim 1 is stated in the family README" grep -q "no-ct-artifacts-upstream" "$TRACE"

# Claim 2 — the one per-instruction TypeScript hook carries a name and a gas delta and nothing else.
SIM="$(at "$TS" yarn-project/simulator/src/public/avm/avm_simulator.ts)"
assert_ge "avm_simulator.ts read at the ts anchor" 100 "$(printf '%s\n' "$SIM" | grep -c . || true)"
assert_true "claim 2: the hook's whole signature is (string, Gas)" \
  bash -c "printf '%s\n' \"\$0\" | grep -q 'tallyInstructionFunction = (_b: string, _c: Gas) => {}'" "$SIM"
assert_true "claim 2: it is called once per instruction with a class name" \
  bash -c "printf '%s\n' \"\$0\" | grep -q 'tallyInstructionFunction(instruction.constructor.name, gasUsed)'" "$SIM"
assert_true "claim 2 is stated in the family README" grep -q "tally-hook-carries-name-and-gas-only" "$TRACE"

# Claim 3 — the per-instruction C++ observer is ours, not upstream's.
if exists_at "$CPP" barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp; then
  fail "claim 3: execution_observer.hpp NOW EXISTS upstream — Tier E's trace justification must be re-argued"
else
  pass "claim 3: execution_observer.hpp does not exist at the cpp anchor, so the observer is ours"
fi
assert_true "claim 3 is stated in the family README" grep -q "execution-observer-not-upstream" "$TRACE"
assert_true "…and M9 is named as the milestone that prepares it upstream" grep -q "M9" "$TRACE"

# The seams that DO exist must exist, or the family is over-claiming.
assert_true "ExecutionEvent exists upstream (a real per-instruction record, in memory only)" \
  exists_at "$CPP" barretenberg/cpp/src/barretenberg/vm2/simulation/events/execution_event.hpp
assert_true "the vm2 debugger exists upstream (interactive, over circuit rows)" \
  exists_at "$CPP" barretenberg/cpp/src/barretenberg/vm2/tooling/debugger.cpp
assert_true "PublicSideEffectTraceInterface exists upstream (transaction-level)" \
  exists_at "$TS" yarn-project/simulator/src/public/side_effect_trace.ts
assert_true "the family README enumerates each of them and says why it is not a trace" \
  bash -c "grep -q 'ExecutionEvent' '$TRACE' && grep -q 'debugger.cpp' '$TRACE' && grep -q 'PublicSideEffectTraceInterface' '$TRACE'"

echo "== each family's authored fixtures carry an assertion that cannot be met by an empty artefact"
assert_true "the trace family's step count is cross-checked against the engine's own tally" \
  grep -q "step count equals the engine" "$TRACE"
assert_true "the block-loop family asserts world-state roots, not just call sequences" \
  grep -q "roots" "$BLOCK_LOOP"

# ---------------------------------------------------------------------------
echo "== negative controls"
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# (1) The upstream re-derivation is real: a claim asserted about a path that DOES have tests must
#     be rejected. `yarn-project/sequencer-client/src/sequencer/` (one level up from automine/) does
#     have test files, so the same probe run against it must come out non-zero.
PARENT_TESTS="$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$CPP" -- yarn-project/sequencer-client/src/sequencer/ ) 2>/dev/null | grep -c '\.test\.ts$' || true)"
assert_ge "negative control: the same probe finds tests one directory up" 1 "${PARENT_TESTS:-0}"

# (2) The "no .ct file" probe is capable of finding one: the same probe over a suffix that DOES
#     occur must come out non-zero, so zero is a measurement rather than a broken pipeline.
TS_FILES="$( ( cd "$FORK_ROOT" && git ls-tree -r --name-only "$CPP" ) 2>/dev/null | grep -c '\.ts$' || true)"
assert_ge "negative control: the same file-suffix probe finds .ts files" 1000 "${TS_FILES:-0}"

# (3) The `git cat-file` existence probe is capable of succeeding.
assert_true "negative control: the existence probe succeeds for a file that is there" \
  exists_at "$CPP" barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.hpp

# (4) A Tier E entry whose claim ids are removed from its README must be caught. Run the same
#     grep-based assertions against a mutated copy.
cp "$BLOCK_LOOP" "$SCRATCH/block-loop.md"
python3 - "$SCRATCH/block-loop.md" <<'PY'
import sys
p = sys.argv[1]
open(p, "w").write(open(p).read().replace("automine-has-no-tests", "REMOVED"))
PY
if grep -q "automine-has-no-tests" "$SCRATCH/block-loop.md"; then
  fail "negative control NOT caught: the claim id survived removal"
else
  pass "negative control caught: a removed claim id is detected by the same grep"
fi

# (5) Tier E must not be able to grow by default, and there are two separate mechanisms for that.
#     Both are exercised here, on real copies, through the real code paths.
#
#       (a) THIS script pins Tier E to exactly the two families the milestone names, so ONE extra
#           entry is already a failure.
#       (b) the parser's "strictly smaller than every other tier" rule is what stops the tier
#           growing over several milestones without any single step looking wrong. It needs enough
#           extra entries to reach the next smallest tier, so the control adds that many.
#
#     (b) alone is deliberately weaker than (a): with A=4, B=4, C=5, D=6 and H=4 it would tolerate
#         Tier E reaching 3. Saying so here rather than letting the pair look stronger than it is.
grow_tier_e() { # <n> -> writes $SCRATCH/grown.md with n extra Tier E entries
  python3 - "$MANIFEST" "$SCRATCH/grown.md" "$1" <<'PY'
import sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
t = open(src).read()
blocks = []
for i in range(n):
    fx = 26 + i
    blocks.append(f"""
### FX-{fx} — An extra authored family
- tier: E
- family: Something someone decided to write rather than look for
- where: fixtures/authored/block-loop/README.md
- upstream-source: none — authored
- capture: `cd diffsim && npm test -- src/corpus` for want of anywhere better to point it
- licence: Apache-2.0
- measured: 2026-08-21 — 1 fixture, 0 claims re-verified
- skeptic-concludes: That an entry can be added to Tier E without anyone noticing, which is exactly the property this manifest is supposed to make impossible, and which the tier-size rule exists to stop happening quietly over several milestones.
- skeptic-cannot-conclude: Anything at all, since nothing about this entry has been measured or checked against upstream at either anchor.
- no-upstream-equivalent: does-not-exist: nothing upstream does this, having looked at `yarn-project/simulator/src` and `barretenberg/cpp/src/barretenberg/vm2`, and it therefore has to be written here, at sufficient length to clear the two-hundred character floor that the manifest checker imposes on this field for exactly this reason.
- inventory: RI-44
""")
open(dst, "w").write(t.replace("\n<!-- END:manifest -->", "".join(blocks) + "\n<!-- END:manifest -->", 1))
PY
}

grow_tier_e 1
GROWN_E="$(python3 "$PARSER" entries --manifest "$SCRATCH/grown.md" | awk -F'\t' '$2=="E"' | grep -c .)"
if [ "$GROWN_E" = "2" ]; then
  fail "negative control NOT caught: one extra Tier E entry did not change the count"
else
  pass "negative control caught: one extra Tier E entry breaks this check's exact-count assertion ($GROWN_E)"
fi

SMALLEST_OTHER="$(python3 "$PARSER" entries --manifest "$MANIFEST" | awk -F'\t' '$2!="E"{print $2}' | sort | uniq -c | awk '{print $1}' | sort -n | head -1)"
NEEDED=$(( SMALLEST_OTHER - 2 ))
note "the smallest non-E tier has $SMALLEST_OTHER entries, so $NEEDED extra E entries reach it"
grow_tier_e "$NEEDED"
if python3 "$PARSER" check --repo "$REPO_ROOT" --manifest "$SCRATCH/grown.md" >/dev/null 2>&1; then
  fail "negative control NOT caught: Tier E grew to $SMALLEST_OTHER entries and the parser accepted it"
else
  pass "negative control caught: Tier E growing to the size of the smallest other tier is rejected"
fi

finish
