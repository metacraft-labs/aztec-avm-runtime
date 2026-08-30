#!/usr/bin/env python3
"""Summarise a campaign sweep log — and REFUSE to print a total while a hole is open.

    scratchpad/campaign/m35-sweep-sum.py <sweep.log> [reference.json]

Why this exists, and why it refuses rather than warns. M22's sweep lost two regions of its own
log when `/tmp` filled, and the campaign TOTAL survived both holes while the per-milestone
attribution was destroyed — M2 read 475 (its own 178 plus all of M17's 297) and M17 read 0. A
summariser that prints a plausible total over a log with a gap in it is worse than one that
crashes, which is what M21's did.

Two rules from the standing brief, both of which have been got wrong before:

  * A SUMMARY LINE IS AT COLUMN 0 and ends `assertion(s), N failure(s)`. A NOTE is indented and
    may quote a sub-tool's internal count — `  --   repin: 175 assertion(s), 0 problem(s)` is why
    M1 was once reported as 316 when it is 141.
  * The check NAME may contain a space: `just check-repo-hygiene: 28 assertion(s), 0 failure(s)`
    is a real line, and an `^([A-Za-z_0-9]+):` needle silently DROPS it, which is how m0 once
    came out 128 against a reference of 156.
"""

import json
import re
import sys

SUMMARY = re.compile(
    r"^([A-Za-z_0-9][A-Za-z_0-9 .-]*): (\d+) assertion\(s\), (\d+) failure\(s\)$"
)
START = re.compile(r"^######## (m\d+)\s+\S")
END = re.compile(r"^######## (m\d+) rc=(-?\d+) secs=(\d+)$")

REFERENCE = {
    "m0": 156, "m1": 175, "m2": 292, "m3": 199, "m4": 218, "m5": 236, "m6": 363,
    "m7": 287, "m8": 516, "m9": 807, "m10": 450, "m11": 259, "m12": 691, "m13": 458,
    "m14": 460, "m15": 537, "m16": 223, "m17": 297, "m18": 283, "m19": 180, "m20": 237,
    "m22": 260, "m23": 509, "m24": 350, "m25": 272, "m26": 313,
    "m21": 325, "m27": 345, "m28": 353, "m29": 127, "m30": 218,
    # M31 moves M11 by three and nothing else. `verify_carry_set_complete` derives every `aztec-*`
    # directory under codetracer-specs/upstream-bugs/ and requires each to be in the carry set or
    # DECLARED not-carried with a reason; M31 adds a sixth directory and declares it, and the check
    # makes exactly three assertions per declared entry. 259 -> 262. M11 is also RED for the ninth
    # upstream move, which is a different fact about the same milestone.
    "m31": 421,
    # M32 adds four checks of its own and moves NO other milestone's count. It vendors nothing
    # (`verify_provenance_complete` stays 64), declares no pin (`verify_pinned_nightly_single_source`
    # 28), adds no `| grep -q` predicate (`verify_no_pipeline_predicates` 69), and its four
    # REUSE-INVENTORY entries add no assertion (the entry-count check is `>= 20`, so it stays 19).
    # What it DOES move is three document FIGURES that checks re-derive — BROWSER-PACKAGING.md's
    # eager table and request accounting, and BROWSER-GATE.md's input count — and those were
    # corrected before this sweep, with M27 re-measured at 345 and M28 at 353.
    #
    # 229 AS DELIVERED; M32'S REVIEW TOOK IT TO 234, in one check and nothing else.
    # `smoke_worker_chain_survives_main_thread_block` 77 -> 82, and both halves are +3:
    #   * §2's operation-list residue was asked of the WHOLE document rather than of the list, so
    #     deleting an operation from §2 left it empty (§4 names the operation in prose). Scoped to
    #     the bullet, it gains the region's own SIZE and the other direction — a name the document
    #     lists that the bundle does not declare. One assertion replaced by three.
    #   * The busy window's block COUNT cannot tell production during the spin from a backlog
    #     draining at the window's edge. The SPACING can, measured from the window's own opening;
    #     a doctored report that keeps the count and moves all sixteen blocks into the last 200 ms
    #     gives a largest interval of 3,812 ms against 252, and fails two assertions.
    # The `detached` fix is a correction to `entry_worker.ts` and adds no assertion.
    # M34's REVIEW takes M32 234 -> 237. `test_worker_transferable_container_not_copied` 71 -> 74:
    # its §10 re-derives WORKER-NODE.md §5's packaging table for a TYPED LIST of six entries, and
    # M34 added a `wallet-demo.js` ROW without adding `wallet-demo.js` to that list — so the row was
    # re-derived by nothing and had already rotted (309.51 against a build reporting 309.91). Three
    # assertions per entry: the row exists, its size and file count together, and in the AFTER
    # column.
    "m32": 237,
    # M33 adds four checks of its own and moves EXACTLY ONE other milestone's count — M1's, by
    # four, DECLARED BEFORE THE SWEEP RAN. It VENDORS three files, so `verify_provenance_complete`
    # goes 64 -> 68: M22's mechanism exactly, one `is tracked` assertion per new single-file row
    # (three) plus one for RI-88, an inventory id no row had cited before. 3 + 1 = 4, exact in both
    # parts. Nothing else moves: `verify_pinned_nightly_single_source` stays 28 (M33 declares no
    # pin; `@aztec/aztec.js` is added at the `deletion_era` pin the file already names),
    # `verify_no_pipeline_predicates` stays 69, `just check-drift` stays 22 (three new `none` rows
    # add no assertion to it), `verify_named_checks_exist` stays 9, `just check-repo-hygiene` stays
    # 28, and the four new REUSE-INVENTORY entries add none because the entry-count check is
    # `>= 20`.
    #
    # M27 and M28 must come out at 345 and 353. M33 moves BROWSER-PACKAGING.md §1's eager table and
    # total and §6's request accounting, and WORKER-NODE.md §5's entry-point table — every one of
    # them a figure a check re-derives from the artefact on every run, all corrected before this
    # sweep and re-measured.
    #
    # M33's own 245 is 33 / 105 / 40 / 67 AFTER ITS REVIEW; it was DECLARED at 224 (33 / 84 / 40 /
    # 67) and the 21 are all in `verify_provider_half_dd9_clean`, in two places and nothing else:
    #   * +14 for §10, which LOADS the built wallet.js in a real page. M33 asserted the browser half
    #     on the esbuild METAFILE, and a metafile records IMPORTS while a free identifier is not one:
    #     with `const _nodeOnlyProbe = setImmediate;` planted (not Buffer, not process, so no shim
    #     supplies it and no free-identifier scan names it), `just verify-m33` was 224 / 4-of-4 /
    #     exit 0, verify_browser_bundle_no_node_builtins 64/0 and smoke_browser_headless_full_flow
    #     50/0, over a bundle that died in Chromium with `ReferenceError: setImmediate is not
    #     defined`. Nothing anywhere loaded wallet.js in a page. The control is that plant, kept as a
    #     second served site the same probe must report as a ReferenceError.
    #   * +7 for §8's census of the spellings the closure walker CANNOT follow — zero dynamic
    #     `import()` and zero `require()` in the provider half, with the wallet half's three and the
    #     scanner's own fixture as two controls that the zero is a reading rather than a scanner that
    #     stopped matching.
    # The review's other two fixes add NO assertion: the document comparer's needle is delimited
    # rather than a bare substring (two of its nineteen figures could not fail), and it now covers
    # the two pxe counts as well — 21 figures against 19, under the same three assertions.
    #
    # The 224 it was declared at: the fourth check went
    # 63 -> 67 during the self-review pass, when `assert_ge "the handshake completed inside a sane
    # wall-clock window" 0 "$ELAPSED"` was found to be the campaign's purest family — a wall-clock
    # duration is never negative, so the assertion could not fail. One removed, five added, on the
    # three declared handshake BOUNDS read out of the built bundle (each positive, key exchange the
    # shortest, discovery the longest), which is what "every wait is bounded" can actually assert.
    "m1": 179,
    # M33 245 -> 246, and the +1 is ONE assertion in `verify_provider_half_dd9_clean`.
    #
    # Its `cpp_` byte scan was asked of `wallet.js` ALONE. M34 adds an EIGHTH entry point to the
    # same esbuild pass, which shares the wallet's modules, so esbuild hoisted the protocol and the
    # provider into a shared chunk and `wallet.js` became a 0.67 KB re-export stub — and the scan's
    # PAIRED positive-control needle (`aztec-wallet-`) went red, which is exactly what a paired
    # needle is for and is the only reason this was noticed. The scan is over the whole EAGER SET
    # now, which is also the question DD-11 means, with one non-emptiness assertion beside it
    # ("the eager set was read as bytes, and it is a real bundle"). 105 -> 106, 245 -> 246.
    "m33": 246,
    # M34's own 210 is 83 / 49 / 33 / 45 across `e2e_wallet_public_transfer`,
    # `test_wallet_keys_deterministic`, `test_deployment_through_wallet` and
    # `verify_wallet_decisions_appear_in_trace`.
    #
    # It moves M33 by one (above) and NOTHING ELSE. It vendors nothing, so
    # `verify_provenance_complete` stays 68; it declares no pin, so
    # `verify_pinned_nightly_single_source` stays 28; it adds no `| grep -q` predicate, so
    # `verify_no_pipeline_predicates` stays 69; `just check-drift` stays 22 (no vendored file
    # changes); `verify_named_checks_exist` stays 9; `just check-repo-hygiene` stays 28; and its
    # three REUSE-INVENTORY entries add none, because the entry-count check is `>= 20`.
    #
    # M27 and M28 must come out at 345 and 353, and M32 at 234. M34 moves SIX document figures —
    # BROWSER-PACKAGING.md §1's four eager rows and its total, BROWSER-GATE.md's browser input count
    # (1135 -> 1138, the wallet demo page's three modules), WORKER-NODE.md §5's six-row table, and
    # WALLET-BOUNDARY.md §6's four wallet figures — every one of them a figure a check re-derives
    # from the artefact on every run, all corrected before this sweep and re-measured.
    #
    # M28's ONE failing assertion is L0's and is not M34's to fix:
    # `verify_npm_pack_no_optional_native` pins the tracked `package.json` list EXACTLY and
    # `replay/package.json` is a fifth tree. The COUNT is unchanged at 353, which is what says it is
    # a pinned list rather than a structure.
    # M34's REVIEW takes its own 210 -> 217, in two checks and nothing else:
    #   * test_wallet_keys_deterministic 49 -> 50. The collision detector's control was a SECOND
    #     script computing `ups[0] in set(ups)` — a tautology over a list already asserted
    #     non-empty. One function serves the subject and the control now, and the control asserts
    #     the planted value is a substitution rather than one of the dev separators (+1).
    #   * test_deployment_through_wallet 33 -> 39. The milestone's headline identity — the wallet
    #     route and the direct path execute the same program to the step — was prose. The shortcut
    #     arm reports its own executedSteps/contexts now and §5b asserts it: the absent-field guard,
    #     a >= 100 floor, the step identity, the context identity, the declining arm's 0 as the
    #     control, and the §5 comparator control re-taken over two values of the same kind (+6).
    # e2e_wallet_public_transfer stays 83 and verify_wallet_decisions_appear_in_trace stays 45.
    "m34": 217,
    # M35 adds three checks of its own and moves EXACTLY TWO other milestones' counts, both
    # DECLARED HERE BEFORE THE SWEEP RAN.
    #
    # M28 353 -> 357, in two checks and nothing else:
    #   * `verify_browser_bundle_no_node_builtins` 64 -> 67. Its §4 asserted "exactly ONE non-inject
    #     external edge is recorded", and M35's fifty vendored files add SIX elided `import type`
    #     edges — `./oracle_registry.js`, `@aztec/foundation/curves/bn254`, `/trees`,
    #     `@aztec/stdlib/avm`, `/aztec-address`, `/kernel`. A count would have to be bumped and would
    #     say nothing, so it is a named SET now: -2 (the count and its single name) +5 (the set, a
    #     non-emptiness floor, the Reactor still in it, no elided specifier surviving into the
    #     emitted bytes, and a non-emptiness assertion on those bytes). The alias for
    #     `@aztec/simulator/client` was moved OUT of the build's `SHIMS` table into a separate
    #     `PACKAGE_ALIASES` one for this check's sake: `SHIMS` is the NODE BUILTIN census and a fifth
    #     entry there is a claim that this graph reaches a fifth builtin.
    #   * `verify_browser_bundle_no_native_deps` 44 -> 45: the same external set, compared as a set,
    #     plus one DD-9 membership test over it.
    # `just ci-browser-gate` stays 104, `verify_npm_pack_no_optional_native` stays 54 with the ONE
    # failing assertion that is L0's (`replay/package.json` is a fifth tree),
    # `verify_verification_code_unreachable_from_browser` 37 and `smoke_browser_headless_full_flow`
    # 50.
    #
    # M33 246 -> 248, both in `verify_provider_half_dd9_clean` §7: the orchestration's dependency pin
    # moved to SIX (`@aztec/noir-acvm_js`, RI-64's single priced install) and the reason it is
    # admissible is re-derived OFFLINE from `orchestration/package-lock.json` — the ACVM's declared
    # dependency list is EMPTY — with `@aztec/aztec.js`'s non-empty one as the control that the
    # reader can answer both ways. Two assertions. (Its control BUILD was also failing outright,
    # because that CLI invocation had none of M35's four new resolutions; fixing it adds no
    # assertion and restores five.)
    #
    # `check-drift` 22 -> 24: two new tree rows (V10, V11), one `tracked file count` assertion each.
    # It is read inside M1's `verify_vendor_drift_clean`, which does not change M1's total.
    # `verify_provenance_complete` 68 -> 70: tree rows add no per-file assertion, and the +2 is one
    # per inventory id no row had cited before — RI-64 and RI-97. So M1 179 -> 181.
    #
    # Nothing else: `verify_pinned_nightly_single_source` 28 (the ACVM goes in at the `deletion_era`
    # pin this file already names), `verify_no_pipeline_predicates` 69, `verify_named_checks_exist`
    # 9, `verify_reuse_inventory_complete` 19 (the entry count is `>= 20`), `check-repo-hygiene` 28.
    # M27 must come out at 345, M32 at 237 and M34 at 217, with twelve document figures in five
    # documents corrected before this sweep and every one of them re-measured.
    #
    # M35's own 198 is 64 / 83 / 51 across `verify_oracle_coverage_is_measured`,
    # `test_unimplemented_oracle_refuses_by_name` and `e2e_private_function_executes_in_browser`.
    #
    # M35'S REVIEW TAKES IT 198 -> 212, in two checks and nothing else. Both numbers were declared in
    # the milestone section and in the review's own commit message BEFORE its sweep was launched; this
    # table is brought in step with them.
    #   * `test_unimplemented_oracle_refuses_by_name` 83 -> 95. A new §5b, twelve assertions, for the
    #     milestone's strongest sentence: `Token.transfer`, `Token.mint_to_private` and
    #     `PrivateVoting.cast_vote` all stop at `aztec_utl_getContractInstance`. That is written in the
    #     refusal reason, in `PRIVATE-EXECUTION.md` §3 and in the goal section, and only `transfer` was
    #     ever EXECUTED by a check — two thirds of the claim was a spike measurement re-derived by
    #     nothing. Re-taken by the review it is true to the byte, and it is a per-run measurement now:
    #     the arm runs all three and the SET of stops is asserted to be a singleton, with the
    #     non-degeneracies that say it is three programs (two contracts, three distinct bytecodes) and
    #     not one run three times. Matrix arm M10 shows those assertions can fail — M1 leaves the
    #     ledger's `refused` record in place, so the frames still report a refusal and §5b cannot see
    #     it.
    #   * `e2e_private_function_executes_in_browser` 51 -> 53. §3 compared the circuit's echoed
    #     `contractAddress` against `0x0…777` TYPED INTO THE CHECK; the arm reports the address it
    #     REQUESTED now and the two are compared, with a non-degeneracy that the request is not zero.
    #     Two producers out of one run, which is what the `returnsHash` assertion beside it already
    #     does.
    # `verify_oracle_coverage_is_measured` stays 64; its document comparer covers 35 figures against
    # 34, under the same three assertions. The build moved ONE figure — `wallet-demo.js`'s eager set
    # 332.68 -> 332.94 KB and the all-chunk total 8,219.06 -> 8,219.32 — corrected in the four places
    # that carry it before this sweep, with M27 345, M32 237, M33 248 and M34 217 re-measured.
    "m35": 212,
}
REFERENCE["m11"] = 262
REFERENCE["m28"] = 357
REFERENCE["m33"] = 248

# M36's declared moves, named BEFORE the sweep ran and measured individually first — which is what
# makes `delta +0` a prediction that held rather than a total that agreed with itself.
#
#   m1  181 -> 182   `verify_provenance_complete` 70 -> 71: one inventory id (RI-98) no PROVENANCE
#                    row had cited. M36's doing.
#   m35 212 -> 239   `test_unimplemented_oracle_refuses_by_name` 95 -> 109 -> 122. **NOT M36's**: two
#                    parallel `m35:` commits landed tier 2's first and second rungs on `origin/dev`
#                    while this milestone was being written, and M36 rebased onto both.
#   m36 —   -> 137   74 / 29 / 34.
#   m2  292 -> 293   `verify_fixture_corpus_manifest_complete` 37 -> 38. M36's doing, and it is a
#                    defect rather than a growth: that check planted `RI-99` as "an inventory id that
#                    does not exist" and M36 CREATED RI-99, so the negative control silently stopped
#                    controlling. The id is derived now (one past the highest), which found a second
#                    defect underneath it — `_manifest_parser.py` matched an id as `RI-\d{2}`, so
#                    `RI-100` was read as `RI-10` and a manifest citing a non-existent three-digit id
#                    validated cleanly. Both fixed; the +1 is the derived id's own non-emptiness
#                    assertion.
REFERENCE["m2"] = 293
REFERENCE["m1"] = 182

# M37's declared move, and it is ONE assertion.
#
#   m1  182 -> 181   `verify_provenance_complete` 71 -> 70. M37 retires the added row F24
#                    (`orchestration/src/vendor/gas_compat.ts`) with its file, and this check makes
#                    exactly one `is tracked` assertion per single-file row. Nothing else in M1
#                    moves: `just check-drift` stays 25 (thirteen rows change ANCHOR, which adds and
#                    removes no assertion), `verify_pinned_nightly_single_source` stays 28 (no pin
#                    VALUE moved), and F24's inventory id RI-72 is still cited by F20..F23 so the
#                    inventory loop is unchanged.
#   m22 260 -> 265   `verify_public_processor_vendored_not_reimplemented` 71 -> 76, all five in the
#                    RI-65 worktree block. It used to end in one pass/fail over an empty residue,
#                    asserting that `upstream/tsavm` and the vendoring anchor were the same bytes —
#                    which measured nothing, because until M37 they WERE. They have come apart, so
#                    that one assertion becomes six: the divergence count (4), the agreement count
#                    (6), and the four diverging paths NAMED.
#
# MEASURED ON THIS HOST, BOTH DIRECTIONS. m1 was re-run with the four documents and the vendored
# directory checked out at the parent commit and came back 180, not 182 — so the -1 is M37's and
# the remaining -2 is this host's, not this milestone's. Every reference below was taken on the
# campaign's Linux host and several of these checks are host-sensitive; see the M37 note in the
# milestone file.
REFERENCE_M37_M1_ON_THIS_HOST_BEFORE = 180
REFERENCE_M37_M1_ON_THIS_HOST_AFTER = 179
REFERENCE["m35"] = 239
REFERENCE["m36"] = 137


def main() -> int:
    path = sys.argv[1]
    ref = REFERENCE
    if len(sys.argv) > 2:
        ref = json.load(open(sys.argv[2], encoding="utf-8"))

    order, per, checks, rcs, secs = [], {}, {}, {}, {}
    holes, current, done = [], None, False

    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        # THE END MARKER IS TESTED FIRST, and that is not cosmetic: `######## m0 rc=0 secs=12`
        # also satisfies the START pattern (`m\d+` followed by whitespace and a non-space), so a
        # start-first reader opens a second m0, never closes either, and reports the whole sweep
        # as one long hole. Caught on this summariser's first run against a live log.
        m = END.match(line)
        if m:
            name, rc, s = m.group(1), int(m.group(2)), int(m.group(3))
            if current != name:
                holes.append(f"rc= marker for {name} while {current} was open")
            rcs[name] = rc
            secs[name] = s
            current = None
            continue
        m = START.match(line)
        if m:
            if current is not None:
                holes.append(f"{current} started and never reported an rc= marker")
            current = m.group(1)
            order.append(current)
            per[current] = 0
            checks[current] = []
            continue
        # THE COMPLETION MARKER THIS SUMMARISER LOOKED FOR WAS NEVER PRINTED BY ANYTHING.
        #
        # `m25-sweep.sh` ends with `printf 'SWEEPDONE\n'`, at column 0 and with no `########`
        # prefix; this line tested for `"######## SWEEP DONE"`, with a prefix and a space. So `done`
        # could never become True, the "no 'SWEEP DONE' marker" hole was ALWAYS open, and the
        # summariser REFUSED TO PRINT A TOTAL FOR EVERY RUN INCLUDING A PERFECT ONE. Found by M25's
        # review on a real log.
        #
        # It fails safe — it never printed a wrong total — which is exactly why it could survive:
        # the failure mode of a refusing instrument is indistinguishable from the thing it refuses
        # over, and the operator reads "there is a hole" rather than "I cannot see holes". An
        # instrument whose only output is a refusal is not obviously broken, and this one had a
        # 100% false-refusal rate.
        #
        # Both spellings are accepted, anchored at column 0 so a check's own output cannot forge one.
        if line.startswith("SWEEPDONE") or line.startswith("######## SWEEP DONE"):
            done = True
            continue
        m = SUMMARY.match(line)
        if m:
            if current is None:
                holes.append(f"a summary line outside any milestone: {line!r}")
                continue
            per[current] += int(m.group(2))
            checks[current].append((m.group(1), int(m.group(2)), int(m.group(3))))

    if current is not None:
        holes.append(f"{current} is still open at end of log (the sweep did not finish)")
    if not done:
        holes.append("no 'SWEEP DONE' marker")

    width = max((len(k) for k in order), default=3)
    for name in order:
        got = per[name]
        want = ref.get(name)
        rc = rcs.get(name, "MISSING")
        fails = sum(f for _, _, f in checks[name])
        flag = ""
        if want is None:
            flag = "  (no reference)"
        elif got != want:
            flag = f"  <-- MOVED, reference {want} ({got - want:+d})"
        print(f"{name:<{width}}  {got:>5}  rc={rc}  {secs.get(name, '?'):>5}s  "
              f"failures={fails}{flag}")
        if want is not None and got != want:
            for cname, ca, cf in checks[name]:
                print(f"        {cname}: {ca} assertion(s), {cf} failure(s)")

    total_failures = sum(f for name in order for _, _, f in checks[name])
    bad_rc = [n for n in order if rcs.get(n, 1) != 0]

    print()
    if holes:
        print("HOLES IN THE LOG — NO TOTAL IS PRINTED:")
        for h in holes:
            print(f"  * {h}")
        return 2

    print(f"TOTAL {sum(per.values())}   milestones {len(order)}   "
          f"failing assertions {total_failures}   non-zero exits {bad_rc or 'none'}")
    ref_total = sum(ref[n] for n in order if n in ref)
    print(f"reference total over the same milestones: {ref_total}  "
          f"(delta {sum(per.values()) - ref_total:+d})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
