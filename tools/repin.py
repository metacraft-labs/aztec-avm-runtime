#!/usr/bin/env python3
"""The @aztec/* pin: hold every consumer to pins.json, or rewrite them from it.

pins.json is the single authority. `package.json` and `package-lock.json` files
CONTAIN pin values because npm requires them to; this tool is what makes those
copies derived rather than independent. Prose is held to the same standard: a
markdown file may only quote a version pins.json declares, so a stale number in
a README fails instead of quietly misinforming.

  repin.py --check    exit non-zero on any disagreement (this is the gate)
  repin.py --apply    rewrite the @aztec/* versions in each tree's package.json
  repin.py --report   print what was examined, for a human

--apply is a targeted textual substitution, not a JSON round trip: on a tree
that already agrees it must be a byte-level no-op, and --check asserts exactly
that. A rewriter that reformats cannot be told apart from one that changes
meaning.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NIGHTLY_RE = re.compile(r"\b\d+\.\d+\.\d+-nightly\.\d{8}\b")
# `"@aztec/foundation": "5.3.0-nightly.20260819"` inside a dependency block.
DEP_RE = re.compile(r'("@aztec/[a-z0-9._-]+"\s*:\s*")([^"]+)(")')
ALIAS_RE = re.compile(r'"(npm:(@aztec/[a-z0-9._-]+)@([^"]+))"')


class Fatal(Exception):
    pass


def load_pins() -> dict:
    with open(os.path.join(REPO, "pins.json"), encoding="utf-8") as fh:
        return json.load(fh)


def tracked(*globs: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-files", "-z", "--", *globs],
        capture_output=True,
        check=True,
    ).stdout
    return sorted(p for p in out.decode().split("\0") if p)


def read(path: str) -> str:
    with open(os.path.join(REPO, path), encoding="utf-8") as fh:
        return fh.read()


class Checker:
    def __init__(self, pins: dict):
        self.pins = pins
        self.problems: list[str] = []
        self.checks = 0
        npm = pins["npm"]
        self.declared = {
            role: spec["version"] for role, spec in npm.items() if not role.startswith("_")
        }
        if len(self.declared) < 2:
            raise Fatal("pins.json declares fewer than two npm pins")
        self.declared_values = set(self.declared.values())
        self.exceptions = {
            k: v["version"]
            for k, v in pins.get("npm_exceptions", {}).items()
            if not k.startswith("_")
        }
        self.consumers = {
            k: v for k, v in pins["npm_consumers"].items() if not k.startswith("_")
        }
        if not self.consumers:
            raise Fatal("pins.json declares no npm consumers")
        # Measured artefacts that RECORD which pin they were produced against. Allowed to carry a
        # literal — and required to carry the right one. Exempting them instead would make "one
        # authority" true by shrinking its subject, which is the absence-asked-of-a-tree-that-
        # cannot-answer defect; a witness whose literal has drifted is an artefact that has stopped
        # describing the tree it was measured on, and that is worth a red.
        self.witnesses = {
            k: v
            for k, v in pins.get("npm_pin_witnesses", {}).items()
            if not k.startswith("_")
        }
        for path, role in self.witnesses.items():
            if role not in self.declared:
                raise Fatal(
                    "pins.json: witness %s names undeclared npm pin %r" % (path, role)
                )

    def bad(self, msg: str) -> None:
        self.problems.append(msg)

    def ok(self) -> None:
        self.checks += 1

    # -- package.json ------------------------------------------------------
    def check_package_json(self, tree: str, pin: str) -> None:
        path = "%s/package.json" % tree
        text = read(path)
        found = 0
        for m in DEP_RE.finditer(text):
            name = m.group(1).split('"')[1]
            got = m.group(2)
            want = self.exceptions.get(name, pin)
            found += 1
            self.ok()
            if got != want:
                self.bad("%s: %s is %s, pins.json says %s" % (path, name, got, want))
        for m in ALIAS_RE.finditer(text):
            name, got = m.group(2), m.group(3)
            self.ok()
            if name not in self.exceptions:
                self.bad(
                    "%s: aliases %s@%s but pins.json has no exception for it"
                    % (path, name, got)
                )
            elif got != self.exceptions[name]:
                self.bad(
                    "%s: %s aliased at %s, pins.json exception says %s"
                    % (path, name, got, self.exceptions[name])
                )
        if found == 0:
            self.bad("%s: no @aztec/* dependency found — the check would be vacuous" % path)

    # -- package-lock.json -------------------------------------------------
    def check_lockfile(self, tree: str, pin: str) -> None:
        path = "%s/package-lock.json" % tree
        lock = json.loads(read(path))
        nodes = lock.get("packages")
        if not nodes:
            self.bad("%s: no 'packages' section (lockfileVersion %r)" % (path, lock.get("lockfileVersion")))
            return
        found = 0
        for key, node in nodes.items():
            name = key.split("node_modules/")[-1] if key else ""
            resolved = node.get("resolved") or ""
            is_aztec = name.startswith("@aztec/") or "/@aztec/" in resolved
            if not is_aztec:
                continue
            if not name.startswith("@aztec/"):
                m = re.search(r"/(@aztec/[a-z0-9._-]+)/-/", resolved)
                if m:
                    name = m.group(1)
            version = node.get("version")
            want = self.exceptions.get(name, pin)
            # An exception package brings its own closure: everything npm nests
            # under node_modules/<exception>/node_modules/ is resolved against
            # THAT package's line, not the tree's pin. Holding those to the
            # tree's pin would demand a resolution npm cannot produce.
            for exc_name, exc_version in self.exceptions.items():
                if "node_modules/%s/node_modules/" % exc_name in key:
                    want = exc_version
                    break
            found += 1
            self.ok()
            if version != want:
                self.bad("%s: %s resolves to %s, pins.json says %s" % (path, name, version, want))
            # The tarball URL carries the version too; a lockfile whose URL and
            # version disagree installs something other than what it claims.
            if resolved and version and version not in resolved:
                self.bad("%s: %s url %s does not carry version %s" % (path, name, resolved, version))
                self.ok()
        if found == 0:
            self.bad("%s: no @aztec/* entry found — the check would be vacuous" % path)

    # -- prose and stray declarations --------------------------------------
    def check_prose_and_authority(self) -> None:
        allowed_files = {"pins.json"}
        for tree in self.consumers:
            allowed_files.add("%s/package.json" % tree)
            allowed_files.add("%s/package-lock.json" % tree)

        files = tracked("*.md", "*.json", "*.sh", "*.nix", "*.ts", "*.mjs", "*.js", "Justfile")
        scanned = 0
        seen_paths: set[str] = set()
        for f in files:
            if f.startswith(("spike/node_modules", "diffsim/node_modules", "drift/node_modules")):
                continue
            try:
                text = read(f)
            except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, OSError):
                continue
            hits = set(NIGHTLY_RE.findall(text))
            if not hits:
                continue
            scanned += 1
            seen_paths.add(f)
            self.ok()
            unknown = hits - self.declared_values - set(self.exceptions.values())
            if unknown:
                self.bad(
                    "%s quotes %s, which pins.json does not declare"
                    % (f, ", ".join(sorted(unknown)))
                )
            if f in self.witnesses:
                want = self.declared[self.witnesses[f]]
                self.ok()
                if hits != {want}:
                    self.bad(
                        "%s is a declared pin witness for npm.%s (%s) but carries %s"
                        % (f, self.witnesses[f], want, ", ".join(sorted(hits)))
                    )
            elif f.endswith(".json") and f not in allowed_files:
                self.bad(
                    "%s is a machine-readable file carrying a pin value but is not "
                    "pins.json, a derived package file or a declared pin witness" % f
                )
        for path in self.witnesses:
            # A witness that no longer carries any literal has stopped witnessing, and the
            # agreement check above would then pass by never running.
            if path not in seen_paths:
                self.bad(
                    "%s is declared a pin witness but carries no nightly literal at all" % path
                )
        if scanned == 0:
            self.bad("no tracked file mentions a nightly version — the scan is vacuous")

    def run(self) -> None:
        for tree, role in self.consumers.items():
            if role not in self.declared:
                self.bad("pins.json: consumer %s names undeclared npm pin %r" % (tree, role))
                continue
            pin = self.declared[role]
            self.check_package_json(tree, pin)
            self.check_lockfile(tree, pin)
        self.check_prose_and_authority()


def apply_pins(pins: dict) -> list[str]:
    """Rewrite each tree's package.json from pins.json. Returns changed files."""
    c = Checker(pins)
    changed = []
    for tree, role in c.consumers.items():
        pin = c.declared[role]
        path = os.path.join(REPO, tree, "package.json")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        def sub(m: re.Match) -> str:
            name = m.group(1).split('"')[1]
            return "%s%s%s" % (m.group(1), c.exceptions.get(name, pin), m.group(3))

        new = DEP_RE.sub(sub, text)
        if new != text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new)
            changed.append("%s/package.json" % tree)
    return changed


def main(argv: list[str]) -> int:
    pins = load_pins()
    if "--apply" in argv:
        changed = apply_pins(pins)
        print("rewrote %d file(s): %s" % (len(changed), " ".join(changed) or "-"))
        return 0
    c = Checker(pins)
    c.run()
    if c.checks == 0:
        print("repin.py: made zero assertions", file=sys.stderr)
        return 2
    if "--report" in argv:
        print("declared pins: %s" % ", ".join("%s=%s" % kv for kv in sorted(c.declared.items())))
        print("consumers:     %s" % ", ".join("%s->%s" % kv for kv in sorted(c.consumers.items())))
    print("repin: %d assertion(s), %d problem(s)" % (c.checks, len(c.problems)))
    for p in c.problems:
        print("  PIN-MISMATCH %s" % p)
    return 1 if c.problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fatal as exc:
        print("repin.py: %s" % exc, file=sys.stderr)
        sys.exit(2)
