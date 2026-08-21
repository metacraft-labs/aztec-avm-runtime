#!/usr/bin/env python3
"""Vendored-file provenance: the mapping, the headers, and the drift comparison.

PROVENANCE.md is the input, not the documentation. This module parses its
machine-readable tables and turns them into three things:

  map      one line per vendored file: where it came from and at which commit
  headers  write (or check) the provenance header in each vendored file
  drift    compare every vendored file against its upstream commit

Design rules, which a reviewer should hold this to:

  * Nothing here can pass by doing nothing. Every subcommand that finds zero
    files to act on exits non-zero: an empty mapping means PROVENANCE.md is
    broken, not that everything is fine.
  * The header is the ONLY edit these tools make to a vendored file, and the
    drift comparison strips it before comparing, so a header can never mask a
    content change.
  * Pin values are never written here. They come from pins.json.

Usage:
  provenance.py map
  provenance.py headers --check | --apply
  provenance.py drift
  provenance.py render-drift <outdir>     # regenerate drift/src from spike/src
  provenance.py compare <local> <upstream-path> <commit>
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FORK = os.path.join(os.path.dirname(REPO), "aztec-packages")
UPSTREAM_REPO = "AztecProtocol/aztec-packages"

BEGIN = "BEGIN VENDORED-PROVENANCE"
END = "END VENDORED-PROVENANCE"


class Fatal(Exception):
    pass


# --------------------------------------------------------------------------
# PROVENANCE.md parsing
# --------------------------------------------------------------------------


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def parse_table(doc: str, name: str) -> list[list[str]]:
    """Rows of the markdown pipe table between <!-- BEGIN:name --> markers."""
    m = re.search(
        r"<!--\s*BEGIN:%s\s*-->(.*?)<!--\s*END:%s\s*-->" % (name, name), doc, re.S
    )
    if not m:
        raise Fatal("PROVENANCE.md: no <!-- BEGIN:%s --> block" % name)
    rows = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not cells or all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
            continue  # separator row
        if cells[0] in ("id", "local", "class"):
            continue  # header row
        rows.append(cells)
    if not rows:
        raise Fatal("PROVENANCE.md: table '%s' has no rows" % name)
    return rows


@dataclass
class Entry:
    local: str
    upstream: str
    anchor: str
    commit: str
    licence: str
    inventory: str
    header: bool = True
    editclass: str = "none"
    kind: str = "vendored"
    tree: str = ""


@dataclass
class Model:
    entries: list[Entry] = field(default_factory=list)
    trees: list[dict] = field(default_factory=list)
    exempt: dict = field(default_factory=dict)
    edits: dict = field(default_factory=dict)
    editkind: dict = field(default_factory=dict)
    editclasses: dict = field(default_factory=dict)
    derived: list[dict] = field(default_factory=list)
    anchors: dict = field(default_factory=dict)


def load_pins() -> dict:
    pins = json.loads(_read(os.path.join(REPO, "pins.json")))
    anchors = {}
    for key, val in pins["anchors"].items():
        commit = val["commit"]
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise Fatal("pins.json: anchor %s commit is not a full sha1" % key)
        anchors[key] = commit
    if not anchors:
        raise Fatal("pins.json declares no anchors")
    return anchors


def git_tracked(prefix: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-files", "-z", "--", prefix],
        capture_output=True,
        check=True,
    ).stdout
    return sorted(p for p in out.decode().split("\0") if p)


def load_model() -> Model:
    doc = _read(os.path.join(REPO, "PROVENANCE.md"))
    m = Model(anchors=load_pins())

    for row in parse_table(doc, "exempt"):
        m.exempt[row[0]] = row[1]
    for row in parse_table(doc, "editclasses"):
        m.editclasses[row[0]] = row[1]
    for row in parse_table(doc, "edits"):
        if row[0] in m.edits:
            raise Fatal("PROVENANCE.md: duplicate edit row for %s" % row[0])
        if row[2] not in ("modified", "added"):
            raise Fatal(
                "PROVENANCE.md: edit row %s has kind %r; expected modified or added"
                % (row[0], row[2])
            )
        m.edits[row[0]] = row[1]
        m.editkind[row[0]] = row[2]
    for row in parse_table(doc, "derived"):
        m.derived.append(
            {"local": row[0], "from": row[1], "transformation": row[2], "why": row[3]}
        )

    def anchor_commit(anchor: str, where: str) -> str:
        if anchor not in m.anchors:
            raise Fatal("%s: anchor '%s' is not declared in pins.json" % (where, anchor))
        return m.anchors[anchor]

    for row in parse_table(doc, "trees"):
        tid, local, upstream, anchor, licence, inventory, count = row[:7]
        commit = anchor_commit(anchor, "PROVENANCE.md tree %s" % tid)
        files = git_tracked(local)
        m.trees.append(
            {
                "id": tid,
                "local": local,
                "declared": int(count),
                "actual": len(files),
            }
        )
        for f in files:
            rel = f[len(local) + 1 :]
            m.entries.append(
                Entry(
                    local=f,
                    upstream="%s/%s" % (upstream, rel),
                    anchor=anchor,
                    commit=commit,
                    licence=licence,
                    inventory=inventory,
                    tree=tid,
                )
            )

    for row in parse_table(doc, "files"):
        fid, local, upstream, anchor, licence, inventory = row[:6]
        commit = anchor_commit(anchor, "PROVENANCE.md file %s" % fid)
        m.entries.append(
            Entry(
                local=local,
                upstream=upstream,
                anchor=anchor,
                commit=commit,
                licence=licence,
                inventory=inventory,
                tree=fid,
            )
        )

    seen = set()
    derived_prefixes = [d["local"] + "/" for d in m.derived]
    for e in m.entries:
        if e.local in seen:
            raise Fatal("PROVENANCE.md maps %s twice" % e.local)
        seen.add(e.local)
        e.header = e.local not in m.exempt
        e.editclass = m.edits.get(e.local, "none")
        e.kind = "added" if m.editkind.get(e.local) == "added" else "vendored"
        if os.path.islink(os.path.join(REPO, e.local)):
            # A symlink is compared as a link, never as its target's content,
            # and can never carry a header: writing one would write THROUGH
            # the link and silently corrupt a different file.
            e.kind = "symlink"
            if e.local not in m.exempt:
                raise Fatal(
                    "%s is a symlink and must be listed in the header-exempt "
                    "table; writing a header would corrupt its target" % e.local
                )
        for d in m.derived:
            pfx = d["local"] + "/"
            if e.local.startswith(pfx):
                # Inherit "addedness" from the source tree: a file the source
                # tree added has no upstream counterpart in the derived tree
                # either, and its header must say so.
                src = d["from"] + "/" + e.local[len(pfx) :]
                if m.editkind.get(src) == "added":
                    e.kind = "added"
        if any(e.local.startswith(p) for p in derived_prefixes):
            # A derived tree is checked by regenerating it, not by comparing
            # each file to upstream. Recording a per-file edit there as well
            # would be two contradictory claims about the same file.
            if e.local in m.edits:
                raise Fatal(
                    "PROVENANCE.md: %s is inside a derived tree and also has a "
                    "recorded local edit; a derived tree is checked by "
                    "regeneration, so the edit row is a contradiction" % e.local
                )
            e.editclass = "derived"

    if not m.entries:
        raise Fatal("PROVENANCE.md produced an empty mapping")
    return m


# --------------------------------------------------------------------------
# Headers
# --------------------------------------------------------------------------

STYLES = {
    ".ts": "line//",
    ".hpp": "line//",
    ".cpp": "line//",
    ".rs": "line//",
    ".nr": "line//",
    ".pil": "line//",
    ".toml": "line#",
    ".yml": "line#",
    ".yaml": "line#",
    ".md": "html",
    ".mdx": "jsx",
}


def style_for(path: str) -> str:
    ext = os.path.splitext(path)[1]
    if ext not in STYLES:
        raise Fatal("no header style for %s (extension %r)" % (path, ext))
    return STYLES[ext]


def header_lines(e: Entry) -> list[str]:
    if e.kind == "added":
        # Not vendored. Saying so is the point: a header naming an upstream
        # path that does not exist would be worse than no header at all.
        return [
            "%s — generated by `just vendor-headers` (tools/provenance.py); do not hand-edit." % BEGIN,
            "ADDED HERE — this file has NO upstream counterpart.",
            "  upstream-repo:   %s" % UPSTREAM_REPO,
            "  upstream-path:   (none — added in this repo)",
            "  upstream-commit: %s (the surrounding tree's anchor)" % e.commit,
            "  licence:         %s" % e.licence,
            "  local-edits:     %s" % e.editclass,
            "  inventory:       REUSE-INVENTORY.md %s" % e.inventory,
            END,
        ]
    return [
        "%s — generated by `just vendor-headers` (tools/provenance.py); do not hand-edit." % BEGIN,
        "VENDORED — not our code. Re-vendor rather than editing here.",
        "  upstream-repo:   %s" % UPSTREAM_REPO,
        "  upstream-path:   %s" % e.upstream,
        "  upstream-commit: %s" % e.commit,
        "  licence:         %s" % e.licence,
        "  local-edits:     %s" % e.editclass,
        "  inventory:       REUSE-INVENTORY.md %s" % e.inventory,
        END,
    ]


def render_header(e: Entry) -> str:
    body = header_lines(e)
    style = style_for(e.local)
    if style == "line//":
        return "".join("// %s\n" % l for l in body) + "\n"
    if style == "line#":
        return "".join("# %s\n" % l for l in body) + "\n"
    # For block-comment formats the closer must sit on the END line: the
    # stripper deletes BEGIN..END inclusive, so a `-->` on its own line would
    # survive as content and corrupt the file.
    if style == "html":
        inner = "\n".join("     %s" % l for l in body[1:-1])
        return "<!-- %s\n%s\n     %s -->\n\n" % (body[0], inner, body[-1])
    if style == "jsx":
        inner = "\n".join("     %s" % l for l in body[1:-1])
        return "{/* %s\n%s\n     %s */}\n\n" % (body[0], inner, body[-1])
    raise Fatal("unknown style %s" % style)


def split_header(text: str) -> tuple[str, str]:
    """Return (prefix_that_must_precede_the_header, body_without_any_header)."""
    lines = text.splitlines(keepends=True)
    i = 0
    # YAML frontmatter must remain the first bytes of the file.
    if lines and lines[0].rstrip("\n") == "---":
        for j in range(1, len(lines)):
            if lines[j].rstrip("\n") == "---":
                i = j + 1
                break
    prefix = "".join(lines[:i])
    rest = lines[i:]
    # Drop an existing header, wherever in `rest` it starts.
    b = e_ = None
    for k, line in enumerate(rest):
        if b is None and BEGIN in line:
            b = k
        elif b is not None and END in line:
            e_ = k
            break
    if b is not None and e_ is not None:
        tail = rest[e_ + 1 :]
        # ...and the single blank line the writer puts after it. Exactly one:
        # stripping more would eat content and make the round trip lossy.
        if tail and tail[0].strip() == "":
            tail = tail[1:]
        rest = rest[:b] + tail
    elif b is not None or e_ is not None:
        raise Fatal("unbalanced provenance header")
    return prefix, "".join(rest)


def strip_header(text: str) -> str:
    prefix, body = split_header(text)
    return prefix + body


def apply_headers(m: Model, write: bool) -> list[str]:
    """Returns the list of files whose header is missing or wrong."""
    bad = []
    for e in m.entries:
        if not e.header or e.kind == "symlink":
            continue
        path = os.path.join(REPO, e.local)
        text = _read(path)
        prefix, body = split_header(text)
        want = prefix + render_header(e) + body
        if text != want:
            bad.append(e.local)
            if write:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(want)
    return bad


# --------------------------------------------------------------------------
# Drift
# --------------------------------------------------------------------------


def git_show(commit: str, path: str) -> bytes | None:
    r = subprocess.run(
        ["git", "-C", FORK, "show", "%s:%s" % (commit, path)], capture_output=True
    )
    return r.stdout if r.returncode == 0 else None


def local_bytes_without_header(local: str) -> bytes:
    path = os.path.join(REPO, local)
    if os.path.islink(path):
        # git stores a symlink's blob as the target path; compare like for like.
        return os.readlink(path).encode()
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw
    return strip_header(text).encode("utf-8")


def compare(e: Entry) -> str:
    """'identical' | 'differs' | 'missing-upstream'"""
    up = git_show(e.commit, e.upstream)
    if up is None:
        return "missing-upstream"
    return "identical" if up == local_bytes_without_header(e.local) else "differs"


# --------------------------------------------------------------------------
# The drift/ derivation — the recorded, reproducible re-pin transformation
# --------------------------------------------------------------------------

RENAME_METHODS = ("fromField", "fromBigInt", "fromNumber", "fromString")
RENAME_RE = re.compile(
    r"\bAztecAddress\.(%s)\b(?!Unsafe)" % "|".join(RENAME_METHODS)
)


def nightly_rename(text: str) -> str:
    return RENAME_RE.sub(lambda mo: "AztecAddress.%sUnsafe" % mo.group(1), text)


def render_drift(outdir: str) -> int:
    """Regenerate drift/src from spike/src, HEADER-STRIPPED.

    Provenance headers are written per tree, so a rendered file carries
    spike/'s header and the real drift/ file carries drift/'s. Stripping both
    sides is what makes the comparison about the transformation rather than
    about the annotation. Returns the number of files written.
    """
    src = os.path.join(REPO, "spike", "src")
    n = 0
    for root, _dirs, names in os.walk(src):
        for name in names:
            p = os.path.join(root, name)
            rel = os.path.relpath(p, src)
            dst = os.path.join(outdir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            raw = open(p, "rb").read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                open(dst, "wb").write(raw)
                n += 1
                continue
            open(dst, "w", encoding="utf-8").write(nightly_rename(strip_header(text)))
            n += 1
    if n == 0:
        raise Fatal("render-drift produced no files")
    return n


def check_derived(m: Model, outdir: str) -> list[str]:
    """Regenerate every derived tree and return the paths that disagree."""
    bad = []
    for d in m.derived:
        if d["local"] != "drift/src":
            raise Fatal(
                "no renderer for derived tree %r; add one before recording it" % d["local"]
            )
        render_drift(outdir)
        live = os.path.join(REPO, d["local"])
        rendered, actual = set(), set()
        for root, _dirs, names in os.walk(outdir):
            for name in names:
                rendered.add(os.path.relpath(os.path.join(root, name), outdir))
        for root, _dirs, names in os.walk(live):
            for name in names:
                actual.add(os.path.relpath(os.path.join(root, name), live))
        for rel in sorted(rendered ^ actual):
            bad.append("%s/%s (present on only one side)" % (d["local"], rel))
        for rel in sorted(rendered & actual):
            want = open(os.path.join(outdir, rel), "rb").read()
            got = local_bytes_without_header("%s/%s" % (d["local"], rel))
            if want != got:
                bad.append("%s/%s" % (d["local"], rel))
    return bad


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "render-drift":
        if len(argv) != 2:
            raise Fatal("render-drift needs an output directory")
        print(render_drift(argv[1]))
        return 0

    m = load_model()

    if cmd == "map":
        for e in m.entries:
            print(
                "\t".join(
                    [
                        e.local,
                        e.upstream,
                        e.commit,
                        e.anchor,
                        e.licence,
                        e.inventory,
                        "header" if e.header else "no-header",
                        e.editclass,
                        e.tree,
                    ]
                )
            )
        return 0

    if cmd == "counts":
        for t in m.trees:
            print("%s\t%s\t%d\t%d" % (t["id"], t["local"], t["declared"], t["actual"]))
        return 0

    if cmd == "classes":
        for name, reason in m.editclasses.items():
            print("%s\t%s" % (name, reason))
        return 0

    if cmd == "inventories":
        for i in sorted({e.inventory for e in m.entries}):
            print(i)
        return 0

    if cmd == "headers":
        write = "--apply" in argv
        check = "--check" in argv
        if write == check:
            raise Fatal("headers needs exactly one of --check / --apply")
        bad = apply_headers(m, write)
        if write:
            print("rewrote %d file(s)" % len(bad))
            return 0
        for b in bad:
            print("HEADER-WRONG\t%s" % b)
        return 1 if bad else 0

    if cmd == "drift":
        rows = 0
        for e in m.entries:
            if e.editclass == "derived":
                # Still checked — by `derived`, which regenerates the tree.
                # The upstream path is verified to exist all the same, so a
                # derived tree cannot hide a path that no longer exists.
                # A file the source tree ADDED has no upstream path here either.
                found = git_show(e.commit, e.upstream) is not None
                ok = (not found) if e.kind == "added" else found
                state = "derived" if ok else "missing-upstream"
                verdict = "OK" if ok else "BAD"
            elif e.kind == "added":
                state = compare(e)
                verdict = "OK" if state == "missing-upstream" else "BAD"
            else:
                state = compare(e)
                expected = "identical" if e.editclass == "none" else "differs"
                verdict = "OK" if state == expected else "BAD"
            print("%s\t%s\t%s\t%s\t%s" % (verdict, state, e.editclass, e.local, e.upstream))
            rows += 1
        if rows == 0:
            raise Fatal("drift compared nothing")
        return 0

    if cmd == "derived":
        if len(argv) != 2:
            raise Fatal("derived needs a scratch directory")
        bad = check_derived(m, argv[1])
        for b in bad:
            print("DERIVED-MISMATCH\t%s" % b)
        return 1 if bad else 0

    if cmd == "compare":
        if len(argv) != 4:
            raise Fatal("compare needs <local> <upstream-path> <commit>")
        e = Entry(
            local=argv[1],
            upstream=argv[2],
            anchor="-",
            commit=argv[3],
            licence="-",
            inventory="-",
        )
        print(compare(e))
        return 0

    raise Fatal("unknown subcommand %r" % cmd)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fatal as exc:
        print("provenance.py: %s" % exc, file=sys.stderr)
        sys.exit(2)
