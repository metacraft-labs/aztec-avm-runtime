#!/usr/bin/env bash
# lib_m22_block.sh — shared machinery for the M22 (block assembly) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M22 runs upstream's own `PublicProcessor.process` over a block of transactions against a built
# `avm.wasm`. Its checks read three things: the FORK at the pinned `ts` anchor (where
# `PublicProcessor` and `GuardedMerkleTreeOperations` actually live, and where the vendored copies
# are diffed against), `orchestration/src` (what we ship), and ONE RUN of the block arms.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, for M20's reason: three checks each instantiating the
# module and each deriving "the gas the block used" would eventually disagree about a number
# nothing had changed. `m22_require_arms` produces `blocks.json` if it is missing or older than any
# input that could move it, and DIES rather than reporting against a stale one.
#
# THE STALENESS TEST TAKES FILES AND NOT THE DIRECTORY, which is M20's review's correction: `find
# -newer` compares a directory's own mtime like any other path, so a check that writes a probe
# under `orchestration/src` before asking for the arms would regenerate them. M22 writes no probe
# there, and the rule is followed anyway so that adding one later does not silently triple the run
# count.
#
# PRECONDITIONS ARE PRECONDITIONS, NOT SKIPS. A check that cannot find a module dies with the
# command that builds one. It never reports "0 problems" against a run that did not happen.

M22_WORK="${M22_WORK:-$HOME/.cache/aztec-m22-block}"
export M22_WORK

M22_ARMS="$M22_WORK/blocks.json"
export M22_ARMS

ORCH_DIR="${ORCH_DIR:-$REPO_ROOT/orchestration}"
ORCH_SRC="${ORCH_SRC:-$ORCH_DIR/src}"
M22_VENDOR="$ORCH_SRC/vendor"
export ORCH_DIR ORCH_SRC M22_VENDOR

# The TypeScript anchor, read out of pins.json rather than restated. PINS ARE NOT DECLARED IN
# CHECKS: pins.json is the single source of truth and `verify_pinned_nightly_single_source` fails
# anything that says otherwise.
M22_TS_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["ts"]["commit"])' "$REPO_ROOT/pins.json" 2>/dev/null)"
export M22_TS_ANCHOR

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M21's review found the campaign's most dangerous defect shape: `verify_vendor_drift_clean` hit
# `Disk quota exceeded` in /tmp, died before `finish`, printed NO summary line, and M1 read 141
# instead of 151 WITH NOTHING FAILING. A check that dies reads as a SMALLER milestone rather than
# as a red one, because the sweep counter sums summary lines and a missing line subtracts silently.
#
# `m22_summary_on_abnormal_exit` installs an EXIT trap that prints a summary line with a failure
# counted, unless `finish` has already printed one. So an abnormal death costs a RED milestone
# rather than a quieter total. It is deliberately local to M22 rather than in `lib.sh`: putting it
# there would change the abnormal-exit behaviour of a hundred and fifty checks in the same commit
# that is supposed to be about block assembly.
# ---------------------------------------------------------------------------
_M22_FINISHED=0
m22_finish() {
  _M22_FINISHED=1
  finish
}
_m22_abnormal_exit() {
  local rc=$?
  [ "$_M22_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m22_summary_on_abnormal_exit() {
  trap _m22_abnormal_exit EXIT
}

# ---------------------------------------------------------------------------
# The fork at the ts anchor.
# ---------------------------------------------------------------------------
m22_require_anchor() {
  case "$M22_TS_ANCHOR" in
    [0-9a-f][0-9a-f]*) : ;;
    *) die "pins.json does not name a TypeScript anchor commit" ;;
  esac
  git -C "$FORK_ROOT" cat-file -e "$M22_TS_ANCHOR^{commit}" 2>/dev/null \
    || die "the fork at $FORK_ROOT does not have the ts anchor $M22_TS_ANCHOR"
}

# A file out of the fork at the ts anchor. Fails LOUDLY rather than yielding empty: an empty
# haystack turns every `grep -c` beneath it into an assertion about nothing.
m22_anchor_file() { # <path-in-fork>
  git -C "$FORK_ROOT" show "$M22_TS_ANCHOR:$1" 2>/dev/null \
    || die "the ts anchor has no $1 (the layout moved; this check's premise is stale)"
}

m22_require_packages() {
  [ -d "$ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed.
             Remedy: cd $ORCH_DIR && npm ci"
}

# ---------------------------------------------------------------------------
# The module. Same preference order and the same required exports as M20's, plus the four the
# block path adds: the tree roots, the append-only write, the sibling path and the checkpoint
# triple. A module without them cannot run a block at all and must be rejected HERE rather than
# half way through an arm.
# ---------------------------------------------------------------------------
M22_REQUIRED_EXPORTS='avm_simulate
avm_merkle_db_create
avm_merkle_db_get_tree_roots
avm_merkle_db_append_leaves
avm_merkle_db_create_checkpoint
avm_merkle_db_commit_checkpoint
avm_merkle_db_revert_checkpoint
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_get_low_indexed_leaf
avm_merkle_db_get_leaf_preimage_public_data_tree
avm_contract_db_create_checkpoint
avm_contract_db_commit_checkpoint
avm_contract_db_revert_checkpoint'
export M22_REQUIRED_EXPORTS

m22_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  for candidate in \
    "$M22_WORK/avm.wasm" \
    "$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m13-contractdb/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m18-orchestration/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m17-node-host/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

m22_module_exports() { # <path>
  node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$1"
}

m22_require_module() {
  AVM_WASM_PATH="$(m22_find_module)" || die "no built avm.wasm was found.
             Looked at \$AVM_WASM_PATH, $M22_WORK and the M13/M12 work directories.
             Remedy: just avm-wasm-build, then set AVM_WASM_PATH."
  export AVM_WASM_PATH
  local have missing want
  have="$(m22_module_exports "$AVM_WASM_PATH")"
  missing=""
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    str_has_line "$have" "$want" || missing="$missing $want"
  done <<< "$M22_REQUIRED_EXPORTS"
  [ -z "$missing" ] || die "the module at $AVM_WASM_PATH is missing:$missing
             M22 drives a block through the resident merkle and contract DBs; a module without
             those exports cannot run these arms. Build one from M13's tree."
  M22_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  export M22_MODULE_SHA
}

# ---------------------------------------------------------------------------
# The block arm run. Produced once; read by every M22 check.
# ---------------------------------------------------------------------------
m22_arms_newer_inputs() { # -> prints the first input newer than $M22_ARMS, or nothing
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_block_arms.mjs" -newer "$M22_ARMS" -print -quit \
    2>/dev/null || true
  find "$ORCH_SRC" -type f ! -name '.*' -newer "$M22_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/node-host/src" -type f ! -name '.*' -newer "$M22_ARMS" -print -quit 2>/dev/null || true
}

m22_require_arms() {
  m22_require_module
  m22_require_packages
  mkdir -p "$M22_WORK"

  local stale=0
  if [ ! -s "$M22_ARMS" ] || [ "${M22_ARMS_REFRESH:-0}" = "1" ]; then
    stale=1
  else
    local newer
    newer="$(m22_arms_newer_inputs)"
    [ -n "$newer" ] && stale=1
  fi

  if [ "$stale" = "1" ]; then
    note "running the block arms against $AVM_WASM_PATH"
    ( cd "$ORCH_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
        node "$REPO_ROOT/tools/run_block_arms.mjs" ) > "$M22_ARMS.tmp" 2> "$M22_WORK/blocks.stderr" \
      || die "the block arm run failed; see $M22_WORK/blocks.stderr"
    mv "$M22_ARMS.tmp" "$M22_ARMS"
  fi
  [ -s "$M22_ARMS" ] || die "the block arm run produced no output"
}

# One field of one arm, from the shared JSON.
#
# Prints `MISSING` rather than empty, so an `assert_eq` against a typo'd arm name FAILS instead of
# comparing two absences — the first form on `CAMPAIGN-BRIEF.md`'s list of assertions that cannot
# fail. DELIBERATELY NO NUMBER HERE: the brief names FIVE places that quote the running total and
# requires them to move together, and the first draft of this line made this a sixth by writing
# "twenty-one times" into it. A counter in a place the rule does not cover is a counter that goes
# stale silently, which is the exact drift the rule exists to prevent. Lists are printed as JSON so
# a set comparison is a string comparison.
m22_arm() { # <arm-name> <dotted path, e.g. processed or guard.afterSealGuarded.ok>
  python3 - "$M22_ARMS" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
node = doc["arms"].get(sys.argv[2])
if node is None:
    print("MISSING"); sys.exit(0)
for part in sys.argv[3].split("."):
    if part == "":
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
# BOOLEANS ARE PRINTED AS JSON, not as Python. `print(True)` writes `True`, and every
# `assert_eq "…" "true"` against it fails for a reason that has nothing to do with the subject —
# which is how eleven assertions in the guard check went red on their first run.
if node is None:
    print("null")
elif isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (dict, list)):
    print(json.dumps(node, separators=(",", ":")))
else:
    print(node)
PY
}

m22_arm_names() {
  python3 -c '
import json, sys
print("\n".join(sorted(json.load(open(sys.argv[1]))["arms"].keys())))' "$M22_ARMS"
}

# The state reference recorded immediately before the named transaction, in the named arm.
m22_before() { # <arm> <tx-label>
  python3 - "$M22_ARMS" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
arm = doc["arms"].get(sys.argv[2])
if arm is None:
    print("MISSING"); sys.exit(0)
for entry in arm.get("observedBefore", []):
    if entry["label"] == sys.argv[3]:
        print(entry["stateReference"]); sys.exit(0)
print("MISSING")
PY
}

# ---------------------------------------------------------------------------
# The vendored copies, and their diffs against the anchor.
#
# `m22_vendor_diff` prints the CHANGED LINES of a vendored file against upstream's blob, with the
# provenance header stripped. Whole lines, not fragments: the campaign has a recorded defect where
# a check matched each changed line against a regex of SUBSTRINGS with `re.search`, so
# `this.depth = depth + 1` was excused by `this.depth = depth` and all three assertions passed on a
# corrupted copy.
# ---------------------------------------------------------------------------
# THE STRIPPER IS `tools/provenance.py`'S OWN, not a second implementation of it. A hand-rolled awk
# version was written first and left the blank line the header's own renderer emits, so every diff
# carried one spurious added line — and a check whose diff is one line off can be made to pass by
# an edit that removes a line somewhere else.
m22_strip_header() { # <file> -> the file without its provenance header
  python3 - "$REPO_ROOT" "$1" <<'STRIP'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'tools'))
import provenance  # noqa: E402
with open(sys.argv[2], 'r', encoding='utf-8') as fh:
    sys.stdout.write(provenance.strip_header(fh.read()))
STRIP
}

m22_vendor_diff() { # <local-path-under-orchestration/src/vendor> <upstream-path-in-fork>
  local local_file="$M22_VENDOR/$1" upstream="$2"
  [ -f "$local_file" ] || die "no vendored file at $local_file"
  diff <(m22_anchor_file "$upstream") <(m22_strip_header "$local_file") || true
}
