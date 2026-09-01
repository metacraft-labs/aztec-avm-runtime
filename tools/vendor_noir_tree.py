#!/usr/bin/env python3
"""vendor_noir_tree.py — turn a Noir package tree that uses `git` dependencies into one a
virtual filesystem can compile.

    tools/vendor_noir_tree.py --entry <dir> --out <file.json> [--roots <dir> ...]

WHY THIS EXISTS, IN THE COMPILER'S OWN WORDS.

`compiler/wasm/src/vfs.rs` refuses a `git` dependency by name and says what to do instead:

    kind: "git-dependency-refused"
    "the dependency `sha256` is a GIT dependency (git = "https://github.com/noir-lang/sha256",
     tag = "v0.3.0"). A virtual filesystem cannot fetch it. Vendor it into the tree and depend
     on it by `path`, or resolve it before you build the tree."

So this script does exactly the remedy the refusal names: it walks the `path` dependency graph
from an entry package, follows every `git` dependency into a local clone, and emits a flat VFS
in which EVERY dependency is a `path`.

THE LAYOUT IS FLAT ON PURPOSE. Upstream's own relative paths (`../../../../aztec-nr/aztec`)
encode the directory depth of the aztec-packages monorepo, and reproducing that depth in a VFS
would make the tree's shape a function of where the sources happened to live. Every package is
placed at `<prefix>/<name>/` instead and every dependency line is rewritten to `../<name>` —
one rule, applied to every manifest, so a manifest that was NOT rewritten is visible as a
`git =` line surviving into the output rather than as a resolution failure three steps later.
The entry package is placed at `<entry-prefix>/` and its dependencies point at
`../<prefix>/<name>`.

WHAT IS COPIED, AND WHAT IS NOT. Each package contributes its `Nargo.toml` and every `.nr`
file under its `src/`, which is exactly the set `resolve_vfs` will read (see its `sources`
computation). A `Prover.toml`, a README, a test directory outside `src/` and a `target/` are
not part of the program and are not carried; carrying them would inflate the measured size with
bytes the compiler never opens.

THE OUTPUT is a JSON object `{ "<vfs path>": "<contents>" }` plus a sidecar
`<out>.manifest.json` recording, per package, where it came from and how many bytes it
contributed — so "398 files, N bytes" is a figure with a derivation rather than a number in a
document.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

MANIFEST = "Nargo.toml"


def die(msg: str) -> "None":
    print("vendor_noir_tree: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------------------
# Manifest reading. Deliberately a narrow regex reader rather than a TOML parser: the only
# thing this script must understand is the `[dependencies]` table's `path` and `git` keys,
# and it must REWRITE the file while preserving everything else byte for byte, which a
# round-trip through a TOML serialiser does not do.
# ---------------------------------------------------------------------------------------

DEP_LINE = re.compile(
    r"""^(?P<indent>[ \t]*)(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{(?P<body>[^}]*)\}\s*$"""
)
KEY_VALUE = re.compile(r"""(?P<key>[A-Za-z_]+)\s*=\s*"(?P<value>[^"]*)\"""")


def read_manifest(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    name = None
    ptype = None
    m = re.search(r"^\s*name\s*=\s*\"([^\"]+)\"", text, re.M)
    if m:
        name = m.group(1)
    m = re.search(r"^\s*type\s*=\s*\"([^\"]+)\"", text, re.M)
    if m:
        ptype = m.group(1)

    deps = []
    in_deps = False
    for lineno, line in enumerate(text.split("\n"), start=1):
        stripped = line.strip()
        if stripped.startswith("["):
            in_deps = stripped == "[dependencies]"
            continue
        if not in_deps or not stripped or stripped.startswith("#"):
            continue
        m = DEP_LINE.match(line)
        if not m:
            continue
        kv = dict((k.group("key"), k.group("value")) for k in KEY_VALUE.finditer(m.group("body")))
        deps.append(
            {
                "name": m.group("name"),
                "line": lineno,
                "raw": line,
                "path": kv.get("path"),
                "git": kv.get("git"),
                "tag": kv.get("tag"),
                "directory": kv.get("directory"),
            }
        )
    if not text.strip():
        die("%s is empty" % path)
    return {"text": text, "name": name, "type": ptype, "dependencies": deps}


def rewrite_manifest(manifest: dict, resolve_to: dict) -> str:
    """Replace every dependency line with a `path` pointing where `resolve_to` says."""
    lines = manifest["text"].split("\n")
    for dep in manifest["dependencies"]:
        target = resolve_to[dep["name"]]
        lines[dep["line"] - 1] = '%s = { path = "%s" }' % (dep["name"], target)
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------
# The walk.
# ---------------------------------------------------------------------------------------


def git_clone_dir(roots: list, git_url: str, tag: str | None) -> Path:
    """Where a `git` dependency has already been materialised on disk.

    This script does NOT clone. A vendoring step that reaches the network is a vendoring
    step whose output depends on when it ran; the caller materialises the clone (once) and
    names the directory holding it. `--roots` is searched for `<repo-name>`.
    """
    repo = git_url.rstrip("/").split("/")[-1]
    if repo.endswith(".git"):
        repo = repo[:-4]
    for root in roots:
        candidate = Path(root) / repo
        if (candidate / MANIFEST).is_file():
            return candidate
    die(
        "the git dependency %s (tag %s) is not on any --roots path; clone it first:\n"
        "    git clone --depth 1 --branch %s %s <root>/%s"
        % (git_url, tag, tag or "<tag>", git_url, repo)
    )


def collect(entry: Path, roots: list) -> tuple:
    """Breadth-first over the dependency graph. Returns (entry_pkg, {name: pkg})."""
    entry = entry.resolve()
    entry_manifest = read_manifest(entry / MANIFEST)
    if not entry_manifest["name"]:
        die("%s declares no [package] name" % (entry / MANIFEST))

    entry_pkg = {"dir": entry, "manifest": entry_manifest, "is_entry": True}
    by_name: dict = {}
    queue = [entry_pkg]

    while queue:
        pkg = queue.pop(0)
        for dep in pkg["manifest"]["dependencies"]:
            if dep["git"]:
                dep_dir = git_clone_dir(roots, dep["git"], dep["tag"])
                if dep["directory"]:
                    dep_dir = dep_dir / dep["directory"]
            elif dep["path"]:
                dep_dir = (pkg["dir"] / dep["path"]).resolve()
            else:
                die(
                    "%s declares `%s` with neither path nor git"
                    % (pkg["dir"] / MANIFEST, dep["name"])
                )
            if not (dep_dir / MANIFEST).is_file():
                die("%s: dependency `%s` has no %s at %s" % (pkg["dir"], dep["name"], MANIFEST, dep_dir))
            dep_manifest = read_manifest(dep_dir / MANIFEST)
            pkg_name = dep_manifest["name"] or dep["name"]
            existing = by_name.get(pkg_name)
            if existing:
                if existing["dir"] != dep_dir:
                    die(
                        "two different directories claim the package name `%s`: %s and %s"
                        % (pkg_name, existing["dir"], dep_dir)
                    )
                continue
            child = {"dir": dep_dir, "manifest": dep_manifest, "is_entry": False, "pkg_name": pkg_name}
            by_name[pkg_name] = child
            queue.append(child)

    return entry_pkg, by_name


def sources_of(pkg_dir: Path) -> list:
    src = pkg_dir / "src"
    if not src.is_dir():
        return []
    out = []
    for path in sorted(src.rglob("*.nr")):
        if path.is_file():
            out.append(path)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--entry", required=True, help="directory holding the entry package's Nargo.toml")
    ap.add_argument("--out", required=True, help="where to write the VFS JSON")
    ap.add_argument(
        "--roots",
        action="append",
        default=[],
        help="a directory holding materialised clones of git dependencies (repeatable)",
    )
    ap.add_argument("--entry-prefix", default="contract")
    ap.add_argument("--vendor-prefix", default="vendor")
    args = ap.parse_args()

    entry_pkg, by_name = collect(Path(args.entry), args.roots)

    # Where every package lands, keyed by the DEPENDENCY ALIAS each parent uses.
    def target_for(pkg, from_entry: bool) -> str:
        name = pkg["pkg_name"]
        return ("../%s/%s" % (args.vendor_prefix, name)) if from_entry else ("../%s" % name)

    def resolve_map(pkg) -> dict:
        out = {}
        for dep in pkg["manifest"]["dependencies"]:
            if dep["git"]:
                dep_dir = git_clone_dir(args.roots, dep["git"], dep["tag"])
                if dep["directory"]:
                    dep_dir = dep_dir / dep["directory"]
            else:
                dep_dir = (pkg["dir"] / dep["path"]).resolve()
            match = [p for p in by_name.values() if p["dir"] == dep_dir]
            if not match:
                die("internal: %s resolved nowhere" % dep_dir)
            out[dep["name"]] = target_for(match[0], from_entry=pkg["is_entry"])
        return out

    vfs: dict = {}
    records = []

    def place(pkg, prefix: str):
        rewritten = rewrite_manifest(pkg["manifest"], resolve_map(pkg))
        vfs["%s/%s" % (prefix, MANIFEST)] = rewritten
        n_bytes = len(rewritten.encode("utf-8"))
        n_files = 1
        for src in sources_of(pkg["dir"]):
            rel = src.relative_to(pkg["dir"]).as_posix()
            text = src.read_text(encoding="utf-8")
            vfs["%s/%s" % (prefix, rel)] = text
            n_bytes += len(text.encode("utf-8"))
            n_files += 1
        records.append(
            {
                "package": pkg["manifest"]["name"],
                "type": pkg["manifest"]["type"],
                "placed_at": prefix,
                "source_dir": str(pkg["dir"]),
                "files": n_files,
                "bytes": n_bytes,
                "git_deps_rewritten": [d["name"] for d in pkg["manifest"]["dependencies"] if d["git"]],
            }
        )

    place(entry_pkg, args.entry_prefix)
    for name in sorted(by_name):
        place(by_name[name], "%s/%s" % (args.vendor_prefix, name))

    # THE POST-CONDITION, asserted here rather than discovered by the compiler: no manifest in
    # the emitted tree may still carry a `git =` line. This is the whole point of the script,
    # so it refuses to write an output that does not have it.
    surviving = [
        p for p, text in vfs.items() if p.endswith(MANIFEST) and re.search(r"^\s*[^#\n]*\bgit\s*=", text, re.M)
    ]
    if surviving:
        die("git dependencies survived into the tree: %s" % ", ".join(sorted(surviving)))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(vfs, ensure_ascii=False, sort_keys=True)
    out.write_text(payload, encoding="utf-8")

    total_bytes = sum(len(v.encode("utf-8")) for v in vfs.values())
    sidecar = {
        "entry_package": entry_pkg["manifest"]["name"],
        "entry_type": entry_pkg["manifest"]["type"],
        "entry_dir": args.entry_prefix,
        "packages": len(records),
        "files": len(vfs),
        "source_bytes": total_bytes,
        "json_bytes": len(payload.encode("utf-8")),
        "per_package": records,
    }
    Path(str(out) + ".manifest.json").write_text(
        json.dumps(sidecar, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(
        "vendor_noir_tree: %d packages, %d files, %d source bytes -> %s"
        % (len(records), len(vfs), total_bytes, out)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
