#!/usr/bin/env bash
# Round 2: do the review's own NEW assertions bite? Each is mutated and must redden.
set -uo pipefail
ROOT=/home/zahary/m/blocktracer/aztec-avm-runtime
cd "$ROOT"
BK=$HOME/.cache/aztec-m24rev/rm2-backups; mkdir -p "$BK"
CTF=/home/zahary/m/blocktracer/codetracer-trace-format

run_check() {
  local c="$1"; shift
  local out rc
  out="$(env "$@" nix develop "$ROOT" --command bash -c "cd '$ROOT' && verification/$c.sh" 2>&1)"
  rc=$?
  printf 'rc=%s  %s\n' "$rc" "$(printf '%s\n' "$out" | grep -E "^$c: [0-9]+ assertion" | tail -1)"
  printf '%s\n' "$out" | grep -E '^  FAIL' | head -6 | sed 's/^/       /'
}

echo "=== RM4a — the instrument, on a DANGLING (unpublished) commit"
D="$(git -C "$CTF" commit-tree '9cbc127ef8e8c09027f5da047c333149f54c8320^{tree}' \
      -p 9cbc127ef8e8c09027f5da047c333149f54c8320 -m 'review probe: an unpublished commit')"
echo "dangling commit: $D"
echo "refs containing it: [$(git -C "$CTF" for-each-ref --contains "$D" --format='%(refname)' refs/remotes | wc -l)]"
echo "refs containing the pinned one: [$(git -C "$CTF" for-each-ref --contains 9cbc127ef8e8c09027f5da047c333149f54c8320 --format='%(refname)' refs/remotes | wc -l)]"
echo "git archive of the dangling commit works locally: $(git -C "$CTF" archive "$D" | wc -c) bytes"

echo
echo "=== RM4b — pins.json points trace_format at that unpublished commit"
cp -p pins.json "$BK/pins.json"
python3 - "$D" <<'PY'
import json, collections, sys
p='pins.json'
d=json.load(open(p,encoding='utf-8'), object_pairs_hook=collections.OrderedDict)
d['anchors']['trace_format']['commit']=sys.argv[1]
open(p,'w',encoding='utf-8').write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")
PY
echo "  verify_ct_writer_wasm_zero_imports: $(run_check verify_ct_writer_wasm_zero_imports)"
cp -p "$BK/pins.json" pins.json; touch pins.json
cmp -s "$BK/pins.json" pins.json && echo "  pins.json RESTORED OK" || echo "  RESTORE FAILED"

echo
echo "=== RM2' — the arm table's rows swapped again, against the row-anchored needle"
cp -p TRACE-ABI.md "$BK/TRACE-ABI.md"
python3 - <<'PY'
p='TRACE-ABI.md'; s=open(p).read()
a = "| `batched` | 534,565 | 523,133 | 25 | 4,435,968 |\n| `perEvent` | 535,350 | 524,353 | 100,000 | 4,435,968 |"
b = "| `batched` | 535,350 | 524,353 | 25 | 4,435,968 |\n| `perEvent` | 534,565 | 523,133 | 100,000 | 4,435,968 |"
assert a in s
open(p,'w').write(s.replace(a,b,1))
PY
echo "  verify_trace_event_abi_batched_faster: $(run_check verify_trace_event_abi_batched_faster)"
cp -p "$BK/TRACE-ABI.md" TRACE-ABI.md; touch TRACE-ABI.md

echo
echo "=== RM3' — §7's byte count set back to the mutation-era figure"
python3 - <<'PY'
p='TRACE-ABI.md'; s=open(p).read()
assert "**246,527 bytes**" in s
open(p,'w').write(s.replace("**246,527 bytes**","**245,724 bytes**",1))
PY
echo "  verify_ct_writer_wasm_zero_imports: $(run_check verify_ct_writer_wasm_zero_imports)"
cp -p "$BK/TRACE-ABI.md" TRACE-ABI.md; touch TRACE-ABI.md

echo
echo "=== RM3'' — §7's sha256 prefix changed"
python3 - <<'PY'
p='TRACE-ABI.md'; s=open(p).read()
assert "sha256 `75626c72" in s
open(p,'w').write(s.replace("sha256 `75626c72","sha256 `deadbeef",1))
PY
echo "  verify_ct_writer_wasm_zero_imports: $(run_check verify_ct_writer_wasm_zero_imports)"
cp -p "$BK/TRACE-ABI.md" TRACE-ABI.md; touch TRACE-ABI.md
cmp -s "$BK/TRACE-ABI.md" TRACE-ABI.md && echo "  TRACE-ABI.md RESTORED OK" || echo "  RESTORE FAILED"
echo "RM2 ROUND DONE"
