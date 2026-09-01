#!/usr/bin/env bash
# verify_fallback_cost_priced — M16.
#
# M16's second and third deliverables ask for the switch to be priced and for the known hazard to
# be recorded with its target values, "so a future reader need not redo the analysis". A price and
# a pair of root values copied out of the milestone text would satisfy that sentence and would
# agree with the milestone text forever, including after the package changed shape or the protocol
# moved its separator. So NOTHING here is quoted.
#
#   * THE REUSE QUESTION IS ASKED FIRST, and by enumeration over the WHOLE FORK rather than a walk
#     of yarn-project/foundation/src/trees/, because it decides whether the line count below is a
#     PRICE or a STARTING POINT. It is asserted as an IDENTITY — three implementations, two
#     subdirectories — so a fourth appearing fails this rather than passing quietly.
#   * THE PRICE is measured out of `@aztec/merkle-tree@5.0.0-nightly.20260316` as installed under
#     probe-mt/node_modules/ — the last published nightly that ships the package at all, carried in
#     pins.json as a declared npm_exceptions entry for exactly that reason. Lines of code per
#     component, the dependency set, the runtime import closure, the store surface a revival has to
#     re-adapt, and the two things the package does not contain at all.
#   * THE HAZARD is re-derived twice over. The undomained root is asked of the PACKAGE, by
#     constructing its own StandardTree at NOTE_HASH_TREE_HEIGHT, and separately reproduced by the
#     undomained recurrence, so the package's answer is explained rather than merely observed. The
#     native root is produced by the domained recurrence with the separator read out of
#     @aztec/constants, and is then checked against two independent Tier D witnesses and against
#     the fork's own DOM_SEP__MERKLE_HASH at the pinned anchor.
#   * THE ADAPTER BREAK is reproduced, and its EXIT STATUS and its SPECIFIC FAILURE MODE are both
#     asserted: a probe that died at import would also exit non-zero, and would prove nothing about
#     the store.
#   * EVERY "N occurrences" CLAIM IS PAIRED WITH A POSITIVE CONTROL. `checkpoint` occurring zero
#     times in the package is only evidence if the same regex finds it where it is; the campaign
#     has been bitten eleven times by a needle that could not match, and once by an assertion of
#     zero on a needle that could never have matched anything.
#   * AND THE DOCUMENT IS HELD TO THE MEASUREMENT, not the other way round: every figure is
#     asserted present in FALLBACK.md, so the prose goes red when the package moves under it.
#
# The last section asserts the CI wiring, and asserts it PRECISELY: the job exists, it parses as a
# job rather than as a string at the wrong indentation, and it names this milestone's checks.
# Whether it has ever RUN is M11's question and is deliberately not answered by grepping one of our
# own comments for the words "has never run" — M8's review removed exactly that assertion.
#
# Run: just verify-fallback-cost

TEST_NAME="verify_fallback_cost_priced"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m16_fallback.sh"

m16_require_package
[ -f "$M16_PRICE" ] || die "the price measurement tool is missing at $M16_PRICE"
[ -f "$M16_PROBE_DIR/m16_hazard.mjs" ] || die "probe-mt/m16_hazard.mjs is missing"
[ -f "$M16_PROBE_DIR/m16_adapter_probe.mjs" ] || die "probe-mt/m16_adapter_probe.mjs is missing"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"

VECTORS="$REPO_ROOT/fixtures/trees/world-state-vectors.json"
[ -f "$VECTORS" ] || die "Tier D's world-state vectors are missing at $VECTORS"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

note "node: $(node --version 2>/dev/null)"

# ---------------------------------------------------------------------------
echo "== 1. the artefact being priced is the one pins.json declares"
# ---------------------------------------------------------------------------
PRICE="$SCRATCH/price.txt"
python3 "$M16_PRICE" "$M16_PKG_DIR" >"$PRICE" 2>&1 || die "the price measurement tool failed to run"
PROBLEMS="$(sed -n 's/^PROBLEM //p' "$PRICE")"
if [ -z "$PROBLEMS" ]; then
  pass "the package is complete enough to price: every component M16 names resolves to a file"
else
  while IFS= read -r p; do [ -n "$p" ] && fail "$p"; done <<EOF
$PROBLEMS
EOF
fi

p() { m16_key "$PRICE" "$1"; }

PINNED="$(python3 -c "
import json,sys
d=json.load(open('$REPO_ROOT/pins.json'))
print(d['npm_exceptions']['@aztec/merkle-tree']['version'])" 2>/dev/null)"
assert_eq "pins.json declares a version for the deleted package" "5.0.0-nightly.20260316" "$PINNED"
assert_eq "the installed package is the declared one" "$PINNED" "$(p pkg.version)"
assert_eq "and it is the package M16 names" "@aztec/merkle-tree" "$(p pkg.name)"

CPP_ANCHOR="$(python3 -c "
import json;print(json.load(open('$REPO_ROOT/pins.json'))['anchors']['cpp']['commit'])")"
[ -n "$CPP_ANCHOR" ] || die "could not read the cpp anchor from pins.json"
note "cpp anchor: $CPP_ANCHOR"

# ---------------------------------------------------------------------------
echo "== 2. the reuse question, answered first: is there anything upstream to lift?"
# ---------------------------------------------------------------------------
# The campaign's standing question, and here it decides whether the line count below is a PRICE or
# a STARTING POINT. ONE regular expression over the WHOLE FORK at the pinned anchor — every *.ts in
# the tree, not a walk of yarn-project/foundation/src/trees/, because every one of this campaign's
# seven reuse misses was a directory PARALLEL to the one being searched. `[A-Za-z0-9_]` and not
# `[A-Za-z_]`, for the reason M13's review measured: a digit in a class name is enough to hide it.
IMPL_RE='class [A-Za-z0-9_]+ (extends [A-Za-z0-9_.<>, ]+ )?implements ([A-Za-z0-9_.]+, )*MerkleTree(Write|Read)Operations'
IMPLS="$SCRATCH/impls.txt"
( cd "$FORK_ROOT" && git grep -nE "$IMPL_RE" "$CPP_ANCHOR" -- '*.ts' ) 2>/dev/null \
  | grep -v '\.test\.ts' | sed "s|^$CPP_ANCHOR:||" >"$IMPLS"
note "implementations found: $(wc -l <"$IMPLS")"
sed 's/^/    /' "$IMPLS" >&2

# An identity, not a lower bound: four would fail this and so would two.
assert_eq "the whole fork has exactly three TypeScript MerkleTree*Operations implementations" \
  "3" "$(wc -l <"$IMPLS")"
assert_eq "and they live in two subdirectories, neither of them foundation/src/trees/" \
  "yarn-project/simulator yarn-project/world-state" \
  "$(awk -F/ '{print $1"/"$2}' "$IMPLS" | sort -u | tr '\n' ' ' | sed 's/ $//')"
for want in GuardedMerkleTreeOperations MerkleTreesFacade MerkleTreesForkFacade; do
  assert_contains "…and one of them is $want" "$want" "$(cat "$IMPLS")"
done

# NOT ONE OF THEM IS A TREE, and that is the finding rather than the count. Two are clients of a
# running aztec-wsdb process reached over an IPC path — and WORLD-STATE.md established that
# aztec-wsdb is C++ and links world_state, so there is no TypeScript store behind that boundary to
# reach for. The third is a decorator over a target.
NWSI="$SCRATCH/native_world_state_instance.ts"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:yarn-project/world-state/src/native/native_world_state_instance.ts" ) \
  >"$NWSI" 2>/dev/null
assert_ge "the facade's backing type was read from the anchor" 50 "$(wc -l <"$NWSI")"
assert_ge "…and it is a handle to a running aztec-wsdb process" 1 \
  "$(m16_words 'running aztec-wsdb world state' "$NWSI")"
assert_ge "…reached over an IPC path" 1 "$(m16_words 'getIpcPath' "$NWSI")"
GUARD="$SCRATCH/guarded_merkle_tree.ts"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:yarn-project/simulator/src/public/public_processor/guarded_merkle_tree.ts" ) \
  >"$GUARD" 2>/dev/null
assert_ge "the third implementation was read from the anchor" 50 "$(wc -l <"$GUARD")"
assert_ge "…and it is a decorator holding a target it forwards to" 1 \
  "$(m16_words 'private target: MerkleTreeWriteOperations' "$GUARD")"

# The deleted package's own interfaces went with it: nothing implements them anywhere, and there is
# no merkle-tree package left in yarn-project/. The second half is the control for the first — a
# zero over interfaces that no longer exist is not a finding on its own.
# THE BOUNDARY IS `([^[:alnum:]_]|$)` AND NOT `\b`, AND THIS IS THE EIGHTH SITE 769e209 MISSED.
# It is the WORSE class the commit's own message names: `\b` is a GNU extension, git's regex engine
# is the platform's, and on macOS the needle matches NOTHING — so `DELETED_IMPLS` is 0, and 0 is
# exactly what the assertion below WANTS. It passed, vacuously, for a platform reason.
#
# Measured at the anchor: the POSIX form also returns 0, so the assertion's VERDICT was right and
# no count moves. That is luck, not evidence. And the control on the next assertion does not cover
# it: `m16_words` runs PLAIN grep over three file paths, and plain grep here is GNU grep, which
# implements `\b` — so the control establishes that a GNU-grep needle matches, while the zero it is
# controlling came from a GIT-grep needle that cannot. The two greps are different engines and the
# control was scoped to the wrong one.
# The trailing boundary is spelled [^A-Za-z0-9_] rather than [^[:alnum:]_] because this needle is
# handed to THREE engines: git grep and GNU grep, which implement POSIX bracket expressions, and
# `m16_words`, which is Python's `re`, which does NOT. Python parses `[^[:alnum:]_]` as a class
# closed by the first `]` followed by the literal `_]`, so it can never match — and the control
# below reported 0 of 3 while the assertion it controls kept passing. Portable across all three.
DELETED_RE='implements [A-Za-z0-9_.]*(AppendOnlyTree|IndexedTree|UpdateOnlyTree)([^A-Za-z0-9_]|$)'
DELETED_IMPLS="$( ( cd "$FORK_ROOT" && git grep -lE "$DELETED_RE" "$CPP_ANCHOR" -- '*.ts' ) 2>/dev/null | grep -vc '\.test\.ts' )"
assert_eq "nothing in the fork implements the deleted package's tree interfaces" "0" "${DELETED_IMPLS:-0}"
# THE SAME REGEX, run over the package that DOES implement them, must find them. Without this the
# line above is a count of zero on a needle whose ability to match anything is unestablished — the
# defect this check's own first run shipped, one section further down.
assert_eq "…and the same regex finds all three of them in the deleted package itself" "3" \
  "$(m16_words "$DELETED_RE" \
      "$M16_PKG_DIR/src/sparse_tree/sparse_tree.ts" \
      "$M16_PKG_DIR/src/standard_tree/standard_tree.ts" \
      "$M16_PKG_DIR/src/standard_indexed_tree/standard_indexed_tree.ts")"
PKG_LEFT="$( ( cd "$FORK_ROOT" && git ls-tree --name-only "$CPP_ANCHOR" yarn-project/ ) 2>/dev/null | grep -ci merkle )"
assert_eq "…because yarn-project/ has no merkle-tree package at the anchor" "0" "${PKG_LEFT:-0}"
# …and the same listing DOES return the sibling packages, so the zero above is not an empty listing.
assert_ge "the package listing itself is non-empty, so that zero is a measurement" 40 \
  "$( ( cd "$FORK_ROOT" && git ls-tree --name-only "$CPP_ANCHOR" yarn-project/ ) 2>/dev/null | wc -l )"
# …and the same case-insensitive grep DOES find 'merkle' in a listing that contains it, so the zero
# is not a grep that cannot match.
assert_ge "…and the same grep finds 'merkle' in a listing that has it" 1 \
  "$( ( cd "$FORK_ROOT" && git ls-tree --name-only "$CPP_ANCHOR" yarn-project/foundation/src/trees/ ) 2>/dev/null | grep -ci merkle )"

# What tree-shaped TypeScript DOES remain is all built on the full node array — including
# indexed_merkle_tree.ts, which EXTENDS MerkleTree and inherits the constructor check. Asserted
# because a reader who checked only merkle_tree.ts would leave it looking like an unexamined
# candidate for the indexed-tree stage, and it is not one.
IMT="$SCRATCH/indexed_merkle_tree.ts"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:yarn-project/foundation/src/trees/indexed_merkle_tree.ts" ) \
  >"$IMT" 2>/dev/null
assert_ge "upstream's IndexedMerkleTree was read from the anchor" 20 "$(wc -l <"$IMT")"
assert_ge "…and it extends MerkleTree, so it inherits the full-node-array constructor" 1 \
  "$(m16_words 'class IndexedMerkleTree[^{]*extends MerkleTree' "$IMT")"
m16_assert_doc_records "the enumeration's result" \
  "It finds **three implementations, in two subdirectories**"
m16_assert_doc_records "that indexed_merkle_tree.ts is the same limitation one file over" \
  "\`indexed_merkle_tree.ts\` \`extends MerkleTree\`"

# ---------------------------------------------------------------------------
echo "== 3. the package by the line, and the milestone's ~2,000 LOC checked against it"
# ---------------------------------------------------------------------------
assert_eq "the published tarball contains no *.test.ts, so 'non-test LOC' is the whole of it" \
  "0" "$(p src.test_files)"
assert_ge "the tarball publishes its TypeScript sources rather than only the build output" 15 "$(p src.files)"

for pair in "tree_base 359" "standard_tree 59" "standard_indexed_tree 641" "sparse_tree 57" "snapshots 747"; do
  set -- $pair
  assert_eq "loc.$1" "$2" "$(p "loc.$1")"
  m16_assert_doc_records "the measured size of $1" "| $2 |"
done
assert_eq "the five components M16 names come to" "1863" "$(p loc.five_named)"
assert_eq "the whole shippable package comes to"  "2450" "$(p loc.shippable)"
assert_eq "the whole published package comes to"  "2756" "$(p loc.all)"
assert_eq "and the two test-support files it excludes are" "306" "$(p loc.test_support)"
m16_assert_doc_records "the five named components' total" "**1863**"
m16_assert_doc_records "the shippable total"              "**2450**"
m16_assert_doc_records "that the milestone's estimate is right about what it names" \
  "The milestone's \"~2,000 non-test LOC\" is right about what it names"

# ---------------------------------------------------------------------------
echo "== 4. what it depends on, and the two corrections the measurement forces"
# ---------------------------------------------------------------------------
assert_eq "the package declares five dependencies, not three" "5" "$(p deps.count)"
assert_eq "three of them are @aztec-scoped, and they are the three M16 names" \
  "@aztec/foundation,@aztec/kv-store,@aztec/stdlib" "$(p deps.aztec)"
assert_eq "two of them are not, and M16 does not name them" "sha256,tslib" "$(p deps.other)"

# `sha256` is declared and never used. BOTH halves are asserted: a check that only counted the uses
# would pass just as happily on a package that had dropped the dependency, which is a different
# finding.
assert_contains "sha256 IS a declared dependency" "sha256" "$(p deps.other)"
assert_eq "…and it is used nowhere in the sources" "0" "$(p words.sha256)"
# THE SAME word-boundary regex, over the file that does name it. Without this the zero above is a
# count on a needle whose ability to match is unestablished.
assert_ge "…and the same regex finds sha256 where it is declared" 1 \
  "$(m16_words '\bsha256\b' "$M16_PKG_DIR/package.json")"
m16_assert_doc_records "that sha256 is declared and unused" "declared and never used"

# The runtime closure. `import type` is erased, so the .js import set and the .d.ts import set are
# different questions; both are asserted, and the .d.ts side is asserted NON-EMPTY so that
# "kv-store and stdlib are type-only" cannot pass because neither set contained anything.
assert_eq "the compiled dest/*.js imports exactly one @aztec package" \
  "@aztec/foundation" "$(p imports.runtime)"
assert_eq "kv-store and stdlib appear in the type declarations only" \
  "@aztec/kv-store,@aztec/stdlib" "$(p imports.types_only)"
assert_eq "and the .d.ts import set is non-empty, so the comparison above is not between two empty sets" \
  "@aztec/foundation,@aztec/kv-store,@aztec/stdlib" "$(p imports.dts_all)"
m16_assert_doc_records "that the runtime closure is one package rather than three" \
  "The runtime closure is one \`@aztec\` package, not three."

# ---------------------------------------------------------------------------
echo "== 5. what the package does NOT contain, with a positive control for every zero"
# ---------------------------------------------------------------------------
# Each of these is a claim of ZERO. A claim of zero on a needle that cannot match is worth nothing —
# this campaign shipped exactly that assertion once — so every regex below is re-run over a
# document that DOES contain the word, and required to find it.
CTRL_DOC="$REPO_ROOT/BOUNDARY-SHAPE.md"

assert_eq "the package contains no checkpoint at all" "0" "$(p words.checkpoint)"
assert_ge "…and the same regex finds checkpoints where they are" 10 \
  "$(m16_words '\bcheckpoint\b' "$CTRL_DOC")"
assert_eq "the package contains no revert either" "0" "$(p words.revert)"
assert_ge "…and the same regex finds reverts where they are" 3 \
  "$(m16_words '\brevert\b' "$CTRL_DOC")"
# The contrast is the price: what it HAS is a snapshot layer, which is a different thing.
assert_ge "what it does have is snapshots, in quantity" 50 "$(p words.snapshot)"
m16_assert_doc_records "the checkpoint/snapshot contrast, with both counts" \
  "\`snapshot\` occurs 78 times"

assert_eq "the package knows nothing about genesis" "0" "$(p words.genesis)"
assert_ge "…and the same regex finds genesis where it is" 5 \
  "$(m16_words '\bgenesis\b' "$REPO_ROOT/WORLD-STATE.md")"
assert_eq "the package knows nothing about the archive tree" "0" "$(p words.archive)"
assert_ge "…and the same regex finds the archive where it is" 20 \
  "$(m16_words '\barchive\b' "$REPO_ROOT/WORLD-STATE.md")"

assert_eq "and it names no domain separator anywhere" "0" "$(p words.domain_separator)"
assert_ge "…and the same regex finds one where it is" 3 \
  "$(m16_words '\bDOM_SEP\w*\b|\bDomainSeparator\b' "$M16_DOC")"

# ---------------------------------------------------------------------------
echo "== 6. the kv-store adapter refresh, sized and localised"
# ---------------------------------------------------------------------------
assert_eq "the package opens ten store handles" "10" "$(p store.handles)"
assert_eq "and makes twenty synchronous accessor calls on them" "20" "$(p store.sync_call_sites)"
assert_contains "the call sites are derived from the handle members rather than a typed list" \
  "nodes" "$(p store.members)"
m16_assert_doc_records "the size of the refresh" "**10 store handles**"
m16_assert_doc_records "…and the number of call sites" "**20 synchronous accessor call sites**"

# The mechanism: the store went synchronous to asynchronous between the two nightlies. Asserted on
# the INSTALLED kv-store, in both directions — the async accessor exists and the sync one does not.
KV_MAP="$M16_PROBE_DIR/node_modules/@aztec/kv-store/dest/lmdb-v2/map.js"
assert_file "the June-2026 kv-store's lmdb-v2 map is installed" "$KV_MAP"
assert_ge "it implements getAsync" 1 "$(m16_words '\bgetAsync\(key\)' "$KV_MAP")"
assert_eq "and it implements no synchronous get" "0" "$(m16_words '\bget\(key\)' "$KV_MAP")"
# The second of those two is a claim of zero, so THE SAME REGEX — not a similar one — is run over
# the file that does have a synchronous `get(key)`, and required to find it. The first draft of
# these two lines anchored the pattern with `^` and ran it without MULTILINE, so both came back 0:
# `getAsync` failed loudly and `get` PASSED, for exactly the wrong reason.
assert_ge "…and the same regex finds a synchronous get in the package that expects one" 1 \
  "$(m16_words '\bget\(key\)' "$M16_PKG_DIR/dest/tree_base.js")"

# --- reproduce it, and assert the SPECIFIC failure mode ---------------------
ADAPTER_OUT="$SCRATCH/adapter.out"
ADAPTER_ERR="$SCRATCH/adapter.err"
( cd "$M16_PROBE_DIR" && node m16_adapter_probe.mjs ) >"$ADAPTER_OUT" 2>"$ADAPTER_ERR"
ADAPTER_RC=$?
note "the adapter probe exited $ADAPTER_RC"

assert_eq "the March-2026 package still fails against the June-2026 store" "1" "$ADAPTER_RC"
assert_contains "and it fails with the exact error M16 records" \
  "TypeError: this.nodes.get is not a function" "$(cat "$ADAPTER_ERR")"
assert_contains "…raised from TreeBase.dbGet, which is the read path" \
  "at StandardTree.dbGet" "$(cat "$ADAPTER_ERR")"
# A probe that died at import would also exit 1. These three markers say it did not: it imported,
# it CONSTRUCTED a tree (so the metadata WRITE path works against this store), and it got as far as
# the read before dying.
assert_contains "the probe got past import"        "imported=1"        "$(cat "$ADAPTER_OUT")"
assert_contains "the probe constructed a tree, so the WRITE half of the store still works" \
  "constructed=1" "$(cat "$ADAPTER_OUT")"
assert_contains "the probe reached the read"       "read_attempted=1"  "$(cat "$ADAPTER_OUT")"
assert_not_contains "and it did NOT append, which is the failure being claimed" \
  "appended=1" "$(cat "$ADAPTER_OUT")"
m16_assert_doc_records "that only the read half broke" \
  "The store went synchronous to asynchronous between the two nightlies, and only the read half"

# ---------------------------------------------------------------------------
echo "== 7. the hazard, re-derived: two roots, and the level they part company at"
# ---------------------------------------------------------------------------
HAZ="$SCRATCH/hazard.txt"
( cd "$M16_PROBE_DIR" && node m16_hazard.mjs ) >"$HAZ" 2>"$SCRATCH/hazard.err"
HAZ_RC=$?
if [ "$HAZ_RC" -ne 0 ]; then
  tail -20 "$SCRATCH/hazard.err" >&2
  die "the hazard measurement exited $HAZ_RC"
fi
h() { m16_key "$HAZ" "$1"; }

NATIVE_ROOT="0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6"
UNDOMAINED_ROOT="0x2ac5dda169f6bb3b9ca09bbac34e14c94d1654597db740153a1288d859a8a30a"

assert_eq "the heights are the protocol's" "42" "$(h height.NOTE_HASH_TREE)"

# The package's OWN answer, asked of a StandardTree it constructed.
assert_eq "the package's empty NOTE_HASH_TREE root is the undomained one" \
  "$UNDOMAINED_ROOT" "$(h package.empty_note_hash_root)"
# …and explained: the undomained recurrence lands on the same value.
assert_eq "and the undomained recurrence reproduces it, so the package's answer is explained" \
  "$(h package.empty_note_hash_root)" "$(h chain.undomained.d42)"
# The domained recurrence, with the separator read from @aztec/constants.
assert_eq "the domain-separated recurrence lands on the native root" \
  "$NATIVE_ROOT" "$(h chain.domained.d42)"
# The two must differ, or everything above is one value compared with itself.
if [ "$(h chain.domained.d42)" = "$(h chain.undomained.d42)" ]; then
  fail "the two roots are equal, so there is no hazard and this whole section is vacuous"
else
  pass "the two roots differ, which is the hazard"
fi

# Two INDEPENDENT Tier D witnesses for the native value: upstream's own hardcoded genesis
# expectation, and the capture harness's own recurrence. They were produced by different things.
FX_GENESIS="$(python3 -c "
import json;d=json.load(open('$VECTORS'));print(d['upstreamPublished']['genesisTrees']['NOTE_HASH_TREE']['root'])")"
FX_DERIVED="$(python3 -c "
import json;d=json.load(open('$VECTORS'));print(d['derived']['emptyRootByHeight']['42'])")"
FX_L1="$(python3 -c "
import json;d=json.load(open('$VECTORS'));print(d['upstreamPublished']['genesisTrees']['L1_TO_L2_MESSAGE_TREE']['root'])")"
FX_SIB1="$(python3 -c "
import json;d=json.load(open('$VECTORS'));print(d['captured']['noteHashZeroSiblingPath'][1])")"

assert_eq "Tier D's upstream-published genesis note-hash root agrees" "$NATIVE_ROOT" "$FX_GENESIS"
assert_eq "Tier D's own captured recurrence at height 42 agrees"      "$NATIVE_ROOT" "$FX_DERIVED"
assert_eq "and the same separator lands on upstream's genesis L1->L2 root at height 36" \
  "$FX_L1" "$(h chain.domained.d36)"

# Where the two chains part. Level 0 is the control: they MUST agree at the leaf, or "diverges from
# level 1" is a statement about something else entirely.
#
# Asserted against the ZERO field element rather than against each other. Comparing the two
# measured values to one another passes when BOTH keys are missing — two absences agree — so the
# control could not fail, which is the exact shape this campaign keeps finding and the shape the
# trigger check's own `bound_mode` comparator was written to refuse. Review found it here by
# renaming both keys in the probe and watching all 219 assertions still pass. The two sibling
# comparisons below are not vulnerable to it: each takes one side from the fixture file, so a
# missing probe key fails them.
ZERO_FR="0x0000000000000000000000000000000000000000000000000000000000000000"
assert_eq "both chains are zero at the leaf, which is the control for the claim below" \
  "$ZERO_FR $ZERO_FR" "$(h chain.undomained.level0) $(h chain.domained.level0)"
assert_eq "the two chains first disagree at level 1" "1" "$(h chain.first_divergence_level)"
assert_eq "and they never agree again at any level above it" \
  "0" "$(h chain.levels_agreeing_at_or_above_divergence)"
assert_eq "the domained level-1 value is Tier D's captured zero sibling path at level 1" \
  "$FX_SIB1" "$(h chain.domained.level1)"

m16_assert_doc_records "the native target value"     "$NATIVE_ROOT"
m16_assert_doc_records "the undomained target value" "$UNDOMAINED_ROOT"
m16_assert_doc_records "where the sibling paths part company" "diverge from level 1 upward"

# ---------------------------------------------------------------------------
echo "== 8. the separators are the fork's, so a revival reads them rather than restating them"
# ---------------------------------------------------------------------------
CONSTANTS_NR="$SCRATCH/constants.nr"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" ) \
  >"$CONSTANTS_NR" 2>/dev/null
assert_ge "upstream's constants.nr was read from the pinned anchor" 200 "$(wc -l <"$CONSTANTS_NR")"

fork_sep() { sed -n "s/^pub global DOM_SEP__$1: u32 = \([0-9]*\);.*/\1/p" "$CONSTANTS_NR" | head -n1; }

for pair in "MERKLE_HASH MERKLE_HASH" "NULLIFIER_MERKLE NULLIFIER_MERKLE" "PUBLIC_DATA_MERKLE PUBLIC_DATA_MERKLE"; do
  set -- $pair
  FORK_V="$(fork_sep "$1")"
  NPM_V="$(h "sep.$2")"
  assert_ge "the fork declares DOM_SEP__$1 at the anchor" 1 "${FORK_V:-0}"
  assert_eq "…and the npm package's DomainSeparator.$2 is the same constant" "$FORK_V" "$NPM_V"
  m16_assert_doc_records "the value of $2" "| $NPM_V |"
done
m16_assert_doc_records "that DOM_SEP__* is the C++ spelling of the same table" \
  "which is the **C++ spelling**"

# The extractor must be able to come back empty, or the three `assert_ge`s above are decorative.
assert_eq "the separator extractor returns nothing for a separator the fork does not declare" \
  "" "$(fork_sep "NO_SUCH_SEPARATOR_AT_ALL")"

# The hasher itself, read out of the source rather than inferred from the root.
assert_eq "src/poseidon.ts hashes without a separator" "1" "$(p hasher.undomained_form)"
assert_eq "and mentions no separator anywhere in the file" "0" "$(p hasher.separator_mentions)"
assert_ge "…and the same alternation finds a separator where one is named" 3 \
  "$(m16_words '\bDOM_SEP\w*\b|\bDomainSeparator\b|\bseparator\b' "$M16_DOC")"

# ---------------------------------------------------------------------------
echo "== 9. the one respect in which the fallback beats what M15 rejected"
# ---------------------------------------------------------------------------
# BOUNDARY-SHAPE.md §4 rejects a host-held world state because upstream's only TypeScript tree
# enforces 2 ** (height + 1) - 1 nodes. The deleted package does not: it is key-value backed. That
# is measured rather than argued, because a price that left it out would be wrong in our favour.
MT_TS="$SCRATCH/merkle_tree.ts"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:yarn-project/foundation/src/trees/merkle_tree.ts" ) \
  >"$MT_TS" 2>/dev/null
assert_ge "upstream's TypeScript merkle tree was read from the anchor" 20 "$(wc -l <"$MT_TS")"
NODE_COUNT_RE='2 \*\* \(height \+ 1\) - 1'
assert_ge "it enforces a full node array in its constructor" 1 "$(m16_words "$NODE_COUNT_RE" "$MT_TS")"
assert_ge "…named as such" 1 "$(m16_words 'expectedNodeCount' "$MT_TS")"
# THE SAME regex on both sides: it finds the bound upstream and does not find it in the package.
assert_eq "the deleted package's TreeBase does no such thing" "0" \
  "$(m16_words "$NODE_COUNT_RE" "$M16_PKG_DIR/src/tree_base.ts")"
assert_eq "…and it constructed at ARCHIVE_HEIGHT, which is where the other one cannot" \
  "1" "$(h package.constructs_at_archive_height)"
assert_eq "at the archive height the protocol uses" "30" "$(h height.ARCHIVE)"
m16_assert_doc_records "that the deleted package does not share the node-count limitation" \
  "The deleted package does not share that limitation."

# ---------------------------------------------------------------------------
echo "== 10. the counterweight and the staged plan are recorded, with real Tier D targets"
# ---------------------------------------------------------------------------
m16_assert_doc_records "the counterweight's first half" "Tree code rarely changes."
m16_assert_doc_records "…and the reason it is still second" "the second choice because it is *ours to maintain*"

MANIFEST="$REPO_ROOT/fixtures/MANIFEST.md"
assert_file "the fixture manifest exists" "$MANIFEST"
for fx in FX-14 FX-15 FX-16 FX-17 FX-18 FX-19; do
  m16_assert_doc_records "the staged plan's target $fx" "$fx"
  if grep -q "^### $fx — " "$MANIFEST"; then
    pass "…and $fx is a real Tier D entry in fixtures/MANIFEST.md"
  else
    fail "the staged plan names $fx and fixtures/MANIFEST.md has no such entry"
  fi
done
# The manifest lookup must be able to fail, or six green rows say nothing.
#
# THE ABSENT ID IS DERIVED, NOT TYPED. This read `FX-99`. `fixtures/MANIFEST.md` is at FX-29 today,
# so the control still worked — but that is a fact about how fast the corpus grows, not a property
# of the check, and this campaign has already had the same control expire once: M36 created RI-98
# and RI-99, and `verify_fixture_corpus_manifest_complete`'s planted `RI-99` silently stopped
# controlling after catching a real defect since M2. "An inventory that grows turns a typed absent
# id into a present one" is the rule, and its remedy is this: derive the needle one past the
# highest id the document declares, and ASSERT that the derived value really is absent — which is
# the assertion that goes red on the day the namespace reaches it, instead of the control going
# quiet.
ABSENT_FX="FX-$(awk 'match($0, /^### FX-([0-9][0-9]+)[^0-9]/, m) { if (m[1]+0 > hi) hi = m[1]+0 } END { print hi + 1 }' "$MANIFEST")"
assert_true "the derived absent fixture id was computed from the manifest rather than typed" \
  str_has_re "$ABSENT_FX" '^FX-[0-9][0-9]+$'
if grep -q "^### $ABSENT_FX — " "$MANIFEST"; then
  fail "the derived id $ABSENT_FX is PRESENT in the manifest, so the lookup control below would be vacuous"
else
  pass "the derived id $ABSENT_FX really is absent, so the lookup control can fail  [$ABSENT_FX]"
fi
if grep -q "^### $ABSENT_FX — " "$MANIFEST"; then
  fail "the manifest lookup found a fixture id that does not exist"
else
  pass "the manifest lookup returns nothing for a fixture id that does not exist"
fi

m16_assert_doc_records "that stage 5 has no upstream starting point" \
  "Stage 5 is the one with no upstream starting point."
m16_assert_doc_records "the outcome, in the milestone's own terms" \
  "the milestone closes as not-required, with the analysis retained"

# ---------------------------------------------------------------------------
echo "== 11. the checks are wired into CI, stated precisely"
# ---------------------------------------------------------------------------
# Stated precisely rather than generously: the job EXISTS, it is a job rather than a string at the
# wrong indentation, and it names this milestone's checks. Whether it has ever RUN is a different
# question and not this check's — M11 owns it, and every job in this workflow still aborts at
# `Generate CI token`. A check that read "the job is defined" and reported "M16 is enforced in CI"
# would be the overstatement this campaign has already had to walk back once.
#
# And there is deliberately NO assertion here that some comment says "has never run". M8's review
# removed exactly that: the text is under our own control, so it goes green when somebody writes
# the right sentence and red when somebody rewords it, and in neither case has it looked at GitHub.
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the AVM_WASM workflow exists" "$WF"
wf="$(cat "$WF" 2>/dev/null)"
assert_contains "…and it has a job for the fallback evaluation" "fallback-triggers" "$wf"
assert_contains "…which runs the whole M16 set" "just verify-m16" "$wf"
assert_contains "…after installing the deleted package the price is measured out of" \
  "Install the deleted merkle-tree package" "$wf"
assert_contains "…and asserts M16's own inputs before running anything" \
  "probe-mt/m16_hazard.mjs" "$wf"

# Parsed, not grepped, wherever a YAML parser can be had — a job declared at the wrong indentation
# is a string match and not a job. The string assertions above stand either way, so this adds
# discrimination rather than being the only thing holding the claim up.
YAML_JOBS=""
if python3 -c "import yaml" >/dev/null 2>&1; then
  YAML_JOBS="$(python3 -c "import yaml;print(' '.join(yaml.safe_load(open('$WF'))['jobs']))" 2>/dev/null)"
elif command -v yq >/dev/null 2>&1; then
  YAML_JOBS="$(yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
elif command -v nix >/dev/null 2>&1; then
  YAML_JOBS="$(nix shell nixpkgs#yq-go --command yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
fi
if [ -n "$YAML_JOBS" ]; then
  assert_contains "the workflow parses as YAML and declares the M16 job as a job" \
    "fallback-triggers" "$YAML_JOBS"
  assert_contains "…alongside M15's, which it must not have displaced" \
    "boundary-shape" "$YAML_JOBS"
  assert_not_contains "…and it does not declare a job M16 never added" \
    "fallback-implementation" "$YAML_JOBS"
else
  fail "no YAML parser was available, so the workflow's structure could not be asserted"
fi

finish
