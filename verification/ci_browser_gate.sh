#!/usr/bin/env bash
# just ci-browser-gate  (verification/ci_browser_gate.sh)
#
# M28 verification: "a Justfile target running the whole browser gate locally, so the check is
# reproducible outside CI" — and the two deliverables that ride on it: "the headless-browser job
# running on EVERY PR, not nightly" and "THE GATE FAILS THE BUILD. It does not warn, and it is not
# skippable by a flag".
#
# THE NAME IS THE RECIPE'S. `just check-repo-hygiene` is the precedent: a check whose TEST_NAME is
# the command a person types, so the summary line in a sweep names the thing that was run.
#
# ==============================================================================================
# WHAT THIS CHECK IS FOR, GIVEN THAT IT RUNS NONE OF THE GATE'S OTHER CHECKS.
# ==============================================================================================
#
# It does NOT run them, deliberately: `just ci-browser-gate` runs this check FIRST and then the
# others, and a check that invoked its siblings would print their summary lines inside its own run
# and be counted twice by any sweep — the shape `CAMPAIGN-BRIEF.md` records as "M1 came out at 316
# when it is 141".
#
# What it asserts is everything about the gate that is not any individual check's business:
#
#   1. THE COMPOSITION. The recipe names seven checks; `verify-m28` names six; the difference is
#      exactly `verify_browser_entry_points_are_dd5_shaped`, which is M27's and is counted there.
#      Both lists are read out of the Justfile, so they cannot drift apart silently.
#   2. THE CI WIRING. The workflow job invokes THAT recipe by name — not a list of its own — and
#      the workflow triggers on `pull_request`, which is what "every PR, not nightly" means.
#   3. IT CANNOT BE SKIPPED. No `|| true` in the recipe, no `continue-on-error` and no `if:` on the
#      job or its gate step, no early `exit 0` in any gate check. Each with a NEGATIVE CONTROL that
#      plants the violation in a scratch copy and requires the same predicate to report it — because
#      "there is no `continue-on-error` in this file" is an absence, and this campaign has shipped
#      three absences that could not fail.
#   4. THE WRITE-UP IS OPENED AND ITS FIGURES ARE RE-DERIVED. `BROWSER-PACKAGING.md` was the only
#      milestone write-up in this repository that no check opened, while claiming in its own first
#      sentence that everything in it is re-derived on every run; eleven of its figures had rotted.
#      `BROWSER-GATE.md` makes the same claim and this section is what makes it true.
#
# Run: just verify-ci-browser-gate   (the gate itself: just ci-browser-gate)

TEST_NAME="just ci-browser-gate"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m28_gate.sh"

m28_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
JUSTFILE="$REPO_ROOT/Justfile"
assert_file "the Justfile exists" "$JUSTFILE"
assert_file "the workflow exists" "$M28_WORKFLOW"
assert_file "M28's write-up exists" "$M28_DOC"

# A recipe's body, by name. Just's grammar: a recipe header at column 0 ending in `:`, then an
# indented body; the body ends at the next column-0 line that is not blank.
recipe_body() { # <recipe-name>
  python3 - "$JUSTFILE" "$1" <<'PY'
import sys
name = sys.argv[2]
out, inside = [], False
for line in open(sys.argv[1], encoding="utf-8"):
    stripped = line.rstrip("\n")
    if not inside:
        if stripped.startswith(name + ":"):
            inside = True
        continue
    if stripped and not stripped[0].isspace():
        break
    out.append(stripped)
print("\n".join(out))
PY
}

# The check names a recipe runs, in order: the `for check in \` list.
recipe_checks() { # <recipe-name>
  recipe_body "$1" | sed -n '/for check in/,/^ *do$/p' \
    | grep -oE '^ *[a-z_0-9]+ *\\?$' | tr -d ' \\' | grep -v '^do$' | grep .
}

echo "== 1. the gate exists as a recipe and runs seven checks, in order"

GATE_BODY="$(recipe_body "$M28_GATE_RECIPE")"
assert_ge "the $M28_GATE_RECIPE recipe has a body" 10 \
  "$(printf '%s\n' "$GATE_BODY" | grep -c . || true)"
GATE_CHECKS="$(recipe_checks "$M28_GATE_RECIPE")"
N_GATE="$(printf '%s\n' "$GATE_CHECKS" | grep -c . || true)"
note "the gate runs: $(printf '%s\n' "$GATE_CHECKS" | tr '\n' ' ')"
assert_eq "the gate runs exactly seven checks" "7" "$N_GATE"
assert_eq "…and they are these, in this order" \
  "ci_browser_gate verify_browser_bundle_no_node_builtins verify_browser_bundle_no_native_deps verify_npm_pack_no_optional_native verify_verification_code_unreachable_from_browser verify_browser_entry_points_are_dd5_shaped smoke_browser_headless_full_flow" \
  "$(printf '%s\n' "$GATE_CHECKS" | tr '\n' ' ' | sed 's/ $//')"
# Every one of them is a check that exists and can run — a recipe naming a script that is not there
# fails at run time with a shell error rather than as a gate that reported nothing.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  assert_file "the gate's check $c exists" "$VERIFY_DIR/$c.sh"
  assert_true "…and is executable" test -x "$VERIFY_DIR/$c.sh"
done <<< "$GATE_CHECKS"

echo "== 2. verify-m28 is the gate minus exactly M27's DD-5 check"

M28_CHECKS="$(recipe_checks verify-m28)"
N_M28="$(printf '%s\n' "$M28_CHECKS" | grep -c . || true)"
assert_eq "verify-m28 runs six checks" "6" "$N_M28"
ONLY_IN_GATE="$(comm -23 <(printf '%s\n' "$GATE_CHECKS" | LC_ALL=C sort) \
                          <(printf '%s\n' "$M28_CHECKS" | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"
ONLY_IN_M28="$(comm -13 <(printf '%s\n' "$GATE_CHECKS" | LC_ALL=C sort) \
                         <(printf '%s\n' "$M28_CHECKS" | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the one check the gate runs and verify-m28 does not is M27's DD-5 check" \
  "verify_browser_entry_points_are_dd5_shaped" "$ONLY_IN_GATE"
assert_eq "…and verify-m28 runs nothing the gate does not" "" "$ONLY_IN_M28"
# The reason the difference exists, asserted rather than only commented: that check IS M27's, and
# M27's own recipe runs it, so counting it in both would double-count it in a sweep.
assert_true "and verify-m27 does run it, which is where its assertions are counted" \
  str_has_line "$(recipe_checks verify-m27)" "verify_browser_entry_points_are_dd5_shaped"
assert_eq "…while verify-m27 does not run any of M28's own checks" "" \
  "$(comm -12 <(recipe_checks verify-m27 | LC_ALL=C sort) \
              <(printf '%s\n' "$M28_CHECKS" | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"

echo "== 3. DD-5 IS the rule this gate exists to keep, and the check that holds it can fail"

# M23 marked DD-5 unmet rather than "met in spirit" and M27 delivered the entry points; what makes
# it STAY met is that the gate runs the check on every PR. The check's own mechanism is asserted
# here — the set equality in BOTH directions — because a subset test in either direction would let
# one of the two failures through, and "Node may add conveniences, never capabilities" is exactly a
# two-directional claim.
DD5="$(cat "$VERIFY_DIR/verify_browser_entry_points_are_dd5_shaped.sh")"
assert_true "the DD-5 check compares the node entry's ADDITIONS against a declared set" \
  str_has_sub "$DD5" "the node entry's ADDITIONS are exactly its DECLARED conveniences"
assert_true "…and asserts the browser's surface is contained in the node one" \
  str_has_sub "$DD5" "Node is the SUPERSET"
assert_true "…with NODE_CONVENIENCES read out of the BUILT bundle rather than from a comment" \
  str_has_sub "$DD5" "Object.keys(m.NODE_CONVENIENCES)"
assert_ge "…and NODE_CONVENIENCES is a value in the source, so the comparison has two sides" 1 \
  "$(grep -c 'NODE_CONVENIENCES' "$BROWSER_SRC/entry_node.ts" || true)"

echo "== 4. the CI job invokes THAT recipe, on every PR, and is not skippable"

WF="$(cat "$M28_WORKFLOW")"
assert_true "the workflow declares the browser-gate job" str_has_line "$WF" "  $M28_GATE_JOB:"
JOB="$(python3 - "$M28_WORKFLOW" "$M28_GATE_JOB" <<'PY'
import sys
name = sys.argv[2]
out, inside = [], False
for line in open(sys.argv[1], encoding="utf-8"):
    s = line.rstrip("\n")
    if not inside:
        if s == "  %s:" % name:
            inside = True
        continue
    if s and not s.startswith("    ") and s.strip():
        break
    out.append(s)
print("\n".join(out))
PY
)"
assert_ge "…and the job has a body" 40 "$(printf '%s\n' "$JOB" | grep -c . || true)"
assert_true "the job invokes the gate BY RECIPE NAME, so it cannot become a parallel copy" \
  str_has_sub "$JOB" "just $M28_GATE_RECIPE"

# THE JOB'S EXECUTABLE LINES, WITH THE COMMENTS STRIPPED. The first version of the two predicates
# below read the whole job text and reported the job's own COMMENTS — which say, in as many words,
# that there is no `continue-on-error` here and that `ci_browser_gate.sh` asserts it. A needle that
# cannot tell a sentence from a statement reports the remedy as the disease; this campaign has the
# same error recorded in its `mktemp -d` census, which counted its own two fix comments as
# remaining exposure.
JOB_CODE="$(printf '%s\n' "$JOB" | grep -vE '^[[:space:]]*#' || true)"
assert_ge "the job has executable lines once its comments are stripped" 30 \
  "$(printf '%s\n' "$JOB_CODE" | grep -c . || true)"
assert_ge "…and it does have comments, so the stripping is doing something" 20 \
  "$(( $(printf '%s\n' "$JOB" | grep -c . || true) - $(printf '%s\n' "$JOB_CODE" | grep -c . || true) ))"

# A parallel copy is exactly what this forbids: the job must not enumerate the checks itself.
NAMED_IN_JOB="$(printf '%s\n' "$JOB_CODE" | grep -oE 'verification/[a-z_0-9]+\.sh' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "…and the job runs no check script directly" "" "${NAMED_IN_JOB% }"

# EVERY PR, NOT NIGHTLY.
TRIGGERS="$(python3 - "$M28_WORKFLOW" <<'PY'
import sys
out, inside = [], False
for line in open(sys.argv[1], encoding="utf-8"):
    s = line.rstrip("\n")
    if s == "on:":
        inside = True
        continue
    if inside and s and not s[0].isspace():
        break
    if inside:
        out.append(s)
print("\n".join(out))
PY
)"
assert_true "the workflow triggers on pull_request" str_has_line "$TRIGGERS" "  pull_request:"
assert_true "…for dev and main" str_has_sub "$TRIGGERS" "branches: [dev, main]"
assert_true "…and on push too, so a merge is gated as well as a proposal" \
  str_has_line "$TRIGGERS" "  push:"
# The schedule exists for the OTHER jobs; what matters is that this job is not restricted to it.
assert_true "the workflow also has a schedule, which is what this job must NOT be limited to" \
  str_has_line "$TRIGGERS" "  schedule:"
assert_eq "the browser-gate job carries no event filter, so it runs on every trigger including PRs" \
  "0" "$(printf '%s\n' "$JOB" | grep -cE "^    if:" || true)"

# NOT SKIPPABLE.
gate_escapes() { # <text> -> one line per escape hatch found
  printf '%s\n' "$1" | grep -nE "continue-on-error|(\|\| *true)|^ *if: *\\\$\{\{" || true
}
# THE STEP THAT RUNS THE GATE, on its own. `|| true` is asked of THIS step rather than of the whole
# job, because the job's `Assert the series base commit is present` step legitimately carries
# `git fetch --unshallow 2>/dev/null || true` — an unshallow of an already-complete clone fails and
# that is not an escape hatch. Found on this check's own first run. The exception is not waved
# through: the count of `|| true` in the rest of the job is PINNED at one and the line is named, so
# a second one is a failure rather than something the exception absorbs.
GATE_STEP="$(printf '%s\n' "$JOB_CODE" | awk '
  /^      - name: THE GATE — just/ { inside = 1 }
  inside && /^      - name:/ && ++seen > 1 { inside = 0 }
  inside { print }')"
assert_ge "the gate step was found in the job" 5 "$(printf '%s\n' "$GATE_STEP" | grep -c . || true)"
assert_eq "the gate step has no continue-on-error and no || true" "" "$(gate_escapes "$GATE_STEP")"
assert_eq "the job carries no continue-on-error and no step-level if: anywhere" "" \
  "$(printf '%s\n' "$JOB_CODE" | grep -nE "continue-on-error|^ *if: *\\\$\{\{" || true)"
assert_eq "the gate step carries no if: of its own, so nothing can skip it conditionally" "0" \
  "$(printf '%s\n' "$GATE_STEP" | grep -cE '^ *if:' || true)"
# EVERY `|| true` IN THE JOB IS CLASSIFIED, and the residue is what is asserted rather than the
# count. Seven of them exist and all seven are in steps that exist to REPORT: the unshallow, five
# artefact copies and two greps over a log that may not be there. A `|| true` on anything else is a
# new shape and fails here — which is the scanner discipline this campaign settled on, "print the
# residue rather than counting the matches".
OR_TRUE="$(printf '%s\n' "$JOB_CODE" | grep -E '\|\| *true' | sed 's/^ *//')"
assert_ge "the job does contain || true lines, so classifying them is not vacuous" 1 \
  "$(printf '%s\n' "$OR_TRUE" | grep -c . || true)"
assert_eq "every || true in the job is a report-or-fetch line, never a check line" "" \
  "$(printf '%s\n' "$OR_TRUE" | grep -vE '^(git fetch --unshallow|cp |grep -|echo )' || true)"
assert_ge "…and the unshallow, which is the one that is not a report, is among them" 1 \
  "$(printf '%s\n' "$OR_TRUE" | grep -c 'git fetch --unshallow' || true)"
assert_eq "…and none of them is the gate invocation itself" "0" \
  "$(printf '%s\n' "$OR_TRUE" | grep -c "just $M28_GATE_RECIPE" || true)"
assert_eq "the recipe has neither" "" "$(gate_escapes "$GATE_BODY")"
# THE CONTROL, ON THE SAME PREDICATE. An absence needs an instrument shown to be capable of finding
# the thing. Both violations are planted into scratch copies of the real text.
assert_ge "the same predicate DOES report a planted continue-on-error" 1 \
  "$(gate_escapes "$JOB_CODE
    continue-on-error: true" | grep -c . || true)"
assert_ge "…and a planted || true in the recipe" 1 \
  "$(gate_escapes "$GATE_BODY
      verification/\"\$check\".sh || true" | grep -c . || true)"
# And it discriminates: the unmodified texts above are what it says nothing about.
assert_eq "…while saying nothing about the unmodified recipe" "" "$(gate_escapes "$GATE_BODY")"

assert_true "the recipe collects failures rather than stopping at the first" \
  str_has_sub "$GATE_BODY" '|| rc=1'
assert_true "…and exits with the collected status, so a failure is the build's status" \
  str_has_sub "$GATE_BODY" 'exit "$rc"'
assert_true "…and says in as many words that it is a build failure rather than a warning" \
  str_has_sub "$GATE_BODY" "not a warning"
assert_true "the gate step uses shell: bash, because the default has no pipefail and it pipes to tee" \
  str_has_sub "$JOB" "shell: bash"
assert_true "…and it does pipe to tee, which is why that matters" str_has_sub "$JOB" "tee ci-browser-gate.log"

echo "== 5. no check in the gate can report success without having run"

# `lib.sh`'s first design rule: "a check that cannot run in this environment FAILS. It never prints
# a SKIP line and exits 0." Asserted over the gate's own members, because an environment-conditional
# early exit is the flag-shaped escape hatch the deliverable forbids, wearing a different hat.
# `exit 0` IN COMMAND POSITION, which is not the same as the characters `exit 0`. The first version
# of this predicate was `^[^#]*\bexit 0\b` and it reported two of the gate's own checks — because
# `smoke_browser_headless_full_flow` has an assertion whose DESCRIPTION reads "so exit 0 above is a
# verdict", and this file has one that names the rule it is enforcing. That is the campaign's own
# "a citation is the opposite of a dependency", committed by the instrument rather than by a check.
# A skip is a statement: a bare `exit 0` on its own line, or one after `then`/`else`/`;`.
exit_zero_sites() { # <file>
  grep -nE '(^[[:space:]]*|[;&]|\bthen\b|\belse\b|\bdo\b)[[:space:]]*exit[[:space:]]+0([[:space:]]*[;&|)]|[[:space:]]*(#.*)?$)' "$1" || true
}
# A SKIP outside a comment. Both `lib.sh` and this file DESCRIBE the no-skip rule in prose, so a
# needle that cannot tell a sentence from a statement reports the remedy as the disease — the same
# error the `mktemp -d` census made when it counted its own two fix comments as remaining exposure.
skip_statements() { # <file>
  grep -vE '^[[:space:]]*#' "$1" | grep -nE '\bSKIP\b' || true
}
EARLY_EXITS=""
SKIPS=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  n="$(exit_zero_sites "$VERIFY_DIR/$c.sh" | grep -c . || true)"
  [ "$n" = "0" ] || EARLY_EXITS="$EARLY_EXITS $c:$n"
  s="$(skip_statements "$VERIFY_DIR/$c.sh" | grep -c . || true)"
  [ "$s" = "0" ] || SKIPS="$SKIPS $c:$s"
done <<< "$GATE_CHECKS"
assert_eq "no gate check exits zero in command position, so none can report success without running" \
  "" "$EARLY_EXITS"
assert_eq "…and none of them carries a skip word outside a comment" "" "$SKIPS"

# THE CONTROLS, ON THE SAME TWO FUNCTIONS.
#
# THE PROBE TEXT LIVES IN A FIXTURE FILE AND NOT IN THIS SCRIPT, and that is not tidiness: with the
# probe written as a `printf` literal here, this file itself contained a skip statement and the two
# predicates above reported THEMSELVES — four hits, all of them inside single-quoted strings. The
# alternative was an exemption for this file, which is how a total rule stops being one. Moving the
# two probes into `verification/m28/` keeps the predicates exemption-free and makes the control
# readable on its own.
PROBE_CLEAN="$VERIFY_DIR/m28/skip_probe_clean.txt"
PROBE_PLANTED="$M28_WORK/skip-probe-planted.txt"
assert_file "the discrimination probe exists" "$PROBE_CLEAN"
assert_file "the planted-skip probe exists" "$VERIFY_DIR/m28/skip_probe_planted.txt"
mkdir -p "$M28_WORK"
assert_eq "neither predicate reports a file whose only mentions are in a comment" "0" \
  "$(( $(exit_zero_sites "$PROBE_CLEAN" | grep -c . || true) + $(skip_statements "$PROBE_CLEAN" | grep -c . || true) ))"
cat "$PROBE_CLEAN" "$VERIFY_DIR/m28/skip_probe_planted.txt" >"$PROBE_PLANTED"
assert_ge "…while the exit-in-command-position predicate DOES report a planted skip" 1 \
  "$(exit_zero_sites "$PROBE_PLANTED" | grep -c . || true)"
assert_ge "…and the skip-word predicate reports it too" 1 \
  "$(skip_statements "$PROBE_PLANTED" | grep -c . || true)"
# The two probes differ by exactly the planted line, so the pair is a discrimination and not two
# unrelated files that happen to answer differently.
assert_eq "the two probes differ by exactly one line" "1" \
  "$(( $(wc -l <"$PROBE_PLANTED") - $(wc -l <"$PROBE_CLEAN") ))"
rm -f "$PROBE_PLANTED"
# Every gate check reaches `finish` through the abnormal-exit trap, so a check that DIES prints a
# summary line and reddens the gate instead of shrinking it.
for c in $GATE_CHECKS; do
  assert_true "$c installs the abnormal-exit trap, so a die is a red gate and not a smaller one" \
    grep -qE '^m2[78]_summary_on_abnormal_exit$' "$VERIFY_DIR/$c.sh"
done

echo "== 6. the write-up is opened here, and its figures are re-derived from the artefacts"

DOC="$(cat "$M28_DOC")"
assert_ge "the write-up has substance" 80 "$(printf '%s\n' "$DOC" | grep -c . || true)"

# THE FIGURE IS LOOKED FOR ON THE LINE THAT NAMES ITS SUBJECT, not anywhere in the file. M24's
# review found an OQ-6 check that matched each figure as `| <number> |` anywhere in the document:
# swapping two rows' medians left the document stating the reverse of the data with 91 assertions
# and 0 failures.
# A VERDICT RATHER THAN AN ASSERTION, so the instrument can be controlled without the control's
# deliberate failures landing in this check's counters. The first draft asserted directly and then
# saved and restored `_FAILURES` around the two control calls, which works and is exactly the kind
# of cleverness a reviewer should not have to verify.
doc_verdict() { # <document-text> <subject-needle> <expected> -> ok | missing | wrong:<line>
  local doc="$1" needle="$2" want="$3" line
  line="$(printf '%s\n' "$doc" | grep -F -- "$needle" | head -1)"
  if [ -z "$line" ]; then printf 'missing\n'; return; fi
  if str_has_word "$line" "$want"; then printf 'ok\n'; else printf 'wrong:%s\n' "${line:0:160}"; fi
}
doc_figure() { # <subject-needle> <expected> <description>
  assert_eq "$3  [$2 on the line naming '$1']" "ok" "$(doc_verdict "$DOC" "$1" "$2")"
}

m27_require_bundle
BROWSER="$(m28_scan browser "$BROWSER_DIST" "$BROWSER_DIST/meta.json" node)" \
  || die "the browser bundle scan could not be read; see the message above and $M28_WORK/scan-browser.err"
NODE="$(m28_scan node "$BROWSER_DIST/node" "$BROWSER_DIST/node/meta.json")" \
  || die "the node bundle scan could not be read; see the message above and $M28_WORK/scan-node.err"

doc_figure "The gate recipe runs" "$N_GATE" "the doc's gate-size figure is the recipe's own"
doc_figure "The verify-m28 recipe runs" "$N_M28" "…and its verify-m28 figure is that recipe's own"
# THE SIZE IS NOT THE COMPOSITION. §2 lists the seven checks by name in a table, and until M28's
# review only the SIZE (7) and the EXISTENCE of every name the document contains were re-derived —
# so replacing one row with a DIFFERENT check that exists satisfied both, and this check reported
# 101 assertions, 0 failures over a table naming the wrong gate. Measured. The table's set of check
# names is compared with the recipe's, as a set.
DOC_TABLE_CHECKS="$(printf '%s\n' "$DOC" | python3 -c '
import re, sys
# A table ROW, not the header and not the separator: the FIRST cell only, so a check named in a
# row description cannot stand in for one named as the row subject.
NAME = re.compile(r"\b(?:verify|test|e2e|smoke)_[a-z0-9_]{4,}\b")
out = set()
for line in sys.stdin:
    if not line.startswith("| `"):
        continue
    cell = line.split("|")[1]
    out.update(NAME.findall(cell))
    # The gate row names the check by the command a person types (`just ci-browser-gate`) with the
    # script beside it, because that is its TEST_NAME; the four-family regex above cannot see it.
    if "ci_browser_gate" in cell:
        out.add("ci_browser_gate")
print(" ".join(sorted(out)))')"
assert_ge "§2s table was read at all, so the comparison below has two sides" 5 \
  "$(printf '%s\n' "$DOC_TABLE_CHECKS" | tr " " "\n" | grep -c . || true)"
assert_eq "§2s table names exactly the checks the gate recipe runs, as a set" \
  "$(printf '%s\n' "$GATE_CHECKS" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')" \
  "$DOC_TABLE_CHECKS"
doc_figure "The browser bundle's module graph has" "$(m28_value "$BROWSER" INPUTS)" \
  "the doc's browser input count is the metafile's"
doc_figure "The node bundle's module graph has" "$(m28_value "$NODE" INPUTS)" \
  "…and its node input count is the node metafile's"
doc_figure "Node builtins left external in the browser bundle" \
  "$(m28_rows "$BROWSER" BUILTIN-EXTERNAL | grep -c . || true)" \
  "the doc's browser-externals figure is the scanner's"
doc_figure "Node builtins left external in the node bundle" \
  "$(m28_rows "$NODE" BUILTIN-EXTERNAL | grep -c . || true)" \
  "…and its node-externals figure is the scanner's"
doc_figure "The browser bundle reaches \`msgpackr-extract\`" \
  "$(m28_rows "$BROWSER" NATIVE-LOADER | awk -F'\t' '$1 == "msgpackr-extract" { print $2 }')" \
  "the doc's browser msgpackr-extract figure is the scanner's"
doc_figure "The node bundle reaches \`msgpackr-extract\`" \
  "$(m28_rows "$NODE" NATIVE-LOADER | awk -F'\t' '$1 == "msgpackr-extract" { print $2 }')" \
  "…and its node msgpackr-extract figure is the scanner's"
doc_figure "distinct directory roots" "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
roots = set()
for k in m["inputs"]:
    p = k.split("/")
    roots.add("orchestration/node_modules" if p[0] == "orchestration" and len(p) > 1 and p[1] == "node_modules"
              else ("orchestration/src" if p[0] == "orchestration" else p[0]))
print(len(roots))' "$BROWSER_DIST/meta.json")" \
  "the doc's root count is the metafile's"
doc_figure "The graph carries" "$(m28_rows "$BROWSER" BUILTIN-SHIMMED | awk -F'\t' '$1 == "util" { print $3 }')" \
  "the doc's util import-edge count is the metafile's"
doc_figure "shipped packages" "$(cd "$REPO_ROOT" && git ls-files '*/package.json' | grep -cE '^(orchestration|node-host|ct-host)/' || true)" \
  "the doc's shipped-package count is the tree's"
# THE CLOSURE WALK, PRINTING BOTH OF ITS FIGURES. §5 used to carry them on ONE line — "is **268**
# packages, of which **3** declare" — with only the 268 re-derived, so swapping the two left the
# document stating that the closure is three packages of which 268 declare an optional native
# dependency, and this check reported 101 assertions, 0 failures. Measured by M28's review. It is
# M24's review's OQ-6 defect exactly, in the section AFTER the one M28 converted to one figure per
# line for that very reason: fixing an instance of a form is not the same as grepping the file for
# it. Both figures are re-derived now, from the same walk, each on its own line.
CLOSURE_WALK="$(python3 - "$REPO_ROOT/orchestration" <<'PY'
import json, os, sys
root = sys.argv[1]
nm = os.path.join(root, "node_modules")
seen, optional = set(), []
stack = list(json.load(open(os.path.join(root, "package.json"))).get("dependencies", {}))
while stack:
    n = stack.pop()
    if n in seen:
        continue
    seen.add(n)
    p = os.path.join(nm, n, "package.json")
    if not os.path.exists(p):
        continue
    d = json.load(open(p))
    od = d.get("optionalDependencies") or {}
    if od:
        optional.append(n)
    stack.extend(d.get("dependencies") or {})
    stack.extend(od)
print("SIZE %d" % len(seen))
print("OPTIONAL %d" % len(optional))
PY
)"
doc_figure "dependency closure of the shipped package is" \
  "$(printf '%s\n' "$CLOSURE_WALK" | sed -n 's/^SIZE //p')" "the doc's closure size is the walk's"
doc_figure "Manifests in that closure declaring" \
  "$(printf '%s\n' "$CLOSURE_WALK" | sed -n 's/^OPTIONAL //p')" \
  "…and its optional-manifest count is the walk's, on its OWN line so the two cannot be swapped"

# THE CONTROL FOR THE INSTRUMENT ITSELF, run over a scratch document through the same function.
# Three cases: a right figure on the right line, a WRONG figure on a line that exists, and a
# subject line the document does not contain. Without the third, a needle that quietly stopped
# matching would report a clean document; without the second, any line naming the subject would do.
SCRATCH="The browser bundle's module graph has 1061 inputs."
assert_eq "the doc instrument passes a figure that is right" "ok" \
  "$(doc_verdict "$SCRATCH" "The browser bundle's module graph has" "1061")"
assert_prefix "…reports a WRONG figure on a line that exists" "wrong:" \
  "$(doc_verdict "$SCRATCH" "The browser bundle's module graph has" "999")"
assert_eq "…and reports a subject line the document does not contain, rather than passing" \
  "missing" "$(doc_verdict "$SCRATCH" "a subject this document does not contain" "1")"
# And the word boundary is real: `106` must not satisfy a line that says `1061`.
assert_prefix "…and it matches on word boundaries, so 106 does not satisfy 1061" "wrong:" \
  "$(doc_verdict "$SCRATCH" "The browser bundle's module graph has" "106")"

echo "== 7. the write-up names the decay, and every check it names exists"

assert_true "the write-up names DD-5 as the reason the gate exists" str_has_sub "$DOC" "DD-5 exists because"
assert_true "…and names upstream's own decay as the specific thing prevented" \
  str_has_sub "$DOC" "browser story decayed"
assert_true "…and gives the four-step mechanism rather than an exhortation" \
  str_has_sub "$DOC" "nobody decided anything"
assert_true "…and states plainly that it has never run in CI" str_has_sub "$DOC" "never run in CI"
assert_true "…and says what it does NOT establish" str_has_sub "$DOC" "does NOT establish"

# `verify_named_checks_exist` scans `verification/`, `tools/`, `browser/` and three `src` roots —
# NOT the repository-root `.md` files, which M27's review recorded as a standing gap
# (`BROWSER-PACKAGING.md` names five checks and is scanned by nothing). This closes the gap for
# THIS document rather than leaving a write-up full of check names that nothing resolves.
DOC_NAMES="$(printf '%s\n' "$DOC" | grep -oE '\b(verify|test|e2e|smoke)_[a-z0-9_]{4,}\b' | LC_ALL=C sort -u)"
assert_ge "the write-up does name checks, so resolving them is not vacuous" 5 \
  "$(printf '%s\n' "$DOC_NAMES" | grep -c . || true)"
UNRESOLVED_DOC=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  [ -f "$VERIFY_DIR/$n.sh" ] && continue
  grep -qlE "^TEST_NAME=\"$n\"" "$VERIFY_DIR"/*.sh 2>/dev/null && continue
  # M25's pending entry, cited in the paragraph that says it does NOT exist — the same declared
  # exception `verify_named_checks_exist` carries for `ct_download.ts` and BROWSER-PACKAGING.md.
  [ "$n" = "test_trace_step_count_matches_instruction_count" ] && continue
  UNRESOLVED_DOC="$UNRESOLVED_DOC $n"
done <<< "$DOC_NAMES"
assert_eq "every check the write-up names exists" "" "$UNRESOLVED_DOC"
assert_ge "…and the one it names as ABSENT is still absent, so that exception is not dead" 1 \
  "$(printf '%s\n' "$DOC_NAMES" | grep -cx 'test_trace_step_count_matches_instruction_count' || true)"

echo "== 8. the gate reuses M27's driver rather than installing a browser stack"

# "No puppeteer, no playwright" is what buys this gate: the driver is 331 lines of this
# repository's own code over Node 24's global WebSocket. M27's review pinned the absence over the
# package manifests; what is asserted here is that the GATE depends on that and nothing else.
assert_file "the CDP driver is M27's" "$REPO_ROOT/tools/browser_cdp.mjs"
assert_eq "the gate installs no browser-automation package" "" \
  "$(cd "$REPO_ROOT" && git ls-files '*/package.json' | xargs python3 "$VERIFY_DIR/_m27_depscan.py" \
     | sed -n 's/^AUTOMATION\t//p')"
assert_ge "…and that scan really parsed the manifests, so the empty answer is a measurement" 7 \
  "$(cd "$REPO_ROOT" && git ls-files '*/package.json' | xargs python3 "$VERIFY_DIR/_m27_depscan.py" \
     | sed -n 's/^FILES\t//p')"
assert_ge "…and its control needle does find something, so the instrument discriminates" 1 \
  "$(cd "$REPO_ROOT" && git ls-files '*/package.json' | xargs python3 "$VERIFY_DIR/_m27_depscan.py" \
     | sed -n 's/^CONTROL\t//p' | wc -w)"

m28_finish
