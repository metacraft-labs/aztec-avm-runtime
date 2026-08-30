#!/usr/bin/env bash
# verify_orchestration_reuse_enumerated — M18.
#
# M18 names two exceptions to "reuse everything" and justifies each in one sentence:
#
#   * `ForkCheckpoint` copied rather than imported. "It is the *only* production
#     `@aztec/world-state/native` import in the whole non-test subtree, and it is 45 lines of
#     pure TypeScript over `MerkleTreeCheckpointOperations`."
#   * `@aztec/telemetry-client` replaced by a no-op stub. "Necessary, not optional: its single
#     entrypoint drags in koa, prom-client, systeminformation and @opentelemetry/host-metrics — a
#     server metrics endpoint with no browser export condition."
#
# THIS CHECK VERIFIES THOSE JUSTIFICATIONS RATHER THAN ASSUMING THEM, because the campaign has
# been wrong seven times about whether a thing needed building or copying, and twice found the
# thing it believed absent sitting in a PARALLEL subdirectory. So the enumeration is over the
# whole fork at the anchor, by subdirectory, and over the published packages — not over the one
# directory whose name matches the subject.
#
# Both justifications move under measurement and both decisions survive. What the check asserts
# is the CORRECTED version, so that the numbers in the tree and the numbers in the milestone
# cannot drift apart:
#
#   * ForkCheckpoint is 46 lines, not 45; and there are THREE production
#     `@aztec/world-state/native` imports in the tree, not one. It is the only one in the
#     SIMULATOR subtree — the orchestration this milestone vendors — and the other two are in
#     `txe/`, which RI-39 has open for M23.
#   * `@aztec/telemetry-client` has FIVE entrypoints, not one; `koa` is not its dependency at all
#     but @aztec/foundation's; and the reason the stub is unavoidable is one nobody had recorded
#     — upstream ALREADY SHIPS the no-op, in `telemetry-client/src/noop.ts` and in TXE's own
#     esbuild stubs, and the published package's `exports` map makes it UNREACHABLE.
#
# Run: just verify-orchestration-reuse

TEST_NAME="verify_orchestration_reuse_enumerated"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m18_orchestration.sh"

m18_require_anchor
m18_require_packages

SCRATCH="$(mktemp -d "$M18_WORK/reuse.XXXXXX" 2>/dev/null)" || {
  mkdir -p "$M18_WORK" && SCRATCH="$(mktemp -d "$M18_WORK/reuse.XXXXXX")"
} || die "could not create a scratch directory under $M18_WORK"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

note "TypeScript anchor: $M18_TS_ANCHOR"

# ===========================================================================
# PART 1 — ForkCheckpoint: is it really the only one, and is it really 45 lines?
# ===========================================================================

# 1a. Every DEFINITION of a thing called ForkCheckpoint, anywhere in the fork at the anchor.
# `git grep` over the commit, not over the working tree: the working tree is checked out far
# later, where these files have moved, and a walk of it would answer a different question.
#
# THE WORD BOUNDARY IS SPELLED THE POSIX WAY, AND THAT IS A DEFECT M37 MET RATHER THAN A STYLE.
# git's regex engine is the platform's. `\b` is a GNU extension: on a macOS host it matches NOTHING,
# so this enumeration answered ZERO definitions of a class that plainly exists, and the assertion
# below went red for a reason that had nothing to do with the fork. `([^[:alnum:]_]|$)` is the
# POSIX ERE that means what `\b` meant, and it answers 1 on both platforms. Five other fork greps
# in this directory carried the same spelling and were corrected in the same pass; the one in
# `test_public_processor_never_defaults_to_cpp` was the dangerous kind, because the answer it
# wanted was ZERO and a needle that can never match would have supplied that for ever.
DEFS="$(git -C "$FORK_ROOT" grep -lE '(export )?(abstract )?class ForkCheckpoint([^[:alnum:]_]|$)|const ForkCheckpoint([^[:alnum:]_]|$)|ForkCheckpoint *= *class' \
  "$M18_TS_ANCHOR" -- 2>/dev/null | sed "s/^$M18_TS_ANCHOR://" | LC_ALL=C sort)"
N_DEFS="$(printf '%s\n' "$DEFS" | grep -c . || true)"
printf '%s\n' "$DEFS" | sed 's/^/      /'
assert_eq "exactly one file in the whole fork defines ForkCheckpoint" "1" "$N_DEFS"
assert_eq "and it is the one the milestone names" \
  "yarn-project/world-state/src/native/fork_checkpoint.ts" "$DEFS"

# The parallel-directory question, asked explicitly rather than left to the grep above: a
# checkpoint helper of this SHAPE living somewhere else under a different name is what the
# campaign has missed twice. Every declaration of the interface it is written over.
MTCO="$(git -C "$FORK_ROOT" grep -lE 'interface MerkleTreeCheckpointOperations([^[:alnum:]_]|$)' \
  "$M18_TS_ANCHOR" -- 2>/dev/null | sed "s/^$M18_TS_ANCHOR://" | LC_ALL=C sort)"
assert_eq "MerkleTreeCheckpointOperations is declared exactly once, so there is one shape to match" \
  "yarn-project/stdlib/src/interfaces/merkle_tree_operations.ts" "$MTCO"

# And in the PUBLISHED packages, which is the other place a consumer could get one from.
#
# TWO TREES, BECAUSE ONE OF THEM CANNOT ANSWER THE QUESTION. The orchestration deliberately does
# not install `@aztec/world-state`, so "no ForkCheckpoint under ITS node_modules" is true by
# construction and says nothing about the published line — a vacuous assertion of exactly the
# shape this campaign keeps finding. M18's review found this one. The real question is asked of
# diffsim's tree, where the package IS installed, and the answer is the OPPOSITE of what an
# earlier revision of this check and of the milestone claimed: the published package DOES ship
# `ForkCheckpoint`, at `dest/native/fork_checkpoint.js`, reachable as
# `@aztec/world-state/native`. That is not an argument against copying it, it is the argument
# FOR: reaching it means taking the whole package, and that package is the LMDB-backed native
# addon RI-27 replaces and DD-9 forbids.
PUB_DEFS="$(grep -rlE 'class ForkCheckpoint\b' "$ORCH_DIR/node_modules/@aztec" 2>/dev/null \
  | sed "s|^$ORCH_DIR/node_modules/||" | LC_ALL=C sort | tr '\n' ' ')"
note "definitions under the orchestration's own node_modules: ${PUB_DEFS:-<none>}"
assert_eq "no package the orchestration installs ships a ForkCheckpoint" \
  "" "$(printf '%s' "$PUB_DEFS" | tr -d ' ')"
[ -d "$REPO_ROOT/diffsim/node_modules/@aztec/world-state" ] \
  || die "the published @aztec/world-state is installed nowhere this check can read it, so the
             published-package question cannot be asked — and asking it of the orchestration's own
             node_modules, which deliberately excludes that package, is the vacuous form.
             Remedy: cd $REPO_ROOT/diffsim && npm ci"
pass "the tree that CAN answer the published-package question is installed"
PUB_WS_DEFS="$(grep -rlE 'class ForkCheckpoint\b' \
  "$REPO_ROOT/diffsim/node_modules/@aztec/world-state/dest" 2>/dev/null | wc -l | tr -d ' ')"
assert_ge "the PUBLISHED @aztec/world-state does ship one, so 'no published package has it' is false" \
  1 "$PUB_WS_DEFS"
assert_eq "and it is reachable — which is why copying it is about the PACKAGE, not about the class" \
  "./dest/native/index.js" \
  "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("exports", {}).get("./native", "<not exported>"))' \
    "$REPO_ROOT/diffsim/node_modules/@aztec/world-state/package.json")"

# 1b. The line count, read out of the file.
UP_FC="$SCRATCH/upstream_fork_checkpoint.ts"
m18_anchor_file yarn-project/world-state/src/native/fork_checkpoint.ts > "$UP_FC"
UP_LINES="$(wc -l < "$UP_FC" | tr -d ' ')"
assert_eq "upstream's ForkCheckpoint is 46 lines, not the 45 the deliverable states" \
  "46" "$UP_LINES"

# 1c. "pure TypeScript over MerkleTreeCheckpointOperations" — one import, and it is type-only,
# which is what makes copying it cost nothing at run time.
UP_IMPORTS="$(grep -c '^import' "$UP_FC" || true)"
assert_eq "it has exactly one import" "1" "$UP_IMPORTS"
assert_eq "and that import is type-only, so the copy has no runtime dependency" \
  "import type { MerkleTreeCheckpointOperations } from '@aztec/stdlib/interfaces/server';" \
  "$(grep '^import' "$UP_FC")"

# 1d. THE COUNT THE DELIVERABLE GETS WRONG. Every `@aztec/world-state/native` import site at the
# anchor, split by the shared test/production classifier.
git -C "$FORK_ROOT" grep -n "from '@aztec/world-state/native'" "$M18_TS_ANCHOR" -- 2>/dev/null \
  | sed "s/^$M18_TS_ANCHOR://" | LC_ALL=C sort > "$SCRATCH/ws_native_all.txt"
N_ALL="$(grep -c . "$SCRATCH/ws_native_all.txt" || true)"
# CLASSIFY THE PATH, NOT THE GREP LINE. `git grep -n` emits `path:line:content`, so an anchored
# pattern like `\.test\.ts$` matches nothing at all — the string ends in source text. The first
# draft of this check did exactly that and reported SEVEN production sites instead of three, with
# four `.test.ts` files among them. The path is cut out first now.
cut -d: -f1 "$SCRATCH/ws_native_all.txt" | grep -vE "$M18_TEST_PATTERN" \
  > "$SCRATCH/ws_native_prod_paths.txt" || true
grep -Ff "$SCRATCH/ws_native_prod_paths.txt" "$SCRATCH/ws_native_all.txt" \
  > "$SCRATCH/ws_native_prod.txt" 2>/dev/null || true
N_PROD="$(grep -c . "$SCRATCH/ws_native_prod.txt" || true)"
printf '%s\n' "$(cat "$SCRATCH/ws_native_prod.txt")" | sed 's/^/      /'
assert_ge "the subpath is imported somewhere, so the classifier is not looking at an empty tree" \
  1 "$N_ALL"
assert_eq "there are THREE production imports of @aztec/world-state/native, not one" "3" "$N_PROD"

# …and the claim that DOES hold, scoped to the subtree this milestone vendors.
N_PROD_SIM="$(grep -c '^yarn-project/simulator/' "$SCRATCH/ws_native_prod.txt" || true)"
assert_eq "exactly one of them is in the simulator subtree, which is the orchestration we reuse" \
  "1" "$N_PROD_SIM"
assert_eq "and it is public_processor.ts importing ForkCheckpoint" \
  "yarn-project/simulator/src/public/public_processor/public_processor.ts" \
  "$(grep '^yarn-project/simulator/' "$SCRATCH/ws_native_prod.txt" | cut -d: -f1)"
N_PROD_TXE="$(grep -c '^yarn-project/txe/' "$SCRATCH/ws_native_prod.txt" || true)"
assert_eq "the other two are in txe/, which RI-39 has open for M23" "2" "$N_PROD_TXE"

# 1e. The classifier can tell the two apart. An assertion that "3 are production" is worthless if
# the pattern matched nothing, so both directions are exercised on paths from THIS enumeration.
N_TEST="$((N_ALL - N_PROD))"
assert_ge "the classifier put some of the sites on the test side too" 1 "$N_TEST"
assert_true "the classifier calls an apps_tests path a test" \
  m18_is_test_path "yarn-project/simulator/src/public/public_tx_simulator/apps_tests/token.test.ts"
assert_false "and does not call public_processor.ts one" \
  m18_is_test_path "yarn-project/simulator/src/public/public_processor/public_processor.ts"
# THE PATTERN THAT DECIDES THE COUNT, probed by name. Of the sixteen sites exactly one is neither
# `.test.ts` nor under `apps_tests/` — `prover-client/src/mocks/test_context.ts` — and it is
# `/mocks/` that puts it on the test side. Without that pattern this count is FOUR, not three, so
# the number in the milestone depends on a rule that until M18's review no assertion exercised.
assert_true "and calls a /mocks/ path a test, which is the rule that makes the count three" \
  m18_is_test_path "yarn-project/prover-client/src/mocks/test_context.ts"
assert_eq "that site is in the enumeration, so the rule above is deciding a real path" "1" \
  "$(cut -d: -f1 "$SCRATCH/ws_native_all.txt" \
     | grep -c '^yarn-project/prover-client/src/mocks/test_context\.ts$' || true)"

# 1f. OUR COPY IS A COPY. The bodies are diffed and the difference must be EXACTLY the
# parameter-property desugaring — because "we copied it" is a claim about every line, and a
# sentence in a header comment is not one.
sed -n '/^import type/,$p' "$ORCH_SRC/fork_checkpoint.ts" > "$SCRATCH/our_body.ts"
diff -u "$UP_FC" "$SCRATCH/our_body.ts" > "$SCRATCH/fc.diff" 2>&1 || true
ADDED="$(grep -c '^+[^+]' "$SCRATCH/fc.diff" || true)"
REMOVED="$(grep -c '^-[^-]' "$SCRATCH/fc.diff" || true)"
note "copy versus upstream: +$ADDED / -$REMOVED line(s)"
sed -n '/^@@/,$p' "$SCRATCH/fc.diff" | sed 's/^/      /'
assert_eq "the copy removes exactly the four parameter-property constructor lines" "4" "$REMOVED"
assert_eq "and adds exactly the six that desugar them" "6" "$ADDED"
assert_eq "every removed line belongs to that constructor" "4" \
  "$(grep '^-[^-]' "$SCRATCH/fc.diff" | grep -cE 'private constructor|private readonly fork: MerkleTreeCheckpointOperations,|public readonly depth: number,|\) *\{\}' || true)"
# The residual: every changed line that is not EXACTLY one of the desugaring's own lines.
#
# THIS USED TO BE A SUBSTRING TEST AND IT HAD A HOLE. The first version matched each changed line
# against a regex of fragments with `search`, so any line CONTAINING `this.depth = depth` was
# excused — and `this.depth = depth + 1;` contains it. Under that rule a copy with an off-by-one
# in the constructor produced +6 / -4 and a residual of 0, and this check went GREEN on a
# corrupted ForkCheckpoint. Found by mutation during M18's review; the deliverable's claim is that
# "a second edit is red rather than excused", so the comparison is now against the exact lines.
#
# Computed in python so that a blank added line — which `grep -E '^[+-][^+-]'` silently drops — is
# counted rather than excused. An earlier draft missed one that way and reported a residual of 1
# it could not name.
RESIDUAL="$(python3 "$VERIFY_DIR/_fork_checkpoint_residual.py" "$SCRATCH/fc.diff")"
assert_eq "the changed lines are EXACTLY the desugaring's own, so a second edit anywhere in the body is red" \
  "0" "$RESIDUAL"

# ...and the residual can be non-zero, exercised with the mutation that got past the substring
# version: an off-by-one inside one of the two desugared assignments. `+6 / -4` still holds for
# it, so this is the only one of the three assertions that can catch it.
sed 's/    this\.depth = depth;/    this.depth = depth + 1;/' "$SCRATCH/our_body.ts" \
  > "$SCRATCH/our_body_mutated.ts"
assert_eq "the mutation the control exists for really is a one-line change" "1" \
  "$(diff "$SCRATCH/our_body.ts" "$SCRATCH/our_body_mutated.ts" | grep -c '^> ' || true)"
diff -u "$UP_FC" "$SCRATCH/our_body_mutated.ts" > "$SCRATCH/fc_mutated.diff" 2>&1 || true
assert_eq "a drifted copy still shows +6 / -4, which is why the counts alone are not enough" \
  "6|4" "$(printf '%s|%s' \
    "$(grep -c '^+[^+]' "$SCRATCH/fc_mutated.diff" || true)" \
    "$(grep -c '^-[^-]' "$SCRATCH/fc_mutated.diff" || true)")"
assert_ge "and the exact-line comparison catches it" 1 \
  "$(python3 "$VERIFY_DIR/_fork_checkpoint_residual.py" "$SCRATCH/fc_mutated.diff" 2>/dev/null)"

# The desugaring is the one Node forces, and that is measured rather than cited: a file with a
# parameter property must be REFUSED by the same node that runs our copy.
cat > "$SCRATCH/param_prop_probe.ts" <<'PROBE'
export class P {
  constructor(private readonly a: number) {}
  get(): number { return this.a; }
}
PROBE
probe_err="$(node -e "import('$SCRATCH/param_prop_probe.ts').then(()=>console.log('ACCEPTED')).catch(e=>console.log(e.code ?? e.name))" 2>&1 | tail -1)"
assert_eq "node refuses a parameter property, which is why the copy could not stay verbatim" \
  "ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX" "$probe_err"
ours_ok="$(node -e "import('$ORCH_SRC/fork_checkpoint.ts').then(m=>console.log(typeof m.ForkCheckpoint)).catch(e=>console.log('FAILED '+(e.code??e.name)))" 2>&1 | tail -1)"
assert_eq "and node loads ours" "function" "$ours_ok"

# ===========================================================================
# PART 2 — telemetry: is the stub necessary, and did we have to write it?
# ===========================================================================

TPKG="$ORCH_DIR/node_modules/@aztec/stdlib/../telemetry-client/package.json"
TPKG="$(cd "$ORCH_DIR" 2>/dev/null && printf '%s\n' "$PWD/node_modules/@aztec/telemetry-client/package.json")"
DIFFSIM_TPKG="$REPO_ROOT/diffsim/node_modules/@aztec/telemetry-client/package.json"
# The orchestration deliberately does NOT depend on the package, so it is not in ITS node_modules.
# That is the subject of part 2's last assertion and it must not make the earlier ones unrunnable:
# the package is read from diffsim's tree, which is where the campaign has had it installed since
# M2, and the check dies rather than skipping if it is not there either.
[ -f "$TPKG" ] || TPKG="$DIFFSIM_TPKG"
[ -f "$TPKG" ] || die "@aztec/telemetry-client is installed nowhere this check can read it.
             Remedy: cd $REPO_ROOT/diffsim && npm ci"
note "reading @aztec/telemetry-client from ${TPKG#"$REPO_ROOT"/}"

# 2a. "single entrypoint" — counted.
N_EXPORTS="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("exports", {})))' "$TPKG")"
assert_eq "@aztec/telemetry-client has FIVE entrypoints, not the one the deliverable states" \
  "5" "$N_EXPORTS"

# 2b. "no browser export condition" — the half of the sentence that is right, and the reason the
# stub cannot be avoided by resolution. A conditional export is an OBJECT; all five are strings.
N_CONDITIONAL="$(python3 -c '
import json, sys
e = json.load(open(sys.argv[1])).get("exports", {})
print(sum(1 for v in e.values() if isinstance(v, dict)))' "$TPKG")"
assert_eq "not one of the five carries a conditional export, so a bundler has no branch to take" \
  "0" "$N_CONDITIONAL"

# 2c. "drags in koa" — koa is not its dependency.
KOA_DEP="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("yes" if "koa" in d.get("dependencies", {}) else "no")' "$TPKG")"
assert_eq "koa is NOT a dependency of @aztec/telemetry-client" "no" "$KOA_DEP"
KOA_OWNER="$(python3 -c '
import json, glob, os, sys
root = sys.argv[1]
owners = []
for pj in glob.glob(os.path.join(root, "@*", "*", "package.json")) + glob.glob(os.path.join(root, "*", "package.json")):
    try: d = json.load(open(pj))
    except Exception: continue
    if "koa" in d.get("dependencies", {}): owners.append(d.get("name"))
print(",".join(sorted(set(owners))))' "$(dirname "$(dirname "$(dirname "$TPKG")")")")"
assert_eq "it is @aztec/foundation's, which the orchestration needs whatever happens to telemetry" \
  "@aztec/foundation" "$KOA_OWNER"

# 2d. The three that ARE reached, measured through the module graph rather than the dependency
# list — the two are different objects and this campaign has already quoted one for the other.
m18_import_graph "$(dirname "$(dirname "$(dirname "$(dirname "$TPKG")")")")" \
  '@aztec/telemetry-client' "$SCRATCH/graph_telemetry.json" >/dev/null 2>&1 \
  || die "could not walk @aztec/telemetry-client's import graph"
T_MODULES="$(m18_graph_modules "$SCRATCH/graph_telemetry.json")"
assert_ge "the telemetry entrypoint's module closure was actually walked" 100 "$T_MODULES"
note "@aztec/telemetry-client '.' closure: $T_MODULES modules"
for pkg in prom-client systeminformation @opentelemetry/host-metrics; do
  assert_eq "its import graph reaches $pkg" "yes" \
    "$(m18_graph_has_package "$SCRATCH/graph_telemetry.json" "$pkg")"
done

# 2e. THE FINDING. Upstream already wrote the no-op — enumerated over the WHOLE fork, by
# subdirectory, not by walking telemetry-client/.
NOOP_SITES="$(git -C "$FORK_ROOT" grep -lE 'NoopTelemetryClient' "$M18_TS_ANCHOR" -- 2>/dev/null \
  | sed "s/^$M18_TS_ANCHOR://" | LC_ALL=C sort)"
printf '%s\n' "$NOOP_SITES" | sed 's/^/      /'
assert_ge "upstream ships a NoopTelemetryClient" 1 \
  "$(printf '%s\n' "$NOOP_SITES" | grep -c 'telemetry-client/src/noop.ts' || true)"
assert_true "and TXE's esbuild build already redirects the package to it for the browser" \
  m18_anchor_has yarn-project/txe/esbuild/stubs/telemetry_stub.ts
assert_true "with a second stub for the start module, which is where the lazy OTel import lives" \
  m18_anchor_has yarn-project/txe/esbuild/stubs/telemetry_start_stub.ts
# `ls-tree -r -- '<dir>/*'` matches nothing: a pathspec glob does not cross `/` unless the
# pathspec is a directory. The directory is the pathspec.
N_TXE_STUBS="$(m18_anchor_paths 'yarn-project/txe/esbuild/stubs' | grep -c . || true)"
note "yarn-project/txe/esbuild/stubs/ holds $N_TXE_STUBS stubs — a solved problem with a name"
# Pinned rather than bounded. `>= 10` was the first version and it let the write-up carry a
# different number from the tree: `telemetry.ts` said twenty-one and the anchor says sixteen,
# which M18's review is where anything compared them. The anchor is fixed, so this cannot drift
# under upstream; it can only drift under a repin, which is when it should be looked at.
assert_eq "that directory is a stub library of sixteen, not a one-off" "16" "$N_TXE_STUBS"

# `getTelemetryClient()` already returns the no-op by default, which is the other half of why the
# necessity is about BUNDLING and not about behaviour.
assert_contains "getTelemetryClient() already defaults to the no-op at run time" \
  "new NoopTelemetryClient()" "$(m18_anchor_file yarn-project/telemetry-client/src/start.ts)"

# 2f. AND WHY WE STILL CANNOT IMPORT IT. The exports map has no ./noop, so the deep path a
# consumer would need is refused. Run, not read: the resolver is the authority.
noop_deep="$(cd "$REPO_ROOT/diffsim" && node -e "import('@aztec/telemetry-client/dest/noop.js').then(()=>console.log('RESOLVED')).catch(e=>console.log(e.code))" 2>&1 | tail -1)"
noop_short="$(cd "$REPO_ROOT/diffsim" && node -e "import('@aztec/telemetry-client/noop').then(()=>console.log('RESOLVED')).catch(e=>console.log(e.code))" 2>&1 | tail -1)"
assert_eq "importing upstream's no-op by its file path is refused by the exports map" \
  "ERR_PACKAGE_PATH_NOT_EXPORTED" "$noop_deep"
assert_eq "and so is the subpath a consumer would guess" \
  "ERR_PACKAGE_PATH_NOT_EXPORTED" "$noop_short"
# The control: the entrypoint that IS exported resolves, so the two refusals above are about the
# exports map and not about a broken installation.
root_ok="$(cd "$REPO_ROOT/diffsim" && node -e "import('@aztec/telemetry-client').then(m=>console.log('RESOLVED')).catch(e=>console.log(e.code))" 2>&1 | tail -1)"
assert_eq "while the '.' entrypoint — the 1,658-module one — resolves fine" "RESOLVED" "$root_ok"
assert_eq "so the no-op upstream ships is unreachable from outside the monorepo" "no" \
  "$(python3 -c '
import json, sys
e = json.load(open(sys.argv[1])).get("exports", {})
print("yes" if any(k.endswith("noop") for k in e) else "no")' "$TPKG")"

# AND WHAT THE ONE ADDITIVE LINE WOULD NOT DO. The write-up said adding `./noop` to the exports
# map "removes the need for this module entirely". M18's review measured that and it is false, so
# the corrected claim is asserted here rather than only written down. `dest/noop.js` IS shipped —
# which is the half that holds, and without it the contribution would not be one line at all —
# but it exports two names and our module exports seven.
NOOP_JS="$(dirname "$TPKG")/dest/noop.js"
assert_file "upstream's compiled no-op is in the published tarball, so the subpath would resolve" \
  "$NOOP_JS"
noop_exports="$(cd "$(dirname "$(dirname "$(dirname "$(dirname "$TPKG")")")")" \
  && node -e "import('file://$NOOP_JS').then(m=>console.log(Object.keys(m).sort().join(','))).catch(e=>console.log('FAILED '+(e.code??e.message)))" 2>&1 | tail -1)"
assert_eq "and it exports exactly the two no-op classes" "NoopTelemetryClient,NoopTracer" \
  "$noop_exports"
ours_exports="$(node -e "import('$ORCH_SRC/telemetry.ts').then(m=>console.log(Object.keys(m).length)).catch(e=>console.log('FAILED '+(e.code??e.message)))" 2>&1 | tail -1)"
assert_eq "our replacement exports seven, so the one line would shrink this module and not delete it" \
  "7" "$ours_exports"
assert_eq "and '.' does not re-export the no-op either, which is why './start' is not the answer" \
  "undefined" \
  "$(cd "$REPO_ROOT/diffsim" && node -e "import('@aztec/telemetry-client').then(m=>console.log(typeof m.NoopTelemetryClient)).catch(e=>console.log(e.code))" 2>&1 | tail -1)"

# 2g. Our replacement is the shape upstream's is, and the two behaviours a no-op tracer can get
# wrong are exercised rather than described.
tel="$(node -e "
import('$ORCH_SRC/telemetry.ts').then(m => {
  const c = m.getTelemetryClient();
  const t = c.getTracer('x');
  const ran = t.startActiveSpan('s', () => 'BODY-RAN');
  console.log([c.isEnabled(), ran, m.Metrics.SOME_NEW_METRIC_NOBODY_ENUMERATED.name,
               m.Attributes.SOME_NEW_ATTRIBUTE].join('|'));
}).catch(e => console.log('FAILED ' + (e.code ?? e.message)))" 2>&1 | tail -1)"
assert_eq "our telemetry replacement is disabled, runs a span's body, and answers any metric name" \
  "false|BODY-RAN|aztec.noop.some_new_metric_nobody_enumerated|aztec.noop.some_new_attribute" "$tel"

# ===========================================================================
# PART 3 — what "reuse" has NOT yet been carried out for, pinned so it cannot be claimed
# ===========================================================================
#
# M18's first deliverable said Aztec's orchestration — `public_tx_simulator/`, `state_manager/`,
# `public_processor/`, `side_effect_trace*.ts`, `db_interfaces.ts`, `public_db_sources.ts` — was
# "vendored under RI-19..RI-23 and unchanged". M18's review measured that and it was not: none of
# those files was under `orchestration/src`, and `@aztec/simulator` is not a dependency because
# importing it would pull `@aztec/native` and `@aztec/world-state`. RI-19..RI-23 were DECISIONS to
# vendor and the vendoring was an outstanding task.
#
# THE BLOCK BELOW WENT RED IN M22, WHICH IS WHAT IT WAS FOR. M22 vendored the block processor and
# the three things its own import closure reaches. The census is therefore re-pinned to what is
# true NOW, per subject, EXACTLY — not `>=`, because a subject growing is as much a finding as one
# disappearing, and an inequality would have let the next milestone vendor the whole simulator
# without moving a deliverable.
#
#   VENDORED IN M22, and each is one file except the processor's own directory:
#     public_processor       3 paths — the directory, public_processor.ts, public_processor_metrics.ts
#                            (guarded_merkle_tree.ts is inside the directory and does not match the
#                            subject's own name, which is why the count is 3 and not 4)
#     db_interfaces          1 — db_interfaces.ts
#     public_db_sources      1 — public_db_sources.ts
#     public_tx_simulator    1 — public_tx_simulator_interface.ts, THE INTERFACE ONLY.
#                            The three-phase transaction model in `public_tx_simulator/` is NOT
#                            here and this check says so by naming the file: the processor takes
#                            its simulator as a constructor argument, so a `PublicTxSimulator-
#                            Interface` is all it needs, and `WasmAvmPublicTxSimulator` is what
#                            satisfies it.
#
#   STILL NOT VENDORED, and still an outstanding task:
#     state_manager          0 — RI-20. Nothing in the block path reaches it: the state manager
#                            lives BELOW a TypeScript AVM and this runtime's AVM is the C++ one
#                            inside avm.wasm, which has its own.
#     side_effect_trace      0 — RI-22. Same reason, and M25 is where it is due.
#
# So the tree and the milestone still cannot drift apart silently; the pin has simply moved to the
# state the milestone that moved it declared.

# M33 ADDED A FIFTH, AND THE PIN MOVED WITH IT RATHER THAN BEING LOOSENED.
#
# `@aztec/aztec.js` is where `WalletSchema` lives — upstream's complete wallet protocol, fifteen
# methods plus the `batch` `createBatchSchemas` derives from them — and M33's whole method surface is
# `Object.keys(WalletSchema)` rather than a list somebody typed. Adding it is admissible for exactly
# the reason this list exists to enforce, and the reason is MEASURED rather than asserted:
# `@aztec/aztec.js`'s own `@aztec` dependency closure is twelve packages and reaches NONE of
# `@aztec/pxe`, `@aztec/simulator`, `@aztec/native` or `@aztec/world-state`, which
# `verify_provider_half_dd9_clean` §6 re-derives offline from the anchor's own manifests on every
# run, with `@aztec/wallet-sdk` — whose closure reaches all four, which is why it is VENDORED from
# instead of depended on — as the control that the walker can answer both ways.
#
# The comparison stays EXACT. A sixth dependency fails here, which is the property, and the
# assertion below (`@aztec/simulator` is not among them) is unchanged and is the one that names the
# rule.
#
# M35 ADDED THE SIXTH, AND IT FAILED HERE FIRST, WHICH IS THE PIN WORKING RATHER THAN THE PIN BEING
# WRONG.
#
# `@aztec/noir-acvm_js` is the ACVM — the executor upstream's own `WASMSimulator` drives — and it is
# the single install RI-64 priced four milestones before M35 spent it. It is admissible for a
# STRONGER reason than `@aztec/aztec.js`'s twelve-package closure: `npm view
# @aztec/noir-acvm_js@5.0.0-nightly.20260626 dependencies` is EMPTY, so there is no closure to walk
# and no path by which it could reach `@aztec/pxe`, `@aztec/simulator`, `@aztec/native` or
# `@aztec/world-state`. That emptiness is re-derived from `orchestration/package-lock.json` — a file
# in this repository, so the derivation is offline — by `verify_oracle_coverage_is_measured` §2,
# with `@aztec/aztec.js`'s non-empty dependency list beside it as the control that the reader can
# answer both ways.
#
# The comparison stays EXACT. A seventh dependency fails here.
assert_eq "the orchestration's dependencies are the six published @aztec packages" \
  "@aztec/aztec.js @aztec/constants @aztec/foundation @aztec/noir-acvm_js @aztec/protocol-contracts @aztec/stdlib" \
  "$(python3 -c '
import json, sys
print(" ".join(sorted(json.load(open(sys.argv[1]))["dependencies"])))' "$ORCH_DIR/package.json")"
assert_eq "and @aztec/simulator is not among them, because upstream does not publish it" "no" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("yes" if "@aztec/simulator" in d.get("dependencies", {}) else "no")' "$ORCH_DIR/package.json")"

m18_subject_paths() { # <subject> -> the matching paths under orchestration/src, one per line
  find "$ORCH_SRC" -name "$1*" 2>/dev/null | sed "s|^$ORCH_SRC/||" | sort
}

# The counts, exact and per subject. `while read` rather than a `for` over a here-string so the
# subject and its expected count travel together and cannot get out of step.
while IFS='|' read -r subject want; do
  [ -n "$subject" ] || continue
  got="$(m18_subject_paths "$subject" | grep -c . || true)"
  if [ "$want" = "0" ]; then
    assert_eq "RI-19..RI-23's $subject is NOT vendored under orchestration/src — recorded, not claimed" \
      "0" "$got"
  else
    assert_eq "RI-19..RI-23's $subject IS vendored under orchestration/src, M22, exactly $want path(s)" \
      "$want" "$got"
    note "  $subject: $(m18_subject_paths "$subject" | tr '\n' ' ')"
  fi
done <<'SUBJECTS'
public_tx_simulator|1
state_manager|0
public_processor|3
side_effect_trace|0
db_interfaces|1
public_db_sources|1
SUBJECTS

# THE PROCESSOR'S DIRECTORY, BY NAME, so "3 paths" cannot be satisfied by three other files that
# happen to start with the same word. The fourth file in it does not match the subject name at all,
# which is exactly why it is named here rather than counted there.
for f in public_processor.ts guarded_merkle_tree.ts public_processor_metrics.ts; do
  assert_file "the vendored processor directory holds $f" "$ORCH_SRC/vendor/public_processor/$f"
done
# And the three-phase model is NOT beside them: only the interface file came across.
assert_eq "the public_tx_simulator path under orchestration/src is the INTERFACE and nothing else" \
  "vendor/public_tx_simulator_interface.ts" "$(m18_subject_paths public_tx_simulator)"
# The negative control for the whole census: a subject that is not vendored anywhere reads 0 by
# the same lookup, so the zeros above are zeros of a lookup that works.
assert_eq "a subject name that is in no tree reads 0 by the same lookup" "0" \
  "$(m18_subject_paths no_such_orchestration_subject | grep -c . || true)"

# …and the enumeration is not looking at an empty directory, which is the shape of vacuity this
# whole check exists to avoid.
assert_ge "orchestration/src holds the seam that IS built" 5 \
  "$(find "$ORCH_SRC" -name '*.ts' | grep -c . || true)"
# The same subjects ARE vendored elsewhere in this repository, which is why "it is vendored" was
# an easy thing to believe. Naming where they actually are is the difference.
assert_ge "they are vendored in drift/, which is what M2's differential reads" 5 \
  "$(find "$REPO_ROOT/drift/src/public" -maxdepth 1 \
       \( -name 'public_tx_simulator' -o -name 'state_manager' -o -name 'public_processor' \
          -o -name 'side_effect_trace*.ts' -o -name 'db_interfaces.ts' \
          -o -name 'public_db_sources.ts' \) 2>/dev/null | grep -c . || true)"

finish
