#!/usr/bin/env bash
# verify_wallet_decisions_appear_in_trace
#
# M34 verification: "oracle calls and signing decisions are present in the container. Control: a run
# with a decision suppressed is missing exactly that record."
#
# ===========================================================================================
# THE PROPERTY IS ABOUT THE CONTAINER, NOT ABOUT THE WALLET'S REPORT
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md` records M29's review finding a check that read an opcode histogram out of the
# RECORDER rather than out of the container — *"a producer's report about itself is not its output;
# ask WHICH artefact"* — and reported 42 assertions, 1 failure over a container full of fabricated
# opcodes. M34's fifth deliverable is that the wallet's decisions are IN THE TRACE, so every
# assertion below reads them out of the `.ct` the BROWSER DOWNLOADED, through the PINNED `ct-print`,
# and the wallet's own `decisions()` array is used only as the other side of the comparison.
#
# ===========================================================================================
# THE CONTROL IS A SUPPRESSION AT THE WALLET, NOT AN EDIT TO THE CONTAINER
# ===========================================================================================
#
# "A run with a decision suppressed is missing exactly that record." Suppressing it at the WALLET —
# `suppressDecisions: ['authorized']` — means the missing record travels the same path the present
# ones do: the same ledger, the same `renderWalletDecision`, the same `extraLogEvents`, the same
# writer, the same download. An edit to the finished container would exercise none of that, and
# would be M32's review's finding — a control that runs beside the instrument instead of through it.
#
# And "EXACTLY that record" is asserted in both directions: the suppressed kind is gone, every other
# record is still there, and the two containers differ by precisely the suppressed rows.
#
# Run: just verify-m34-trace

TEST_NAME="verify_wallet_decisions_appear_in_trace"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"
. "$VERIFY_DIR/lib_m34_wallet.sh"

m34_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m34_require_arms
m24_require_readers

WORK="$M34_WORK/trace"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. the container the browser downloaded, read by the PINNED reader"

SUBJECT="$(m34_container record)"
CONTROL="$(m34_container suppressed)"
assert_false "the subject arm downloaded a container" str_has_sub "$SUBJECT" 'MISSING'
assert_false "the control arm downloaded one too" str_has_sub "$CONTROL" 'MISSING'
assert_true "…and the subject is on disk" test -s "$SUBJECT"
assert_true "…and so is the control" test -s "$CONTROL"
assert_false "…and they are two different files" test "$SUBJECT" = "$CONTROL"
assert_false "…with different contents" \
  test "$(m34_arm record.downloadedSha256)" = "$(m34_arm suppressed.downloadedSha256)"

ROWS="$(m34_log_events "$SUBJECT")"
CROWS="$(m34_log_events "$CONTROL")"
assert_false "the pinned ct-print read the subject container" str_has_sub "$ROWS" 'ERR:'
assert_false "…and the control container" str_has_sub "$CROWS" 'ERR:'
# NON-DEGENERACY BEFORE ANY COMPARISON. `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero":
# two empty row sets satisfy several of the comparisons below and say nothing.
assert_ge "the subject container carries log events at all" 10 \
  "$(printf '%s\n' "$ROWS" | grep -c . || true)"
assert_ge "…and so does the control" 10 "$(printf '%s\n' "$CROWS" | grep -c . || true)"

echo "== 2. THE SEED IS IN THE TRACE, which is what makes a recording replayable"

SEED_ROWS="$(m34_contents "$ROWS" 'ct.wallet-seed')"
WALLET_SEED="$(m34_arm record.report.seedRecord)"
ARM_SEED="$(m34_arm transfer.report.seed)"
m34_absent "record.report.seedRecord=$WALLET_SEED" "transfer.report.seed=$ARM_SEED"
assert_eq "exactly one seed record is in the container" "1" "$(m34_count_meta "$ROWS" 'ct.wallet-seed')"
assert_eq "…and it is the seed the wallet used, read out of the CONTAINER" "$WALLET_SEED" "$SEED_ROWS"
assert_true "…which names the seed the transfer arm reported" str_has_sub "$SEED_ROWS" "$ARM_SEED"
# THE OTHER METADATA KEYS ARE STILL THERE. M34 adds records; it must not displace M29's.
assert_eq "M29's step-producer record is still in the container" "1" \
  "$(m34_count_meta "$ROWS" 'ct.step-producer')"
assert_eq "…and M25's mapping-rung declaration" "1" "$(m34_count_meta "$ROWS" 'ct.mapping-rung')"

echo "== 3. EVERY DECISION THE WALLET MADE IS IN THE CONTAINER, in order"

DECISION_ROWS="$(m34_contents "$ROWS" 'ct.wallet-decision')"
N_IN_CONTAINER="$(printf '%s\n' "$DECISION_ROWS" | grep -c . || true)"
EXPECTED="$(m34_arm record.report.decisionRecords)"
m34_absent "record.report.decisionRecords=$EXPECTED"
N_EXPECTED="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$EXPECTED")"
assert_ge "the wallet made a real number of decisions" 10 "$N_EXPECTED"
assert_eq "every one of them is a trace record in the container" "$N_EXPECTED" "$N_IN_CONTAINER"

# ROW BY ROW AND IN ORDER, not as a count. M24's review's finding is that a total can be right while
# the rows say the opposite; the `seq=` prefix is what makes the order checkable.
printf '%s\n' "$DECISION_ROWS" > "$WORK/container_rows.txt"
printf '%s' "$EXPECTED" > "$WORK/expected_rows.json"
assert_eq "…each record byte for byte, in the wallet's own order" "MATCH" \
  "$(python3 - "$WORK/expected_rows.json" "$WORK/container_rows.txt" <<'PYD'
import json, sys
want = json.load(open(sys.argv[1]))
got = [l for l in open(sys.argv[2]).read().split('\n') if l]
if len(want) != len(got):
    print('COUNT %d != %d' % (len(want), len(got))); raise SystemExit
bad = ['#%d' % i for i, (a, b) in enumerate(zip(want, got)) if a != b]
print('MATCH' if not bad else 'DIFFER at ' + ' '.join(bad))
PYD
)"
assert_eq "…numbered from 0 with no gap, so no record was dropped in the middle" "SEQUENTIAL" \
  "$(python3 - "$WORK/container_rows.txt" <<'PYD'
import re, sys
seqs = [int(m.group(1)) for m in
        (re.match(r'seq=(\d+) ', l) for l in open(sys.argv[1]).read().split('\n') if l) if m]
print('SEQUENTIAL' if seqs and seqs == list(range(len(seqs))) else 'GAPS: %r' % seqs)
PYD
)"

echo "== 4. THE ORACLE CALLS AND THE SIGNING DECISION, BY NAME, out of the container"

# The deliverable names two classes and both are asserted separately, because "13 records exist" is
# satisfied by thirteen copies of one.
for method in requestCapabilities getAccounts getChainInfo registerSender getAddressBook \
              registerContractClass registerContract getContractMetadata getContractClassMetadata \
              sendTx; do
  assert_true "the container records the wallet call '$method'" \
    str_has_line_re "$DECISION_ROWS" "method=$method "
done
assert_true "…and the SIGNING DECISION: the wallet authorized the transaction" \
  str_has_sub "$DECISION_ROWS" 'decision=authorized'
assert_true "…naming which of its accounts it authorized for" \
  str_has_sub "$DECISION_ROWS" "from=$(m34_arm transfer.report.accounts.0.address)"
assert_true "…and the transaction hash it went on to submit" \
  str_has_sub "$DECISION_ROWS" "txHash=$(m34_arm transfer.report.send.sent.txHash)"

echo "== 5. THE CONTROL — one decision KIND suppressed at the wallet, and only that"

C_DECISIONS="$(m34_contents "$CROWS" 'ct.wallet-decision')"
N_CONTROL="$(printf '%s\n' "$C_DECISIONS" | grep -c . || true)"
assert_ge "the control container still carries decisions" 5 "$N_CONTROL"
assert_eq "…exactly one fewer than the subject's" "$((N_IN_CONTAINER - 1))" "$N_CONTROL"
assert_false "…and the suppressed kind is GONE from it" \
  str_has_sub "$C_DECISIONS" 'decision=authorized'
# THE OTHER DIRECTION, which is the half that makes it "exactly that record": the kinds that were
# NOT suppressed are still there, and the seed and the step producer survived too.
assert_true "…while the served decisions are still there" str_has_sub "$C_DECISIONS" 'decision=served'
assert_eq "…and the seed record survived the suppression" "1" \
  "$(m34_count_meta "$CROWS" 'ct.wallet-seed')"
assert_eq "…and so did M29's step-producer record" "1" \
  "$(m34_count_meta "$CROWS" 'ct.step-producer')"

# THE SET DIFFERENCE, COMPUTED. "One fewer" and "the right one fewer" are different statements, and
# only the second is what the deliverable asks for. Compared on the METHOD/DECISION pair rather than
# on the whole row, because the suppression shifts every later `seq=`.
printf '%s\n' "$C_DECISIONS" > "$WORK/control_rows.txt"
assert_eq "the two containers differ by EXACTLY the suppressed decisions and nothing else" "OK" \
  "$(python3 - "$WORK/container_rows.txt" "$WORK/control_rows.txt" <<'PYD'
import re, sys
def key(line):
    m = re.search(r'method=(\S+) decision=(\S+)', line)
    return (m.group(1), m.group(2)) if m else ('?', line)
a = [key(l) for l in open(sys.argv[1]).read().split('\n') if l]
b = [key(l) for l in open(sys.argv[2]).read().split('\n') if l]
removed = [k for k in a if k not in b or a.count(k) > b.count(k)]
added = [k for k in b if k not in a]
problems = []
if added:
    problems.append('ADDED %r' % sorted(set(added)))
kinds = {k[1] for k in removed}
if kinds != {'authorized'}:
    problems.append('REMOVED KINDS %r' % sorted(kinds))
if not removed:
    problems.append('NOTHING REMOVED')
print('OK' if not problems else '; '.join(problems))
PYD
)"

echo "== 6. THE CONTAINER IS STILL A CONTAINER, and the reader still reads all of it"

# M34 writes extra `TraceLogEvent`s. The container's OTHER properties must be untouched, or the
# fifth deliverable would have been bought with the fourth.
STEPS="$(m34_arm record.report.executedSteps)"
POS="$(m34_arm record.report.stepsPositioned)"
UNPOS="$(m34_arm record.report.stepsUnpositioned)"
m34_absent "record.report.executedSteps=$STEPS" "record.report.stepsPositioned=$POS" \
  "record.report.stepsUnpositioned=$UNPOS"
assert_eq "positioned + unpositioned = the executed step count" "$STEPS" "$((POS + UNPOS))"
assert_ge "…and the stream is not degenerate" 100 "$STEPS"
# READ BACK OUT OF THE CONTAINER, through the pinned reader, rather than out of the recorder's
# report about itself — M29's review's rule, applied to the number this milestone did not change.
CONTAINER_STEPS="$(python3 - "$M34_WORK/$(basename "$SUBJECT" .ct).ct-print.json" <<'PYD'
import json, sys
doc = json.load(open(sys.argv[1]))
print(sum(1 for e in doc.get('events', []) if e.get('type') == 'Step'))
PYD
)"
assert_eq "the reader finds that many Step records in the container" "$STEPS" "$CONTAINER_STEPS"

m34_finish
