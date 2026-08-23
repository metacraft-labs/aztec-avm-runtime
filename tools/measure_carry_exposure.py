#!/usr/bin/env python3
"""Measure what carrying the whole series costs if upstream accepts none of it.

The spike's estimate was "roughly 80 lines of CMake plus one function-level rebase
risk in `hybrid_execution.cpp`". This replaces that with measurements, because an
estimate that is never checked becomes a number people quote.

Four things are measured, and each is a different kind of exposure:

  SIZE       How much diff there is, by file type. A big diff is not by itself a
             maintenance cost — a new file nobody else edits costs nothing to
             carry — so size is reported but is the weakest of the four.

  SURFACE    How much of the diff can conflict at all. A hunk in a file the patch
             CREATES has no conflict surface: upstream has no version of it to
             move underneath us. Only modified files count, and within them only
             the lines of context a three-way merge has to match.

  CHURN      How often upstream actually edits those files. Measured from
             upstream's own history over the twelve months before the pinned base,
             so it is a rate rather than a guess, and separately since the base so
             the current state is visible.

  EXPECTED   Churn x surface: the number of upstream commits per month that land
             in a file we modify. That is the population from which conflicts are
             drawn. It is an upper bound on conflicts, not a prediction of them —
             most commits touching a file do not touch our hunks — and it is
             reported as such.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_ROOT = REPO_ROOT.parent
DEFAULT_FORK = WORKSPACE_ROOT / "aztec-packages"
DEFAULT_SPECS = WORKSPACE_ROOT / "codetracer-specs"


def run(args, env=None, check=True):
    proc = subprocess.run(args, check=False, text=True, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and proc.returncode != 0:
        raise RuntimeError("command failed (%d): %s\n%s"
                           % (proc.returncode, " ".join(args), proc.stdout))
    return proc.stdout or ""


def categorise(path: str) -> str:
    name = os.path.basename(path)
    if name == "CMakeLists.txt" or path.endswith(".cmake") or name == "CMakePresets.json":
        return "cmake"
    if path.endswith((".cpp", ".hpp", ".c", ".h", ".tcc")):
        return "c++"
    if path.endswith((".sh", ".bash")):
        return "shell"
    return "other"


def parse_patch(patch: Path) -> dict:
    """What one `git format-patch` file does, per path.

    `new` / `deleted` / `renamed` come from the extended headers, which is the
    only reliable place: a rename that git detected has no +/- lines at all, and a
    new file has as many + lines as it has lines.
    """
    text = patch.read_text(errors="replace")
    files: dict[str, dict] = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"^diff --git a/(.+?) b/(.+)$", line)
        if m:
            cur = m.group(2)
            files[cur] = {"kind": "modified", "added": 0, "removed": 0,
                          "hunks": 0, "context": 0, "old": m.group(1), "ranges": []}
            continue
        if cur is None:
            continue
        if line.startswith("new file mode"):
            files[cur]["kind"] = "new"
        elif line.startswith("deleted file mode"):
            files[cur]["kind"] = "deleted"
        elif line.startswith("rename from") or line.startswith("rename to"):
            files[cur]["kind"] = "renamed"
        elif line.startswith("@@"):
            files[cur]["hunks"] += 1
            hm = re.match(r"^@@ -(\d+)(?:,(\d+))? ", line)
            if hm:
                start = int(hm.group(1))
                count = int(hm.group(2) or 1)
                if count > 0:
                    files[cur]["ranges"].append((start, start + count - 1))
        elif line.startswith("+") and not line.startswith("+++"):
            files[cur]["added"] += 1
        elif line.startswith("-") and not line.startswith("---"):
            files[cur]["removed"] += 1
        elif line.startswith(" ") and files[cur]["hunks"]:
            files[cur]["context"] += 1
    return files


def line_churn(fork: Path, base: str, path: str, ranges: list[tuple[int, int]],
               since: str) -> tuple[int, bool]:
    """Distinct upstream commits that touched THESE LINES, in the window.

    This is the number that predicts conflicts. `git log -L a,b:file` follows the
    range backwards through history, so it answers "how often did upstream edit
    the very lines this patch's hunks sit on" rather than "how busy is the file".
    Returns (commits, measurable).
    """
    if not ranges:
        return 0, False
    args = ["git", "-C", str(fork), "log", "--format=%H %ad", "--date=short"]
    for start, end in ranges:
        args += ["-L", "%d,%d:%s" % (start, end, path)]
    args += [base]
    proc = subprocess.run(args, check=False, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if proc.returncode != 0:
        return 0, False
    seen = set()
    for line in (proc.stdout or "").splitlines():
        m = re.match(r"^([0-9a-f]{40}) (\d{4}-\d{2}-\d{2})$", line)
        if m and m.group(2) >= since:
            seen.add(m.group(1))
    return len(seen), True


def churn(fork: Path, paths: list[str], since: str, until: str) -> dict[str, int]:
    """Commits in upstream's own history touching each path in a window."""
    out: dict[str, int] = {}
    for p in paths:
        text = run(["git", "-C", str(fork), "rev-list", "--count",
                    "--since=%s" % since, "--until=%s" % until,
                    "upstream/next", "--", p])
        out[p] = int(text.strip() or 0)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fork", default=str(DEFAULT_FORK))
    ap.add_argument("--specs", default=str(DEFAULT_SPECS))
    ap.add_argument("--json", default=str(REPO_ROOT / "carry" / "exposure.json"))
    args = ap.parse_args()

    fork = Path(args.fork).resolve()
    specs = Path(args.specs).resolve()
    series = json.loads((REPO_ROOT / "carry" / "series.json").read_text())
    base = series["base"]["commit"]

    base_date = run(["git", "-C", str(fork), "log", "-1", "--format=%ad",
                     "--date=short", base]).strip()
    tip = run(["git", "-C", str(fork), "rev-parse", "upstream/next"]).strip()
    tip_date = run(["git", "-C", str(fork), "log", "-1", "--format=%ad",
                    "--date=short", tip]).strip()
    window_start = (date.fromisoformat(base_date) - timedelta(days=365)).isoformat()

    per_patch = []
    all_files: dict[str, dict] = {}
    for p in sorted(series["patches"], key=lambda p: p["order"]):
        patch = specs / "upstream-bugs" / p["entry"] / p["patch"]
        files = parse_patch(patch)
        cats = collections.Counter()
        added = removed = hunks = 0
        for path, info in files.items():
            cats[categorise(path)] += 1
            added += info["added"]
            removed += info["removed"]
            hunks += info["hunks"]
            # Later patches in the series can touch a file an earlier one did.
            prev = all_files.get(path)
            if prev is None or prev["kind"] == "modified":
                all_files[path] = dict(info)
            else:
                all_files[path]["added"] += info["added"]
                all_files[path]["removed"] += info["removed"]
                all_files[path]["hunks"] += info["hunks"]
                all_files[path]["context"] += info["context"]
        per_patch.append({
            "id": p["id"], "entry": p["entry"], "title": p["title"],
            "files": len(files), "added": added, "removed": removed, "hunks": hunks,
            "by_category": dict(cats),
            "kinds": dict(collections.Counter(i["kind"] for i in files.values())),
        })

    modified = sorted(p for p, i in all_files.items() if i["kind"] == "modified")
    created = sorted(p for p, i in all_files.items() if i["kind"] == "new")
    renamed = sorted(p for p, i in all_files.items() if i["kind"] == "renamed")
    deleted = sorted(p for p, i in all_files.items() if i["kind"] == "deleted")

    before = churn(fork, modified, window_start, base_date)
    after = churn(fork, modified, base_date, tip_date)

    hunk_churn: dict[str, int] = {}
    unmeasurable: list[str] = []
    for path in modified:
        n, ok = line_churn(fork, base, path, all_files[path]["ranges"], window_start)
        if ok:
            hunk_churn[path] = n
        else:
            unmeasurable.append(path)

    months = 12.0
    commits_per_month = sum(before.values()) / months
    line_commits_per_month = sum(hunk_churn.values()) / months
    hot = sorted(before.items(), key=lambda kv: -kv[1])
    hot_lines = sorted(hunk_churn.items(), key=lambda kv: -kv[1])

    totals_by_cat = collections.Counter()
    lines_by_cat = collections.Counter()
    for path, info in all_files.items():
        c = categorise(path)
        totals_by_cat[c] += 1
        lines_by_cat[c] += info["added"] + info["removed"]

    # The union, which is what the SET costs. Summing the per-patch rows instead
    # would double-count the files two patches both touch, and this project has
    # already shipped one pair of documents quoting two different numbers for one
    # quantity. Both are reported, each labelled with what it is.
    union_added = sum(i["added"] for i in all_files.values())
    union_removed = sum(i["removed"] for i in all_files.values())
    union_hunks = sum(i["hunks"] for i in all_files.values())

    report = {
        "union_added": union_added,
        "union_removed": union_removed,
        "union_hunks": union_hunks,
        "sum_of_per_patch_added": sum(r["added"] for r in per_patch),
        "sum_of_per_patch_removed": sum(r["removed"] for r in per_patch),
        "sum_of_per_patch_hunks": sum(r["hunks"] for r in per_patch),
        "base": base, "base_date": base_date,
        "upstream_tip": tip, "upstream_tip_date": tip_date,
        "churn_window": [window_start, base_date],
        "per_patch": per_patch,
        "files_total": len(all_files),
        "files_modified": len(modified),
        "files_created": len(created),
        "files_renamed": len(renamed),
        "files_deleted": len(deleted),
        "modified_paths": modified,
        "by_category_files": dict(totals_by_cat),
        "by_category_lines": dict(lines_by_cat),
        "churn_12mo_before_base": before,
        "churn_since_base": after,
        "line_churn_12mo_before_base": hunk_churn,
        "line_churn_unmeasurable": unmeasurable,
        "upstream_commits_per_month_touching_a_modified_file": round(commits_per_month, 2),
        "upstream_commits_per_month_touching_a_carried_hunk": round(line_commits_per_month, 2),
    }
    Path(args.json).write_text(json.dumps(report, indent=2) + "\n")

    total_added = sum(i["added"] for i in all_files.values())
    total_removed = sum(i["removed"] for i in all_files.values())
    total_hunks = sum(i["hunks"] for i in all_files.values())
    ctx = sum(all_files[p]["context"] for p in modified)

    print("Carry exposure if upstream accepts NOTHING")
    print("  measured against %s (%s); upstream tip %s (%s)"
          % (base[:10], base_date, tip[:10], tip_date))
    print()
    print("SIZE")
    print("  %d file(s), +%d / -%d over %d hunk(s)"
          % (len(all_files), total_added, total_removed, total_hunks))
    for c in sorted(totals_by_cat):
        print("    %-6s %2d file(s), %4d changed line(s)" % (c, totals_by_cat[c], lines_by_cat[c]))
    print()
    print("SURFACE — only files upstream also has can conflict")
    print("  %d created, %d renamed, %d deleted, %d MODIFIED"
          % (len(created), len(renamed), len(deleted), len(modified)))
    print("  the modified files carry %d line(s) of context a three-way merge must match"
          % ctx)
    for p in modified:
        i = all_files[p]
        print("    +%-4d -%-4d %2d hunk(s)  %s" % (i["added"], i["removed"], i["hunks"], p))
    print()
    print("CHURN — upstream commits touching those files")
    print("  window %s .. %s (12 months before the base)" % (window_start, base_date))
    for p, n in hot:
        print("    %4d  %s   (%d since the base)" % (n, p, after.get(p, 0)))
    print("  total %d commit(s) in 12 months = %.2f per month"
          % (sum(before.values()), commits_per_month))
    print("  since the base (%s .. %s): %d commit(s)"
          % (base_date, tip_date, sum(after.values())))
    print()
    print("LINE CHURN — upstream commits touching the LINES the hunks sit on")
    print("  same window; `git log -L` over each hunk's pre-image range")
    for p, n in hot_lines:
        if n:
            print("    %4d  %s" % (n, p))
    print("    %d file(s) with zero commits on their carried lines"
          % sum(1 for _, n in hot_lines if n == 0))
    if unmeasurable:
        print("    %d file(s) NOT MEASURABLE this way (their pre-image is produced by an"
              % len(unmeasurable))
        print("      earlier patch in the series, so the range does not exist at the base):")
        for p in unmeasurable:
            print("        %s" % p)
    print("  total %d commit(s) in 12 months = %.2f per month"
          % (sum(hunk_churn.values()), line_commits_per_month))
    print()
    print("EXPECTED")
    print("  %.2f upstream commit(s) per month land in a file this series modifies;"
          % commits_per_month)
    print("  %.2f per month land on the LINES it modifies." % line_commits_per_month)
    print("  The first is the population conflicts are drawn from and is an upper bound.")
    print("  The second is the rate that actually predicts a rebase conflict.")
    print()
    print("report: %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
