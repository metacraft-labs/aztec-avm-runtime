#!/usr/bin/env bash
# e2e_wallet_public_transfer
#
# M34 verification: "`transfer_in_public` from wallet handshake to settled block to `.ct`. Control:
# a wallet refusing to sign produces a named failure, not a silent no-op."
#
# ===========================================================================================
# WHAT MAKES THIS DIFFERENT FROM M27'S SMOKE TEST, IN ONE SENTENCE
# ===========================================================================================
#
# M27 executes a token transfer in a page. This one executes it **through a wallet**: every
# registration, every query and the transaction itself cross an AES-256-GCM session as
# `SECURE_MESSAGE`s over M33's protocol, and the transaction is BUILT by the object on the far side.
# The runtime does not reach around the seam at any point, and the check reads which methods the
# wallet was asked for out of the wallet's own ledger rather than out of the caller's intentions.
#
# ===========================================================================================
# IT RUNS IN CHROMIUM, AND THAT IS THE MILESTONE'S OWN INSTRUCTION
# ===========================================================================================
#
# M33 shipped with its browser half asserted on the esbuild METAFILE. Its review measured how much
# weaker that is by planting `const _nodeOnlyProbe = setImmediate;` — a free identifier is not an
# import, and a metafile records only imports — and got 224 assertions, 4/4, exit 0 over a bundle
# that died on the first line a page evaluated. M34's wallet must be **loaded and exercised** in a
# browser, so every arm this check reads was measured in one.
#
# Run: just verify-m34-transfer

TEST_NAME="e2e_wallet_public_transfer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"
. "$VERIFY_DIR/lib_m34_wallet.sh"

m34_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m34_require_arms

WORK="$M34_WORK/e2e"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. the arm ran in a real browser, and the page is a page"

CHROMIUM="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("chromium") or "MISSING")' "$M34_ARMS")"
assert_false "the arms record which Chromium ran them" str_has_sub "$CHROMIUM" 'MISSING'
note "measured in $CHROMIUM"

PAGE_ERRORS="$(m34_arm transfer.pageErrors)"
CONSOLE_ERRORS="$(m34_arm transfer.consoleErrors)"
AVM_REQ="$(m34_arm transfer.avmWasmRequests)"
BB_REQ="$(m34_arm transfer.barretenbergRequests)"
m34_absent "transfer.pageErrors=$PAGE_ERRORS" "transfer.consoleErrors=$CONSOLE_ERRORS" \
  "transfer.avmWasmRequests=$AVM_REQ" "transfer.barretenbergRequests=$BB_REQ"

assert_eq "the wallet page evaluated without a page-level exception" "[]" "$PAGE_ERRORS"
assert_eq "…and without a console error" "[]" "$CONSOLE_ERRORS"
# THE INSTRUMENT IS SHOWN TO SEE SOMETHING BEFORE ITS ABSENCE IS BELIEVED. `avm.wasm` is present in
# the same log the barretenberg absence is measured over, which is the remedy `CAMPAIGN-BRIEF.md`
# records for "an absence asked of a tree that excludes its subject by construction".
assert_eq "…and it fetched avm.wasm, so the network log is a log of this page" \
  '["/assets/avm.wasm"]' "$AVM_REQ"
assert_eq "…and NOT the proving stack: deriving the wallet's keys reached the module's grumpkin" \
  "[]" "$BB_REQ"

echo "== 2. the handshake happened, over M33's protocol, unchanged"

WALLET_ID="$(m34_arm transfer.report.walletId)"
VHASH="$(m34_arm transfer.report.verificationHash)"
DISCLOSED="$(m34_arm transfer.report.walletSideDisclosure)"
HANDLER_REFUSALS="$(m34_arm transfer.report.handlerRefusals)"
PROVIDER_REFUSALS="$(m34_arm transfer.report.providerRefusals)"
m34_absent "transfer.report.walletId=$WALLET_ID" "transfer.report.verificationHash=$VHASH" \
  "transfer.report.walletSideDisclosure=$DISCLOSED" \
  "transfer.report.handlerRefusals=$HANDLER_REFUSALS" \
  "transfer.report.providerRefusals=$PROVIDER_REFUSALS"

assert_eq "discovery returned the dev wallet's id" "codetracer-dev-wallet" "$WALLET_ID"
assert_ge "the verification hash is a derived value and not an empty string" 8 "${#VHASH}"
assert_eq "the handler refused nothing during a well-formed session" "[]" "$HANDLER_REFUSALS"
assert_eq "the provider refused nothing either" "[]" "$PROVIDER_REFUSALS"

# §8.4 ACROSS THE BOUNDARY, and the expected line is READ OUT OF `disclosure.ts` rather than typed
# here — two readings of one string, which is M33's rule and the reason a reflow cannot rot it.
# TWO SEGMENTS, EACH A COMPLETE LITERAL IN THE SOURCE, so neither is broken by the template
# substitution in the middle of that string and neither spans a line break — `CAMPAIGN-BRIEF.md`
# records three of M23's assertions going red because a needle contained a newline the file wraps.
DISCLOSURE_HEAD="$(python3 - "$REPO_ROOT/orchestration/src/disclosure.ts" <<'PYD'
import sys
src = open(sys.argv[1]).read()
i = src.find('SIMULATED AVM RUNTIME')
j = src.find('${', i)
print(src[i:j] if i >= 0 and j > i else 'MISSING')
PYD
)"
DISCLOSURE_TAIL="$(python3 - "$REPO_ROOT/orchestration/src/disclosure.ts" <<'PYD'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"'(This runtime executes[^']*)'", src)
print(m.group(1) if m else 'MISSING')
PYD
)"
assert_false "the disclosure line's head was found in disclosure.ts" \
  str_has_sub "$DISCLOSURE_HEAD" 'MISSING'
assert_false "...and its tail" str_has_sub "$DISCLOSURE_TAIL" 'MISSING'
assert_true "the wallet was TOLD this chain is simulated, in upstream's own metadata field" \
  str_has_sub "$DISCLOSED" "$DISCLOSURE_HEAD"
assert_true "...and told what that means, in the runtime's own words" \
  str_has_sub "$DISCLOSED" "$DISCLOSURE_TAIL"

echo "== 3. THE TRANSACTION: built by the wallet, settled by the chain"

OUTCOME="$(m34_arm transfer.report.outcome)"
BLOCK="$(m34_arm transfer.report.blockNumber)"
REVERT="$(m34_arm transfer.report.revertCode)"
STEPS="$(m34_arm transfer.report.executedSteps)"
INSTR="$(m34_arm transfer.report.instructionsExecuted)"
CONTEXTS="$(m34_arm transfer.report.contexts)"
TXHASH="$(m34_arm transfer.report.send.sent.txHash)"
BLOCK_HASHES="$(m34_arm transfer.report.blockTxHashes)"
m34_absent "transfer.report.outcome=$OUTCOME" "transfer.report.blockNumber=$BLOCK" \
  "transfer.report.revertCode=$REVERT" "transfer.report.executedSteps=$STEPS" \
  "transfer.report.instructionsExecuted=$INSTR" "transfer.report.contexts=$CONTEXTS" \
  "transfer.report.send.sent.txHash=$TXHASH" "transfer.report.blockTxHashes=$BLOCK_HASHES"

assert_eq "the block processed the wallet's transaction" "processed" "$OUTCOME"
assert_ge "…into a real block" 1 "$BLOCK"
# `outcome` CANNOT ANSWER THIS AND IS NOT WRONG TO BE UNABLE TO. `processed` is upstream's word for
# "the public processor turned it into a TxEffect", and a transaction that reverts at instruction
# one is still processed. M29's finding, and the reason `revertCode` is read separately.
assert_eq "…and it did NOT revert: upstream's own ProcessedTx.revertCode" "0" "$REVERT"
assert_true "…and the sealed block contains this transaction's hash" \
  str_has_sub "$BLOCK_HASHES" "$TXHASH"

# THE FLOORS ARE M29'S, AND THEY ARE FLOORS RATHER THAN EQUALITIES ON PURPOSE: a pinned step count
# would be a figure that rots the day the artifact moves. The identity beside them is what says the
# stream is not degenerate — the module's own statistic and the drained record count are two
# readings of one execution.
assert_ge "the AVM executed a real program through the wallet's transaction" 100 "$STEPS"
assert_eq "…and the module's own instruction statistic agrees with the drained record count" \
  "$STEPS" "$INSTR"
assert_ge "…across more than one AVM context, so the second enqueued call ran too" 2 "$CONTEXTS"

echo "== 4. THE SELECTOR THE AVM RECEIVED IS THE WALLET'S DERIVATION"

DECISIONS="$(m34_arm transfer.report.decisionMethods)"
KINDS="$(m34_arm transfer.report.decisionKinds)"
m34_absent "transfer.report.decisionMethods=$DECISIONS" "transfer.report.decisionKinds=$KINDS"

for method in requestCapabilities getAccounts getChainInfo registerSender getAddressBook \
              registerContractClass registerContract getContractMetadata getContractClassMetadata \
              sendTx; do
  assert_true "the wallet was asked for '$method' across the encrypted session" \
    str_has_sub "$DECISIONS" "\"$method\""
done
assert_true "…and it AUTHORIZED the transaction, which is the signing decision" \
  str_has_sub "$KINDS" '"authorized"'
assert_true "…and then served it" str_has_sub "$KINDS" '"served"'
assert_false "…and declined nothing in this arm" str_has_sub "$KINDS" '"declined"'

# THE VENDORED BUILDER NEVER TOUCHED A WORLD STATE, read out of the decision the wallet recorded
# rather than out of a comment. `merkleTouches` is the tripwire proxy's counter.
SEND_SERVED="$(python3 - "$M34_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [x for x in d['arms']['transfer']['report']['decisions']
        if x['method'] == 'sendTx' and x['decision'] == 'served']
print(rows[0]['detail'] if rows else 'MISSING')
PY
)"
m34_absent "transfer.sendTx.served.detail=$SEND_SERVED"
assert_true "the wallet's transaction builder never read the world state (M26's tripwire)" \
  str_has_sub "$SEND_SERVED" 'merkleTouches=0'
assert_true "…and it enqueued both public calls" str_has_sub "$SEND_SERVED" 'calls=2'

echo "== 5. THE CONTROL — a wallet that refuses to sign fails BY NAME, not silently"

D_SEND="$(m34_arm declined.report.send)"
D_OUTCOME="$(m34_arm declined.report.outcome)"
D_BLOCK="$(m34_arm declined.report.blockNumber)"
D_KINDS="$(m34_arm declined.report.decisionKinds)"
D_STEPS="$(m34_arm declined.report.executedSteps)"
m34_absent "declined.report.send=$D_SEND" "declined.report.decisionKinds=$D_KINDS" \
  "declined.report.executedSteps=$D_STEPS"

assert_true "the refusing wallet produced a NAMED failure" \
  str_has_sub "$D_SEND" 'DevWalletAuthorizationDeclined'
assert_true "…naming the account it declined for" \
  str_has_sub "$D_SEND" "$(m34_arm transfer.report.accounts.0.address)"
assert_true "…and the reason it was given" \
  str_has_sub "$D_SEND" 'the operator declined this transaction'
assert_true "…and the wallet's own ledger records the decision as 'declined'" \
  str_has_sub "$D_KINDS" '"declined"'
# NOT A SILENT NO-OP: nothing settled, nothing executed. Both halves, because "it failed" and "it
# did nothing" are different statements and the milestone asks for both.
assert_eq "…and NOTHING was submitted: the chain has no outcome for it" "MISSING" "$D_OUTCOME"
assert_eq "…and produced no block" "MISSING" "$D_BLOCK"
assert_eq "…and the AVM executed nothing" "0" "$D_STEPS"
# AND THE TWO ARMS DIFFER, which is what says the control is a control rather than a second
# measurement of the same thing.
assert_false "the subject arm and the control arm are not the same run" \
  test "$D_KINDS" = "$KINDS"

echo "== 6. every method the wallet does NOT serve refuses BY NAME"

METHODS="$(m34_arm refusals.report.methods)"
SERVED="$(m34_arm refusals.report.served)"
REFUSED="$(m34_arm refusals.report.refused)"
OVERWIRE="$(m34_arm refusals.report.overWire)"
CONTROL="$(m34_arm refusals.report.servedControl)"
m34_absent "refusals.report.methods=$METHODS" "refusals.report.served=$SERVED" \
  "refusals.report.refused=$REFUSED" "refusals.report.overWire=$OVERWIRE" \
  "refusals.report.servedControl=$CONTROL"

# THE METHOD LIST IS UPSTREAM'S, READ TWICE BY TWO ROUTES — out of the built bundle, and out of the
# installed `@aztec/aztec.js` in a separate process — and compared as a SET before anything else.
# M33's rule: two readings that agree is a measurement, one reading is a copy.
SCHEMA_KEYS="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
const { WalletSchema } = await import('@aztec/aztec.js/wallet');
console.log(JSON.stringify(Object.keys(WalletSchema).sort()));
" 2>&1 )"
assert_false "upstream's WalletSchema was importable" str_has_sub "$SCHEMA_KEYS" 'Error'
assert_eq "the wallet's method list IS WalletSchema's key set, read independently" \
  "$(python3 -c 'import json,sys; print(",".join(sorted(json.loads(sys.argv[1]))))' "$SCHEMA_KEYS")" \
  "$(python3 -c 'import json,sys; print(",".join(sorted(json.loads(sys.argv[1]))))' "$METHODS")"

# SERVED AND REFUSED PARTITION IT. Disjoint and summing to the whole, so a method that fell out of
# both — the shape a fabricated name would take — fails.
assert_eq "served and refused are DISJOINT and sum to the whole schema" "OK" \
  "$(python3 - "$METHODS" "$SERVED" "$REFUSED" <<'PY'
import json, sys
m, s, r = (set(json.loads(a)) for a in sys.argv[1:4])
problems = []
if s & r: problems.append('overlap: %s' % sorted(s & r))
if (s | r) != m: problems.append('symmetric difference: %s' % sorted((s | r) ^ m))
print('OK' if not problems else '; '.join(problems))
PY
)"
assert_ge "…over a non-empty refused set" 5 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$REFUSED")"

# EACH ONE NAMES ITSELF. Read out of the DIRECT results, because a refused method called across the
# wire with the wrong arity never reaches the wallet at all: upstream's own `parseWithOptionals`
# rejects the arguments first, with a `too_small` zod error naming no method. The first run of this
# arm measured exactly that, and every "refusal" in it was upstream's codec rather than the wallet.
REFUSAL_VERDICT="$(python3 - "$M34_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = d['arms']['refusals']['report']
bad = []
for name in json.loads(json.dumps(r['refused'])):
    got = r['direct'].get(name)
    if got is None:
        bad.append('%s:ABSENT' % name); continue
    if 'rejected' not in got:
        bad.append('%s:RESOLVED' % name); continue
    if got['rejected']['name'] != 'DevWalletRefused':
        bad.append('%s:WRONG_ERROR(%s)' % (name, got['rejected']['name'])); continue
    if ("'%s'" % name) not in got['rejected']['message']:
        bad.append('%s:UNNAMED' % name); continue
    reason = r['reasons'].get(name, '')
    if not reason or reason not in got['rejected']['message']:
        bad.append('%s:NO_REASON' % name)
print(' '.join(bad) if bad else 'ALL_REFUSE_BY_NAME')
PY
)"
assert_eq "every unserved method refuses, names ITSELF, and states what is missing" \
  "ALL_REFUSE_BY_NAME" "$REFUSAL_VERDICT"

# THE DECLARATION AND THE IMPLEMENTATION ARE RECONCILED AT CONSTRUCTION, and the reconciliation is
# exercised in BOTH DIRECTIONS over the BUILT bundle. `DEV_WALLET_SERVED` is a list a check reads
# and the `served` object is what answers; three separate declarations of one partition (those two
# and the refusal-reason map) are three things to drift, and a method listed as served that silently
# refuses is the plausible-default shape wearing a table of contents.
GUARD_OK="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
try { m.assertServedMatchesDeclaration([...m.DEV_WALLET_SERVED]); console.log('ACCEPTS'); }
catch (e) { console.log('REJECTED: ' + e.message); }
" 2>&1 )"
GUARD_NO="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
// One name dropped and one fabricated: the guard must report BOTH directions in one message.
const bad = [...m.DEV_WALLET_SERVED].filter(n => n !== 'sendTx').concat(['notAWalletMethod']);
try { m.assertServedMatchesDeclaration(bad); console.log('ACCEPTED'); }
catch (e) { console.log(e.message); }
" 2>&1 )"
assert_eq "the served declaration matches the implementation, over the BUILT bundle" \
  "ACCEPTS" "$GUARD_OK"
assert_true "…and the reconciliation CAN say no: a served method nothing implements" \
  str_has_sub "$GUARD_NO" 'names [sendTx] that nothing implements'
assert_true "…and, in the same message, an implementation nothing declares" \
  str_has_sub "$GUARD_NO" 'serves [notAWalletMethod] that DEV_WALLET_SERVED does not name'

# AND THE BEHAVIOURAL HALF, which the construction-time guard cannot give: not one of the ten served
# methods appears in the wallet's own ledger as REFUSED. All ten were called in §4; a method that
# was listed as served and refused anyway would show up here and nowhere else.
assert_eq "no method the wallet declares SERVED was refused when it was called" "NONE_REFUSED" \
  "$(python3 - "$M34_ARMS" <<'PYD'
import json, sys
d = json.load(open(sys.argv[1]))
served = set(d['arms']['refusals']['report']['served'])
rows = d['arms']['transfer']['report']['decisions']
bad = sorted({r['method'] for r in rows if r['method'] in served and r['decision'] == 'refused'})
seen = sorted({r['method'] for r in rows if r['method'] in served})
if len(seen) < 10:
    print('ONLY %d OF THE SERVED METHODS WERE EXERCISED: %s' % (len(seen), seen))
else:
    print('NONE_REFUSED' if not bad else 'REFUSED: ' + ' '.join(bad))
PYD
)"

assert_true "…and a refusal survives the whole encrypted round trip" \
  str_has_sub "$OVERWIRE" 'DevWalletRefused'
assert_true "…naming the method there too" str_has_sub "$OVERWIRE" "simulateTx"
# THE POSITIVE CONTROL, on the same object across the same session: a SERVED method reaches through
# and comes back through upstream's own return codec.
assert_true "the control: a served method reaches through the same encrypted boundary" \
  str_has_sub "$CONTROL" 'resolved'
assert_true "…answering with the chain info the runtime declared" str_has_sub "$CONTROL" 'chainId'

echo "== 7. and the '.ct' at the end of it, read by the PINNED reader"

m24_require_readers
CONTAINER="$(m34_container record)"
assert_false "the browser downloaded a container" str_has_sub "$CONTAINER" 'MISSING'
assert_true "…and it is on disk" test -s "$CONTAINER"
BYTES="$(m34_arm record.downloadedBytes)"
m34_absent "record.downloadedBytes=$BYTES"
assert_ge "…and it is not an empty file" 4096 "$BYTES"

ROWS="$(m34_log_events "$CONTAINER")"
assert_false "the pinned ct-print read it" str_has_sub "$ROWS" 'ERR:'
assert_ge "…and it carries the wallet's decisions as trace records" 10 \
  "$(m34_count_meta "$ROWS" 'ct.wallet-decision')"

echo "== 8. THE ENUMERATION AND THE WRITE-UP, RE-DERIVED AND COMPARED"

# `CAMPAIGN-BRIEF.md`: *"If a document states a measurement, something must take that measurement
# again and compare."* Every figure `DEV-WALLET.md` states about the closure, the surface, the
# transfer and the packaging is re-derived here — the closure out of the anchor's OBJECT STORE with
# M33's own walker, the transfer figures out of the BROWSER ARM, the packaging out of the build's
# own report — and matched on the line that NAMES ITS SUBJECT, as a DELIMITED figure. Both anchorings
# were earned by somebody else's rotted number; `_m34_doc_figures.py`'s header carries the accounts.
m33_require_anchor_tree
{
  for group in basewallet walletschema entrypoints; do
    out="$(python3 "$VERIFY_DIR/_m34_closure.py" "$M33_ANCHOR_TREE" "$group")"
    printf '%s\t%s\t%s\t%s\n' "$group" \
      "$(printf '%s\n' "$out" | sed -n 's/^FILES\t//p')" \
      "$(printf '%s\n' "$out" | sed -n 's/^LINES\t//p')" \
      "$(printf '%s\n' "$out" | awk -F'\t' '$1=="WS_PKGS"{print $2}')"
    if [ "$group" = "basewallet" ]; then
      # THE VALUE-EDGE SUBSET, which is the number the vendoring decision rests on. `PXE_EDGE` is
      # the value subset of `PXE_CLAUSE`, and the difference between them IS the type-erasure
      # argument — M33's review found the two conflated in two places that ship.
      printf 'basewallet-pxe\t%s\t%s\t0\n' \
        "$(printf '%s\n' "$out" | grep -c '^PXE_EDGE' || true)" \
        "$(printf '%s\n' "$out" | grep -c '^PXE_CLAUSE' || true)"
      printf '%s\n' "$out" > "$WORK/basewallet_closure.txt"
    fi
  done
} > "$WORK/closure.tsv"

# THE WALKER IS SHOWN TO HAVE ANSWERED, and its residues are asserted, before any figure is
# believed. A closure of zero files satisfies nothing above but would make every `compare` below a
# MISSING rather than a BAD, which reads as a smaller check.
assert_ge "the BaseWallet closure is a real walk" 400 \
  "$(awk -F'\t' '$1=="basewallet"{print $2}' "$WORK/closure.tsv")"
assert_eq "…with no import clause the classifier could not place" "0" \
  "$(sed -n 's/^UNCLASSIFIED\t//p' "$WORK/basewallet_closure.txt")"
assert_ge "…and it REACHES the packages the decision rests on, so the walker can answer both ways" 2 \
  "$(grep -c '^REACHES' "$WORK/basewallet_closure.txt" || true)"
assert_true "…naming @aztec/pxe" str_has_line "$(cat "$WORK/basewallet_closure.txt")" \
  "$(printf 'REACHES\t@aztec/pxe')"
assert_true "…and @aztec/simulator" str_has_line "$(cat "$WORK/basewallet_closure.txt")" \
  "$(printf 'REACHES\t@aztec/simulator')"
# THE CONTROL FOR THAT REACH: the two groups M34 DOES depend on, through the same walker in the same
# invocation, reach neither. An absence measured by an instrument that has just been seen to find one.
for clean in walletschema entrypoints; do
  out="$(python3 "$VERIFY_DIR/_m34_closure.py" "$M33_ANCHOR_TREE" "$clean")"
  assert_eq "the $clean closure reaches NO DD-9 package, through the same walker" "0" \
    "$(printf '%s\n' "$out" | grep -c '^REACHES' || true)"
  assert_ge "…over a non-empty walk" 100 "$(printf '%s\n' "$out" | sed -n 's/^FILES\t//p')"
done

DOC_OUT="$(python3 "$VERIFY_DIR/_m34_doc_figures.py" "$M34_DOC" "$BROWSER_DIST/chunks.json" \
  "$M34_ARMS" "$WORK/closure.tsv")"
CHECKED="$(printf '%s\n' "$DOC_OUT" | sed -n 's/^CHECKED\t//p')"
assert_ge "the write-up's figures were re-derived and compared, and there are several" 18 "$CHECKED"
assert_eq "no subject line the comparer looks for has gone from the write-up" "" \
  "$(printf '%s\n' "$DOC_OUT" | sed -n 's/^MISSING\t//p')"
assert_eq "every figure in the write-up equals what the artefacts measure" "" \
  "$(printf '%s\n' "$DOC_OUT" | sed -n 's/^BAD\t//p')"

# AND THE COMPARER IS SHOWN TO SAY NO. Without this, "no BAD" is satisfied by a comparer that never
# compared — the second form on `CAMPAIGN-BRIEF.md`'s list. A copy of the document with ONE figure
# perturbed by one digit must be reported, and the report must NAME that figure.
# AND THE PERTURBATION ITSELF MUST APPLY. `CAMPAIGN-BRIEF.md`'s fourth mutation state — *"a
# substitution that does not find its needle must abort, restore, and say so"* — applies to a
# control inside a check as much as to a mutation harness: over an ALREADY-WRONG document the
# perturbation finds nothing, and the two assertions below would then be failing for a reason that
# has nothing to do with the comparer. Measured, because M34's own M9 arm produced exactly that.
PERTURBED="$WORK/perturbed.md"
if ! python3 - "$M34_DOC" "$PERTURBED" <<'PYD'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
# The executed-step count, in the §4 table row that names it. One digit, one row.
out = src.replace('| executed AVM steps | **516** |', '| executed AVM steps | **517** |')
assert out != src, 'the perturbation did not apply: the row this control needs is gone'
open(sys.argv[2], 'w', encoding='utf-8').write(out)
PYD
then
  die "the doc-figure control could not perturb $M34_DOC: the row it needs is not there, or already
             carries the perturbed value. A control that silently perturbs nothing is a control that
             passes for the wrong reason."
fi
PERTURBED_OUT="$(python3 "$VERIFY_DIR/_m34_doc_figures.py" "$PERTURBED" "$BROWSER_DIST/chunks.json" \
  "$M34_ARMS" "$WORK/closure.tsv")"
assert_true "the comparer CAN report a wrong figure" \
  str_has_sub "$(printf '%s\n' "$PERTURBED_OUT" | sed -n 's/^BAD\t//p')" 'steps expected'
assert_eq "…and it compared the same number of figures while doing so" "$CHECKED" \
  "$(printf '%s\n' "$PERTURBED_OUT" | sed -n 's/^CHECKED\t//p')"

m34_finish
