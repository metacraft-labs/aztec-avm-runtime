import re,sys,json,collections
sys.path.insert(0,'.')
files=[l.strip() for l in open('linked-files.txt') if l.strip()]
FAM = {
 'fs': [(r'(?<![A-Za-z0-9_:])std::fs\b','std::fs'),(r'(?<![A-Za-z0-9_:])fs::[a-z_]','fs::*'),
        (r'(?<![A-Za-z0-9_:])File::(open|create)\b','File::open/create'),(r'(?<![A-Za-z0-9_:])OpenOptions\b','OpenOptions'),
        (r'(?<![A-Za-z0-9_:])read_to_string\s*\(','read_to_string()'),
        (r'(?<![A-Za-z0-9_:])(create_dir_all|remove_file|remove_dir_all|read_dir|canonicalize)\s*\(','fs op')],
 'env': [(r'(?<![A-Za-z0-9_:])std::env\b','std::env'),
         (r'(?<![A-Za-z0-9_:])env::(var|args|current_dir|set_var|var_os|args_os|current_exe|temp_dir|vars)\b','env::*')],
 'time': [(r'(?<![A-Za-z0-9_:])std::time\b','std::time'),
          (r'(?<![A-Za-z0-9_:])(SystemTime|Instant)\s*::\s*now\b','SystemTime/Instant::now'),
          (r'(?<![A-Za-z0-9_:])(SystemTime|Instant)\b','SystemTime/Instant type'),
          (r'(?<![A-Za-z0-9_:])(Utc|Local)\s*::\s*now\b','chrono now')],
 'thread': [(r'(?<![A-Za-z0-9_:])std::thread\b','std::thread'),
            (r'(?<![A-Za-z0-9_:])thread::(spawn|sleep|park|current|available_parallelism)\b','thread::*'),
            (r'(?<![A-Za-z0-9_:])rayon::','rayon'),(r'(?<![A-Za-z0-9_:])par_iter\s*\(','par_iter()'),
            (r'(?<![A-Za-z0-9_:])std::sync::mpsc\b','mpsc')],
 'process': [(r'(?<![A-Za-z0-9_:])std::process\b','std::process'),(r'(?<![A-Za-z0-9_:])Command::new\b','Command::new'),
             (r'(?<![A-Za-z0-9_:])process::(exit|abort|Command)\b','process::*')],
}
COMP={f:[(re.compile(p),l) for p,l in v] for f,v in FAM.items()}
RESIDUE=re.compile(r'(?<![A-Za-z0-9_:])(std::(fs|env|time|thread|process|net)|fs::|env::|thread::|process::|Command|SystemTime|Instant|Utc::|Local::|getrandom|libc::|js_sys|web_sys|wasm_bindgen::)\b')
def pkg(f):
    if '/registry/src/' in f: return f.split('/registry/src/')[1].split('/',1)[1].split('/')[0]
    if '/noir/noir-repo/' in f:
        p=f.split('/noir/noir-repo/')[1].split('/'); return 'noir:'+'/'.join(p[:2])
    return 'avm-transpiler'
hits=collections.defaultdict(lambda: collections.defaultdict(list)); residue=collections.defaultdict(list)
for f in files:
    try: lines=open(f,encoding='utf-8',errors='replace').read().split('\n')
    except OSError: continue
    P=pkg(f)
    for i,raw in enumerate(lines,1):
        line='' if raw.lstrip().startswith('//') else raw
        if not line.strip(): continue
        placed=False
        for fam,pats in COMP.items():
            for rx,lbl in pats:
                if rx.search(line):
                    hits[fam][P].append((f,i,lbl,raw.strip()[:140])); placed=True; break
            if placed: break
        if not placed and RESIDUE.search(line): residue[P].append((f,i,raw.strip()[:140]))
tot=0
print(f"files compiled into the wasm32 build: {len(files)}")
for fam in ('fs','env','time','thread','process'):
    n=sum(len(v) for v in hits[fam].values()); tot+=n
    print(f"  {fam:8s} {n:5d}  packages {len(hits[fam])}")
print(f"  {'TOTAL':8s} {tot:5d}")
print(f"  residue no family placed: {sum(len(v) for v in residue.values())} across {len(residue)} packages")
per=collections.Counter()
for fam,pk in hits.items():
    for p,v in pk.items(): per[p]+=len(v)
print("\ntop packages:")
for p,c in per.most_common(20):
    fams=" ".join(f"{f}:{len(hits[f][p])}" for f in ('fs','env','time','thread','process') if hits[f][p])
    print(f"  {c:5d}  {p:34s} {fams}")
json.dump({'hits':{f:dict(d) for f,d in hits.items()},'residue':dict(residue)},open('census-linked-files.json','w'))
