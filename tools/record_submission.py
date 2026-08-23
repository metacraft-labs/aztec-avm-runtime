#!/usr/bin/env python3
"""Record an upstream outcome for one prepared contribution.

Three documents say where a patch stands with upstream: `carry/series.json`
(the authority), `CARRY-LEDGER.md` (the readable ledger) and the contribution's
own `PR.md` `**Status:**` line, which the `upstream-bugs` convention requires to
carry the URL once filed. Updating one by hand and forgetting the others is the
failure this project has hit repeatedly, so all three move together here.

Usage:

    tools/record_submission.py --id p1 --url https://github.com/.../pull/123 \\
        --status submitted
    tools/record_submission.py --id p2 --status declined \\
        --reason "..." --maintenance "..."

`declined` requires both `--reason` and `--maintenance`; `stalled` requires
`--reason`. Those are not decoration: a declined patch whose consequence is not
written down becomes an unpriced liability, which is the thing the carry ledger
exists to prevent.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SERIES = REPO_ROOT / "carry" / "series.json"
SPECS = REPO_ROOT.parent / "codetracer-specs"

STATUSES = ("prepared", "submitted", "accepted", "declined", "stalled")


def update_pr_md(md: Path, status: str, url: str | None) -> bool:
    """Rewrite the `**Status:**` line of a PR.md. Returns True if it changed."""
    if not md.is_file():
        print("warning: %s does not exist; not updating it" % md, file=sys.stderr)
        return False
    text = md.read_text()
    if status == "prepared":
        new = "**Status:** READY TO REVIEW — not filed, no upstream PR URL yet."
    elif status == "submitted":
        new = "**Status:** FILED — %s. Awaiting review." % url
    elif status == "accepted":
        new = "**Status:** ACCEPTED upstream — %s." % url
    elif status == "declined":
        new = "**Status:** DECLINED upstream — %s. Carried downstream; see the carry ledger." % url
    else:
        new = "**Status:** STALLED — %s. Filed, no verdict; carried downstream meanwhile." % url

    out, n = re.subn(r"^\*\*Status:\*\*.*$", new.replace("\\", "\\\\"), text,
                     count=1, flags=re.MULTILINE)
    if n != 1:
        print("error: %s has no `**Status:**` line to rewrite" % md, file=sys.stderr)
        return False
    if out == text:
        return False
    md.write_text(out)
    return True


def regenerate_ledger() -> int:
    """Rebuild CARRY-LEDGER.md from series.json, so the two cannot disagree."""
    return subprocess.call([sys.executable, str(REPO_ROOT / "tools" / "render_carry_ledger.py")])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--id", required=True, help="patch id from carry/series.json (p1 .. p5)")
    ap.add_argument("--status", required=True, choices=STATUSES)
    ap.add_argument("--url", default=None, help="the upstream pull request URL")
    ap.add_argument("--reason", default=None, help="why it was declined or stalled")
    ap.add_argument("--maintenance", default=None,
                    help="what carrying it costs us, for a declined patch")
    args = ap.parse_args()

    if args.status in ("submitted", "accepted", "declined") and not args.url:
        print("error: --status %s requires --url" % args.status, file=sys.stderr)
        return 1
    if args.status == "declined" and not (args.reason and args.maintenance):
        print("error: --status declined requires both --reason and --maintenance",
              file=sys.stderr)
        return 1
    if args.status == "stalled" and not args.reason:
        print("error: --status stalled requires --reason", file=sys.stderr)
        return 1

    doc = json.loads(SERIES.read_text())
    entry = next((p for p in doc["patches"] if p["id"] == args.id), None)
    if entry is None:
        print("error: no such patch id: %s" % args.id, file=sys.stderr)
        return 1

    entry["ledger"]["status"] = args.status
    entry["ledger"]["url"] = args.url
    entry["ledger"]["reason"] = args.reason
    entry["ledger"]["maintenance"] = args.maintenance
    SERIES.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print("carry/series.json: %s -> %s%s"
          % (args.id, args.status, (" (%s)" % args.url) if args.url else ""))

    md = SPECS / "upstream-bugs" / entry["entry"] / "PR.md"
    if update_pr_md(md, args.status, args.url):
        print("%s: Status line updated" % md)
    else:
        print("%s: Status line already correct" % md)

    rc = regenerate_ledger()
    if rc != 0:
        print("error: regenerating CARRY-LEDGER.md failed", file=sys.stderr)
        return rc
    print("CARRY-LEDGER.md regenerated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
