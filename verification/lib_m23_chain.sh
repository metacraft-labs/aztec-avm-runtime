#!/usr/bin/env bash
# lib_m23_chain.sh — shared machinery for the M23 (chain loop, timer, facade) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M23 runs a CHAIN — blocks on a timer, empty blocks by default, one archive — against a built
# `avm.wasm`. Its checks read three things: the FORK at the pinned anchors (where the sequencer,
# TXE and `AztecNodeDebug` actually live), this repository's own sources and documents, and ONE RUN
# of the chain arms.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, for M20's reason and M22's: three checks each deriving
# "the archive root after three blocks" from their own run is how two checks come to disagree about
# a number nothing changed. `m23_require_arms` produces `chain.json` if it is missing or older than
# any input that could move it, and DIES rather than reporting against a stale one.
#
# THE STALENESS TEST TAKES FILES AND NOT THE DIRECTORY, which is M20's review's correction: `find
# -newer` compares a directory's own mtime like any other path.
#
# IT NEEDS A MODULE WITH THE ARCHIVE, AND THAT IS A DIFFERENT MODULE FROM M22'S. Every arm seals
# blocks, and a seal reads and writes the archive tree. M12's tree exports thirty-nine names and
# M13's forty-nine; neither has the archive. M23's overlay stack — M13's ten, then M14's archive
# patch, then `verification/m23/0001-*.patch` — produces a module with FIFTY-ONE, and that is the
# only one these arms will run against. A module without the two archive exports is rejected HERE,
# with the command that builds one, rather than half way through an arm.
#
# PRECONDITIONS ARE PRECONDITIONS, NOT SKIPS. A check that cannot find a module dies. It never
# reports "0 problems" against a run that did not happen.

M23_WORK="${M23_WORK:-$HOME/.cache/aztec-m23-chain}"
export M23_WORK

M23_ARMS="$M23_WORK/chain.json"
export M23_ARMS

ORCH_DIR="${ORCH_DIR:-$REPO_ROOT/orchestration}"
ORCH_SRC="${ORCH_SRC:-$ORCH_DIR/src}"
export ORCH_DIR ORCH_SRC

# The anchors, read out of pins.json rather than restated. PINS ARE NOT DECLARED IN CHECKS.
M23_CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json" 2>/dev/null)"
M23_TS_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["ts"]["commit"])' "$REPO_ROOT/pins.json" 2>/dev/null)"
export M23_CPP_ANCHOR M23_TS_ANCHOR

M23_PATCH="$REPO_ROOT/verification/m23/0001-test-vm2-expose-the-archive-tree-through-the-reactor.patch"
M23_DOC="$REPO_ROOT/CHAIN-LOOP.md"
export M23_PATCH M23_DOC

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT — M22's machinery, for M21's review's reason: a check
# that dies before `finish` prints no summary and reads as a SMALLER milestone rather than a red
# one, which took M1 from 151 to 141 with nothing reported as failing.
#
# It is duplicated here rather than moved into `lib.sh` for M22's stated reason: changing the
# abnormal-exit behaviour of a hundred and fifty checks does not belong in a commit about a chain
# loop. The two copies are independent by design; if a third milestone wants it, that is the point
# at which it moves.
# ---------------------------------------------------------------------------
_M23_FINISHED=0
m23_finish() {
  _M23_FINISHED=1
  finish
}
_m23_abnormal_exit() {
  local rc=$?
  [ "$_M23_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m23_summary_on_abnormal_exit() {
  trap _m23_abnormal_exit EXIT
}

# ---------------------------------------------------------------------------
# The fork.
# ---------------------------------------------------------------------------
m23_require_anchor() {
  case "$M23_CPP_ANCHOR" in
    [0-9a-f][0-9a-f]*) : ;;
    *) die "pins.json does not name a C++ anchor commit" ;;
  esac
  [ -e "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
  git -C "$FORK_ROOT" cat-file -e "$M23_CPP_ANCHOR^{commit}" 2>/dev/null \
    || die "the fork at $FORK_ROOT does not have the cpp anchor $M23_CPP_ANCHOR"
}

# A file out of the fork at the cpp anchor. Fails LOUDLY rather than yielding empty: an empty
# haystack turns every `grep -c` beneath it into an assertion about nothing.
m23_anchor_file() { # <path-in-fork>
  git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:$1" 2>/dev/null \
    || die "the cpp anchor has no $1 (the layout moved; this check's premise is stale)"
}

# The number of lines of a file at the cpp anchor, or `MISSING`.
m23_anchor_lines() { # <path-in-fork>
  git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:$1" 2>/dev/null | wc -l | tr -d ' ' \
    || printf 'MISSING\n'
}

# ---------------------------------------------------------------------------
# The module.
# ---------------------------------------------------------------------------
M23_ARCHIVE_EXPORTS='avm_merkle_db_update_archive
avm_merkle_db_get_archive_snapshot'
export M23_ARCHIVE_EXPORTS

# M22's required set, plus the archive's two. A chain drives everything a block drives and then
# seals, so the preconditions are a superset rather than a different list.
M23_REQUIRED_EXPORTS='avm_simulate
avm_merkle_db_create
avm_merkle_db_get_tree_roots
avm_merkle_db_append_leaves
avm_merkle_db_get_leaf_value
avm_merkle_db_get_sibling_path
avm_merkle_db_create_checkpoint
avm_merkle_db_commit_checkpoint
avm_merkle_db_revert_checkpoint
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_get_low_indexed_leaf
avm_merkle_db_get_leaf_preimage_public_data_tree
avm_contract_db_create_checkpoint
avm_contract_db_commit_checkpoint
avm_contract_db_revert_checkpoint
avm_merkle_db_update_archive
avm_merkle_db_get_archive_snapshot'
export M23_REQUIRED_EXPORTS

m23_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  # DELIBERATELY SHORT. M22's list falls back to M13's and M12's trees; here they would all be
  # rejected for want of the archive, and a preference order whose every fallback is rejected is a
  # list that only makes the failure slower to read.
  for candidate in \
    "$M23_WORK/avm.wasm" \
    "$M23_WORK/m23/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

m23_module_exports() { # <path>
  node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$1"
}

m23_require_module() {
  AVM_WASM_PATH="$(m23_find_module)" || die "no built avm.wasm with the archive was found.
             Looked at \$AVM_WASM_PATH and $M23_WORK.
             Remedy: just avm-wasm-build-m23, then set AVM_WASM_PATH."
  export AVM_WASM_PATH
  local have missing want
  have="$(m23_module_exports "$AVM_WASM_PATH")"
  missing=""
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    str_has_line "$have" "$want" || missing="$missing $want"
  done <<< "$M23_REQUIRED_EXPORTS"
  [ -z "$missing" ] || die "the module at $AVM_WASM_PATH is missing:$missing
             M23 seals blocks, and a seal reads and writes the archive tree. Build one from M23's
             overlay stack: just avm-wasm-build-m23."
  M23_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  M23_MODULE_EXPORT_COUNT="$(printf '%s\n' "$have" | grep -c .)"
  export M23_MODULE_SHA M23_MODULE_EXPORT_COUNT
}

m23_require_packages() {
  [ -d "$ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed.
             Remedy: cd $ORCH_DIR && npm ci"
}

# ---------------------------------------------------------------------------
# The chain arm run. Produced once; read by every behavioural M23 check.
# ---------------------------------------------------------------------------
m23_arms_newer_inputs() { # -> prints the first input newer than $M23_ARMS, or nothing
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_chain_arms.mjs" -newer "$M23_ARMS" -print -quit \
    2>/dev/null || true
  find "$ORCH_SRC" -type f ! -name '.*' -newer "$M23_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/node-host/src" -type f ! -name '.*' -newer "$M23_ARMS" -print -quit 2>/dev/null || true
}

m23_require_arms() {
  m23_require_module
  m23_require_packages
  mkdir -p "$M23_WORK"

  local stale=0
  if [ ! -s "$M23_ARMS" ] || [ "${M23_ARMS_REFRESH:-0}" = "1" ]; then
    stale=1
  else
    local newer
    newer="$(m23_arms_newer_inputs)"
    [ -n "$newer" ] && stale=1
  fi

  # THE RUN IS BOUNDED, AND THAT IS NOT A PRECAUTION. M23's review mutated the chain so that every
  # block is numbered 1; `armHundredBlocks` waits on a `block` subscription for `b.number >= 100`,
  # which then never resolves, and the run sat at zero bytes of output until it was killed by hand.
  # Every one of the nine arm-reading checks would have done the same in turn. M21's review taught
  # that a check which dies must read as a RED milestone rather than a smaller one; a check that
  # HANGS is the third state and is worse than either, because it reports nothing at all and blocks
  # the sweep behind it. Sixty times the observed run (about five seconds) is the bound.
  M23_ARMS_TIMEOUT="${M23_ARMS_TIMEOUT:-300}"
  if [ "$stale" = "1" ]; then
    note "running the chain arms against $AVM_WASM_PATH (timeout ${M23_ARMS_TIMEOUT}s)"
    ( cd "$ORCH_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
        timeout -s KILL "$M23_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_chain_arms.mjs" ) > "$M23_ARMS.tmp" 2> "$M23_WORK/chain.stderr"
    local arms_rc=$?
    if [ "$arms_rc" -eq 137 ] || [ "$arms_rc" -eq 124 ]; then
      die "the chain arm run did not finish within ${M23_ARMS_TIMEOUT}s and was killed.
             A chain that stops advancing makes the hundred-block arm wait forever; see
             $M23_WORK/chain.stderr. Raise M23_ARMS_TIMEOUT only if the box is genuinely slow."
    fi
    [ "$arms_rc" -eq 0 ] || die "the chain arm run failed; see $M23_WORK/chain.stderr"
    mv "$M23_ARMS.tmp" "$M23_ARMS"
  fi
  [ -s "$M23_ARMS" ] || die "the chain arm run produced no output"
}

# One field of one arm, from the shared JSON.
#
# Prints `MISSING` rather than empty, so an `assert_eq` against a typo'd arm name FAILS instead of
# comparing two absences — the first form on the vacuous-assertion list `CAMPAIGN-BRIEF.md` keeps.
# Lists and objects are printed as compact JSON so a set comparison is a string comparison.
m23_arm() { # <arm-name> <dotted path, e.g. emptyBlocks.finalBlockNumber>
  python3 - "$M23_ARMS" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
node = doc["arms"].get(sys.argv[2])
if node is None:
    print("MISSING"); sys.exit(0)
for part in sys.argv[3].split("."):
    if part == "":
        continue
    if isinstance(node, list):
        try:
            node = node[int(part)]
            continue
        except (ValueError, IndexError):
            print("MISSING"); sys.exit(0)
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
if isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (dict, list)):
    print(json.dumps(node, separators=(",", ":"), sort_keys=True))
else:
    print(node)
PY
}

# A top-level field of the run report (`module`, `exports`).
m23_run() { # <key>
  python3 - "$M23_ARMS" "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
v = doc.get(sys.argv[2], "MISSING")
print(v if not isinstance(v, bool) else ("true" if v else "false"))
PY
}

# ---------------------------------------------------------------------------
# The scanned source roots. `orchestration/src` and `node-host/src` are what SHIPS; `tools/` and
# `verification/` are not, and are excluded deliberately rather than by accident — a check that
# planted a `Date.now()` in a probe would otherwise catch its own probe.
# ---------------------------------------------------------------------------
M23_SHIPPED_ROOTS="$ORCH_SRC
$REPO_ROOT/node-host/src"
export M23_SHIPPED_ROOTS
