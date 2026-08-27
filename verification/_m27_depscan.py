#!/usr/bin/env python3
"""Scan package.json files for browser-automation dependencies.

    _m27_depscan.py <package.json>...

Prints `KEY<TAB>VALUE` lines for `verify_browser_bundle_builds`:

    FILES       how many files were actually parsed
    AUTOMATION  `<file>:<package>` for every browser-automation package declared, space separated
    CONTROL     `<file>:<package>` for every hit of the control needle, space separated

THE CONTROL IS PART OF THE SCAN AND NOT A SECOND SCAN. `CAMPAIGN-BRIEF.md` records a control that
did not share an instrument with the thing it controlled, so both stayed green when the instrument
was typo'd. Here the same loop, over the same parsed files, in the same process, answers both — a
scan that stopped reading files drives AUTOMATION and CONTROL to empty together, and CONTROL's
assertion fails.

A FILE THAT CANNOT BE PARSED IS A FAILURE, not a zero. `FILES` counts only successful parses and
the caller asserts a floor on it, so a scanner that silently skipped everything cannot report a
clean tree.
"""

import json
import sys

# Prefix matching rather than equality: `@puppeteer/browsers`, `puppeteer-core`,
# `playwright-chromium` and `@playwright/test` are all the thing this absence is about, and an
# equality test would have missed every one of them.
AUTOMATION = (
    "puppeteer",
    "@puppeteer/",
    "playwright",
    "@playwright/",
    "selenium",
    "webdriverio",
    "webdriver",
    "chromedriver",
    "chrome-launcher",
    "chrome-remote-interface",
)
CONTROL = ("esbuild",)

FIELDS = ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")


def hits(doc, needles):
    out = []
    for field in FIELDS:
        for name in (doc.get(field) or {}):
            low = name.lower()
            if any(low.startswith(n) for n in needles):
                out.append(name)
    return out


def main(paths):
    parsed = 0
    automation, control = [], []
    for path in paths:
        with open(path) as handle:
            doc = json.load(handle)
        parsed += 1
        for name in hits(doc, AUTOMATION):
            automation.append("%s:%s" % (path, name))
        for name in hits(doc, CONTROL):
            control.append("%s:%s" % (path, name))
    print("FILES\t%d" % parsed)
    print("AUTOMATION\t%s" % " ".join(sorted(automation)))
    print("CONTROL\t%s" % " ".join(sorted(control)))


if __name__ == "__main__":
    main(sys.argv[1:])
