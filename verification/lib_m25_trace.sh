#!/usr/bin/env bash
# lib_m25_trace.sh — shared machinery for the M25 (step-level tracing, OQ-4, OQ-5) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M25's checks read three things: the BUILT `ct_writer.wasm`, ONE run of the source-mapping arms,
# and a real Aztec contract artifact. Every one of them is produced here and shared, for the reason
# M20, M22, M23 and M24 all give: three checks each deriving "the rung this contract reached" from
# their own run is how two checks come to disagree about a number nothing changed.
#
# IT REUSES M24's MACHINERY RATHER THAN COPYING IT. `lib_m24_ct_writer.sh` already owns the module
# build, the bounded runner, the abnormal-exit trap, the published-refcount predicate and the pin
# reader, and M25 builds the SAME module — there is one `ct-writer` crate and one artefact. A
# second copy of `m24_require_module` would be a second answer to "is the module current".
#
# ---------------------------------------------------------------------------
# EVERY SUBPROCESS HAS A BOUND, AND EXCEEDING IT IS A NAMED FAILURE.
#
# M24's inheritance, and the reason is M23's review: a check that HANGS prints no summary, never
# exits, and blocks the sweep behind it. A trap fires on exit; a process that never exits has none.
# `m24_require_bounded_logged` is what wraps the arms run, and the redirection goes on `timeout`
# rather than on the function call — the third instance of that family in M24 was a `die` whose
# summary line went to `/dev/null` because the caller had redirected the FUNCTION.
# ---------------------------------------------------------------------------

M25_WORK="${M25_WORK:-$HOME/.cache/aztec-m25-trace}"
export M25_WORK

M25_ARMS="$M25_WORK/trace.json"
export M25_ARMS

M25_ARMS_TIMEOUT="${M25_ARMS_TIMEOUT:-900}"
export M25_ARMS_TIMEOUT

# ---------------------------------------------------------------------------
# THE ARTIFACT IS A REAL SHIPPED AZTEC CONTRACT AND ITS ABSENCE IS A `die`, NOT A SKIP.
#
# OQ-5's verdict is a claim about what `avm-transpiler` leaves in an artifact somebody else built,
# so it is settled against one. `@aztec/noir-test-contracts.js` is installed under `diffsim/` and
# `spike/` at the `deletion_era` pin and is NOT under `orchestration/` — enumerated rather than
# assumed, which is why the search is a list of roots and the residue is printed.
#
# A check that silently used a fixture of ours instead would be measuring this repository's opinion
# of a debug-symbol table, which is exactly the shape of vacuity this campaign keeps finding.
# ---------------------------------------------------------------------------
M25_ARTIFACT_REL="node_modules/@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json"
M25_ARTIFACT_ROOTS="diffsim spike drift probe-mt orchestration"
export M25_ARTIFACT_REL M25_ARTIFACT_ROOTS

M25_ARTIFACT=""
export M25_ARTIFACT

# m25_artifact_roots_found — one `<root>\t<yes|no>` line per searched root, so the residue is
# PRINTED rather than counted. A scanner that reports only its hits cannot show an undercount.
m25_artifact_roots_found() {
  local root
  for root in $M25_ARTIFACT_ROOTS; do
    if [ -f "$REPO_ROOT/$root/$M25_ARTIFACT_REL" ]; then
      printf '%s\tyes\n' "$root"
    else
      printf '%s\tno\n' "$root"
    fi
  done
}

m25_require_artifact() {
  local root
  for root in $M25_ARTIFACT_ROOTS; do
    if [ -f "$REPO_ROOT/$root/$M25_ARTIFACT_REL" ]; then
      M25_ARTIFACT="$REPO_ROOT/$root/$M25_ARTIFACT_REL"
      return 0
    fi
  done
  die "no shipped AvmTest artifact under any of: $M25_ARTIFACT_ROOTS (looking for $M25_ARTIFACT_REL).
     OQ-5's verdict is a claim about an artifact upstream builds, so it is settled against one and
     never against a fixture of ours. Run \`yarn install\` in diffsim/ or spike/."
}

# ---------------------------------------------------------------------------
# The arms — measured once, shared, refused rather than reported stale.
#
# A `die` INSIDE `$( … )` KILLS THE SUBSHELL AND NOTHING ELSE, which is M24's hard-won lesson, so
# this sets a GLOBAL and prints nothing. A precondition that prints nothing cannot be redirected
# into silence by a caller.
# ---------------------------------------------------------------------------
m25_require_arms() {
  local stale=0 src
  m24_require_module
  m25_require_artifact
  if [ ! -f "$M25_ARMS" ]; then
    stale=1
  else
    for src in "$M24_MODULE" "$REPO_ROOT/tools/run_trace_arms.mjs" \
               "$M24_HOST/src/index.ts" "$M24_HOST/src/abi.ts" \
               "$M24_HOST/src/config.ts" "$M24_HOST/src/writer.ts" \
               "$M24_HOST/src/source_map.ts" "$M25_ARTIFACT"; do
      [ -f "$src" ] || continue
      [ "$src" -nt "$M25_ARMS" ] && stale=1
    done
  fi
  if [ "$stale" = 1 ]; then
    mkdir -p "$M25_WORK" || die "could not create $M25_WORK"
    m24_require_bounded_logged "$M25_ARMS_TIMEOUT" "the M25 source-mapping arms run" \
      node --experimental-strip-types "$REPO_ROOT/tools/run_trace_arms.mjs" \
        --module "$M24_MODULE" --artifact "$M25_ARTIFACT" --work "$M25_WORK" \
      || die "tools/run_trace_arms.mjs failed; see $M24_WORK/bounded-run.log"
  fi
  [ -s "$M25_ARMS" ] || die "the arms run produced no $M25_ARMS"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$M25_ARMS" >/dev/null 2>&1 \
    || die "$M25_ARMS is not valid JSON — the arms run was interrupted; delete it and re-run"
}

# m25_arm <python-expression-over-`d`> — one value out of trace.json, or `MISSING`.
#
# `MISSING` is a loud string rather than an empty one, because `assert_eq "" ""` is this campaign's
# oldest defect and an empty haystack turns every comparison beneath it into an assertion about
# nothing.
m25_arm() { # <expr>
  python3 - "$M25_ARMS" "$1" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    v = eval(sys.argv[2], {"d": d, "len": len, "sorted": sorted, "sum": sum, "abs": abs, "str": str})
except Exception:
    print("MISSING"); raise SystemExit(0)
if v is None:
    print("MISSING")
elif isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
PY
}

# ---------------------------------------------------------------------------
# The transpiler, read out of the OBJECT STORE at the `cpp` anchor and never out of a worktree.
#
# M22's review turned "vendor from the object store, not the worktree" from an instruction into a
# checked precondition, and OQ-5's evidence needs the same treatment for the opposite reason: the
# claim is about what upstream's transpiler does AT THE ANCHOR, and a worktree can be dirty, on a
# branch, or carrying somebody's experiment.
# ---------------------------------------------------------------------------
m25_transpiler_file() { # <path-under-avm-transpiler>
  local anchor
  anchor="$(m24_pin cpp commit)"
  git -C "$FORK_ROOT" show "$anchor:avm-transpiler/$1" 2>/dev/null
}

# m25_split_probe_of <arm> — the split-stream reader's answers for one arm's container.
#
# Wrapped rather than inlined so the three checks that need it cannot come to disagree about WHICH
# container an arm names — the arm report is the single source for the path, exactly as M20's
# convention asks.
m25_split_probe_of() { # <arm>
  local ct
  ct="$(m25_arm "d[\"$1\"][\"container\"]")"
  [ -s "$ct" ] || { printf 'ERR:no-container\t%s\n' "$ct"; return 0; }
  m24_split_probe "$ct"
}
