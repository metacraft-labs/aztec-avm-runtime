#!/usr/bin/env python3
"""Parse and judge `fixtures/MANIFEST.md`.

Factored out of the shell checks for one reason: the negative controls have to run the SAME code
path against a mutated copy. A checker whose failure mode is only ever reasoned about is a checker
nobody has seen fail.

What this enforces, and what it deliberately cannot:

  ENFORCED — every entry has every field; the tier and licence come from closed vocabularies; every
  `where:` path exists; every `capture:` names a command; `skeptic-concludes` and
  `skeptic-cannot-conclude` are both present and substantial; no field asserts an absence without
  evidence; every cited inventory id resolves; Tier E entries carry a tagged
  `no-upstream-equivalent:` reason that names upstream paths; and Tier E is strictly the smallest
  tier, which is the mechanical form of "this tier is deliberately the smallest".

  NOT ENFORCED — whether a stated conclusion is TRUE. Structure cannot tell a true justification
  from a false one; M1 established that the hard way, where three of eight tagged, padded rejection
  reasons turned out to be factually wrong. The substantive claims are re-verified against upstream
  by `verify_tier_e_authored_fixtures_justified.sh` and
  `test_world_state_golden_vectors_regenerate.sh`, not here.

Usage:
    _manifest_parser.py check [--manifest PATH] [--repo PATH]
    _manifest_parser.py entries [--manifest PATH]     # id<TAB>tier<TAB>family
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

TIERS = {"A", "B", "C", "D", "E", "H"}

LICENCES = {
    "Apache-2.0",
    "MIT-OR-Apache-2.0",
    "MIT",
    "Apache-2.0 (output of Apache-2.0 code)",
}

REQUIRED = [
    "tier",
    "family",
    "where",
    "upstream-source",
    "capture",
    "licence",
    "measured",
    "skeptic-concludes",
    "skeptic-cannot-conclude",
    "inventory",
]

OPTIONAL = ["no-upstream-equivalent"]

REJECTION_TAGS = ("does-not-exist:", "does-not-cover:", "cannot-reach-target:")

# Phrases that assert an absence without producing evidence for it. Same list as the inventory
# checker's, for the same reason: "we didn't find one" is not a finding.
WEASEL = [
    "we didn't find",
    "we did not find",
    "we could not find",
    "couldn't find",
    "presumably",
    "as far as we know",
    "probably does not",
    "seems to be no",
    "appears to be no",
    "i believe",
    "should be fine",
    "no upstream equivalent exists",
]

ENTRY_RE = re.compile(r"^### (FX-\d{2}) — (.+)$")
FIELD_RE = re.compile(r"^- ([a-z-]+): (.*)$")


class Problem(Exception):
    pass


def parse(manifest_text: str) -> list[dict]:
    entries: list[dict] = []
    current: dict | None = None
    in_block = False
    for lineno, line in enumerate(manifest_text.splitlines(), 1):
        if line.strip() == "<!-- BEGIN:manifest -->":
            in_block = True
            continue
        if line.strip() == "<!-- END:manifest -->":
            in_block = False
            continue
        if not in_block:
            continue
        m = ENTRY_RE.match(line)
        if m:
            current = {"id": m.group(1), "_title": m.group(2), "_line": lineno}
            entries.append(current)
            continue
        f = FIELD_RE.match(line)
        if f and current is not None:
            key, value = f.group(1), f.group(2).strip()
            if key in current:
                raise Problem(f"{current['id']}: duplicate field `{key}` at line {lineno}")
            current[key] = value
            continue
        # Continuation of the previous field (a wrapped value).
        if current is not None and line.startswith("  ") and line.strip():
            last = [k for k in current if not k.startswith("_") and k != "id"]
            if last:
                current[last[-1]] = (current[last[-1]] + " " + line.strip()).strip()
    return entries


def check(manifest: Path, repo: Path) -> tuple[int, int, list[str]]:
    """Return (entries, assertions, failures)."""
    failures: list[str] = []
    assertions = 0

    def assert_(cond: bool, message: str) -> bool:
        nonlocal assertions
        assertions += 1
        if not cond:
            failures.append(message)
        return cond

    text = manifest.read_text()
    assert_("<!-- BEGIN:manifest -->" in text, "manifest: no BEGIN:manifest marker")
    assert_("<!-- END:manifest -->" in text, "manifest: no END:manifest marker")
    entries = parse(text)
    assert_(len(entries) >= 15, f"manifest: only {len(entries)} entries; expected at least 15")

    # SCOPE. `parse` only looks between the markers, so an entry written outside
    # them is invisible to every rule below while this checker still reports green.
    # That is not hypothetical: DRIFT.md's D8 was authored below its END marker and
    # went unvalidated for a whole milestone. Measured here too during M5's review —
    # an `### FX-99` planted one line after END:manifest passed 37/37. So the
    # parser's reach is compared against the document rather than assumed.
    headings = re.findall(r"^### (FX-\d{2}) — ", text, re.M)
    outside = [h for h in headings if h not in {e["id"] for e in entries}]
    assert_(
        not outside,
        f"manifest: {', '.join(outside)} written OUTSIDE the <!-- BEGIN:manifest --> "
        "block, so nothing validates them",
    )

    inventory_text = (repo / "REUSE-INVENTORY.md").read_text()
    known_ri = set(re.findall(r"^### (RI-\d{2}) ", inventory_text, re.M))
    assert_(len(known_ri) >= 40, f"manifest: only {len(known_ri)} inventory ids found to check against")

    seen_ids: set[str] = set()
    per_tier: dict[str, int] = {t: 0 for t in TIERS}

    for e in entries:
        eid = e["id"]
        assert_(eid not in seen_ids, f"{eid}: duplicate id")
        seen_ids.add(eid)

        for key in REQUIRED:
            if not assert_(key in e and e[key], f"{eid}: missing or empty field `{key}`"):
                e.setdefault(key, "")
        # No field outside the vocabulary. A manifest that accepts arbitrary keys accepts a
        # `measured` typo'd as `measurd` and reports it as present.
        for key in e:
            if key.startswith("_") or key == "id":
                continue
            assert_(key in REQUIRED or key in OPTIONAL, f"{eid}: unknown field `{key}`")

        tier = e.get("tier", "")
        if assert_(tier in TIERS, f"{eid}: tier `{tier}` is not one of {sorted(TIERS)}"):
            per_tier[tier] += 1

        assert_(
            e.get("licence", "") in LICENCES,
            f"{eid}: licence `{e.get('licence')}` is not one of {sorted(LICENCES)}",
        )

        # `where:` names real paths. Every whitespace/comma-separated token that looks like a path
        # (contains a `/` or a `.`) must exist relative to the repo root.
        wheres = [w.strip().strip("`,") for w in re.split(r"[,\s]+", e.get("where", "")) if w.strip()]
        path_tokens = [w for w in wheres if ("/" in w or "." in w) and not w.startswith("(")]
        assert_(len(path_tokens) >= 1, f"{eid}: `where` names no path")
        for token in path_tokens:
            assert_((repo / token).exists(), f"{eid}: `where` path does not exist: {token}")

        # `capture:` must name something runnable, not describe a vibe.
        capture = e.get("capture", "")
        assert_(
            any(k in capture for k in ("`", "just ", "node ", "npm ", "python3 ", "cd ")),
            f"{eid}: `capture` names no command: {capture[:80]}",
        )
        assert_(len(capture) >= 30, f"{eid}: `capture` is too short to be a procedure ({len(capture)} chars)")

        # The two halves of honesty. Both required, both substantial.
        concl = e.get("skeptic-concludes", "")
        cannot = e.get("skeptic-cannot-conclude", "")
        assert_(len(concl) >= 120, f"{eid}: `skeptic-concludes` is {len(concl)} chars; 120 required")
        assert_(len(cannot) >= 60, f"{eid}: `skeptic-cannot-conclude` is {len(cannot)} chars; 60 required")
        assert_(concl != cannot, f"{eid}: `skeptic-concludes` and `skeptic-cannot-conclude` are identical")

        # `measured:` must carry at least one number, because that is what "measured" means.
        measured = e.get("measured", "")
        assert_(bool(re.search(r"\d", measured)), f"{eid}: `measured` carries no number: {measured[:80]}")

        # Absence asserted without evidence, anywhere in the entry.
        blob = " ".join(str(v).lower() for k, v in e.items() if not k.startswith("_"))
        for phrase in WEASEL:
            assert_(phrase not in blob, f"{eid}: asserts an absence without evidence: `{phrase}`")

        # Inventory ids resolve.
        cited = re.findall(r"RI-\d{2}", e.get("inventory", ""))
        assert_(len(cited) >= 1, f"{eid}: `inventory` cites no RI-nn entry")
        for ri in cited:
            assert_(ri in known_ri, f"{eid}: cites {ri}, which is not an entry in REUSE-INVENTORY.md")

        # Tier E carries a tagged justification; no other tier may.
        nue = e.get("no-upstream-equivalent", "")
        if tier == "E":
            assert_(bool(nue), f"{eid}: Tier E entry has no `no-upstream-equivalent` reason")
            assert_(
                nue.startswith(REJECTION_TAGS),
                f"{eid}: `no-upstream-equivalent` must begin with one of {REJECTION_TAGS}",
            )
            assert_(
                len(nue) >= 200,
                f"{eid}: `no-upstream-equivalent` is {len(nue)} chars; 200 required",
            )
            # It must name upstream places it looked, by path.
            paths = re.findall(r"`([A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+)`", nue)
            assert_(
                len(paths) >= 2,
                f"{eid}: `no-upstream-equivalent` names {len(paths)} upstream paths; at least 2 required",
            )
        else:
            assert_(
                not nue,
                f"{eid}: only Tier E entries may carry `no-upstream-equivalent` (tier {tier})",
            )

        # Authored entries must say so in `upstream-source`, and reused ones must not.
        src = e.get("upstream-source", "")
        if tier == "E":
            assert_(
                src.startswith("none"),
                f"{eid}: a Tier E entry's `upstream-source` must begin with `none`, got `{src[:60]}`",
            )
        else:
            assert_(
                not src.startswith("none"),
                f"{eid}: a non-Tier-E entry claims no upstream source; it belongs in Tier E",
            )

    # Every tier is populated, and Tier E is STRICTLY the smallest — the mechanical form of
    # "this tier is deliberately the smallest, and cannot grow by default".
    for tier in sorted(TIERS):
        assert_(per_tier[tier] > 0, f"manifest: tier {tier} has no entries")
    others = [per_tier[t] for t in TIERS if t != "E"]
    assert_(
        all(per_tier["E"] < n for n in others),
        f"manifest: Tier E has {per_tier['E']} entries, not strictly fewer than every other tier "
        f"({ {t: per_tier[t] for t in sorted(TIERS)} })",
    )

    # Ids are contiguous from FX-01, so an entry cannot be dropped without the gap showing.
    numbers = sorted(int(i.split("-")[1]) for i in seen_ids)
    assert_(numbers == list(range(1, len(numbers) + 1)), f"manifest: ids are not contiguous from FX-01: {numbers}")

    return len(entries), assertions, failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["check", "entries"])
    here = Path(__file__).resolve().parent
    ap.add_argument("--repo", type=Path, default=here.parent)
    ap.add_argument("--manifest", type=Path, default=None)
    args = ap.parse_args()
    manifest = args.manifest or (args.repo / "fixtures/MANIFEST.md")

    if not manifest.exists():
        sys.stderr.write(f"_manifest_parser: {manifest} does not exist\n")
        return 2

    if args.command == "entries":
        for e in parse(manifest.read_text()):
            print(f"{e['id']}\t{e.get('tier','?')}\t{e.get('family','?')}")
        return 0

    try:
        count, assertions, failures = check(manifest, args.repo)
    except Problem as exc:
        sys.stderr.write(f"_manifest_parser: {exc}\n")
        return 2
    for f in failures:
        print(f"  FAIL {f}")
    print(json.dumps({"entries": count, "assertions": assertions, "failures": len(failures)}))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
