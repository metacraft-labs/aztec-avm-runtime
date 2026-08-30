#!/usr/bin/env bash
# verify_oracle_coverage_is_measured
#
# M35 verification: "The implemented and refusing sets are disjoint and sum to the registry's
# re-derived count. Control: a fabricated oracle name is in neither set."
#
# ===========================================================================================
# THE COUNT IS RE-DERIVED THREE WAYS AND ONE OF THEM IS ITS OWN CONTROL
# ===========================================================================================
#
# The milestone's fifth deliverable is *"the registry count RE-DERIVED, never remembered"*, and
# RI-65 records why: the `upstream/tsavm` worktree that is already checked out declares **53**
# entries against the anchor's **68**, and does not carry `acir_callback.ts` or
# `legacy_oracle_registry.ts` at all — so vendoring from the tree that happens to be on disk, the way
# RI-25 vendored the simulator files, would ship a 53-oracle surface against 68-oracle bytecode.
#
# So the number is taken:
#
#   1. from the `cpp` ANCHOR'S OBJECT STORE, by a structural parse (`_m35_oracles.py`) that walks the
#      object literal's balanced region with a string- and comment-aware reader and PRINTS the
#      residue rather than counting the matches;
#   2. from the VENDORED COPY in this repository, which must agree to the entry — `check-drift`
#      already says the bytes are identical, and this says the DERIVATION over them is;
#   3. from the `upstream/tsavm` WORKTREE, which must NOT agree, and whose 53 is the control that the
#      derivation can tell two registries apart. A parse that had silently stopped matching would
#      report the same wrong number for all three, and this is the assertion that catches it.
#
# And the same count is read a fourth time out of the BUILT BUNDLE, in the browser, as
# `Object.keys(ORACLE_REGISTRY).length` — because what the page executes against is the bundle and
# not the file.
#
# ===========================================================================================
# WHY THE PARTITION NEEDS MORE THAN A SUM
# ===========================================================================================
#
# `implemented + refusing == 68` is satisfied by a great many wrong pairs. Four more things are
# asserted, and each closes a way the sum could be true and the surface wrong:
#
#   * DISJOINT — a name in both would be counted twice and served once.
#   * EVERY NAME IN EITHER SET IS A REGISTRY NAME — the fabricated-name control, in both directions:
#     a name the check invents is in neither set, and the sets' union IS the registry's key set
#     compared as a SET rather than as a size.
#   * EVERY REFUSED ORACLE HAS A DECLARED REASON — a refusal that says only "not implemented" is a
#     refusal a reader cannot act on.
#   * EVERY IMPLEMENTED ORACLE WAS EXERCISED. This is the one a count cannot give: the `surface` arm
#     reports the SET of oracles it actually reached through the handler, and it must equal the
#     declared implemented set. "Implemented" has to mean "observed to answer" — a handler whose
#     unexercised methods returned plausible defaults would satisfy every other assertion here.
#
# Run: just verify-m35-coverage

TEST_NAME="verify_oracle_coverage_is_measured"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"
. "$VERIFY_DIR/lib_m35_private.sh"

m35_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -d "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT; the anchor's object store is where the registry is read from"
m35_require_arms

ANCHOR="$(m35_cpp_anchor)"
WORK="${M35_CHECK_WORK:-$HOME/.cache/aztec-m35-coverage}"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. THE COUNT, out of the ANCHOR'S OBJECT STORE"

m35_anchor_show yarn-project/pxe/src/contract_function_simulator/oracle/oracle_registry.ts > "$WORK/anchor_registry.ts"
m35_anchor_show yarn-project/pxe/src/contract_function_simulator/oracle/legacy_oracle_registry.ts > "$WORK/anchor_legacy.ts"
assert_true "the anchor's oracle_registry.ts came out of the object store" test -s "$WORK/anchor_registry.ts"
assert_true "the anchor's legacy_oracle_registry.ts came out of the object store" test -s "$WORK/anchor_legacy.ts"

ANCHOR_OUT="$(m35_registry "$WORK/anchor_registry.ts" "$WORK/anchor_legacy.ts")"
A_COUNT="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="COUNT"{print $2}')"
A_UNBAL="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="UNBALANCED"{print $2}')"
A_RESIDUE="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="RESIDUE"{print $2}')"
A_RESIDUE_KINDS="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="RESIDUE_TOKEN"{print $2}' | sort -u | tr '\n' ' ')"
A_LEGACY="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="LEGACY_COUNT"{print $2}')"
A_MISC="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="SCOPE" && $2=="misc"{print $3}')"
A_UTL="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="SCOPE" && $2=="utl"{print $3}')"
A_PRV="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="SCOPE" && $2=="prv"{print $3}')"
A_UNKNOWN_SCOPE="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="SCOPE" && $2=="?"{print $3}')"

assert_eq "the scanner found the object's closing brace" "0" "$A_UNBAL"
assert_eq "the anchor's ORACLE_REGISTRY declares 68 entries" "68" "$A_COUNT"
assert_eq "3 misc" "3" "$A_MISC"
assert_eq "49 utl" "49" "$A_UTL"
assert_eq "16 prv" "16" "$A_PRV"
assert_eq "and every key follows upstream's aztec_{scope}_{method} convention" "" "$A_UNKNOWN_SCOPE"
assert_eq "3 + 49 + 16 sums to the whole" "$A_COUNT" "$((A_MISC + A_UTL + A_PRV))"
# THE RESIDUE IS PRINTED AND ASSERTED, which is what makes the count a derivation rather than a
# grep: everything at depth 0 that is not a key is reported, and here it is exactly one `makeEntry`
# token per entry — the value half of each pair — and nothing else.
assert_eq "the residue is one token per entry" "$A_COUNT" "$A_RESIDUE"
assert_eq "and every residue token is the entry's own makeEntry call" "makeEntry " "$A_RESIDUE_KINDS"
assert_eq "the anchor declares 3 legacy oracle aliases beside them" "3" "$A_LEGACY"

echo "== 2. THE SAME DERIVATION OVER THE VENDORED COPY, and over the worktree that is FIFTEEN SHORT"

V_OUT="$(m35_registry "$M35_VENDOR_PXE/contract_function_simulator/oracle/oracle_registry.ts" \
                      "$M35_VENDOR_PXE/contract_function_simulator/oracle/legacy_oracle_registry.ts")"
V_COUNT="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1=="COUNT"{print $2}')"
V_LEGACY="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1=="LEGACY_COUNT"{print $2}')"
V_NAMES="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1=="ORACLE"{print $2}' | sort | tr '\n' ' ')"
A_NAMES="$(printf '%s\n' "$ANCHOR_OUT" | awk -F'\t' '$1=="ORACLE"{print $2}' | sort | tr '\n' ' ')"
assert_eq "the vendored registry declares the anchor's count" "$A_COUNT" "$V_COUNT"
assert_eq "and the same three legacy aliases" "$A_LEGACY" "$V_LEGACY"
assert_eq "and the same names, compared as a set" "$A_NAMES" "$V_NAMES"

# THE CONTROL, AND IT IS THE ONE RI-65 ASKED FOR. The worktree copy is a DIFFERENT registry, and a
# derivation that could not tell them apart would report 68 for both.
TSAVM="$REPO_ROOT/upstream/tsavm/yarn-project/pxe/src/contract_function_simulator/oracle/oracle_registry.ts"
assert_file "the checked-out upstream/tsavm worktree carries an oracle_registry.ts" "$TSAVM"
T_OUT="$(m35_registry "$TSAVM")"
T_COUNT="$(printf '%s\n' "$T_OUT" | awk -F'\t' '$1=="COUNT"{print $2}')"
assert_eq "and it declares 53, which is the trap RI-65 records" "53" "$T_COUNT"
assert_true "so the derivation distinguishes two registries rather than printing one number" \
  test "$T_COUNT" -ne "$A_COUNT"
assert_eq "the worktree is fifteen entries short of the anchor" "15" "$((A_COUNT - T_COUNT))"
assert_false "and it does not carry acir_callback.ts at all" \
  test -f "$REPO_ROOT/upstream/tsavm/yarn-project/pxe/src/contract_function_simulator/oracle/acir_callback.ts"

echo "== 3. THE COUNT AS THE BUILT BUNDLE SEES IT, in the browser"

B_TOTAL="$(m35_arm surface.report.registry.total)"
B_IMPL="$(m35_arm surface.report.registry.implemented)"
B_REFUSING="$(m35_arm surface.report.registry.refusing)"
B_REASONS="$(m35_arm surface.report.registry.reasons)"
B_METHODS="$(m35_arm surface.report.registry.handlerMethods)"
B_MARKERS="$(m35_arm surface.report.registry.handlerMarkers)"
B_EXERCISED="$(m35_arm surface.report.exercised)"
B_ENVV="$(m35_arm surface.report.registry.environmentVersion)"
m35_absent "surface.report.registry.total=$B_TOTAL" "surface.report.registry.implemented=$B_IMPL" \
  "surface.report.registry.refusing=$B_REFUSING" "surface.report.registry.reasons=$B_REASONS" \
  "surface.report.exercised=$B_EXERCISED" "surface.report.registry.handlerMethods=$B_METHODS" \
  "surface.report.registry.handlerMarkers=$B_MARKERS" "surface.report.registry.environmentVersion=$B_ENVV"

assert_eq "the BUILT bundle's registry has the anchor's count" "$A_COUNT" "$B_TOTAL"
assert_eq "the handler carries one method per oracle" "$A_COUNT" "$B_METHODS"
assert_eq "plus the three scope markers buildACIRCallback checks" "3" "$B_MARKERS"
# ...and ONE non-oracle method, counted separately. It is what the unknown-oracle trap reads, it is
# not in the registry, and folding it into either number would say the handler serves a 69th oracle.
B_NONORACLE="$(m35_arm surface.report.registry.handlerNonOracle)"
m35_absent "surface.report.registry.handlerNonOracle=$B_NONORACLE"
assert_eq "and one non-oracle method, which is the unknown-oracle trap's own input" "1" "$B_NONORACLE"

N_IMPL="$(printf '%s' "$B_IMPL" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
N_REF="$(printf '%s' "$B_REFUSING" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
N_REASONS="$(printf '%s' "$B_REASONS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
N_EXERCISED="$(printf '%s' "$B_EXERCISED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

echo "== 4. THE PARTITION: disjoint, summing, and every member a registry name"

PARTITION="$(python3 - "$A_NAMES" "$B_IMPL" "$B_REFUSING" "$B_EXERCISED" <<'PY'
import json, sys
registry = set(sys.argv[1].split())
impl = set(json.loads(sys.argv[2]))
ref = set(json.loads(sys.argv[3]))
exercised = set(json.loads(sys.argv[4]))
print('OVERLAP\t%s' % ' '.join(sorted(impl & ref)))
print('UNION_EQUALS_REGISTRY\t%s' % ('yes' if impl | ref == registry else 'no'))
print('NOT_IN_REGISTRY\t%s' % ' '.join(sorted((impl | ref) - registry)))
print('UNCOVERED\t%s' % ' '.join(sorted(registry - (impl | ref))))
print('EXERCISED_EQUALS_IMPLEMENTED\t%s' % ('yes' if exercised == impl else 'no'))
print('EXERCISED_MINUS_IMPLEMENTED\t%s' % ' '.join(sorted(exercised - impl)))
print('IMPLEMENTED_MINUS_EXERCISED\t%s' % ' '.join(sorted(impl - exercised)))
# The fabricated-name control: a name the check invents must be in NEITHER set and must not be a
# registry name either, so the three memberships are asked of the same instrument.
fake = 'aztec_utl_getNothingAtAll'
print('FAKE_IN_IMPLEMENTED\t%s' % ('yes' if fake in impl else 'no'))
print('FAKE_IN_REFUSING\t%s' % ('yes' if fake in ref else 'no'))
print('FAKE_IN_REGISTRY\t%s' % ('yes' if fake in registry else 'no'))
# ...and a REAL one must be found by the same three questions, so "no" is a reading rather than a
# comparator that never compares.
real = sorted(registry)[0]
print('REAL\t%s' % real)
print('REAL_IN_EITHER\t%s' % ('yes' if real in impl or real in ref else 'no'))
print('REAL_IN_REGISTRY\t%s' % ('yes' if real in registry else 'no'))
PY
)"
p_field() { printf '%s\n' "$PARTITION" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

assert_eq "the implemented and refusing sets are DISJOINT" "" "$(p_field OVERLAP)"
assert_eq "they sum to the re-derived count" "$A_COUNT" "$((N_IMPL + N_REF))"
assert_eq "and their union IS the registry's key set, compared as a set" "yes" "$(p_field UNION_EQUALS_REGISTRY)"
assert_eq "no member of either set is absent from the registry" "" "$(p_field NOT_IN_REGISTRY)"
assert_eq "and no registry oracle falls out of both" "" "$(p_field UNCOVERED)"
assert_ge "the implemented set is not empty" 1 "$N_IMPL"
assert_ge "the refusing set is not empty" 1 "$N_REF"
assert_eq "every refused oracle has a declared reason" "$N_REF" "$N_REASONS"

# THE CONTROL, run through the SAME three memberships as the subject.
assert_eq "a fabricated oracle name is in neither set" "no no" \
  "$(p_field FAKE_IN_IMPLEMENTED) $(p_field FAKE_IN_REFUSING)"
assert_eq "and is not a registry name either" "no" "$(p_field FAKE_IN_REGISTRY)"
assert_eq "while a real one is found by the same questions" "yes yes" \
  "$(p_field REAL_IN_EITHER) $(p_field REAL_IN_REGISTRY)"
assert_true "and the real one the control used is a registry name" \
  str_has_word "$A_NAMES" "$(p_field REAL)"

echo "== 5. IMPLEMENTED MEANS OBSERVED TO ANSWER"

assert_eq "every implemented oracle was exercised in the browser" "yes" "$(p_field EXERCISED_EQUALS_IMPLEMENTED)"
assert_eq "nothing was exercised that is not declared implemented" "" "$(p_field EXERCISED_MINUS_IMPLEMENTED)"
assert_eq "and nothing declared implemented went unexercised" "" "$(p_field IMPLEMENTED_MINUS_EXERCISED)"
assert_eq "the exercised count is the implemented count" "$N_IMPL" "$N_EXERCISED"

echo "== 6. THE ORACLE VERSION, honoured against the pinned anchor"

# The environment's version is READ from the vendored `oracle_version.ts`; the contract's is read
# from what the BYTECODE passed to the version oracle. Neither is typed here.
ANCHOR_VERSION="$(m35_anchor_show yarn-project/pxe/src/oracle_version.ts \
  | awk -F'= ' '/export const ORACLE_VERSION_(MAJOR|MINOR)/{gsub(/;/,"",$2); printf "%s ", $2}')"
A_MAJOR="$(printf '%s' "$ANCHOR_VERSION" | awk '{print $1}')"
A_MINOR="$(printf '%s' "$ANCHOR_VERSION" | awk '{print $2}')"
assert_ge "the anchor declares an oracle major version" 1 "$A_MAJOR"
assert_eq "and the bundle's environment version is the anchor's, to the digit" \
  "{\"major\":$A_MAJOR,\"minor\":$A_MINOR}" "$B_ENVV"

E_SOLVED_FOR_CONTROL="$(m35_arm private.report.executes.solvedWitnessSize)"
EXEC_CV="$(m35_arm private.report.executes.contractOracleVersion)"
EXEC_EV="$(m35_arm private.report.executes.environmentOracleVersion)"
m35_absent "private.report.executes.contractOracleVersion=$EXEC_CV" \
  "private.report.executes.environmentOracleVersion=$EXEC_EV" \
  "private.report.executes.solvedWitnessSize=$E_SOLVED_FOR_CONTROL"
CV_MAJOR="$(printf '%s' "$EXEC_CV" | python3 -c 'import json,sys; print(json.load(sys.stdin)["major"])')"
CV_MINOR="$(printf '%s' "$EXEC_CV" | python3 -c 'import json,sys; print(json.load(sys.stdin)["minor"])')"
assert_eq "the executed bytecode declared its own oracle version" "$A_MAJOR" "$CV_MAJOR"
assert_true "and its minor is one this environment can serve (environment minor >= contract minor)" \
  test "$A_MINOR" -ge "$CV_MINOR"
# THE TWO MINORS ARE DIFFERENT, which is what makes the >= a comparison rather than an identity: the
# artefact is the deletion-era line and the environment is the anchor's, and upstream's own rule is
# that a minor gap in that direction is not breaking.
assert_true "and the two minors are NOT equal, so the comparison above is not an identity" \
  test "$A_MINOR" -ne "$CV_MINOR"

echo "== 7. THE EPHEMERAL-ARRAY MEASUREMENT, derived rather than listed"

EPH="$(m35_arm surface.report.registry.ephemeralReturnOracles)"
EPH_LABELS="$(m35_arm surface.report.registry.ephemeralReturnLabels)"
m35_absent "surface.report.registry.ephemeralReturnOracles=$EPH" \
  "surface.report.registry.ephemeralReturnLabels=$EPH_LABELS"
N_EPH="$(printf '%s' "$EPH" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_ge "at least one oracle's return carries an EphemeralArray" 1 "$N_EPH"
# THE SECOND DERIVATION, AND THE TWO DO NOT AGREE ON A NUMBER — WHICH IS THE POINT.
#
# The bundle's set comes from each return `TypeMapping`'s own `label`, so it sees the combinator
# however deeply it is nested. The parser's `OUTERMOST_EPHEMERAL` reads the anchor's SOURCE and sees
# only the entries where `EPHEMERAL_ARRAY` is the outermost return type. So one is a subset of the
# other, asserting them equal would be false, and asserting a floor on each would let both pass while
# one had gone dead. The SUBSET relation is asserted and the residue is NAMED.
ANCHOR_EPH_NAMES="$(printf '%s\n' "$ANCHOR_OUT" \
  | awk -F'\t' '$1=="OUTERMOST_EPHEMERAL_ORACLE"{print $2}' | sort | tr '\n' ' ')"
N_ANCHOR_EPH="$(printf '%s' "$ANCHOR_EPH_NAMES" | wc -w)"
assert_ge "the outermost-combinator derivation over the anchor's source finds some too" 1 "$N_ANCHOR_EPH"
EPH_RELATION="$(python3 - "$EPH" "$ANCHOR_EPH_NAMES" <<'PY'
import json, sys
label = set(json.loads(sys.argv[1]))
grep = set(sys.argv[2].split())
print('GREP_MINUS_LABEL\t%s' % ' '.join(sorted(grep - label)))
print('LABEL_MINUS_GREP\t%s' % ' '.join(sorted(label - grep)))
PY
)"
assert_eq "the outermost derivation is a SUBSET of the label derivation" "" \
  "$(printf '%s\n' "$EPH_RELATION" | awk -F'\t' '$1=="GREP_MINUS_LABEL"{print $2}')"
# ...and the residue is NAMED rather than counted away: the label derivation additionally finds the
# one whose `EphemeralArray` is nested inside an `Option`, which is exactly the case a line-oriented
# needle cannot see and the reason this milestone did not trust one derivation.
assert_eq "and the residue is the nested case, named" "aztec_utl_getFactCollection" \
  "$(printf '%s\n' "$EPH_RELATION" | awk -F'\t' '$1=="LABEL_MINUS_GREP"{print $2}')"
assert_eq "every one of them has a label naming the combinator" "$N_EPH" \
  "$(printf '%s' "$EPH_LABELS" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(sum(1 for v in d.values() if "ephemeral-array(" in v))')"

echo "== 8. PRIVATE-EXECUTION.md's figures, re-derived from the artefacts and compared"

# EVERY FIGURE IS LOOKED FOR ON THE LINE THAT NAMES ITS SUBJECT, and matched as a DELIMITED figure on
# that line. Both halves were earned by somebody else: M24's review found a document stating the
# reverse of its own data with every figure present and 91 assertions green, and M33's review found
# two of nineteen figures that could not fail because `245.87` supplies an `8`.
printf '%s\n' "$ANCHOR_OUT" > "$WORK/registry.tsv"

# THE VENDORING TABLE IS DERIVED IN FULL, and the reason is that half of it was wrong.
#
# A first version of this block compared the row's FILE count and left its LINE count alone. The
# line count said 4,870 — which is 923 + 3,947, the 36-file RELATIVE CLOSURE — on a row stating that
# 37 files are vendored; the true figure is 4,961. The file count was right, so nothing looked
# wrong. Each of the four rows is compared on the line that names its own subject now, and BOTH of
# its figures are compared.
#
# Three rows are relative closures over the materialised anchor (M33's tree, M33's walker); the
# fourth is the TRACKED tree measured against the anchor's own blobs, so a vendored file that grew a
# line here would be caught by `check-drift` and a vendored file that was DELETED would be caught
# here.
m33_require_anchor_tree
closure_figures() { # <entry> -> "<files>\t<lines>"
  python3 "$VERIFY_DIR/_import_closure.py" "$M33_ANCHOR_TREE" "$1" \
    | awk -F'\t' '$1=="FULL_FILES"{f=$2} $1=="FULL_LINES"{l=$2} END{printf "%s\t%s", f, l}'
}
SIM_ONE="$(closure_figures yarn-project/simulator/src/private/acvm_wasm.ts)"
SIM_ALL="$(closure_figures yarn-project/simulator/src/client.ts)"
WIRE="$(closure_figures yarn-project/pxe/src/contract_function_simulator/oracle/acir_callback.ts)"
VENDORED_TOTAL="$(python3 - "$REPO_ROOT" "$FORK_ROOT" "$ANCHOR" <<'PY'
import subprocess, sys
repo, fork, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
maps = {'browser/src/vendor/simulator': 'yarn-project/simulator/src',
        'browser/src/vendor/pxe': 'yarn-project/pxe/src'}
files = lines = 0
for local, upstream in maps.items():
    tracked = subprocess.run(['git', '-C', repo, 'ls-files', local],
                             capture_output=True, text=True).stdout.split()
    files += len(tracked)
    for f in tracked:
        rel = f[len(local) + 1:]
        out = subprocess.run(['git', '-C', fork, 'cat-file', '-p', '%s:%s/%s' % (anchor, upstream, rel)],
                             capture_output=True, text=True)
        # A vendored file whose upstream path does not resolve contributes NOTHING and is reported,
        # rather than counting as zero lines and reading as a smaller tree.
        if out.returncode != 0:
            print('UNRESOLVED\t%s' % f, file=sys.stderr)
            raise SystemExit(1)
        lines += out.stdout.count('\n')
print('%d\t%d' % (files, lines))
PY
)"
assert_true "every vendored file resolves at the anchor, so the total below is a measurement" \
  test -n "$VENDORED_TOTAL"
printf '%s\n' \
  "acvm_wasm	\`acvm_wasm.ts\` alone	$SIM_ONE" \
  "simclient	\`@aztec/simulator/client\`, the whole entry point	$SIM_ALL" \
  "oraclewire	the oracle WIRE layer, relative closure	$WIRE" \
  "total	vendored in total	$VENDORED_TOTAL" > "$WORK/vendored.tsv"
assert_eq "the vendoring table has four rows to compare" "4" "$(grep -c . "$WORK/vendored.tsv")"

DOC_OUT="$(python3 "$VERIFY_DIR/_m35_doc_figures.py" "$M35_DOC" "$BROWSER_DIST/chunks.json" \
  "$M35_ARMS" "$WORK/registry.tsv" "$WORK/vendored.tsv")"
DOC_CHECKED="$(printf '%s\n' "$DOC_OUT" | awk -F'\t' '$1=="CHECKED"{print $2}')"
assert_ge "the comparer checked a real number of figures rather than none" 20 "$DOC_CHECKED"
assert_eq "no subject line the comparer names has gone from the write-up" "" \
  "$(printf '%s\n' "$DOC_OUT" | awk -F'\t' '$1=="MISSING"{print $2}')"
assert_eq "every figure in the write-up equals what the artefacts measure" "" \
  "$(printf '%s\n' "$DOC_OUT" | awk -F'\t' '$1=="BAD"{print $2}')"

# THE PERTURBATION CONTROL, AND THE FIGURE IT PERTURBS IS NOT TYPED HERE.
#
# M34's review found this exact control with `**516**` hard-coded into it — a constant typed into a
# check over a figure the same check re-derives, so the day the artefact legitimately moves and the
# document is correctly updated, the needle stops matching and a green check turns into a `die`. The
# row is found by its SUBJECT and the replacement is what the ARTEFACT measured plus one, so the
# perturbed document is wrong whatever the row said.
PERTURB_SUBJECT="its solved witness"
PERTURBED="$WORK/perturbed.md"
python3 - "$M35_DOC" "$PERTURBED" "$PERTURB_SUBJECT" "$E_SOLVED_FOR_CONTROL" <<'PY'
import re, sys
doc, out, subject, measured = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(doc, encoding='utf-8').read().split('\n')
hits = [i for i, l in enumerate(lines) if subject in l]
if len(hits) != 1:
    raise SystemExit("the perturbation subject %r matches %d lines, not one" % (subject, len(hits)))
i = hits[0]
wrong = str(int(measured) + 1)
lines[i] = re.sub(r'(?<![\d.,])\d[\d,]*(?![\d.,])', wrong, lines[i], count=1)
open(out, 'w', encoding='utf-8').write('\n'.join(lines))
PY
assert_file "the perturbed copy was written" "$PERTURBED"
assert_false "and it is not the original" cmp -s "$M35_DOC" "$PERTURBED"
PERTURB_OUT="$(python3 "$VERIFY_DIR/_m35_doc_figures.py" "$PERTURBED" "$BROWSER_DIST/chunks.json" \
  "$M35_ARMS" "$WORK/registry.tsv" "$WORK/vendored.tsv")"
PERTURB_BAD="$(printf '%s\n' "$PERTURB_OUT" | awk -F'\t' '$1=="BAD"{print $2}')"
assert_true "the comparer REPORTS the perturbed figure" str_has_sub "$PERTURB_BAD" "executes-witness expected"
assert_true "…naming the row it found it on" str_has_sub "$PERTURB_BAD" "$PERTURB_SUBJECT"
assert_eq "…and it compared the same number of figures as over the real document" \
  "$DOC_CHECKED" "$(printf '%s\n' "$PERTURB_OUT" | awk -F'\t' '$1=="CHECKED"{print $2}')"

m35_finish
