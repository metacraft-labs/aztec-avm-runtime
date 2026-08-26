#!/usr/bin/env bash
# lib_m18_orchestration.sh — shared machinery for the M18 checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M18 puts Aztec's own transaction orchestration on top of the wasm AVM, so its checks read three
# things: the fork at the TypeScript anchor (what upstream actually has), the published @aztec/*
# packages (what a consumer can actually reach), and `orchestration/` (what we ship).
#
# THE PRECONDITIONS ARE PRECONDITIONS, NOT SKIPS. A check that cannot see the anchor, or that has
# no installed packages to walk an import graph over, DIES with the command that fixes it. It
# never reports "0 problems found" against a tree it could not read — which is the shape of
# vacuous assertion this campaign has now found twenty-four times.

M18_WORK="${M18_WORK:-$HOME/.cache/aztec-m18-orchestration}"
export M18_WORK

# The TypeScript anchor. Read out of pins.json rather than restated, so that a repin moves this
# and the documents together or fails loudly.
M18_TS_ANCHOR="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["anchors"]["ts"]["commit"])' "$REPO_ROOT/pins.json" 2>/dev/null)"
export M18_TS_ANCHOR

ORCH_DIR="$REPO_ROOT/orchestration"
ORCH_SRC="$ORCH_DIR/src"
export ORCH_DIR ORCH_SRC

m18_require_anchor() {
  case "$M18_TS_ANCHOR" in
    [0-9a-f][0-9a-f]*) : ;;
    *) die "pins.json does not name a TypeScript anchor commit" ;;
  esac
  git -C "$FORK_ROOT" cat-file -e "$M18_TS_ANCHOR^{commit}" 2>/dev/null \
    || die "the fork at $FORK_ROOT does not have the TypeScript anchor $M18_TS_ANCHOR
             Fetch it: git -C $FORK_ROOT fetch upstream next"
}

# The published packages the orchestration depends on. Not vendored by this repository, and the
# remedy is one command; `npm ci` rather than `npm install` because the lockfile is tracked and a
# check must not be able to move a dependency underneath itself.
m18_require_packages() {
  [ -d "$ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed, and the import graph cannot
             be walked without them.
             Remedy: cd $ORCH_DIR && npm ci"
}

# Read a file out of the fork at the anchor. Fails loudly rather than yielding empty, because an
# empty haystack is how a `grep -c` assertion becomes an assertion about nothing.
m18_anchor_file() { # <path-in-fork>
  git -C "$FORK_ROOT" show "$M18_TS_ANCHOR:$1" 2>/dev/null \
    || die "the anchor has no $1 (the layout moved; the check's premise is stale)"
}

m18_anchor_has() { # <path-in-fork>
  git -C "$FORK_ROOT" cat-file -e "$M18_TS_ANCHOR:$1" 2>/dev/null
}

# Every path at the anchor matching a pattern, so an enumeration is over the tree rather than
# over a list somebody typed.
m18_anchor_paths() { # <pathspec...>
  git -C "$FORK_ROOT" ls-tree -r --name-only "$M18_TS_ANCHOR" -- "$@" 2>/dev/null
}

# Classify a repository path as test or production, ONE WAY, in one place. Six patterns, and they
# are here rather than inline because two checks disagreeing about whether `fixtures/` is a test
# directory would silently produce two different counts of the same thing.
M18_TEST_PATTERN='\.test\.ts$|/test/|/tests/|/testing/|/fixtures/|/apps_tests/|/mocks/|\.bench\.'
export M18_TEST_PATTERN

m18_is_test_path() { # <path>
  str_has_line_re "$1" "$M18_TEST_PATTERN"
}

# The import-graph walker, with its work landing in M18's own directory.
m18_import_graph() { # <from-dir> <entry> <out-json>
  node "$REPO_ROOT/tools/import_graph.mjs" --entry "$2" --from "$1" --json "$3"
}

m18_graph_packages() { # <graph-json>
  python3 -c '
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["packages"]))' "$1"
}

m18_graph_has_package() { # <graph-json> <package>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in d["packages"] else "no")' "$1" "$2"
}

m18_graph_modules() { # <graph-json>
  python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["module_count"])' "$1"
}
