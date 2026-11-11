#!/usr/bin/env python3
"""Read how CMake built a translation unit and linked a test binary, so the transcript split of
upstream's MemoryMerkleDB equivalence test is compiled and linked exactly the way that build
directory compiles and links its own tests -- rather than with a flag list typed into a script.

  _build_cmds.py compile <build-dir> <source-suffix> [<target-objects-dir>]
      The compiler and its flags for the ONE compile-database entry whose file ends with
      <source-suffix> (and, if given, whose output lies under CMakeFiles/<target-objects-dir>/ --
      a native build compiles vm2's test sources into two targets), without -o/-c/-MD/-MT/-MF
      and without the source itself. NUL-separated.
  _build_cmds.py link <build-dir> <ninja-target>
      The FLAGS, LINK_FLAGS (minus --dependency-file) and LINK_LIBRARIES of <ninja-target>'s
      link statement in build.ninja, as three NUL-separated sections divided by a lone "--".

Exits non-zero, saying why, when the entry or the statement is not there exactly once.
"""
import json
import os
import shlex
import sys


def compile_cmd(bdir, suffix, objdir=None):
    db = json.load(open(os.path.join(bdir, "compile_commands.json")))
    hits = [e for e in db if e["file"].endswith(suffix)]
    if objdir is not None:
        hits = [e for e in hits if f"/CMakeFiles/{objdir}/" in e.get("output", e.get("command", ""))]
    if len(hits) != 1:
        sys.exit(f"expected exactly one compile-database entry ending in {suffix}, got {len(hits)}")
    argv = shlex.split(hits[0]["command"]) if "command" in hits[0] else hits[0]["arguments"]
    keep, skip = [argv[0]], False
    for a in argv[1:]:
        if skip:
            skip = False
            continue
        if a in ("-o", "-MT", "-MF"):
            skip = True
            continue
        if a in ("-c", "-MD") or a == hits[0]["file"] or a.endswith(suffix):
            continue
        keep.append(a)
    return keep


def link_vars(bdir, target):
    lines = open(os.path.join(bdir, "build.ninja")).read().split("\n")
    starts = [i for i, l in enumerate(lines) if l.startswith(f"build {target}:") or l.startswith(f"build {target} ")]
    if len(starts) != 1:
        sys.exit(f"expected exactly one build statement for {target}, got {len(starts)}")
    vals = {}
    for l in lines[starts[0] + 1:]:
        if not l.startswith("  "):
            break
        k, _, v = l.strip().partition(" = ")
        vals[k] = v
    for k in ("FLAGS", "LINK_FLAGS", "LINK_LIBRARIES"):
        if k not in vals:
            sys.exit(f"{target}'s link statement has no {k}")
    out = shlex.split(vals["LINK_FLAGS"])
    # Drop `-Xlinker --dependency-file=...`: it names ninja's own depfile for the real target.
    cleaned, i = [], 0
    while i < len(out):
        if out[i] == "-Xlinker" and i + 1 < len(out) and out[i + 1].startswith("--dependency-file="):
            i += 2
            continue
        cleaned.append(out[i])
        i += 1
    return shlex.split(vals["FLAGS"]) + ["--"] + cleaned + ["--"] + shlex.split(vals["LINK_LIBRARIES"])


def main():
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in ("compile", "link"):
        sys.exit(__doc__)
    mode, bdir, what = sys.argv[1:4]
    if mode == "compile":
        words = compile_cmd(bdir, what, sys.argv[4] if len(sys.argv) == 5 else None)
    else:
        words = link_vars(bdir, what)
    sys.stdout.write("\0".join(words) + "\0")


if __name__ == "__main__":
    main()
