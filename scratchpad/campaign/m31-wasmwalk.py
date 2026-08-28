#!/usr/bin/env python3
"""Independent leb128 walker over a wasm module's import and export sections.
Deliberately NOT wasm-tools/wabt: the point is a second, independent reading."""
import sys, struct
b=open(sys.argv[1],'rb').read()
assert b[:4]==b'\0asm', 'not a wasm module'
i=8
def u32(i):
    r=0; s=0
    while True:
        c=b[i]; i+=1; r |= (c&0x7f)<<s
        if not c&0x80: return r,i
        s+=7
imports=[]; exports=[]
while i < len(b):
    sid=b[i]; i+=1
    size,i=u32(i)
    end=i+size
    if sid==2:
        n,j=u32(i)
        for _ in range(n):
            ml,j=u32(j); mod=b[j:j+ml].decode(); j+=ml
            nl,j=u32(j); nm=b[j:j+nl].decode(); j+=nl
            k=b[j]; j+=1
            if k==0: _,j=u32(j)
            elif k==1:
                j+=1; lim=b[j]; j+=1; _,j=u32(j)
                if lim: _,j=u32(j)
            elif k==2:
                lim=b[j]; j+=1; _,j=u32(j)
                if lim: _,j=u32(j)
            elif k==3: j+=2
            imports.append((mod,nm,k))
    if sid==7:
        n,j=u32(i)
        for _ in range(n):
            nl,j=u32(j); nm=b[j:j+nl].decode(); j+=nl
            k=b[j]; j+=1; _,j=u32(j)
            exports.append((nm,k))
    i=end
print(f"module {sys.argv[1]}  {len(b)} bytes")
print(f"IMPORTS: {len(imports)}")
mods={}
for m,n,k in imports: mods.setdefault(m,[]).append(n)
for m in sorted(mods):
    print(f"  {m}  ({len(mods[m])})")
    for n in sorted(mods[m]): print(f"     {n}")
print(f"EXPORTS: {len(exports)}")
for n,k in sorted(exports): print(f"  {n} (kind {k})")
