#!/usr/bin/env node
// scan_reverted_transactions.mjs — does a REVERTED settled transaction exist to record?
//
// `test_reverted_transaction_recorded_as_reverted` (L3) needs one, and it needs a REAL one: L2's
// wrong-block control produces a genuine revert, but that is a REPLAY THAT FAILED and not a
// TRANSACTION THAT REVERTED, and conflating the two would be the check's own defect. So the check
// stays named-but-pending until a subject exists, and this is the measurement that says so.
//
// COMMITTED SO THE CLAIM IS RE-RUNNABLE RATHER THAN QUOTED. A scan is a measurement of a chain at
// the moment it ran; "no reverted transaction exists" is a sentence with a date on it, and the next
// agent should be able to re-take it in one command instead of rebuilding the tooling.
//
// CHEAP FIRST, THEN EXPENSIVE. `getBlock(n)` WITHOUT `{ includeTransactions: true }` answers a
// BODY-LESS block — the artefact L0 met live and L1 captured — so counting `body.txEffects` on it
// reports zero for every block. That is not hypothetical: L2's first activity scan reported 135
// consecutive empty testnet blocks over a range that had thirteen transactions in it. The tell was
// in the same response and was not being read. So this walks `header.totalManaUsed` first and only
// fetches a body when the mana is non-zero.
//
// Usage: node tools/scan_reverted_transactions.mjs --url <rpc> [--from N] [--to N] [--conc N]
// With no range it scans backwards from the tip.

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const url = arg('url', 'https://aztec-testnet.drpc.org');
const conc = Number(arg('conc', 10));
const depth = Number(arg('depth', 300));

async function rpc(method, params) {
  for (let a = 0; a < 3; a++) {
    try {
      const r = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(30000),
      });
      const j = await r.json();
      if (j.error) { await new Promise(s => setTimeout(s, 500)); continue; }
      return j.result;
    } catch { await new Promise(s => setTimeout(s, 500)); }
  }
  return 'ERR';
}

const tip = await rpc('aztec_getBlockNumber', []);
const finalized = await rpc('aztec_getBlockNumber', ['finalized']);
const to = Number(arg('to', tip));
const from = Number(arg('from', Math.max(1, to - depth)));
console.error(`scan: ${url} tip=${tip} finalized=${finalized} range=${from}..${to}`);

const nums = []; for (let n = from; n <= to; n++) nums.push(n);
let idx = 0, err = 0, active = 0, txs = 0;
const reverted = [];
const codes = new Map();
async function worker() {
  while (idx < nums.length) {
    const n = nums[idx++];
    const head = await rpc('aztec_getBlock', [n]);
    if (head === 'ERR' || head == null) { err++; continue; }
    if (BigInt(head.header?.totalManaUsed ?? '0x0') === 0n) continue;
    active++;
    const full = await rpc('aztec_getBlock', [n, { includeTransactions: true }]);
    if (full === 'ERR' || full == null) { err++; continue; }
    for (const t of full.body?.txEffects ?? []) {
      txs++;
      const rc = typeof t.revertCode === 'number' ? t.revertCode : (t.revertCode?.code ?? String(t.revertCode));
      codes.set(String(rc), (codes.get(String(rc)) ?? 0) + 1);
      // ABOVE THE FINALIZED TIP IS THE ONLY USEFUL ANSWER. Below it `getTxByHash` has pruned the
      // body, so a reverted transaction found there is visible and unreplayable — which is this
      // campaign's founding constraint, and reporting it as a candidate would waste the finder's time.
      if (String(rc) !== '0') reverted.push({ block: n, txHash: t.txHash, revertCode: rc, replayable: n > finalized });
    }
  }
}
await Promise.all(Array.from({ length: conc }, worker));

console.log(JSON.stringify({
  url, tip, finalized, from, to,
  blocksScanned: nums.length, blocksWithActivity: active, transactions: txs, unanswered: err,
  revertCodeHistogram: Object.fromEntries(codes),
  reverted,
  verdict: reverted.length === 0
    ? 'NO REVERTED SETTLED TRANSACTION IN THIS RANGE — test_reverted_transaction_recorded_as_reverted stays pending'
    : `${reverted.length} found; ${reverted.filter(r => r.replayable).length} above the finalized tip and therefore still replayable`,
}, null, 2));
