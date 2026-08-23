#!/usr/bin/env bash
# verify_reuse_inventory_complete
#
# M1 verification: every Aztec component the runtime depends on has an inventory
# entry with a decision and a reason, and any entry marked "build" (or "replace")
# carries a SPECIFIC rejection reason for reuse rather than an assumption.
#
# The last clause is the one that matters. This project has been wrong four times
# about whether a component needed building, always in the same direction, so an
# inventory that merely EXISTS proves nothing. Asserted here, via
# verification/_inventory_parser.py:
#
#   * every entry has every key, and the decision is from a closed vocabulary;
#   * every `build` / `replace` entry's rejection-reason begins with one of three
#     admissible tags — does-not-exist:, does-not-cover:, cannot-reach-target: —
#     is long enough to name what was looked at, and contains no phrase that
#     asserts an absence without evidence ("we didn't find", "presumably", …);
#   * every `open` entry names the experiment that would settle it AND the
#     milestone where the verdict is due, so `open` cannot be used to dodge a
#     rejection reason;
#   * every component the plan names — the AVM, the world state, the contract DB,
#     the transaction simulator, the block processor, the side-effect trace, the
#     private-execution path, the msgpack IO schemas, the test harnesses — is
#     covered by at least one entry, through its `covers:` slug;
#   * every inventory id referenced from PROVENANCE.md resolves.
#
# And then five NEGATIVE CONTROLS. Each mutates a real entry in a scratch copy
# and requires the same code path to reject it. A checker that has never been
# seen to reject anything is not a checker.
#
# Run: just verify-reuse-inventory

TEST_NAME="verify_reuse_inventory_complete"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
PARSER="$VERIFY_DIR/_inventory_parser.py"
[ -f "$PARSER" ] || die "the inventory parser is missing at $PARSER"
[ -f "$REPO_ROOT/REUSE-INVENTORY.md" ] || die "REUSE-INVENTORY.md does not exist"
[ -f "$REPO_ROOT/PROVENANCE.md" ] || die "PROVENANCE.md does not exist"

# The components the milestone plan names explicitly. An inventory that does not
# cover one of these is incomplete by definition, whatever else it contains.
REQUIRED_SLUGS="avm world-state contract-db transaction-simulator block-processor side-effect-trace private-execution msgpack-io test-harnesses"

report="$(python3 "$PARSER" "$REPO_ROOT" "$REQUIRED_SLUGS")" \
  || die "the inventory parser failed to run"

entries="$(printf '%s\n' "$report"   | sed -n 's/^ENTRIES //p')"
subchecks="$(printf '%s\n' "$report" | sed -n 's/^CHECKS //p')"
covered="$(printf '%s\n' "$report"   | sed -n 's/^COVERED //p')"
decisions="$(printf '%s\n' "$report" | sed -n 's/^DECISIONS //p')"
problems="$(printf '%s\n' "$report"  | sed -n 's/^PROBLEM //p')"

note "decisions: $decisions"
note "components covered: $covered"

assert_ge "the inventory has a meaningful number of entries" 20 "$entries"
assert_ge "the parser made a meaningful number of sub-checks" 200 "$subchecks"

for slug in $REQUIRED_SLUGS; do
  assert_contains "the plan's named component '$slug' is covered by an entry" "$slug" "$covered"
done

# At least one entry must actually be `build` and at least one `replace` —
# otherwise the rejection-reason rules below are never exercised and the whole
# check passes without ever having judged a construction decision.
assert_contains "at least one entry decides to build" "build=" "$decisions"
assert_contains "at least one entry decides to replace" "replace=" "$decisions"

if [ -z "$problems" ]; then
  pass "every entry has a decision and a reason; every build/replace carries a specific rejection reason"
else
  while IFS= read -r p; do
    [ -n "$p" ] && fail "$p"
  done <<EOF
$problems
EOF
fi

# ---- negative controls -----------------------------------------------------
# Each mutates a scratch copy of the REAL inventory and requires a PROBLEM.
neg() { # <description> <sed-expression>
  local desc="$1" expr="$2" tmp out
  tmp="$(mktemp -d)"
  cp "$REPO_ROOT/REUSE-INVENTORY.md" "$REPO_ROOT/PROVENANCE.md" "$tmp/"
  sed -i "$expr" "$tmp/REUSE-INVENTORY.md"
  if cmp -s "$tmp/REUSE-INVENTORY.md" "$REPO_ROOT/REUSE-INVENTORY.md"; then
    fail "$desc — the mutation changed nothing, so the control is vacuous"
    rm -rf "$tmp"
    return
  fi
  out="$(python3 "$PARSER" "$tmp" "$REQUIRED_SLUGS" 2>&1)"
  if printf '%s' "$out" | grep -q '^PROBLEM '; then
    pass "$desc — rejected"
  else
    fail "$desc — ACCEPTED; the check is too weak"
  fi
  rm -rf "$tmp"
}

# 1. A build entry whose rejection reason is the phrase this milestone forbids.
neg "a 'build' entry reasoned as \"we didn't find one\"" \
    's|^- rejection-reason: does-not-exist:.*$|- rejection-reason: does-not-exist: we did not find one.|'
# 2. A build entry with no rejection reason at all.
neg "a 'build' entry with its rejection-reason deleted" \
    '/^- rejection-reason: does-not-exist:/d'
# 3. A rejection reason that is present, tagged, but says nothing.
neg "a tagged but contentless rejection reason" \
    's|^- rejection-reason: cannot-reach-target:.*$|- rejection-reason: cannot-reach-target: no.|'
# 4. An 'open' entry with no experiment — the way `open` could be used to dodge.
#
# The mutation is expressed over the STRUCTURE — the `- experiment:` line inside any block whose
# decision is `open` — and not over the text of one entry's experiment. It used to name `M13`,
# which was RI-07's; when M13 settled that entry the needle stopped matching, the mutation changed
# nothing, and the control reported ITSELF as vacuous rather than passing. That is the check
# working, and the fix is to stop tying a control to a sentence that is supposed to change.
neg "an 'open' entry with its experiment deleted" \
    '/^- decision: open$/,/^### RI-/{/^- experiment: /s|.*|- experiment: n/a|}'
# 5. A decision outside the vocabulary.
neg "a decision outside the closed vocabulary" \
    '0,/^- decision: depend$/s//- decision: probably-fine/'

finish
