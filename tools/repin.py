#!/usr/bin/env python3
"""The npm pins: hold every consumer to pins.json, or rewrite them from it.

Each npm pin line in pins.json names the package SCOPES it governs (`scopes`, default
`["@aztec"]`). Two lines are @aztec/* nightlies; since the operator adopted the v6 rename on
2026-11-26 (DRIFT.md D36) a third governs `@aztec-labs/*` and `@aztec-foundation/*`, which is
what the working tree's `replay/` installs. A consumer tree is held to its own line for every
package in that line's scopes, AND refused any package from another line's scopes: one tree
carrying two generations is the class-identity hazard `replay/package.json` documents, not a
version detail. `historical_runtimes` are commits of this repository that a check executes
instead of the working tree; their package files are read out of the object store and held to
their declared line the same way (they cannot be rewritten, so `--apply` leaves them alone).

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
# `"@aztec/foundation": "5.3.0-nightly.20260819"` inside a dependency block, for ANY scope; the
# checker keeps only the scopes some pin line declares.
DEP_RE = re.compile(r'("(@[a-z0-9-]+)/[a-z0-9._-]+"\s*:\s*")([^"]+)(")')
ALIAS_RE = re.compile(r'"(npm:((@[a-z0-9-]+)/[a-z0-9._-]+)@([^"]+))"')
DEFAULT_SCOPES = ["@aztec"]


def scope_of(name: str) -> str:
    return name.split("/", 1)[0]


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


def read_at(commit: str, path: str) -> str | None:
    """A file at a commit, out of the object store; None if the commit or path is absent."""
    res = subprocess.run(
        ["git", "-C", REPO, "show", "%s:%s" % (commit, path)], capture_output=True
    )
    return res.stdout.decode() if res.returncode == 0 else None


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
        self.scopes = {
            role: list(spec.get("scopes", DEFAULT_SCOPES))
            for role, spec in npm.items()
            if not role.startswith("_")
        }
        self.all_scopes = {s for ss in self.scopes.values() for s in ss}
        self.historical = {
            k: v
            for k, v in pins.get("historical_runtimes", {}).items()
            if not k.startswith("_")
        }
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
    def check_package_json(self, tree: str, role: str, text: str | None = None,
                           label: str | None = None) -> None:
        path = label or "%s/package.json" % tree
        if text is None:
            text = read("%s/package.json" % tree)
        pin = self.declared[role]
        own = set(self.scopes[role])
        found = 0
        for m in DEP_RE.finditer(text):
            name = m.group(1).split('"')[1]
            scope = m.group(2)
            if scope not in self.all_scopes:
                continue
            got = m.group(3)
            self.ok()
            if name in self.exceptions:
                found += 1
                if got != self.exceptions[name]:
                    self.bad("%s: %s is %s, pins.json says %s"
                             % (path, name, got, self.exceptions[name]))
                continue
            if scope not in own:
                self.bad("%s: %s is in %s, a scope of another declared pin line, not npm.%s's"
                         % (path, name, scope, role))
                continue
            found += 1
            if got != pin:
                self.bad("%s: %s is %s, pins.json says %s" % (path, name, got, pin))
        for m in ALIAS_RE.finditer(text):
            name, scope, got = m.group(2), m.group(3), m.group(4)
            if scope not in self.all_scopes:
                continue
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
            self.bad("%s: no %s dependency found — the check would be vacuous"
                     % (path, "/".join(s + "/*" for s in sorted(own))))

    # -- package-lock.json -------------------------------------------------
    def check_lockfile(self, tree: str, role: str, text: str | None = None,
                       label: str | None = None) -> None:
        path = label or "%s/package-lock.json" % tree
        if text is None:
            text = read("%s/package-lock.json" % tree)
        lock = json.loads(text)
        pin = self.declared[role]
        own = set(self.scopes[role])
        nodes = lock.get("packages")
        if not nodes:
            self.bad("%s: no 'packages' section (lockfileVersion %r)" % (path, lock.get("lockfileVersion")))
            return
        found = 0
        for key, node in nodes.items():
            name = key.split("node_modules/")[-1] if key else ""
            resolved = node.get("resolved") or ""
            scope = scope_of(name) if name.startswith("@") else ""
            if scope not in self.all_scopes:
                m = re.search(r"/((@[a-z0-9-]+)/[a-z0-9._-]+)/-/", resolved)
                if not m or m.group(2) not in self.all_scopes:
                    continue
                name, scope = m.group(1), m.group(2)
            version = node.get("version")
            want = self.exceptions.get(name)
            # An exception package brings its own closure: everything npm nests
            # under node_modules/<exception>/node_modules/ is resolved against
            # THAT package's line, not the tree's pin. Holding those to the
            # tree's pin would demand a resolution npm cannot produce.
            for exc_name, exc_version in self.exceptions.items():
                if "node_modules/%s/node_modules/" % exc_name in key:
                    want = exc_version
                    break
            self.ok()
            if want is None:
                if scope not in own:
                    self.bad("%s: %s is in %s, a scope of another declared pin line, not npm.%s's"
                             % (path, name, scope, role))
                    continue
                want = pin
            found += 1
            if version != want:
                self.bad("%s: %s resolves to %s, pins.json says %s" % (path, name, version, want))
            # The tarball URL carries the version too; a lockfile whose URL and
            # version disagree installs something other than what it claims.
            if resolved and version and version not in resolved:
                self.bad("%s: %s url %s does not carry version %s" % (path, name, resolved, version))
                self.ok()
        if found == 0:
            self.bad("%s: no %s entry found — the check would be vacuous"
                     % (path, "/".join(s + "/*" for s in sorted(own))))

    # -- historical runtimes -------------------------------------------------
    def check_historical(self) -> None:
        """A commit a check executes instead of the working tree: its package files, out of the
        object store, held to the line it declares. Absence is a failure, never a skip."""
        for name, spec in self.historical.items():
            commit = spec.get("commit", "")
            tree = spec.get("subject_tree", "")
            role = spec.get("npm_pin", "")
            self.ok()
            if role not in self.declared:
                self.bad("pins.json: historical_runtimes.%s names undeclared npm pin %r"
                         % (name, role))
                continue
            short = commit[:10]
            pkg = read_at(commit, "%s/package.json" % tree)
            lock = read_at(commit, "%s/package-lock.json" % tree)
            if pkg is None or lock is None:
                self.bad("historical_runtimes.%s: commit %s is not in this repository's object "
                         "store, or carries no %s/package.json and package-lock.json "
                         "(Remedy: just materialize-historical-replay, which fetches it)"
                         % (name, commit, tree))
                continue
            self.check_package_json(tree, role, pkg, "%s:%s/package.json" % (short, tree))
            self.check_lockfile(tree, role, lock, "%s:%s/package-lock.json" % (short, tree))

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
            self.check_package_json(tree, role)
            self.check_lockfile(tree, role)
        self.check_historical()
        self.check_prose_and_authority()


def apply_pins(pins: dict) -> list[str]:
    """Rewrite each tree's package.json from pins.json. Returns changed files."""
    c = Checker(pins)
    changed = []
    for tree, role in c.consumers.items():
        pin = c.declared[role]
        own = set(c.scopes[role])
        path = os.path.join(REPO, tree, "package.json")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        def sub(m: re.Match) -> str:
            name = m.group(1).split('"')[1]
            if name in c.exceptions:
                return "%s%s%s" % (m.group(1), c.exceptions[name], m.group(4))
            if m.group(2) not in own:
                return m.group(0)  # another line's scope: a --check failure, not a rewrite
            return "%s%s%s" % (m.group(1), pin, m.group(4))

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
        print("scopes:        %s" % ", ".join("%s=%s" % (r, "+".join(s)) for r, s in sorted(c.scopes.items())))
        print("historical:    %s" % ", ".join(
            "%s@%s->%s" % (k, v.get("commit", "")[:10], v.get("npm_pin")) for k, v in sorted(c.historical.items())))
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
