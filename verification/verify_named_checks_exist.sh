#!/usr/bin/env bash
# verify_named_checks_exist — every check this repository NAMES in prose is a check that exists.
#
# WHY THIS IS A CHECK AND NOT A CONVENTION. M20's review found FIVE comments that named a
# verification check to reassure the reader that a property was pinned:
#
#   form_a.ts               `verify_form_a_error_classification`
#   form_a_e2e_driver.ts    `verify_form_a_arms_are_distinguishable`
#   tx_intake.ts            `test_phase_sources_match_upstream_helper`
#   shipped_module_config.ts `verify_form_a_encoding_delta_is_one_named_key`
#   fee_juice.ts            `test_fee_juice_slot_matches_cpp_derivation`
#
# None of the five existed. Two of the five properties were pinned somewhere else under another
# name; THREE WERE NOT PINNED AT ALL — including the milestone's third deliverable and D14's
# encoding-delta comparison, whose own module was built around the discipline the comment
# described. A comment that says "X pins this so it cannot regress" is worse than no comment,
# because it tells the next reader to stop looking. All five were found by reading, one at a time,
# which is exactly the way a sixth would be missed.
#
# So: every `verify_*` / `test_*` / `e2e_*` / `smoke_*` identifier mentioned anywhere in this repository's own
# sources must RESOLVE — to a check script, to a shell function, or to a `TEST_NAME`. It is a
# cheap, total rule over a class of claim this campaign has now got wrong five times.
#
# WHAT RESOLUTION MEANS, and each arm is here because something legitimate needs it:
#   * `verification/<name>.sh` exists                        — the ordinary case
#   * `<name>()` is defined in some `verification/*.sh`      — helpers named like checks
#   * `TEST_NAME="<name>"` appears in some check             — a check whose file is named
#                                                              differently from its TEST_NAME
#   * the name is in the DECLARED EXCEPTIONS below           — upstream identifiers that merely
#                                                              look like ours, each with a reason
#
# Names ending in `_` are family PREFIXES (`verify_vm2_tests_`, `test_node_`), not names, and are
# skipped — with an assertion that some are seen, so the skip is not silently skipping everything.
#
# THREE CONTROLS, because a resolver that resolved everything would pass over a repository full of
# dangling names: the scan must see a substantial number of names; a fabricated name planted in a
# probe file must be REPORTED; and a real name in the SAME probe file must NOT be, so the first
# control is not passing because the probe file is unreadable.
#
# Run: just verify-named-checks

TEST_NAME="verify_named_checks_exist"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"

# OUTSIDE the scanned roots on purpose: a probe under `verification/` would be seen by the
# MAIN scan as well as by the control scan, and the rule would then fail on its own control.
# `~/.cache`, never `$TMPDIR`: this campaign has met a quota-limited tmpfs where `df` reports
# gigabytes free and a write fails at 356 MiB. The probe is tiny, and the rule is the rule.
PROBE_ROOT="${HOME}/.cache/aztec-named-checks"
mkdir -p "$PROBE_ROOT" || die "could not create $PROBE_ROOT"
PROBE_DIR="$(mktemp -d "$PROBE_ROOT/probe.XXXXXX")" || die "no scratch under $PROBE_ROOT"
trap 'rm -rf "$PROBE_DIR"' EXIT INT TERM HUP
printf '// see verify_named_checks_exist for the rule, and\n// see verify_a_check_that_does_not_exist_at_all for the control\n' \
  > "$PROBE_DIR/probe.ts"

scan() { # <extra-dir-or-empty> -> prints "UNRESOLVED <name> <first-file>" lines then "SEEN <n>" and "PREFIXES <n>"
  python3 - "$REPO_ROOT" "${1:-}" <<'PY'
import os, re, sys

repo, extra = sys.argv[1], sys.argv[2]

# Upstream identifiers that merely look like one of ours. Each needs a reason, and the reason is
# the point: an exceptions list without one is an exemption list.
EXCEPTIONS = {
    "e2e_prover_test": "upstream's end-to-end/src/fixtures/e2e_prover_test.ts, cited by path",
    "test_context": "upstream's own identifier, quoted where its behaviour is described",
    "test_files": "a local shell variable in verify_fallback_cost_priced",
    "test_support": "a local shell variable in verify_fallback_cost_priced",
    "verify_line": "a local shell function in reproduce_aztec_bytecode_size_shift_32bit",
    "verify_reported": "a local shell function in reproduce_aztec_merkle_tree_lmdb_coupling",
    "verify_observer": "a local shell function in verify_execution_observer_patch_applies_to_upstream",
    # A RUST TEST FILE IN ANOTHER REPOSITORY, NAMED BY THE CHECK THAT RUNS IT. M38's seam is
    # established by running `noir`'s own `tooling/tracer/tests/test_foreign_call_executor.rs`
    # rather than by grepping for the new function's name, so
    # `verify_foreign_call_executor_is_injectable` names that FILE in the `cargo test --test`
    # argument it passes. It is not a check of this repository and cannot resolve to one; the four
    # tests INSIDE it are asserted present and passing, one at a time, by name.
    "test_foreign_call_executor": "noir's tooling/tracer/tests/test_foreign_call_executor.rs, run by verify_foreign_call_executor_is_injectable",
    # AN UPSTREAM CONTRACT'S OWN NOIR TEST, NAMED WHERE THE RULE IT ENFORCES IS OBEYED. M39 keeps
    # the ephemeral-array service PER FRAME while making six other stores the transaction's, and the
    # reason is that upstream constructs one per oracle and ships
    # `EphemeralParent.test_isolation` to say a child must not see its parent's slots. The comment in
    # `private_oracles.ts` names it because a reader deciding whether to "simplify" that asymmetry
    # needs to know something already tests it. It is a Noir function in `aztec-packages`, not a
    # check here, and it cannot resolve to one.
    "test_isolation": "aztec-packages' ephemeral_parent_contract test, cited by private_oracles.ts where its rule is obeyed",
    # AND ITS SIBLING, WHICH M38 DECLARED THE OTHER HALF OF AND NOT THIS ONE.
    # `verify_foreign_call_executor_is_injectable` names TWO Rust test files in `noir`:
    # `test_foreign_call_executor.rs`, excepted above, and `test_tracer.rs`, which was not. So that
    # check's one set-comparison assertion has carried an unresolved name of this repository's OWN
    # making since M38 landed, while M38's sweep attributed m20's single failure entirely to a
    # parallel track's `test_reverted_transaction_recorded_as_reverted`.
    #
    # **The attribution was right about that name and incomplete about the set**, and a set
    # comparison reports ONE failure however many members it has — so the count did not move and
    # nothing said the list was longer than the story. Found by M39 running the check after adding a
    # name of its own. *A check that names a set needs its whole set read, not its count.*
    "test_tracer": "noir's tooling/tracer/tests/test_tracer.rs, the twelve-fixture suite verify_foreign_call_executor_is_injectable asserts present and non-skipping",
    # HISTORICAL MENTIONS. Three of the five names this check exists because of are still
    # mentioned, by comments that record the correction. (The other two were repointed
    # outright and are NOT excepted — the dead-exception assertion below would fail if they
    # were, which is how that half of the list is kept honest.) Each surviving mention is
    # mentioned only by a comment that says, in the same breath, that it never existed and names
    # the check that does hold the property. Removing the mention would delete the record of the
    # defect; leaving it unexcepted would make this check red forever. Both are wrong, so they are
    # declared, with the file that is allowed to say them.
    "verify_form_a_arms_are_distinguishable": "historical: never existed; form_a_e2e_driver.ts now names the three things that do guard it",
    "verify_form_a_encoding_delta_is_one_named_key": "historical: never existed; the property is e2e_form_a_external_tx_roundtrip Part 8",
    # NAMED AS ABSENT, WHICH IS A DIFFERENT THING FROM NAMED AS EXISTING. M21's milestone entry
    # `test_form_b_tx_matches_pxe_bytes` is `pending`: it would compare this runtime's transaction
    # against one PXE itself produced, and PXE cannot be installed here (OQ-2). `form_b.ts` cites it
    # in the sentence that says it DOES NOT EXIST, because the determinism of the first nullifier is
    # for its benefit and a future reader has to know why the constant is there. This is exactly the
    # distinction M20's review had to make five times in the other direction — the defect is a
    # comment that says a check pins something when it does not, and a comment that says a check is
    # absent is the cure rather than the disease. It stops being an exception when the entry lands.
    "test_form_b_tx_matches_pxe_bytes": "M21's pending entry, cited by form_b.ts in the sentence that says it does not exist",
    # THE SAME DISTINCTION, ONE MILESTONE LATER. M25's entry
    # `test_trace_step_count_matches_instruction_count` is `pending` because the step stream in a
    # recording is the artifact's own first N MAPPED program counters and not the pcs an execution
    # visited. `browser/src/ct_download.ts` names it in the paragraph that says so, because a reader
    # who sees a container downloaded from a page that just executed a transaction will otherwise
    # read the step count as an instruction count. Naming a check as ABSENT is the cure for the
    # defect this file exists to catch, not an instance of it.
    "test_trace_step_count_matches_instruction_count": "M25's pending entry, cited by ct_download.ts AND by BROWSER-PACKAGING.md section 7, each in the paragraph that says the step count is not an instruction count -- the second site was attached to this one-file exemption without widening it, found by M27's review",
}

verification = os.path.join(repo, "verification")
resolved = set()
func = re.compile(r"^\s*((?:verify|test|e2e)_[a-z0-9_]+)\s*\(\)", re.M)
tname = re.compile(r'^TEST_NAME="([^"]+)"', re.M)
for entry in sorted(os.listdir(verification)):
    if not entry.endswith(".sh"):
        continue
    resolved.add(entry[:-3])
    text = open(os.path.join(verification, entry), encoding="utf-8", errors="replace").read()
    resolved.update(func.findall(text))
    resolved.update(tname.findall(text))

# THIS REPOSITORY'S OWN SOURCES. `diffsim/`, `drift/` and `spike/` are VENDORED upstream
# TypeScript plus M19's harness on top of it, whose vitest test names (`test_utils`,
# `verify_three_way_differential_runs`) follow a different convention entirely and are not this
# campaign's checks. Scanning them would make the rule about upstream's naming.
# `browser` — THE WHOLE PACKAGE, not `browser/src` and `browser/demo`, which is how M27 first
# added it. `browser/build.mjs`, `browser/esbuild-driver.mjs` and `browser/crypto_differential.mjs`
# sit directly under `browser/` and name four checks between them, and the two-subdirectory spelling
# left every one of them unpinned: rename a check and leave `build.mjs` naming the old spelling and
# nothing goes red, which is this file's own subject happening to this file. `dist` is excluded the
# way `node_modules` is, because it is build output. (`browser/chunk-budgets.json` also names a
# check and is still not scanned — `.json` is not in the extension list for any root.)
# `browser/src` and `browser/demo` were added by M27 for exactly the reason `ct-host/src` was
# added by M24: those files name checks in order to tell a reader that a property is pinned —
# `poseidon.ts` names the differential that says its hash agrees with bb.js, `entry_browser.ts`
# names the check that holds DD-5 over it — and that is precisely the claim this file exists to
# hold to account. Adding the root moves no assertion count; only the `SEEN` note.
# `ct-host/src` was added by M24 and the reason is the rule itself: `ct-host/src/config.ts` and
# `writer.ts` each name a check to tell the reader a property is pinned, which is EXACTLY the
# claim this file exists to hold to account. A new source directory that is not in this list is
# the PARALLEL-SUBDIRECTORY family (whose count `CAMPAIGN-BRIEF.md` states once), so the root is added
# in the same commit as the sources. It moves no assertion count — every assertion below is an
# `assert_ge` or an emptiness comparison — only the `SEEN` note.
roots = [os.path.join(repo, r) for r in
         ("orchestration/src", "node-host/src", "ct-host/src", "browser",
          "verification", "tools")]
if extra:
    roots.append(extra)

# This file names all five of the dangling names in its own header, which is the record of why it
# exists. It is excluded from the scan rather than excepted, because the exceptions above already
# carry those five with reasons and a file that documents a rule should not be its own subject.
SELF = "verification/verify_named_checks_exist.sh"

# `smoke` IS IN THIS LIST AND WAS NOT, AND THE OMISSION WAS A WHOLE NAMING CONVENTION.
# M27 and M28 added three checks named `smoke_*` — `smoke_browser_token_transfer`,
# `smoke_browser_produces_block_on_real_timer`, `smoke_browser_headless_full_flow` — and
# `browser/src/entry_testing.ts` and `browser/src/wasi.ts` cite two of them to tell a reader that a
# property is pinned, which is EXACTLY the claim this file exists to hold to account. None of the
# three was in scope. Measured by M28's review; `ci_browser_gate.sh` section 7 already used the
# four-family spelling, so M28's own document check saw a wider class than the repository-wide rule
# did. "An absence claim is only as wide as the spellings you enumerated", in the instrument.
NAME = re.compile(r"\b((?:verify|test|e2e|smoke)_[a-z0-9_]{4,}_?)\b")
seen, prefixes, unresolved = set(), set(), {}
for base in roots:
    if not os.path.isdir(base):
        continue
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", "dist")]
        for fn in filenames:
            if not fn.endswith((".ts", ".sh", ".mjs", ".js", ".py", ".md")):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, repo)
            if rel == SELF:
                continue
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in NAME.finditer(text):
                name = m.group(1)
                if name.endswith("_"):
                    prefixes.add(name)
                    continue
                seen.add(name)
                if name in resolved or name in EXCEPTIONS:
                    continue
                unresolved.setdefault(name, rel)

for name in sorted(unresolved):
    print("UNRESOLVED %s %s" % (name, unresolved[name]))
# A declared exception that nothing mentions any more is a dead exemption, and an exemption list
# that only grows is how a rule stops being one.
for name in sorted(EXCEPTIONS):
    if name not in seen:
        print("DEAD-EXCEPTION %s %s" % (name, EXCEPTIONS[name]))
print("SEEN %d" % len(seen))
print("PREFIXES %d" % len(prefixes))
print("EXCEPTIONS %d" % len(EXCEPTIONS))
PY
}

REPORT="$(scan)" || die "the scan failed"
SEEN="$(printf '%s\n' "$REPORT" | sed -n 's/^SEEN //p')"
PREFIXES="$(printf '%s\n' "$REPORT" | sed -n 's/^PREFIXES //p')"
UNRESOLVED="$(printf '%s\n' "$REPORT" | grep '^UNRESOLVED ' || true)"
note "check-shaped names seen: $SEEN, family prefixes skipped: $PREFIXES"
printf '%s\n' "$UNRESOLVED" | grep . | sed 's/^/      /' || true

# The scan is not vacuous: this repository names a lot of its own checks.
assert_ge "the scan sees a substantial number of check-shaped names" 100 "$SEEN"
assert_ge "and it does skip some family prefixes, so that arm is exercised rather than dead" 4 \
  "$PREFIXES"

# THE RULE.
assert_eq "every check this repository names in its own sources exists" "" "$UNRESOLVED"

# The exceptions list cannot rot: every declared exception must still be mentioned somewhere, or
# it is an exemption for nothing and the next one gets added on top of it.
assert_eq "no declared exception has gone dead" "" \
  "$(printf '%s\n' "$REPORT" | grep '^DEAD-EXCEPTION ' || true)"
assert_ge "and the exceptions list is declared rather than empty" 5 \
  "$(printf '%s\n' "$REPORT" | sed -n 's/^EXCEPTIONS //p')"

# CONTROL 1 — a fabricated name planted in a probe file IS reported.
PROBE_REPORT="$(scan "$PROBE_DIR")" || die "the probe scan failed"
assert_ge "a fabricated check name in a probe file IS reported as unresolved" 1 \
  "$(printf '%s\n' "$PROBE_REPORT" | grep -c '^UNRESOLVED verify_a_check_that_does_not_exist_at_all ' || true)"

# CONTROL 2 — a REAL name in the SAME probe file is NOT reported, so control 1 is not passing
# because the probe directory is unreadable or because the resolver rejects everything.
assert_eq "while a real check name in the same file is not" "0" \
  "$(printf '%s\n' "$PROBE_REPORT" | grep -c '^UNRESOLVED verify_named_checks_exist ' || true)"
assert_ge "and the probe file really was read, so both controls are about the same scan" 1 \
  "$(printf '%s\n' "$PROBE_REPORT" | grep -c 'probe.ts' || true)"

rm -rf "$PROBE_DIR"
assert_eq "the probe directory was removed" "0" \
  "$([ -e "$PROBE_DIR" ] && echo 1 || echo 0)"

finish
