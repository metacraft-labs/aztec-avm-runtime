#!/usr/bin/env bash
# lib_token_blocks.sh — shared machinery for the checks that run REAL CONTRACTS through REAL BLOCKS.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# WHY THIS LIBRARY IS NOT `lib_m<N>_*.sh`. Its arms close verification entries in THREE milestones —
# M18's token, phase and nested-call entries, M22's block-token-flows and deployment entries, and
# M25's debug-log entry — because all six were blocked on one thing (a transaction that calls a
# registered contract) and all six are answered by one arm run. Six checks each instantiating the
# module and each deriving "the balance after the transfer" from their own run is how two checks
# come to disagree about a number nothing changed. `lib_avm_wasm.sh`, `lib_bytecode_shift.sh` and
# `lib_l2_replay.sh` are the existing precedent for a cross-milestone library.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, and produced by `tools/run_token_block_arms.mjs`. This
# library regenerates them when they are missing or older than any input that could move them, and
# DIES rather than reporting against a stale run.
#
# PRECONDITIONS ARE PRECONDITIONS, NOT SKIPS. A check that cannot find a module dies with the
# command that builds one. It never reports "0 problems" against a run that did not happen.

TB_WORK="${TB_WORK:-$HOME/.cache/aztec-token-blocks}"
export TB_WORK

TB_ARMS="$TB_WORK/token-blocks.json"
export TB_ARMS

TB_ORCH_DIR="${TB_ORCH_DIR:-$REPO_ROOT/orchestration}"
TB_ORCH_SRC="$TB_ORCH_DIR/src"
export TB_ORCH_DIR TB_ORCH_SRC

tb_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# ---------------------------------------------------------------------------
# The module. The same preference order M22 uses, plus the two contract-DB registration exports
# these arms need: they register real contracts, and a module without them cannot do it at all.
# A module that could not register would report a transaction that reverted at instruction one —
# and `processed` — which is the campaign's deepest recorded defect wearing a precondition's
# clothes. Rejecting it HERE is the difference.
# ---------------------------------------------------------------------------
TB_REQUIRED_EXPORTS='avm_simulate
avm_steps_count
avm_contract_db_register_class
avm_contract_db_register_instance
avm_merkle_db_get_tree_roots
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree'
export TB_REQUIRED_EXPORTS

tb_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  for candidate in \
    "$TB_WORK/avm.wasm" \
    "$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m13-contractdb/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

tb_module_exports() { # <path>
  node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$1"
}

tb_require_module() {
  AVM_WASM_PATH="$(tb_find_module)" || die "no built avm.wasm was found.
             Looked at \$AVM_WASM_PATH, $TB_WORK and the M13/M15 work directories.
             Remedy: just avm-wasm-build-m23, then set AVM_WASM_PATH."
  export AVM_WASM_PATH
  local have missing want
  have="$(tb_module_exports "$AVM_WASM_PATH")"
  missing=""
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    str_has_line "$have" "$want" || missing="$missing $want"
  done <<< "$TB_REQUIRED_EXPORTS"
  [ -z "$missing" ] || die "the module at $AVM_WASM_PATH is missing:$missing
             These arms register real contracts and execute them, and they read the executed
             instruction count back. Build a module from M13's overlay stack."
  TB_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  export TB_MODULE_SHA
}

tb_require_packages() {
  [ -d "$TB_ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed.
             Remedy: cd $TB_ORCH_DIR && npm ci"
  [ -f "$REPO_ROOT/diffsim/node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json" ] \
    || die "no Token artifact under diffsim/node_modules.
             Remedy: cd $REPO_ROOT/diffsim && npm ci"
}

# THE STALENESS TEST TAKES FILES AND NOT THE DIRECTORY, which is M20's review's correction:
# `find -newer` compares a directory's own mtime like any other path, so a check that wrote a probe
# under `orchestration/src` would regenerate the arms.
tb_arms_newer_inputs() {
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_token_block_arms.mjs" -newer "$TB_ARMS" -print -quit \
    2>/dev/null || true
  find "$TB_ORCH_SRC" -type f ! -name '.*' -newer "$TB_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/node-host/src" -type f ! -name '.*' -newer "$TB_ARMS" -print -quit 2>/dev/null || true
}

tb_require_arms() {
  tb_require_module
  tb_require_packages
  mkdir -p "$TB_WORK"

  local stale=0
  if [ ! -s "$TB_ARMS" ] || [ "${TB_ARMS_REFRESH:-0}" = "1" ]; then
    stale=1
  else
    local newer
    newer="$(tb_arms_newer_inputs)"
    [ -n "$newer" ] && stale=1
  fi

  if [ "$stale" = "1" ]; then
    note "running the token/block arms against $AVM_WASM_PATH"
    # A BOUND ON THE SUBPROCESS. M23's review: a trap fires on exit, and a process that never exits
    # has no exit — the arms sit at zero bytes of output and block the sweep behind them. The
    # default is about twenty times the run's measured cost. It is an ENVIRONMENT VARIABLE because
    # the hang arm of the mutation matrix has to be able to reach it: a bound nobody has seen fire
    # is a bound nobody has seen work, and waiting half an hour to see it is not a test anyone runs.
    #
    # `|| rc=$?` AND NOT `if timeout …; then`. M37's own defect, three lines from here in shape: an
    # `if` whose condition is false with no `else` exits 0, so `$?` after the `fi` is the `if`
    # STATEMENT's status and not the command's — and a hang would be reported as a clean run.
    # And NO `--preserve-status`: with it a killed command's own status comes back (143 for
    # SIGTERM) and the 124 test never fires, so a HANG reads as an ordinary failure.
    local rc=0
    local bound="${TB_ARMS_BOUND_S:-1800}"
    ( cd "$TB_ORCH_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
        timeout "$bound" node --experimental-strip-types "$REPO_ROOT/tools/run_token_block_arms.mjs" ) \
      > "$TB_ARMS.tmp" 2> "$TB_WORK/token-blocks.stderr" || rc=$?
    if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
      die "the token/block arm run exceeded its ${bound} s bound (rc $rc). That is a HANG and not a
             failure; see $TB_WORK/token-blocks.stderr"
    fi
    [ "$rc" = "0" ] || die "the token/block arm run failed (rc $rc); see $TB_WORK/token-blocks.stderr"
    mv "$TB_ARMS.tmp" "$TB_ARMS"
  fi
  [ -s "$TB_ARMS" ] || die "the token/block arm run produced no output"
  tb_require_arms_shape
}

# THE FILE PARSES AND CARRIES THE ARMS IT IS SUPPOSED TO.
#
# A non-empty file satisfies the staleness test, and every accessor beneath it then throws one at a
# time — which reads as a check with thirty-five unrelated failures rather than as a run that did
# not happen. Measured: arm M10 of this pass's mutation matrix reported exactly that. This
# precondition turns it into ONE named refusal, under the abnormal-exit trap, so the milestone goes
# RED rather than confusing.
tb_require_arms_shape() {
  local shape
  shape="$(python3 "$VERIFY_DIR/_token_blocks_shape.py" "$TB_ARMS" 2>&1)"
  [ "$shape" = "ok" ] || die "the token/block arm file at $TB_ARMS is not a complete arm run: $shape
             Remedy: TB_ARMS_REFRESH=1, and see $TB_WORK/token-blocks.stderr"
}

# One field of one arm, from the shared JSON.
#
# Prints `MISSING` rather than empty, so an `assert_eq` against a typo'd arm name FAILS instead of
# comparing two absences — the first form on `CAMPAIGN-BRIEF.md`'s list of assertions that cannot
# fail. Lists and objects are printed as compact JSON so a set comparison is a string comparison.
tb_arm() { # <arm-name> <dotted path>
  python3 - "$TB_ARMS" "$1" "$2" <<'PY'
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
            idx = int(part)
        except ValueError:
            print("MISSING"); sys.exit(0)
        if idx < 0 or idx >= len(node):
            print("MISSING"); sys.exit(0)
        node = node[idx]
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
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

# One field of one BLOCK of one arm, selected BY THE BLOCK'S OWN LABEL rather than by position.
#
# Selecting by index is how a check comes to assert about a different block after somebody inserts
# one — and the campaign has a recorded instance of a check whose population was selected by a
# decision and went silently empty. `MISSING` for a label that is not there.
tb_block() { # <arm-name> <block-label> <dotted path>
  python3 - "$TB_ARMS" "$1" "$2" "$3" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
arm = doc["arms"].get(sys.argv[2])
if arm is None:
    print("MISSING"); sys.exit(0)
blocks = arm.get("blocks") if isinstance(arm, dict) else None
if not isinstance(blocks, list):
    print("MISSING"); sys.exit(0)
hit = [b for b in blocks if isinstance(b, dict) and b.get("label") == sys.argv[3]]
if len(hit) != 1:
    print("MISSING"); sys.exit(0)
node = hit[0]
for part in sys.argv[4].split("."):
    if part == "":
        continue
    if isinstance(node, list):
        try:
            idx = int(part)
        except ValueError:
            print("MISSING"); sys.exit(0)
        if idx < 0 or idx >= len(node):
            print("MISSING"); sys.exit(0)
        node = node[idx]
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
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

# The labels of every block an arm ran, as compact JSON. A check that asserts about a block asserts
# this first, so "the block is not there" fails as itself rather than as every field being MISSING.
tb_block_labels() { # <arm-name>
  tb_arm "$1" blocks | python3 -c '
import json, sys
try:
    blocks = json.load(sys.stdin)
except Exception:
    print("MISSING"); raise SystemExit(0)
if not isinstance(blocks, list):
    print("MISSING"); raise SystemExit(0)
print(json.dumps([b.get("label") for b in blocks], separators=(",", ":")))
'
}

# The module and artefacts the arms were measured against, so every check can name them.
tb_note_provenance() {
  note "module $(tb_arm_meta module.path)"
  note "module sha256 $(tb_arm_meta module.sha256)"
  note "Token artifact sha256 $(tb_arm_meta artifacts.token.sha256)"
  note "AvmTest artifact sha256 $(tb_arm_meta artifacts.avmTest.sha256)"
  note "AMM artifact sha256 $(tb_arm_meta artifacts.amm.sha256)"
}

tb_arm_meta() { # <dotted path outside arms>
  python3 - "$TB_ARMS" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
print(node if not isinstance(node, (dict, list)) else json.dumps(node, separators=(",", ":")))
PY
}
