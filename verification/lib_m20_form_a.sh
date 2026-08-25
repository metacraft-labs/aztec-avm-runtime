#!/usr/bin/env bash
# lib_m20_form_a.sh — shared machinery for the M20 (Form A) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M20 accepts a transaction whose private half ran elsewhere and executes only its public half.
# Its checks read three things: the C++ at the PINNED ANCHOR (where the three-phase model, the
# gas accounting and the asymmetric revert model actually live, since upstream moved them out of
# TypeScript), `orchestration/src` (what we ship), and ONE RUN of the arms against a built
# `avm.wasm` (what actually happens).
#
# THE ARMS ARE MEASURED ONCE AND SHARED. Six checks read the same `arms.json`. That is not only a
# saving: two checks each instantiating the module and each deriving "the fee" would eventually
# disagree about a number nothing had changed, which is a failure mode this campaign has met.
# `m20_require_arms` produces it if it is missing or older than any input that could move it, and
# DIES rather than reporting against a stale one.
#
# "ONCE" IS NOW TRUE. It was not: the staleness test used to compare against the `orchestration/src`
# DIRECTORY, and two checks write a probe into it before asking for the arms, so a single
# `verify-m20` ran the arms three times. `e2e_form_a_external_tx_roundtrip` asserts the fix, by
# writing a probe of exactly that shape and requiring the run to still be considered fresh — with
# a control that a real source edit IS still considered stale, because a staleness test that never
# fires would also make the count come out at one.
#
# PRECONDITIONS ARE PRECONDITIONS, NOT SKIPS. A check that cannot find a module dies with the
# command that builds one. It never reports "0 problems" against a run that did not happen.

M20_WORK="${M20_WORK:-$HOME/.cache/aztec-m20-form-a}"
export M20_WORK

M20_ARMS="$M20_WORK/arms.json"
export M20_ARMS

ORCH_DIR="${ORCH_DIR:-$REPO_ROOT/orchestration}"
ORCH_SRC="${ORCH_SRC:-$ORCH_DIR/src}"
export ORCH_DIR ORCH_SRC

# The C++ anchor, read out of pins.json rather than restated.
M20_CPP_ANCHOR="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json" 2>/dev/null)"
export M20_CPP_ANCHOR

m20_require_anchor() {
  case "$M20_CPP_ANCHOR" in
    [0-9a-f][0-9a-f]*) : ;;
    *) die "pins.json does not name a C++ anchor commit" ;;
  esac
  git -C "$FORK_ROOT" cat-file -e "$M20_CPP_ANCHOR^{commit}" 2>/dev/null \
    || die "the fork at $FORK_ROOT does not have the C++ anchor $M20_CPP_ANCHOR
             Fetch it: git -C $FORK_ROOT fetch upstream next"
}

# A file out of the fork at the C++ anchor. Fails loudly rather than yielding empty, because an
# empty haystack turns a `grep -c` into an assertion about nothing.
m20_anchor_file() { # <path-in-fork>
  git -C "$FORK_ROOT" show "$M20_CPP_ANCHOR:$1" 2>/dev/null \
    || die "the anchor has no $1 (the layout moved; this check's premise is stale)"
}

m20_require_packages() {
  [ -d "$ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed.
             Remedy: cd $ORCH_DIR && npm ci"
}

# Find a built `avm.wasm`, in preference order. THE CONTRACT-DB REGISTER PAIR AND BOTH INDEXED
# INSERTS MUST BE PRESENT: M20 seeds the resident merkle DB, so a module without
# `avm_merkle_db_insert_indexed_leaves_nullifier_tree` cannot run these arms at all and must be
# rejected here rather than half way through an arm.
m20_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  for candidate in \
    "$M20_WORK/avm.wasm" \
    "$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m13-contractdb/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m18-orchestration/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m17-node-host/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

M20_REQUIRED_EXPORTS='avm_simulate
avm_merkle_db_create
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_get_low_indexed_leaf
avm_merkle_db_get_leaf_preimage_public_data_tree'
export M20_REQUIRED_EXPORTS

m20_module_exports() { # <path>
  node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$1"
}

m20_require_module() {
  AVM_WASM_PATH="$(m20_find_module)" || die "no built avm.wasm was found.
             Looked at \$AVM_WASM_PATH, $M20_WORK and the M13/M12 work directories.
             Remedy: just avm-wasm-build, then set AVM_WASM_PATH to
             barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  export AVM_WASM_PATH
  local have missing
  have="$(m20_module_exports "$AVM_WASM_PATH")"
  missing=""
  local want
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    printf '%s\n' "$have" | grep -qx -- "$want" || missing="$missing $want"
  done <<< "$M20_REQUIRED_EXPORTS"
  [ -z "$missing" ] || die "the module at $AVM_WASM_PATH is missing:$missing
             M20 seeds the resident merkle DB, so a module without those exports cannot run
             these arms. Build one from M13's tree."
  M20_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  export M20_MODULE_SHA
}

# The inputs that could move the arm run, as FILES.
#
# `-type f` AND `! -name '.*'` are both load-bearing and both were learned by counting.
#
# The first revision passed `$ORCH_SRC` — a DIRECTORY — to `find -newer`, and `find` compares the
# directory's own mtime like any other path. Two of the six checks write a probe under
# `orchestration/src` (`.m20_traps.mjs`, `.m20_fee.mjs`) BEFORE they ask for the arms, so each one
# bumped the directory's mtime and each one regenerated the file. Measured: `running the Form A
# arms` appeared THREE times in a single `verify-m20` transcript. The header above promises the
# opposite — "six checks read the same arms.json … two checks each deriving 'the fee' would
# eventually disagree about a number nothing had changed" — and that property was being delivered
# only by the driver happening to be deterministic. Checks that ran before a regeneration were
# comparing against a different file from the ones that ran after.
#
# `! -name '.*'` is the second half: the probes ARE files under that directory, so restricting to
# `-type f` alone would still make every probe write invalidate the run. Dot-prefixed is exactly
# the naming the probes use, and it is the naming the containment assertions already police.
m20_arms_newer_inputs() { # -> prints the first input newer than $M20_ARMS, or nothing
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_form_a_arms.mjs" -newer "$M20_ARMS" -print -quit \
    2>/dev/null || true
  find "$ORCH_SRC" -type f ! -name '.*' -newer "$M20_ARMS" -print -quit 2>/dev/null || true
}

# The arm run. Produced once; reused by every M20 check.
#
# STALENESS IS DECIDED BY MTIME AGAINST EVERY INPUT THAT COULD MOVE IT — the module, the driver,
# and every orchestration source the driver reaches. `find -newer` rather than a hash, because the
# question is "could this be stale", and a false rebuild costs a minute while a false reuse costs
# a wrong answer. Set M20_ARMS_REFRESH=1 to force one.
m20_require_arms() {
  m20_require_module
  m20_require_packages
  mkdir -p "$M20_WORK"

  local stale=0
  if [ ! -s "$M20_ARMS" ] || [ "${M20_ARMS_REFRESH:-0}" = "1" ]; then
    stale=1
  else
    local newer
    newer="$(m20_arms_newer_inputs)"
    [ -n "$newer" ] && stale=1
  fi

  if [ "$stale" = "1" ]; then
    note "running the Form A arms against $AVM_WASM_PATH"
    ( cd "$ORCH_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
        node "$REPO_ROOT/tools/run_form_a_arms.mjs" ) > "$M20_ARMS.tmp" 2> "$M20_WORK/arms.stderr" \
      || die "the Form A arm run failed; see $M20_WORK/arms.stderr"
    mv "$M20_ARMS.tmp" "$M20_ARMS"
  fi
  [ -s "$M20_ARMS" ] || die "the arm run produced no output"
}

# One field of one arm, from the shared JSON. Prints `MISSING` rather than empty, so that an
# `assert_eq` against a typo'd arm name FAILS instead of comparing two empty strings — the exact
# shape of vacuous assertion this campaign has found twenty times.
m20_arm() { # <arm-name> <jq-ish path, e.g. external.kind>
  python3 - "$M20_ARMS" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
arms = {a["arm"]: a for a in doc["arms"]}
arm = arms.get(sys.argv[2])
if arm is None:
    print("MISSING"); sys.exit(0)
node = arm
for part in sys.argv[3].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("MISSING"); sys.exit(0)
print("null" if node is None else (json.dumps(node) if isinstance(node, (dict, list)) else node))
PY
}

m20_arm_names() {
  python3 -c '
import json, sys
print("\n".join(a["arm"] for a in json.load(open(sys.argv[1]))["arms"]))' "$M20_ARMS"
}
