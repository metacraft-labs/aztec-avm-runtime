#!/usr/bin/env python3
"""Where a Cargo workspace takes one dependency from, as cargo would read it.

    verification/_cargo_dep_source.py <workspace-dir> <dependency-name>

Prints exactly one line and exits 0:
    path <absolute-directory>          for `{ path = "…" }`, resolved against the workspace dir
    git <url> <rev>                    for `{ git = "…", rev = "…" }`
and exits 1 with a reason on stderr for anything else — a missing key, a `branch`/`tag` git
dependency (which names no single revision), or a path that does not exist. It never prints an
empty answer: a caller that runs `git -C "$dir"` on an empty string asks the CURRENT repository,
which is how a check once read this repository's HEAD as the writer's revision.

The dependency is looked up in `[workspace.dependencies]` first and `[dependencies]` second,
because that is where the Noir workspace declares its writer crates.
"""
import os
import sys
import tomllib


def main() -> int:
    ws, name = sys.argv[1], sys.argv[2]
    manifest = os.path.join(ws, "Cargo.toml")
    try:
        doc = tomllib.load(open(manifest, "rb"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"cannot read {manifest}: {e}", file=sys.stderr)
        return 1
    dep = doc.get("workspace", {}).get("dependencies", {}).get(name)
    if dep is None:
        dep = doc.get("dependencies", {}).get(name)
    if not isinstance(dep, dict):
        print(f"{manifest} declares no table for dependency {name!r}", file=sys.stderr)
        return 1
    if "path" in dep:
        d = os.path.realpath(os.path.join(ws, dep["path"]))
        if not os.path.isdir(d):
            print(f"{manifest} takes {name} from {dep['path']!r}, and {d} does not exist", file=sys.stderr)
            return 1
        print(f"path {d}")
        return 0
    if "git" in dep:
        rev = dep.get("rev")
        if not rev:
            print(f"{manifest} takes {name} from git without a rev (branch/tag name no single revision)",
                  file=sys.stderr)
            return 1
        print(f"git {dep['git']} {rev}")
        return 0
    print(f"{manifest} takes {name} from neither a path nor a git revision: {dep!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
