#!/usr/bin/env python3
"""The pinned historical replay runtime: materialise it, and prove a directory IS it.

WHY THIS EXISTS. `replay/` moved onto the `@aztec-labs/*` 6.0.0 packages (d50bb03, a8b8efc;
adopted by the operator on 2026-11-26, see DRIFT.md D36). The Live-Chain-Replay floors replay
fixtures that were captured from node-5.2.0 testnet nodes, and the v6 schemas cannot read them:
v6's `BlockHeader` consumes four bytes fewer than v5's, so the very first prestate header a fixture
carries dies with "greater or equal to field modulus" (measured 2026-11-27). The operator's
decision is that the floors keep guarding that committed v5 corpus, on the runtime that wrote it,
and only the follower's runtime moves -- the arrangement blocktracer already uses for its own 42
Aztec fixtures (`aztec-avm-runtime-historical` in its flake.nix).

So the floors run against `pins.json` -> `historical_runtimes.replay_v5`: one commit of THIS
repository, declared there and nowhere else. This tool is the only thing that turns that
declaration into a directory, and the only thing that says whether a directory is it.

  historical_replay.py materialize [--name replay_v5]
      Make the directory if it is missing or does not verify: `git archive` of the declared commit
      (fetching that one commit from `origin` if a shallow checkout lacks it), then `npm ci` in its
      `replay/` from the commit's OWN lockfile. The result is reproducible: same commit, same
      lockfile, same install. Prints the `verify` report of what it produced.

  historical_replay.py verify [--name replay_v5] [--expect-commit SHA] [--tamper PATH]
      Read-only. Prints `key value` lines and exits non-zero on any problem. It does NOT trust the
      directory's own stamp: every blob the commit tracks is re-hashed from disk and compared with
      the object store, and the runtime source directories may hold nothing the commit does not.
      `--expect-commit` and `--tamper` exist for the negative controls in
      `verification/lib_historical_replay.sh`: the first makes the verifier compare against a
      commit that is not the declared one, the second makes it hash one file as if a byte had
      changed. Both must turn the verdict red, or the green verdict is not evidence.

  historical_replay.py path [--name replay_v5]
      Print the directory, nothing else (for recipes).

The directory is `$AZTEC_HISTORICAL_REPLAY_DIR` if set, else
`~/.cache/aztec-historical-replay/<short>-<repo key>`. The repo key is a hash of this checkout's
path because the materialised tree carries two TOOL symlinks back into it (below), and two
workspaces must not share a directory whose symlinks point into only one of them. Never `$TMPDIR`:
on the campaign's Linux host that is a quota-limited tmpfs (see `lib_l0_node_client.sh`).

THE TWO TOOL SYMLINKS, AND WHY THEY ARE NOT PART OF THE SUBJECT. The historical
`replay/tools/build_browser_bundle.mjs` finds esbuild at `<repo>/spike/node_modules/.bin/esbuild`
or `<repo>/diffsim/node_modules/.bin/esbuild`. esbuild is the bundler, not the runtime under test,
so `spike/node_modules` and `diffsim/node_modules` are linked to this checkout's installs when
those exist. Every other byte the floors execute comes from the declared commit or from the
declared commit's own lockfile, and `verify` asserts exactly that.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The directories whose code the floors EXECUTE. `verify` refuses any file in them that the commit
# does not track: a planted module there would be imported by the floors and nothing else would
# notice. Build outputs (`replay/dist-browser/`) and installs (`node_modules/`) are outside them.
RUNTIME_SOURCE_DIRS = (
    "replay/src",
    "replay/tools",
    "replay/browser-demo",
    "ct-host/src",
    "node-host/src",
    "browser/src",
)

# Tool installs linked from this checkout (see the module docstring). Linked only if present.
TOOL_LINKS = ("spike/node_modules", "diffsim/node_modules")

STAMP = ".historical-replay.json"


class Fatal(Exception):
    pass


def git(*args: str, check: bool = True, input_bytes: bytes | None = None) -> bytes:
    res = subprocess.run(
        ["git", "-C", REPO, *args], capture_output=True, input=input_bytes
    )
    if check and res.returncode != 0:
        raise Fatal("git %s failed: %s" % (" ".join(args), res.stderr.decode().strip()))
    return res.stdout


def load_decl(name: str) -> dict:
    with open(os.path.join(REPO, "pins.json"), encoding="utf-8") as fh:
        pins = json.load(fh)
    runtimes = pins.get("historical_runtimes") or {}
    decl = runtimes.get(name)
    if not decl or name.startswith("_"):
        raise Fatal("pins.json declares no historical_runtimes.%s" % name)
    commit = decl.get("commit", "")
    if len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise Fatal("pins.json historical_runtimes.%s.commit is not a full SHA: %r" % (name, commit))
    role = decl.get("npm_pin", "")
    npm = pins.get("npm", {})
    if role not in npm or role.startswith("_"):
        raise Fatal("pins.json historical_runtimes.%s names undeclared npm pin %r" % (name, role))
    decl = dict(decl)
    decl["_name"] = name
    decl["_npm_version"] = npm[role]["version"]
    decl["_exceptions"] = {
        k: v["version"] for k, v in pins.get("npm_exceptions", {}).items() if not k.startswith("_")
    }
    return decl


def target_dir(decl: dict) -> str:
    override = os.environ.get("AZTEC_HISTORICAL_REPLAY_DIR")
    if override:
        return os.path.abspath(override)
    key = hashlib.sha256(os.path.realpath(REPO).encode()).hexdigest()[:8]
    return os.path.join(
        os.path.expanduser("~/.cache/aztec-historical-replay"),
        "%s-%s-%s" % (decl["_name"], decl["commit"][:10], key),
    )


def have_commit(commit: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", REPO, "cat-file", "-e", commit + "^{commit}"], capture_output=True
        ).returncode
        == 0
    )


def ensure_commit(commit: str) -> None:
    # The commit AND its parent: `lib_historical_replay.sh`'s wrong-commit control verifies the
    # same directory against `<commit>^`, and in a shallow object store the commit has no parent
    # (`<commit>^` does not resolve), so a depth-1 fetch would leave every floor dying on that
    # control rather than running.
    if have_commit(commit) and have_commit(commit + "^"):
        return
    # A shallow CI checkout (actions/checkout's default depth 1) does not carry the commit. Fetch
    # exactly that commit and its parent from origin; GitHub serves a reachable SHA by name.
    print("historical_replay: %s or its parent is not in the object store; fetching both from "
          "origin" % commit, file=sys.stderr)
    git("fetch", "--no-tags", "--depth=2", "origin", commit)
    if not (have_commit(commit) and have_commit(commit + "^")):
        raise Fatal("%s or its parent is still not in the object store after fetching it from "
                    "origin" % commit)


def tracked_entries(commit: str) -> list[tuple[str, str, str]]:
    """(mode, sha, path) for every blob and symlink the commit tracks."""
    out = git("ls-tree", "-r", "-z", "--full-tree", commit).decode()
    entries = []
    for rec in out.split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, kind, sha = meta.split()
        if kind != "blob":
            continue  # a submodule (commit) has no bytes to compare
        entries.append((mode, sha, path))
    return entries


def blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def verify(decl: dict, expect_commit: str | None = None, tamper: str | None = None) -> list[str]:
    """Print the report; return the problems."""
    commit = expect_commit or decl["commit"]
    d = target_dir(decl)
    problems: list[str] = []
    lines: list[tuple[str, str]] = [("declared", decl["commit"]), ("compared_against", commit),
                                    ("dir", d)]

    def report() -> list[str]:
        for k, v in lines:
            print("%s %s" % (k, v))
        for p in problems:
            print("problem %s" % p)
        return problems

    if not os.path.isdir(d):
        problems.append("not materialised at %s" % d)
        return report()
    stamp_path = os.path.join(d, STAMP)
    try:
        with open(stamp_path, encoding="utf-8") as fh:
            stamp = json.load(fh)
    except (OSError, ValueError):
        stamp = {}
    lines.append(("stamp_commit", stamp.get("commit", "<none>")))
    if stamp.get("commit") != commit:
        problems.append("the directory was materialised from %s, not %s"
                        % (stamp.get("commit", "<no stamp>"), commit))
    if not have_commit(commit):
        problems.append("%s is not in the object store (Remedy: just materialize-historical-replay)"
                        % commit)
        return report()

    entries = tracked_entries(commit)
    lines.append(("tracked_files", str(len(entries))))
    mismatched = []
    tracked_paths = set()
    for mode, sha, path in entries:
        tracked_paths.add(path)
        full = os.path.join(d, path)
        try:
            if mode == "120000":
                data = os.readlink(full).encode()
            else:
                with open(full, "rb") as fh:
                    data = fh.read()
        except OSError:
            mismatched.append(path + " (missing)")
            continue
        if tamper is not None and path == tamper:
            data = data + b"\0"
        if blob_sha(data) != sha:
            mismatched.append(path)
    lines.append(("mismatched_files", str(len(mismatched))))
    if mismatched:
        problems.append("%d file(s) differ from %s: %s"
                        % (len(mismatched), commit[:10], ", ".join(mismatched[:5])))
    if tamper is not None and tamper not in tracked_paths:
        problems.append("--tamper names %s, which the commit does not track" % tamper)

    extra = []
    for sub in RUNTIME_SOURCE_DIRS:
        root = os.path.join(d, sub)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [n for n in dirnames if n != "node_modules"]
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), d)
                if rel not in tracked_paths:
                    extra.append(rel)
    lines.append(("untracked_runtime_files", str(len(extra))))
    if extra:
        problems.append("the runtime source directories hold %d file(s) %s does not track: %s"
                        % (len(extra), commit[:10], ", ".join(sorted(extra)[:5])))

    # The INSTALL is the declared pin, read from what is installed rather than from the lockfile.
    installed = {}
    scope_dir = os.path.join(d, "replay/node_modules/@aztec")
    if os.path.isdir(scope_dir):
        for pkg in sorted(os.listdir(scope_dir)):
            try:
                with open(os.path.join(scope_dir, pkg, "package.json"), encoding="utf-8") as fh:
                    installed["@aztec/" + pkg] = json.load(fh).get("version", "")
            except (OSError, ValueError):
                installed["@aztec/" + pkg] = "<unreadable>"
    lines.append(("installed_aztec_packages", str(len(installed))))
    lines.append(("installed_stdlib", installed.get("@aztec/stdlib", "<absent>")))
    lines.append(("npm_pin", "%s=%s" % (decl["npm_pin"], decl["_npm_version"])))
    if "@aztec/stdlib" not in installed:
        problems.append("replay/node_modules/@aztec/stdlib is not installed (Remedy: just "
                        "materialize-historical-replay)")
    for name, ver in installed.items():
        want = decl["_exceptions"].get(name, decl["_npm_version"])
        if ver != want:
            problems.append("installed %s is %s, pins.json npm.%s says %s"
                            % (name, ver, decl["npm_pin"], want))
    if os.path.isdir(os.path.join(d, "replay/node_modules/@aztec-labs")):
        problems.append("replay/node_modules carries @aztec-labs/*: this is not the v5 runtime")
    return report()


def materialize(decl: dict) -> int:
    d = target_dir(decl)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    lock_path = d + ".lock"
    with open(lock_path, "w") as lockfh:
        fcntl.flock(lockfh, fcntl.LOCK_EX)
        ensure_commit(decl["commit"])
        with open(os.devnull, "w") as devnull:
            saved = sys.stdout
            sys.stdout = devnull
            try:
                already = not verify(decl)
            finally:
                sys.stdout = saved
        if already:
            print("historical_replay: %s already verifies; nothing to do" % d, file=sys.stderr)
            return 1 if verify(decl) else 0
        tmp = d + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
        archive = git("archive", "--format=tar", decl["commit"])
        res = subprocess.run(["tar", "-x", "-C", tmp], input=archive, capture_output=True)
        if res.returncode != 0:
            raise Fatal("tar -x failed: %s" % res.stderr.decode().strip())
        for link in TOOL_LINKS:
            src = os.path.join(REPO, link)
            if os.path.exists(src):
                dst = os.path.join(tmp, link)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.symlink(os.path.realpath(src), dst)
        # `npm ci` from the commit's own lockfile: the install is a function of the commit.
        res = subprocess.run(
            ["npm", "ci", "--no-audit", "--no-fund"], cwd=os.path.join(tmp, "replay")
        )
        if res.returncode != 0:
            raise Fatal("npm ci in the historical replay/ failed (rc %d)" % res.returncode)
        with open(os.path.join(tmp, STAMP), "w", encoding="utf-8") as fh:
            json.dump({"name": decl["_name"], "commit": decl["commit"],
                       "lockfile_sha256": hashlib.sha256(
                           open(os.path.join(tmp, "replay/package-lock.json"), "rb").read()
                       ).hexdigest()}, fh, indent=2)
            fh.write("\n")
        shutil.rmtree(d, ignore_errors=True)
        os.rename(tmp, d)
    return 1 if verify(decl) else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["materialize", "verify", "path"])
    ap.add_argument("--name", default="replay_v5")
    ap.add_argument("--expect-commit")
    ap.add_argument("--tamper")
    args = ap.parse_args(argv)
    decl = load_decl(args.name)
    if args.action == "path":
        print(target_dir(decl))
        return 0
    if args.action == "materialize":
        return materialize(decl)
    return 1 if verify(decl, args.expect_commit, args.tamper) else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fatal as exc:
        print("historical_replay.py: %s" % exc, file=sys.stderr)
        sys.exit(2)
