#!/usr/bin/env python3
"""M31 host-capability census over avm-transpiler's dependency closure.

Prints every site, per package, in five families, and PRINTS THE RESIDUE — lines that look
host-shaped but that no family placed. A scanner that only counts what it matches cannot
tell a narrow needle from an empty tree (CAMPAIGN-BRIEF: "write scanners that PRINT the
residue rather than counting the matches").
"""
import os, re, sys, json, collections

closure = sys.argv[1]
rows = []
with open(closure) as f:
    next(f)
    for line in f:
        n, v, k, s = line.rstrip('\n').split('\t')
        rows.append((n, v, k, s))

# Families. Each is a list of (name, compiled regex). Word-boundary anchored where a bare
# substring would over-match (`now(` matches `snow(`; `fs::` matches `dfs::`).
FAM = {
 'fs': [
   (r'(?<![A-Za-z0-9_:])std::fs\b', 'std::fs'),
   (r'(?<![A-Za-z0-9_:])fs::[a-z_]', 'fs::*'),
   (r'(?<![A-Za-z0-9_:])File::(open|create)\b', 'File::open/create'),
   (r'(?<![A-Za-z0-9_:])OpenOptions\b', 'OpenOptions'),
   (r'(?<![A-Za-z0-9_:])read_to_string\s*\(', 'read_to_string()'),
   (r'(?<![A-Za-z0-9_:])(create_dir_all|remove_file|remove_dir_all|read_dir|canonicalize|metadata)\s*\(', 'fs op'),
 ],
 'env': [
   (r'(?<![A-Za-z0-9_:])std::env\b', 'std::env'),
   (r'(?<![A-Za-z0-9_:])env::(var|args|current_dir|set_var|var_os|args_os|current_exe|temp_dir|vars)\b', 'env::*'),
 ],
 'time': [
   (r'(?<![A-Za-z0-9_:])std::time\b', 'std::time'),
   (r'(?<![A-Za-z0-9_:])(SystemTime|Instant)\s*::\s*now\b', 'SystemTime/Instant::now'),
   (r'(?<![A-Za-z0-9_:])(SystemTime|Instant)\b', 'SystemTime/Instant type'),
   (r'(?<![A-Za-z0-9_:])(Utc|Local)\s*::\s*now\b', 'chrono now'),
   (r'(?<![A-Za-z0-9_:])time::(Instant|SystemTime)\b', 'time::*'),
 ],
 'thread': [
   (r'(?<![A-Za-z0-9_:])std::thread\b', 'std::thread'),
   (r'(?<![A-Za-z0-9_:])thread::(spawn|sleep|park|current|available_parallelism)\b', 'thread::*'),
   (r'(?<![A-Za-z0-9_:])(rayon)::', 'rayon'),
   (r'(?<![A-Za-z0-9_:])par_iter\s*\(', 'par_iter()'),
   (r'(?<![A-Za-z0-9_:])std::sync::mpsc\b', 'mpsc'),
 ],
 'process': [
   (r'(?<![A-Za-z0-9_:])std::process\b', 'std::process'),
   (r'(?<![A-Za-z0-9_:])Command::new\b', 'Command::new'),
   (r'(?<![A-Za-z0-9_:])process::(exit|abort|Command)\b', 'process::*'),
 ],
}
COMP = {fam: [(re.compile(p), lbl) for p, lbl in v] for fam, v in FAM.items()}

# The residue net: broad, deliberately over-wide. Anything it catches that no family placed
# is PRINTED, so a family that is too narrow shows up as a line rather than as a silent zero.
RESIDUE = re.compile(
  r'(?<![A-Za-z0-9_:])(std::(fs|env|time|thread|process|net|io::stdin)|'
  r'fs::|env::|thread::|process::|Command|SystemTime|Instant|Utc::|Local::|'
  r'getrandom|libc::|getenv|dirs::|home_dir|tempfile|TempDir|available_parallelism|'
  r'js_sys|web_sys|wasm_bindgen::|extern\s+"C")\b')

# cfg attribute on or shortly before the line — used to say whether a site is even compiled
# for a non-unix, non-windows target.
CFG = re.compile(r'#\[cfg(_attr)?\((.*)\)\]')
CFG_OFF_WASM = re.compile(r'\b(unix|windows|target_family\s*=\s*"(unix|windows)"|target_os\s*=\s*"(linux|macos|windows|android|ios|hermit|wasi)")\b')

hits = collections.defaultdict(lambda: collections.defaultdict(list))
residue = collections.defaultdict(list)
scanned_files = 0
scanned_pkgs = 0
missing = []

def strip_comment(line):
    # naive but reported: only strips a WHOLE-LINE comment, never an inline one, so a `//`
    # inside a string literal cannot eat code (the walker defect CAMPAIGN-BRIEF records).
    return '' if line.lstrip().startswith('//') else line

for name, ver, kind, src in rows:
    if not os.path.isdir(src):
        missing.append(src); continue
    scanned_pkgs += 1
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'target')]
        rel_parts = os.path.relpath(dirpath, src).split(os.sep)
        for fn in filenames:
            if not fn.endswith('.rs'):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, src)
            # tests/benches/examples are not linked into a cdylib
            top = rel.split(os.sep)[0]
            is_test = top in ('tests', 'benches', 'examples', 'fuzz')
            scanned_files += 1
            try:
                text = open(p, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            lines = text.split('\n')
            for i, raw in enumerate(lines, 1):
                line = strip_comment(raw)
                if not line.strip():
                    continue
                placed = False
                for fam, pats in COMP.items():
                    for rx, lbl in pats:
                        if rx.search(line):
                            ctx = '\n'.join(lines[max(0, i-4):i-1])
                            cfg = ''
                            for m in CFG.finditer(ctx):
                                if CFG_OFF_WASM.search(m.group(0)):
                                    cfg = m.group(0)[:60]
                            hits[fam][name].append((rel, i, lbl, raw.strip()[:150], is_test, cfg))
                            placed = True
                            break
                    if placed:
                        break
                if not placed and RESIDUE.search(line):
                    residue[name].append((rel, i, raw.strip()[:150], is_test))

print(f"# packages in closure: {len(rows)}   scanned: {scanned_pkgs}   .rs files: {scanned_files}")
if missing:
    print(f"# UNSCANNABLE (source dir absent): {len(missing)}")
    for m in missing: print("#   ", m)
print()
tot = 0
for fam in ('fs','env','time','thread','process'):
    n = sum(len(v) for v in hits[fam].values())
    nlib = sum(1 for v in hits[fam].values() for h in v if not h[4])
    tot += n
    print(f"{fam:8s} total {n:5d}   of which lib-linked (not tests/benches/examples) {nlib:5d}   packages {len(hits[fam])}")
print(f"{'TOTAL':8s}       {tot:5d}")
print(f"residue lines no family placed: {sum(len(v) for v in residue.values())} across {len(residue)} packages")
json.dump({'hits': {f: {k: v for k, v in d.items()} for f, d in hits.items()},
           'residue': dict(residue)}, open(sys.argv[2], 'w'))
