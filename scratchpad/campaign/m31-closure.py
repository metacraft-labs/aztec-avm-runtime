import json, sys, os
md = json.load(open(sys.argv[1]))
pkgs = {p['id']: p for p in md['packages']}
resolve = {n['id']: n for n in md['resolve']['nodes']}
root = md['resolve']['root']

def is_proc_macro(i):
    return any('proc-macro' in t['kind'] for t in pkgs[i]['targets'])

# LINKED closure: follow only `normal` dep edges, and stop at proc-macro crates (their code
# runs in the compiler, never in the module).
linked=set(); stack=[root]
while stack:
    i=stack.pop()
    if i in linked: continue
    linked.add(i)
    for d in resolve[i]['deps']:
        kinds={(k['kind'] or 'normal') for k in d.get('dep_kinds',[])}
        if 'normal' not in kinds: continue
        if is_proc_macro(d['pkg']): continue
        stack.append(d['pkg'])

# HOST-ONLY closure: everything else in the full graph (build deps, proc macros and their deps)
full=set(); stack=[root]
while stack:
    i=stack.pop()
    if i in full: continue
    full.add(i)
    for d in resolve[i]['deps']:
        kinds={(k['kind'] or 'normal') for k in d.get('dep_kinds',[])}
        if kinds=={'dev'}: continue
        stack.append(d['pkg'])
host = full - linked

def emit(ids, path):
    rows=[]
    for i in sorted(ids):
        p=pkgs[i]; mani=p['manifest_path']
        rows.append((p['name'],p['version'],'path' if '/registry/src/' not in mani else 'crates.io', os.path.dirname(mani)))
    rows.sort()
    with open(path,'w') as f:
        f.write(f"CLOSURE {len(rows)}\n")
        for r in rows: f.write("\t".join(r)+"\n")
    return rows

l=emit(linked, sys.argv[2]); h=emit(host, sys.argv[3])
print(f"full graph (normal+build, wasm32): {len(full)}")
print(f"LINKED (normal edges only, proc-macros excluded): {len(l)}")
print(f"HOST-ONLY (build scripts + proc macros + their deps): {len(h)}")
print("host-only names:", ", ".join(sorted({r[0] for r in h})))
