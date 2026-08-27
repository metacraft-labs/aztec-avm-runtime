#!/usr/bin/env python3
"""Measure a BUILT bundle: its module graph, its externals and its emitted bytes.

    _m28_bundle_scan.py <repo-root> <dist-dir> <meta.json>[,<meta.json>...] [--shims <build-config.json>]

Prints `KEY<TAB>VALUE...` lines. One instrument answers all three of M28's graph gates
(`verify_browser_bundle_no_node_builtins`, `verify_browser_bundle_no_native_deps`,
`verify_verification_code_unreachable_from_browser`), and every one of them runs it over the NODE
bundle as its control. That is deliberate: `CAMPAIGN-BRIEF.md` records a builtin census whose
control was a hand-written literal beside the loop rather than a second run of the same instrument,
so typing the loop's needle list left the assertion AND its control green.

=================================================================================================
WHY THE METAFILE AND THE EMITTED BYTES, AND NOT EITHER ALONE.
=================================================================================================

The deliverable says "checked on the built artifact rather than on source". There are two artefacts
and they answer different questions.

  * THE METAFILE is the bundler's own record of the resolved module graph: for every import edge it
    holds the specifier AS WRITTEN (`original`), the file it RESOLVED to (`path`), and whether it
    was left `external`. That is the only place the difference between "polyfilled by our shim" and
    "reaches the real Node builtin" is visible — both are spelled `util` in the source.
  * THE EMITTED BYTES are what a page actually runs. A bundler that renamed, inlined or rewrote a
    specifier cannot hide there. The brief's warning — "must not pass merely because a bundler
    rewrote a name" — is exactly this arm.

Neither is redundant. A builtin resolved to a shim is INVISIBLE in the emitted bytes (correctly, it
is bundled); a builtin left external is visible in BOTH; and a specifier the metafile does not
record at all — a string handed to a bare `require` at run time — is visible only in the bytes.

=================================================================================================
WHAT A SCANNER MUST DO WITH WHAT IT CANNOT PLACE.
=================================================================================================

`CAMPAIGN-BRIEF.md`: "write scanners that PRINT the residue rather than counting the matches". Every
classification here has an `-OTHER` bucket that is printed, and the caller asserts those buckets are
either empty or exactly the declared contents. A class that is too narrow becomes a red line instead
of a silent undercount.
"""

import json
import os
import re
import sys

# The Node builtin set. Written out rather than taken from `sys` at run time, because the question
# is what NODE's module registry holds and this script runs under python3. It is the same list
# `tools/import_graph.mjs` carries, plus the subpath spellings, and the deliverable's ten names are
# all in it (`fs`, `path`, `url`, `readline`, `process`, `tty`, `child_process`, `net`,
# `worker_threads`, `assert`).
BUILTINS = {
    "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console",
    "constants", "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain",
    "events", "fs", "fs/promises", "http", "http2", "https", "inspector", "module", "net", "os",
    "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring",
    "readline", "readline/promises", "repl", "stream", "stream/consumers", "stream/promises",
    "stream/web", "string_decoder", "sys", "timers", "timers/promises", "tls", "trace_events",
    "tty", "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib",
}


def builtin_name(spec):
    """`node:fs/promises` and `fs/promises` -> `fs/promises`; anything else -> None.

    BOTH SPELLINGS, because `CAMPAIGN-BRIEF.md` records a graph claim that rested on a
    single-quote-only grep and therefore missed the same import written the other way; the
    `node:` prefix is the same class of thing one level up.
    """
    if not isinstance(spec, str):
        return None
    bare = spec[5:] if spec.startswith("node:") else spec
    return bare if bare in BUILTINS else None


def load_metas(repo, paths):
    """Every metafile merged into one (input-path -> record) map, paths made repo-relative."""
    inputs = {}
    for path in paths:
        doc = json.load(open(path))
        for key, rec in doc.get("inputs", {}).items():
            inputs.setdefault(rel(repo, key), rec)
    return inputs


def rel(repo, p):
    if os.path.isabs(p):
        try:
            return os.path.relpath(p, repo)
        except ValueError:
            return p
    return p


# ---------------------------------------------------------------------------------------------
# The emitted bytes. A specifier position, not a substring: `import ... from "fs"`,
# `import("fs")`, `require("fs")`, `export ... from "fs"` — in BOTH quote spellings, with and
# without the `node:` prefix.
#
# `\bfs\b` over a megabyte of bundled JavaScript would match a property called `fs`, a minified
# identifier and the word inside a comment, so the needle is anchored to the syntax that MAKES a
# specifier rather than to the name.
# ---------------------------------------------------------------------------------------------
SPEC_RES = [
    re.compile(r"""(?:^|[\s;}(,=])(?:import|export)\s*(?:[^'"();]*?\bfrom\s*)?['"]([^'"\n]+)['"]"""),
    re.compile(r"""\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)"""),
    re.compile(r"""\b(?:require|__require)\s*\(\s*['"]([^'"\n]+)['"]\s*\)"""),
    re.compile(r"""\bcreateRequire\s*\([^)]*\)\s*\(\s*['"]([^'"\n]+)['"]\s*\)"""),
]


def emitted_specifiers(text):
    out = []
    for rx in SPEC_RES:
        for m in rx.finditer(text):
            out.append(m.group(1))
    return out


def package_of(path):
    """The npm package a path belongs to, scope included, or None.

    The LAST `node_modules/` segment, so a nested dependency is attributed to itself. Package
    BOUNDARY rather than substring: `@aztec/stdlib/dest/world-state/index.js` belongs to
    `@aztec/stdlib` and NOT to `@aztec/world-state`, which is precisely the needle this campaign
    has been caught by fourteen times (`honk` in `chonk`, `world_state` in
    `world_state_reference`).
    """
    idx = path.rfind("node_modules/")
    if idx == -1:
        return None
    rest = path[idx + len("node_modules/"):].split("/")
    if not rest:
        return None
    if rest[0].startswith("@"):
        return "/".join(rest[:2]) if len(rest) > 1 else None
    return rest[0]


# Paths that no browser entry point may reach. Each is a repository ROOT rather than a substring,
# and `differential/` is a path component rather than a word, so `three_way_differential.ts` in a
# permitted directory would not satisfy it and `.../differential/x.ts` would.
FORBIDDEN_ROOTS = ("diffsim/", "drift/", "spike/", "probe-mt/", "verification/", "reference/",
                   "submit/", "upstream/", "browser-probe/probe")
FORBIDDEN_PATTERNS = [
    ("differential-dir", re.compile(r"(^|/)differential/")),
    ("cpp-file", re.compile(r"(^|/)cpp_[A-Za-z0-9_]*\.")),
    ("cpp-provider", re.compile(r"contract_provider_for_cpp")),
    ("native-addon", re.compile(r"\.node$")),
]
# The packages DD-9 forbids in the shipped graph, matched on the package name the walk derives
# rather than on the path text.
FORBIDDEN_PACKAGES = ("@aztec/native", "@aztec/world-state", "@aztec/telemetry-client")
# Native-addon LOADERS. These are not forbidden by name in the deliverable; they are the mechanism
# by which a prebuilt binary is reached, and they are the CONTROL: they are installed in the same
# tree the browser pass resolves from, the node pass reaches them, and the browser pass must not.
NATIVE_LOADERS = ("msgpackr-extract", "node-gyp-build-optional-packages", "node-gyp-build",
                  "@crate-crypto/node-eth-kzg", "bindings", "prebuild-install")


def main(argv):
    repo = os.path.abspath(argv[0])
    dist = argv[1]
    metas = argv[2].split(",")
    shims = {}
    if "--shims" in argv:
        cfg = json.load(open(argv[argv.index("--shims") + 1]))
        shims = {name: rel(repo, p) for name, p in (cfg.get("shims") or {}).items()}
        globals_file = rel(repo, cfg.get("globals") or "")
    else:
        globals_file = ""

    # THE NODE BUNDLE LIVES INSIDE THE BROWSER BUNDLE'S DIRECTORY (`browser/dist/node/`), so a
    # naive walk of `browser/dist` scans the control as though it were the subject and reports 24
    # Node builtins in "the browser bundle". Measured on the first run of this scanner, which is
    # why the exclusion is a parameter and not a comment: an instrument that cannot tell the
    # subject from its control is the fourth defect family in the brief.
    exclude = []
    if "--exclude" in argv:
        exclude = [argv[argv.index("--exclude") + 1]]

    inputs = load_metas(repo, metas)
    print("INPUTS\t%d" % len(inputs))
    print("SHIMS\t%s" % " ".join("%s=%s" % kv for kv in sorted(shims.items())))

    edges = 0
    builtin_external = {}   # spec -> [count, first importer]
    builtin_polyfilled = {}  # spec -> {resolved: count}
    external_other = {}     # resolved path -> [count, first importer]
    for importer, rec in sorted(inputs.items()):
        for imp in rec.get("imports", []):
            edges += 1
            spec = imp.get("original")
            resolved = rel(repo, imp.get("path", ""))
            # `original` is absent for an INJECTED import (esbuild's `--inject`), which is how the
            # globals file appears on a thousand inputs. Fall back to the resolved path so the
            # classification below still has something to say rather than silently skipping.
            key = spec if spec is not None else resolved
            name = builtin_name(key)
            if imp.get("external"):
                if name:
                    slot = builtin_external.setdefault(name, [0, importer])
                    slot[0] += 1
                else:
                    slot = external_other.setdefault(resolved, [0, importer])
                    slot[0] += 1
                continue
            if name:
                builtin_polyfilled.setdefault(name, {})
                builtin_polyfilled[name][resolved] = builtin_polyfilled[name].get(resolved, 0) + 1
    print("EDGES\t%d" % edges)
    for name in sorted(builtin_external):
        count, first = builtin_external[name]
        print("BUILTIN-EXTERNAL\t%s\t%d\t%s" % (name, count, first))
    for name in sorted(builtin_polyfilled):
        for resolved, count in sorted(builtin_polyfilled[name].items()):
            shim = next((s for s, p in shims.items() if p == resolved), None)
            kind = "BUILTIN-SHIMMED" if shim else "BUILTIN-OTHER"
            print("%s\t%s\t%s\t%d" % (kind, name, resolved, count))
    for resolved in sorted(external_other):
        count, first = external_other[resolved]
        label = "EXTERNAL-INJECT" if resolved == globals_file else "EXTERNAL-OTHER"
        print("%s\t%s\t%d\t%s" % (label, resolved, count, first))

    # ---- the packages and the paths the graph reaches --------------------------------------
    packages = sorted({p for p in (package_of(k) for k in inputs) if p})
    print("PACKAGES\t%d" % len(packages))
    for p in packages:
        print("PACKAGE\t%s" % p)
    for p in FORBIDDEN_PACKAGES:
        print("FORBIDDEN-PACKAGE\t%s\t%d" % (p, 1 if p in packages else 0))
    for p in NATIVE_LOADERS:
        print("NATIVE-LOADER\t%s\t%d" % (p, 1 if p in packages else 0))
    for label, rx in FORBIDDEN_PATTERNS:
        hits = sorted(k for k in inputs if rx.search(k))
        print("FORBIDDEN-PATH\t%s\t%d\t%s" % (label, len(hits), " ".join(hits[:5])))
    roots = sorted(k for k in inputs if k.startswith(FORBIDDEN_ROOTS))
    print("FORBIDDEN-ROOT\t%d\t%s" % (len(roots), " ".join(roots[:5])))

    # ---- the emitted bytes ------------------------------------------------------------------
    files, total = 0, 0
    emitted = {}
    for dirpath, dirnames, filenames in os.walk(dist):
        dirnames[:] = sorted(d for d in dirnames if d not in exclude)
        for fn in sorted(filenames):
            if not fn.endswith(".js"):
                continue
            full = os.path.join(dirpath, fn)
            text = open(full, encoding="utf-8", errors="replace").read()
            files += 1
            total += len(text)
            for spec in emitted_specifiers(text):
                name = builtin_name(spec)
                if name:
                    emitted.setdefault(name, {})
                    key = rel(repo, full)
                    emitted[name][key] = emitted[name].get(key, 0) + 1
    print("EMITTED-FILES\t%d" % files)
    print("EMITTED-CHARS\t%d" % total)
    for name in sorted(emitted):
        for f, n in sorted(emitted[name].items()):
            print("EMITTED-BUILTIN\t%s\t%s\t%d" % (name, f, n))
    print("scan.done\t1")


if __name__ == "__main__":
    main(sys.argv[1:])
