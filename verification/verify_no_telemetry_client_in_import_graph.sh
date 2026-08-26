#!/usr/bin/env bash
# verify_no_telemetry_client_in_import_graph — M18.
#
# The deliverable: "The shipped import graph contains no @aztec/telemetry-client and none of koa,
# prom-client, systeminformation or @opentelemetry/host-metrics."
#
# WHAT THE GRAPH IS, AND WHY IT IS NOT `npm ls`. A package's DEPENDENCY LIST and a bundle's
# IMPORT GRAPH are different objects, and the difference is exactly where this deliverable's
# wording goes wrong: `koa` is in `node_modules` because @aztec/foundation depends on it, so an
# assertion over dependency lists would either pass trivially (we do not list telemetry) or fail
# for a reason with nothing to do with telemetry. `tools/import_graph.mjs` walks the transitive
# closure of the specifiers that are actually imported, resolving each through Node's own
# resolver, which is what a bundler emits.
#
# It is STATIC. Importing the entry point and inspecting what got loaded would miss every branch
# not taken, and a check that only sees the happy path is the failure this file exists to catch.
# The price is that a specifier assembled at run time is invisible, so the walker reports those
# separately and this check asserts their COUNT — a computed `import()` appearing in the shipped
# graph is a hole in the measurement and must be a failure, not a silent omission.
#
# THE ASSERTION IS A CONJUNCTION OF SEVEN, and each conjunct gets a negative case: a probe module
# that imports exactly that package is walked through the same walker and must be caught. A
# conjunction whose parts have never been made to fail individually is one assertion wearing seven
# hats. Seven and not five: two of them had no negative case until the M19 review, and they were
# the two whose absence could not fail — see the note above the probe list.
#
# Run: just verify-no-telemetry

TEST_NAME="verify_no_telemetry_client_in_import_graph"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m18_orchestration.sh"

m18_require_packages

mkdir -p "$M18_WORK"
SCRATCH="$(mktemp -d "$M18_WORK/imports.XXXXXX")" || die "no scratch under $M18_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.probe_"*.ts' EXIT INT TERM HUP

# The packages the deliverable names, plus the package itself. `koa` is kept in the list on
# purpose even though RI-29 argues it does not belong to telemetry: it is a JSON-RPC server and
# has no business in a browser bundle either, so the assertion is worth making — it is the
# ATTRIBUTION that was wrong, not the requirement.
FORBIDDEN="@aztec/telemetry-client koa prom-client systeminformation @opentelemetry/host-metrics"
# Two more the milestone does not name and which matter as much: DD-9's native AVM, and the
# native world-state package RI-27 replaces.
FORBIDDEN="$FORBIDDEN @aztec/native @aztec/world-state"

# The pristine copy the restoration assertion at the end compares against. Taken before any
# probe writes into the package, so it is the state the check found rather than a state a
# probe produced.
cp "$ORCH_SRC/index.ts" "$SCRATCH/index.ts.pristine"

GRAPH="$SCRATCH/graph.json"
out="$(m18_import_graph "$ORCH_DIR" ./src/index.ts "$GRAPH" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -E '^(modules|packages|unresolvable|computed-dynamic-sites) ' | sed 's/^/  |  /'
assert_eq "the walker completed" "0" "$rc"
assert_contains "and said so with its own sentinel rather than merely exiting" \
  "import-graph.done 1" "$out"
assert_file "the walker wrote a graph" "$GRAPH"

MODULES="$(m18_graph_modules "$GRAPH")"
PACKAGES="$(m18_graph_packages "$GRAPH" | grep -c . || true)"
note "the shipped graph is $MODULES modules across $PACKAGES packages"

# THE GRAPH IS NOT EMPTY. Every assertion below is an absence, and an absence over an empty set
# is the vacuous-assertion family this campaign has now found twenty-four times. Both sides are
# pinned: a real module count, and the presence of the packages the orchestration MUST reach.
assert_ge "the graph is a real closure and not an empty one" 200 "$MODULES"
for want in @aztec/stdlib @aztec/foundation @aztec/protocol-contracts; do
  assert_eq "the graph reaches $want, which the orchestration genuinely depends on" "yes" \
    "$(m18_graph_has_package "$GRAPH" "$want")"
done

# The absences.
for pkg in $FORBIDDEN; do
  assert_eq "the shipped import graph does not reach $pkg" "no" \
    "$(m18_graph_has_package "$GRAPH" "$pkg")"
done

# A computed `import()` in the shipped graph is an unmeasured edge. Reported by the walker and
# asserted here, so the measurement's own coverage is part of the result.
N_COMPUTED="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["computed_dynamic_import_sites"]))' "$GRAPH")"
assert_eq "no module in the shipped graph builds an import specifier at run time" "0" "$N_COMPUTED"

# Unresolvable specifiers are named rather than counted to zero: `ws` has two optional native
# accelerators that are legitimately absent, and requiring zero would fail for a reason that says
# nothing about telemetry. What is asserted is that every one of them is one of those two.
python3 -c '
import json, sys
for u in json.load(open(sys.argv[1]))["unresolvable"]:
    print(u["spec"])' "$GRAPH" | LC_ALL=C sort -u > "$SCRATCH/unresolvable.txt"
sed 's/^/      unresolvable: /' "$SCRATCH/unresolvable.txt"
UNEXPECTED="$(grep -vxE 'bufferutil|utf-8-validate' "$SCRATCH/unresolvable.txt" | grep -c . || true)"
assert_eq "every unresolved specifier is one of ws's two optional native accelerators" \
  "0" "$UNEXPECTED"

# ---------------------------------------------------------------------------
# THE NEGATIVE CASES — one per conjunct.
#
# Each writes a probe module into the package that imports exactly one forbidden package, walks
# the SAME graph from the SAME entry point with the probe re-exported, and requires the walker to
# find it. Without these, "no koa in the graph" is indistinguishable from "the walker cannot see
# koa", and the two look identical in a passing run.
# ---------------------------------------------------------------------------

probe_finds() { # <package-specifier> <package-name>
  local spec="$1" name="$2" pfile="$ORCH_SRC/.probe_import.ts" saved="$SCRATCH/index.ts.saved"
  cp "$ORCH_SRC/index.ts" "$saved"
  printf "export * from '%s';\n" "$spec" > "$pfile"
  printf "\nexport * from './.probe_import.ts';\n" >> "$ORCH_SRC/index.ts"
  local g="$SCRATCH/probe_$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' _).json"
  m18_import_graph "$ORCH_DIR" ./src/index.ts "$g" >/dev/null 2>&1
  local found
  found="$(m18_graph_has_package "$g" "$name" 2>/dev/null || echo "no")"
  cp "$saved" "$ORCH_SRC/index.ts"
  rm -f "$pfile"
  printf '%s\n' "$found"
}

# ONE PROBE PER FORBIDDEN PACKAGE, and the last two were missing until the M19 review. `FORBIDDEN`
# carries seven names; this list carried five. `@aztec/native` and `@aztec/world-state` were
# asserted absent with no negative case at all — and they are the two that are NOT INSTALLED in
# `orchestration/node_modules`, so an import of either is MODULE_NOT_FOUND, lands in `unresolvable`,
# and never enters `packages`. The absence could not fail. (M19's own containment check had the
# same hole and it was proved by mutation there: with `import * as x from "@aztec/native";` in a
# reached module, the assertion still printed `ok … [0]`.) Both ARE installed in `diffsim/`, so the
# first branch below walks that tree, which is exactly the case this loop was already built for.
for probe in \
  "@aztec/telemetry-client:@aztec/telemetry-client" \
  "koa:koa" \
  "prom-client:prom-client" \
  "systeminformation:systeminformation" \
  "@opentelemetry/host-metrics:@opentelemetry/host-metrics" \
  "@aztec/native:@aztec/native" \
  "@aztec/world-state:@aztec/world-state"
do
  spec="${probe%%:*}"; name="${probe#*:}"
  if [ -d "$REPO_ROOT/diffsim/node_modules/$name" ] && [ ! -d "$ORCH_DIR/node_modules/$name" ]; then
    # The package is not installed here BECAUSE the orchestration does not depend on it, which is
    # the very thing under test. A probe that could not resolve it would prove nothing, so the
    # negative case is run against the tree where it IS installed and the walker's ability to see
    # it is what is asserted.
    g="$SCRATCH/neg_$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' _).json"
    m18_import_graph "$REPO_ROOT/diffsim" "$spec" "$g" >/dev/null 2>&1
    assert_eq "negative case: the walker DOES report $name when a graph reaches it" "yes" \
      "$(m18_graph_has_package "$g" "$name" 2>/dev/null || echo "no")"
  else
    assert_eq "negative case: the walker DOES report $name when the shipped entry point imports it" \
      "yes" "$(probe_finds "$spec" "$name")"
  fi
done

# THE SCANNER'S OWN BLIND SPOT, exercised. Every assertion above is an ABSENCE, so the failure
# that matters is a walker that cannot SEE an import. Its first version scanned for `//`
# unconditionally, treating one inside a string literal as the start of a comment — so an import
# on the same line as a URL was silently dropped. M18's review found it. The probe puts exactly
# that shape in front of the walker and requires the import to still be reported.
URLPROBE="$ORCH_SRC/.probe_urlcomment.ts"
saved_url="$SCRATCH/index.ts.saved.url"
cp "$ORCH_SRC/index.ts" "$saved_url"
{
  printf "export const collectorUrl = 'http://localhost:4318/v1/traces'; import '@aztec/foundation/log';\n"
  printf "export const shipped = true;\n"
} > "$URLPROBE"
printf "\nexport { shipped } from './.probe_urlcomment.ts';\n" >> "$ORCH_SRC/index.ts"
URLGRAPH="$SCRATCH/graph_urlprobe.json"
m18_import_graph "$ORCH_DIR" ./src/index.ts "$URLGRAPH" >/dev/null 2>&1 || true
cp "$saved_url" "$ORCH_SRC/index.ts"
rm -f "$URLPROBE"
assert_eq "an import sharing a line with a URL string is still seen by the walker" "yes" \
  "$(m18_graph_has_package "$URLGRAPH" "@aztec/foundation" 2>/dev/null || echo "no")"
assert_ge "…and that probe graph is a real walk rather than an empty one" 200 \
  "$(m18_graph_modules "$URLGRAPH" 2>/dev/null || echo 0)"

# The probe left nothing behind. This check writes inside the package it measures, so it says so
# and proves it rather than hoping.
assert_eq "the probe files are gone" "0" \
  "$(find "$ORCH_SRC" -name '.probe_*' | grep -c . || true)"
# Compared against a copy this check took BEFORE any probe ran, not against `git status`. THE
# GIT VERSION WAS VACUOUS AND M18's REVIEW FOUND IT: while `orchestration/` was untracked,
# `git status --porcelain -- orchestration/src/index.ts` printed nothing whatever a probe had
# done, so the assertion reported 0 either way — an absence measured over an empty set, which is
# the family of defect this very check's header calls out.
if cmp -s "$SCRATCH/index.ts.pristine" "$ORCH_SRC/index.ts"; then
  pass "and index.ts is byte-for-byte as it was found"
else
  fail "index.ts differs from the copy taken before the first probe ran"
fi
assert_eq "…and the comparison can tell two files apart, so that is not vacuous either" "1" \
  "$(cmp -s "$SCRATCH/index.ts.pristine" "$ORCH_SRC/telemetry.ts" && echo 0 || echo 1)"

finish
