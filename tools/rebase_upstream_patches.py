#!/usr/bin/env python3
"""Replay the carry set onto upstream HEAD and report, per patch, what happened.

This is the rebase harness. Its job is to make the recurring cost of carrying
patches VISIBLE — a number that moves when upstream moves — rather than something
discovered during an emergency.

For each patch in `carry/series.json`, in order, against a fresh fetch of
upstream's own branch:

  applies       `git am` succeeded. The patch still fits.
  already       upstream already contains it. Reported for every patch, not only
                the ones marked accepted, because the interesting failure is a
                patch we still carry that upstream has silently taken, or one
                marked accepted that upstream does NOT have.
  CONFLICTS     `git am` was rejected. The conflicting paths are named, because
                "it broke" and "it broke on these three files" are different
                amounts of information at 3am.

Exit status is non-zero if any patch we still carry stops applying. A patch whose
ledger status is `accepted` and which upstream demonstrably contains is dropped
from the carry set here rather than conflicting — that is the whole point of
recording acceptance.
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

# The replay checks out the whole upstream tree. That is not a scratch file, it is a
# CHECKOUT, and it must not go to `tempfile.mkdtemp()`'s default: on this workstation
# `/tmp` is a 32 GB tmpfs shared with everything else, and the replay died there with
#   error: unable to write file yarn-project/sequencer-client/src/sequencer/sequencer.ts
# under a Python traceback that named neither the cause nor the remedy. Every other
# multi-hundred-megabyte step in this campaign takes a work directory under
# `~/.cache`; this one now does too, by the same `<M>_WORK` convention.
DEFAULT_WORK = Path(os.environ.get("M11_WORK") or (Path.home() / ".cache" / "aztec-m11-rebase"))
# Measured: the upstream tree at `next` is 451 MB checked out, and `git am --3way`
# rewrites files in place rather than doubling it. 2 GB is that with room for the
# index, the rerere cache and a second replay landing beside it.
WORK_MIN_GB = 2


def free_gb(path: Path) -> float:
    st = os.statvfs(path)
    return (st.f_bavail * st.f_frsize) / (1024.0 ** 3)


def prepare_work(work: Path) -> Path:
    """Create the replay's work directory, or fail saying why and what to do.

    A precondition, not an assertion: nothing after it can be evaluated, and the
    failure it replaces was a traceback whose last line was a `git worktree add`
    command line.
    """
    try:
        work.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SystemExit(
            "rebase-upstream-patches: cannot create the work directory %s: %s\n"
            "  Point M11_WORK (or --work) at a directory with room." % (work, exc))
    if not os.access(work, os.W_OK):
        raise SystemExit(
            "rebase-upstream-patches: the work directory is not writable: %s" % work)
    avail = free_gb(work)
    if avail < WORK_MIN_GB:
        raise SystemExit(
            "rebase-upstream-patches: the work directory has %.1f GB free and this replay\n"
            "  checks out the whole upstream tree, which needs about %d GB: %s\n"
            "  /tmp is usually a small tmpfs; point M11_WORK (or --work) somewhere with room."
            % (avail, WORK_MIN_GB, work))
    # FREE SPACE AND A QUOTA ARE DIFFERENT QUESTIONS, and on this workstation they give
    # different answers: `df /tmp` reports 6.7 GB free and the next write fails at
    # 356 MiB with `Disk quota exceeded`. `statvfs` cannot see that, so the check that
    # matters is a write. `require_work_dir` in verification/lib.sh has probed with
    # 4 MB since M9's review found the same tmpfs; this is the same probe.
    probe = work / (".write-probe.%d" % os.getpid())
    try:
        with open(probe, "wb") as fh:
            fh.write(b"\0" * (4 * 1024 * 1024))
            fh.flush()
            os.fsync(fh.fileno())
    except OSError as exc:
        probe.unlink(missing_ok=True)
        raise SystemExit(
            "rebase-upstream-patches: the work directory reports %.1f GB free and refuses a\n"
            "  4 MB write: %s\n"
            "  %s\n"
            "  That is a quota, not a full filesystem. Point M11_WORK (or --work) elsewhere."
            % (avail, work, exc))
    finally:
        probe.unlink(missing_ok=True)
    return work


def run(args, cwd=None, env=None, check=True):
    proc = subprocess.run(args, cwd=cwd, env=env, check=False, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and proc.returncode != 0:
        raise RuntimeError("command failed (%d): %s\n%s"
                           % (proc.returncode, " ".join(args), proc.stdout))
    return proc.returncode, (proc.stdout or "")


def already_applied(fork: Path, tip: str, patch: Path, work: Path | None = None) -> bool:
    """True if `tip` already contains this patch's change.

    Tested by reverse-applying it against the tip's tree in a scratch index: if
    the reverse application is clean, everything the patch adds is already there.

    The scratch index is a git index for the whole upstream tree — small next to a
    checkout but not nothing — and it goes under the caller's work directory for
    the same reason the checkout does.
    """
    with tempfile.TemporaryDirectory(dir=str(work) if work else None) as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"))
        run(["git", "-C", str(fork), "read-tree", tip + "^{tree}"], env=env)
        rc, _ = run(["git", "-C", str(fork), "apply", "--cached", "--reverse", "--check",
                     str(patch)], env=env, check=False)
        return rc == 0


def conflicting_paths(text: str) -> list[str]:
    paths = []
    for line in text.splitlines():
        line = line.strip()
        for marker in ("error: patch failed: ", "Auto-merging ", "CONFLICT (content): Merge conflict in "):
            if line.startswith(marker):
                p = line[len(marker):]
                p = p.split(":")[0]
                if marker.startswith("Auto-merging"):
                    continue
                if p not in paths:
                    paths.append(p)
    return paths


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fork", default=str(DEFAULT_FORK))
    ap.add_argument("--specs", default=str(DEFAULT_SPECS))
    ap.add_argument("--no-fetch", action="store_true",
                    help="use the upstream ref already in the repository")
    ap.add_argument("--onto", default=None,
                    help="rebase onto this rev instead of upstream's branch tip")
    ap.add_argument("--json", default=None, help="also write the report as JSON here")
    ap.add_argument("--work", default=str(DEFAULT_WORK),
                    help="work directory for the replay checkout (default: $M11_WORK or "
                         "~/.cache/aztec-m11-rebase). NOT /tmp: the replay checks out the "
                         "whole upstream tree.")
    args = ap.parse_args()

    work_root = prepare_work(Path(args.work).expanduser().resolve())

    fork = Path(args.fork).resolve()
    specs = Path(args.specs).resolve()
    series = json.loads((REPO_ROOT / "carry" / "series.json").read_text())
    upstream_branch = series["fork"]["upstream_branch"]
    base = series["base"]["commit"]

    if not args.no_fetch and not args.onto:
        print("fetching upstream/%s" % upstream_branch)
        rc, out = run(["git", "-C", str(fork), "fetch", "upstream", upstream_branch], check=False)
        if rc != 0:
            print("error: could not fetch upstream/%s:\n%s" % (upstream_branch, out),
                  file=sys.stderr)
            return 1

    tip = args.onto or ("upstream/" + upstream_branch)
    try:
        _, tip_sha = run(["git", "-C", str(fork), "rev-parse", "--verify", tip + "^{commit}"])
        tip_sha = tip_sha.strip()
    except RuntimeError:
        print("error: %s is not a commit in %s" % (tip, fork), file=sys.stderr)
        return 1

    _, distance = run(["git", "-C", str(fork), "rev-list", "--count", "%s..%s" % (base, tip_sha)])
    distance = distance.strip()
    _, tip_subject = run(["git", "-C", str(fork), "log", "-1", "--format=%h %ad %s",
                          "--date=short", tip_sha])

    print("carry set replayed onto %s" % tip)
    print("  tip:  %s" % tip_subject.strip())
    print("  base: %s (%s commits behind the tip)" % (series["base"]["short"], distance))
    print()

    report = {"tip": tip_sha, "tip_ref": tip, "base": base,
              "commits_since_base": int(distance), "patches": []}
    failures = 0
    work = Path(tempfile.mkdtemp(prefix="carry-rebase-", dir=str(work_root)))
    print("  work: %s (%.1f GB free)" % (work, free_gb(work_root)))
    try:
        run(["git", "-C", str(fork), "worktree", "prune"], check=False)
        rc, out = run(["git", "-C", str(fork), "worktree", "add", "--detach", "--force",
                       str(work), tip_sha], check=False)
        if rc != 0:
            # Say what happened and where, rather than raising the git command line
            # as a traceback. "unable to write file <path>" with 0.0 GB free beside
            # it is a diagnosis; a stack trace ending in `worktree add` is not.
            print("error: could not check the upstream tree out into %s (exit %d)\n"
                  "  %.1f GB free there now.\n%s" % (work, rc, free_gb(work_root), out),
                  file=sys.stderr)
            return 1
        broken: set[str] = set()
        for p in sorted(series["patches"], key=lambda p: p["order"]):
            blocked_by = [d for d in p["apply_depends_on"] if d in broken]
            if blocked_by:
                # Not counted as a second failure: it is the same failure. Saying
                # "5 also broke" when 1 broke and 5 needs 1 would inflate the
                # number this harness exists to report.
                print("%-4s %-34s blocked  by %s, which did not apply"
                      % (p["id"], p["branch"], ", ".join(blocked_by)))
                report["patches"].append({"id": p["id"], "result": "blocked",
                                          "blocked_by": blocked_by})
                broken.add(p["id"])
                continue
            patch = specs / "upstream-bugs" / p["entry"] / p["patch"]
            if not patch.is_file():
                print("%-4s %-34s MISSING PATCH FILE %s" % (p["id"], p["branch"], patch))
                report["patches"].append({"id": p["id"], "result": "missing"})
                broken.add(p["id"])
                failures += 1
                continue

            status = p["ledger"]["status"]
            if already_applied(fork, tip_sha, patch, work_root):
                verdict = "already"
                note = "upstream already contains it"
                if status != "accepted":
                    note += " — its ledger status is '%s'; update it" % status
                print("%-4s %-34s already  %s" % (p["id"], p["branch"], note))
                report["patches"].append({"id": p["id"], "result": verdict, "note": note})
                continue

            if status == "accepted":
                print("%-4s %-34s FAIL     ledger says accepted, but upstream does not "
                      "contain it" % (p["id"], p["branch"]))
                report["patches"].append({"id": p["id"], "result": "accepted-but-absent"})
                broken.add(p["id"])
                failures += 1
                continue

            rc, out = run(["git", "-C", str(work), "-c", "commit.gpgsign=false",
                           "am", "--3way", "--committer-date-is-author-date", str(patch)],
                          check=False)
            if rc == 0:
                print("%-4s %-34s applies" % (p["id"], p["branch"]))
                report["patches"].append({"id": p["id"], "result": "applies"})
            else:
                paths = conflicting_paths(out)
                run(["git", "-C", str(work), "am", "--abort"], check=False)
                print("%-4s %-34s CONFLICTS on %d file(s):" % (p["id"], p["branch"], len(paths)))
                for path in paths:
                    print("       %s" % path)
                if not paths:
                    print("       (no paths parsed; raw output follows)")
                    for line in out.splitlines()[:20]:
                        print("       | %s" % line)
                report["patches"].append({"id": p["id"], "result": "conflicts",
                                          "paths": paths, "output": out})
                broken.add(p["id"])
                failures += 1
                # The next patch is replayed against the tree WITHOUT this one, so
                # one broken patch does not report the whole rest of the set as
                # broken. One run tells you everything that stopped applying.
    finally:
        run(["git", "-C", str(fork), "worktree", "remove", "--force", str(work)], check=False)
        run(["git", "-C", str(fork), "worktree", "prune"], check=False)
        shutil.rmtree(work, ignore_errors=True)

    print()
    counts = {}
    for row in report["patches"]:
        counts[row["result"]] = counts.get(row["result"], 0) + 1
    print("%d patch(es): %s" % (len(report["patches"]),
                                ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items()))))
    report["failures"] = failures
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
        print("report: %s" % args.json)
    if failures:
        print("rebase-upstream-patches: %d patch(es) no longer apply to %s"
              % (failures, tip), file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
