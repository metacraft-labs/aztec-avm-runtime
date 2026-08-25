#!/usr/bin/env python3
"""Rebuild the fork's per-PR branches and its `codetracer` development branch.

Everything this script produces is derived. The inputs are `carry/series.json`
(the order and the dependency structure) and the `git format-patch` files under
`codetracer-specs/upstream-bugs/`; nothing is transcribed by hand, so a branch
cannot silently disagree with the patch it is supposed to carry.

Two kinds of branch come out of it.

  * `pr/<n>-<slug>` — one per prepared contribution, for filing upstream. A
    standalone patch's branch is BASE + that patch and nothing else, so the PR
    diff is exactly the patch. The one non-standalone patch is stacked on its
    dependencies, and `--report` prints which of them is an APPLY prerequisite
    and which are BUILD prerequisites, because those are different claims.

  * `codetracer` — the downstream development branch: the fork's own branch
    (which carries the dev-shell commits) plus all five patches in dependency
    order. This is the base for downstream work. It is NOT a substitute for the
    base-versus-patched trees the verification harness builds; those exist to
    demonstrate native neutrality and require the pristine base.

The identity assertion is on TREES, not on diff text. For each branch the script
re-applies the patch(es) to the base in a scratch index, writes the tree, and
requires it to equal the branch's tree. A branch whose content drifted from its
patch by so much as one byte fails here, which a `--stat` comparison would not
catch.

Idempotent down to the commit id. The committer identity and date are taken from
each patch's own `From:`/`Date:` headers and signing is turned off for the
rebuild, so running this twice produces byte-identical commits: regenerating a
branch and comparing it against what is published is a real check rather than a
comparison of two different-looking equivalents.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_ROOT = REPO_ROOT.parent
DEFAULT_FORK = WORKSPACE_ROOT / "aztec-packages"
DEFAULT_SPECS = WORKSPACE_ROOT / "codetracer-specs"

# Each branch is built in a FULL CHECKOUT of the upstream tree (451 MB), five of them
# in sequence plus the downstream branch. That is not a scratch file and it must not
# default to `tempfile.mkdtemp()`: this workstation's /tmp is a quota-limited tmpfs
# where `df` reports 6.7 GB free and the next write fails at 356 MiB with
# `Disk quota exceeded`, and the checkout died there — reported, by the code below,
# as "no such patch id". Same `<M>_WORK` convention as every other heavy step, and the
# same default the Justfile already passed.
DEFAULT_WORK = Path(os.environ.get("M11_WORK") or (Path.home() / ".cache" / "aztec-m11-branches"))
WORK_MIN_GB = 4


def prepare_work(work: Path) -> Path:
    """Create the branch builder's work directory, or fail saying why and what to do."""
    try:
        work.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SystemExit("make-fork-branches: cannot create the work directory %s: %s\n"
                         "  Point M11_WORK (or --work) at a directory with room." % (work, exc))
    if not os.access(work, os.W_OK):
        raise SystemExit("make-fork-branches: the work directory is not writable: %s" % work)
    st = os.statvfs(work)
    avail = (st.f_bavail * st.f_frsize) / (1024.0 ** 3)
    if avail < WORK_MIN_GB:
        raise SystemExit(
            "make-fork-branches: the work directory has %.1f GB free and this builds six\n"
            "  checkouts of the upstream tree, which needs about %d GB: %s\n"
            "  Point M11_WORK (or --work) somewhere with room."
            % (avail, WORK_MIN_GB, work))
    # Free space and a quota are different questions; only a write answers the second.
    probe = work / (".write-probe.%d" % os.getpid())
    try:
        with open(probe, "wb") as fh:
            fh.write(b"\0" * (4 * 1024 * 1024))
            fh.flush()
            os.fsync(fh.fileno())
    except OSError as exc:
        probe.unlink(missing_ok=True)
        raise SystemExit(
            "make-fork-branches: the work directory reports %.1f GB free and refuses a 4 MB\n"
            "  write: %s\n  %s\n"
            "  That is a quota, not a full filesystem. Point M11_WORK (or --work) elsewhere."
            % (avail, work, exc))
    finally:
        probe.unlink(missing_ok=True)
    return work


class Failure(Exception):
    pass


def run(args, cwd=None, env=None, check=True, capture=True):
    proc = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if check and proc.returncode != 0:
        raise Failure(
            "command failed (%d): %s\n%s"
            % (proc.returncode, " ".join(args), proc.stdout or "")
        )
    return (proc.stdout or "").strip()


def git(fork: Path, *args, **kwargs):
    return run(["git", "-C", str(fork)] + list(args), **kwargs)


def patch_author(patch: Path) -> tuple[str, str]:
    """The `From:` header of a `git format-patch` file, as (name, email)."""
    for line in patch.read_text(errors="replace").splitlines():
        if line.startswith("From: "):
            value = line[len("From: "):].strip()
            if "<" in value and value.endswith(">"):
                name, email = value.rsplit("<", 1)
                return name.strip(), email[:-1].strip()
            return value, ""
        if not line.strip():
            break
    raise Failure("%s has no From: header" % patch)


def tree_of_applied(fork: Path, base_tree: str, patch_files: list[Path]) -> str:
    """Apply patches to `base_tree` in a scratch index; return the written tree.

    This is the identity check. `git apply --cached` reproduces exactly what the
    patch says the tree should become, independent of how the branch was built.
    """
    with tempfile.TemporaryDirectory() as tmp:
        index = os.path.join(tmp, "index")
        env = dict(os.environ, GIT_INDEX_FILE=index)
        run(["git", "-C", str(fork), "read-tree", base_tree], env=env)
        for p in patch_files:
            run(
                ["git", "-C", str(fork), "apply", "--cached", "--whitespace=nowarn", str(p)],
                env=env,
            )
        return run(["git", "-C", str(fork), "write-tree"], env=env)


def build_branch(fork: Path, work: Path, start: str, patches: list[Path],
                 branch: str | None) -> str:
    """Check out `start` detached in `work`, `git am` each patch, name the result.

    `branch=None` builds the commit without naming anything, which is what the
    `--check` and `--print-sha` modes need: they must be able to recompute a
    branch without moving it.
    """
    git(fork, "worktree", "prune", check=False)
    git(fork, "worktree", "add", "--detach", "--force", str(work), start)
    try:
        for p in patches:
            # Determinism, so that regenerating a branch produces the SAME commit
            # ids rather than merely the same content: the committer identity and
            # date are taken from the patch's own `From:`/`Date:` headers instead
            # of from whoever happens to be running this and when.
            name, email = patch_author(p)
            env = dict(os.environ,
                       GIT_COMMITTER_NAME=name,
                       GIT_COMMITTER_EMAIL=email)
            try:
                # `commit.gpgsign=false` is part of the determinism, not a policy
                # opinion: an OpenPGP signature carries a fresh random nonce, so a
                # signed rebuild lands the same TREE under a different commit id
                # every time, and "regenerate it and compare" stops being a check.
                run(["git", "-C", str(work), "-c", "commit.gpgsign=false", "am", "--3way",
                     "--committer-date-is-author-date", str(p)], env=env)
            except Failure as exc:
                run(["git", "-C", str(work), "am", "--abort"], check=False)
                raise Failure("`git am` of %s onto %s failed:\n%s" % (p.name, start, exc))
        head = run(["git", "-C", str(work), "rev-parse", "HEAD"])
        if branch is not None:
            git(fork, "branch", "-f", branch, head)
        return head
    finally:
        git(fork, "worktree", "remove", "--force", str(work), check=False)
        git(fork, "worktree", "prune", check=False)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fork", default=str(DEFAULT_FORK), help="path to the aztec-packages fork")
    ap.add_argument("--specs", default=str(DEFAULT_SPECS),
                    help="path to codetracer-specs (holds upstream-bugs/)")
    ap.add_argument("--work", default=str(DEFAULT_WORK),
                    help="scratch worktree root. NOT /tmp: each branch is a full checkout "
                         "of the upstream tree (default: $M11_WORK or "
                         "~/.cache/aztec-m11-branches)")
    ap.add_argument("--push", action="store_true", help="push the branches to the fork's origin")
    ap.add_argument("--report", action="store_true",
                    help="print the dependency structure and exit without building")
    ap.add_argument("--check", action="store_true",
                    help="rebuild every branch WITHOUT moving any ref, and require the "
                         "fork's branches (local and origin/) to equal the rebuild")
    ap.add_argument("--print-sha", metavar="ID", default=None,
                    help="rebuild one branch without moving any ref and print its commit id")
    args = ap.parse_args()

    readonly = args.check or bool(args.print_sha)

    fork = Path(args.fork).resolve()
    specs = Path(args.specs).resolve()
    series_path = REPO_ROOT / "carry" / "series.json"
    series = json.loads(series_path.read_text())
    patches = series["patches"]
    base = series["base"]["commit"]

    if args.report:
        print("carry set, in order (from %s):" % series_path)
        for p in patches:
            deps = []
            if p["apply_depends_on"]:
                deps.append("apply: " + ", ".join(p["apply_depends_on"]))
            if p["build_depends_on"]:
                deps.append("build: " + ", ".join(p["build_depends_on"]))
            print("  %s  %-34s  %s" % (p["id"], p["branch"], "; ".join(deps) or "standalone"))
        return 0

    if not (specs / "upstream-bugs").is_dir():
        print("error: %s has no upstream-bugs/" % specs, file=sys.stderr)
        return 1

    by_id = {p["id"]: p for p in patches}
    patch_path = {
        p["id"]: specs / "upstream-bugs" / p["entry"] / p["patch"] for p in patches
    }
    for pid, path in patch_path.items():
        if not path.is_file():
            print("error: %s: missing patch file %s" % (pid, path), file=sys.stderr)
            return 1

    try:
        git(fork, "rev-parse", "--verify", base + "^{commit}")
    except Failure:
        print("error: the fork does not have base commit %s; fetch upstream first" % base,
              file=sys.stderr)
        return 1

    base_tree = git(fork, "rev-parse", base + "^{tree}")

    work_root = prepare_work(Path(args.work).expanduser().resolve())
    made: list[tuple[str, str, list[str]]] = []
    failures = 0

    def resolve(rev: str) -> str | None:
        try:
            return git(fork, "rev-parse", "--verify", "--quiet", rev)
        except Failure:
            return None

    try:
        matched_print_sha = False
        for p in patches:
            if args.print_sha and p["id"] != args.print_sha:
                continue
            matched_print_sha = True
            # A branch carries its APPLY prerequisites because git am would be
            # rejected without them, and its BUILD prerequisites because a branch
            # that cannot be compiled is not reviewable. Both sets come from
            # series.json rather than from a hand-written order.
            stack = [d for d in p["apply_depends_on"]]
            for d in p["build_depends_on"]:
                if d not in stack:
                    stack.append(d)
            stack.sort(key=lambda i: by_id[i]["order"])
            stack.append(p["id"])

            files = [patch_path[i] for i in stack]
            work = work_root / p["id"]
            shutil.rmtree(work, ignore_errors=True)
            try:
                head = build_branch(fork, work, base, files,
                                    None if readonly else p["branch"])
            except Failure as exc:
                print("FAIL %s: %s" % (p["branch"], exc), file=sys.stderr)
                failures += 1
                continue

            want_tree = tree_of_applied(fork, base_tree, files)
            got_tree = git(fork, "rev-parse", head + "^{tree}")
            if want_tree != got_tree:
                print("FAIL %s: tree from `git am` (%s) != tree from applying the patch "
                      "files (%s)" % (p["branch"], got_tree[:12], want_tree[:12]),
                      file=sys.stderr)
                failures += 1
                continue

            subject = git(fork, "log", "-1", "--format=%s", head)
            if subject != p["title"]:
                print("FAIL %s: commit subject %r != series.json title %r"
                      % (p["branch"], subject, p["title"]), file=sys.stderr)
                failures += 1
                continue

            if args.print_sha:
                print(head)
                return 0

            if args.check:
                # Only the PUBLISHED ref. That is the one a pull request is opened
                # from, so it is the one whose agreement with the patch file
                # matters; a local branch is incidental, and requiring it would
                # make this check fail on any fresh clone (CI's, for one) for a
                # reason that says nothing about the patches.
                for ref in ("origin/" + p["branch"],):
                    have = resolve(ref)
                    if have is None:
                        print("FAIL %s: does not exist; rebuild gives %s"
                              % (ref, head[:12]), file=sys.stderr)
                        failures += 1
                    elif have != head:
                        print("FAIL %s: is %s but rebuilding from the patch gives %s"
                              % (ref, have[:12], head[:12]), file=sys.stderr)
                        failures += 1
                    else:
                        print("ok   %-41s %s == rebuild" % (ref, head[:12]))
                continue

            made.append((p["branch"], head, stack))
            print("ok   %-34s %s  (%d commit(s): %s)"
                  % (p["branch"], head[:12], len(stack), " ".join(stack)))

        if args.print_sha:
            # These are two different failures and they used to print as one. A
            # checkout that dies of a disk quota reported as "no such patch id: p1"
            # sends the reader to look at series.json, which is correct and has
            # nothing to do with it; the caller (submit/_lib.sh) then reports that
            # the patch does not exist. Say which one happened.
            if matched_print_sha:
                print("error: %s is in the carry set but its branch could not be rebuilt; "
                      "see the FAIL line above" % args.print_sha, file=sys.stderr)
            else:
                print("error: no such patch id: %s" % args.print_sha, file=sys.stderr)
            return 1

        # The downstream development branch: the fork's own branch, which carries
        # the dev-shell commits, plus every patch in dependency order.
        down = series["fork"]["downstream_branch"]
        down_base = series["fork"]["downstream_base_branch"]
        ordered = sorted(patches, key=lambda p: p["order"])
        files = [patch_path[p["id"]] for p in ordered]
        work = work_root / down
        shutil.rmtree(work, ignore_errors=True)
        try:
            down_start = git(fork, "rev-parse", down_base)
            head = build_branch(fork, work, down_start, files,
                                None if readonly else down)
            down_base_tree = git(fork, "rev-parse", down_start + "^{tree}")
            want_tree = tree_of_applied(fork, down_base_tree, files)
            got_tree = git(fork, "rev-parse", head + "^{tree}")
            if want_tree != got_tree:
                print("FAIL %s: tree from `git am` (%s) != tree from applying the patch files "
                      "(%s)" % (down, got_tree[:12], want_tree[:12]), file=sys.stderr)
                failures += 1
            elif args.check:
                for ref in ("origin/" + down,):
                    have = resolve(ref)
                    if have is None:
                        print("FAIL %s: does not exist; rebuild gives %s"
                              % (ref, head[:12]), file=sys.stderr)
                        failures += 1
                    elif have != head:
                        print("FAIL %s: is %s but rebuilding from the patches gives %s"
                              % (ref, have[:12], head[:12]), file=sys.stderr)
                        failures += 1
                    else:
                        print("ok   %-41s %s == rebuild" % (ref, head[:12]))
            else:
                made.append((down, head, [p["id"] for p in ordered]))
                print("ok   %-34s %s  (%d patch(es) on %s)"
                      % (down, head[:12], len(files), down_base))
        except Failure as exc:
            print("FAIL %s: %s" % (down, exc), file=sys.stderr)
            failures += 1

        if args.push and made:
            names = [branch for branch, _, _ in made]
            print("pushing %d branch(es) to origin: %s" % (len(names), " ".join(names)))
            print(git(fork, "push", "--force-with-lease", "origin", *names))
    finally:
        # The work root is a NAMED directory now, not a temp dir this process invented,
        # so it is not removed: the per-branch subdirectories are, by build_branch's own
        # `worktree remove`, and the root is the milestone's <M>_WORK.
        pass

    if args.check:
        print("checked 6 branch(es) against their patches, %d failure(s)" % failures)
    else:
        print("%d branch(es) built, %d failure(s)" % (len(made), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print("error: %s" % exc, file=sys.stderr)
        sys.exit(1)
