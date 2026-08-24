#!/usr/bin/env bash
# lib_m16_fallback.sh — shared plumbing for M16's two checks.
#
# M16 is the campaign's narrowed fallback: revive the deleted TypeScript merkle trees instead of
# using Aztec's own C++ world_state_reference in wasm. It is executed only if one of three
# conjunctions fires, and none of them does — but the milestone requires the evaluation and the
# price to be RECORDED either way, so a future reader need not redo them.
#
# The two things this library exists to keep honest:
#
#   1. THE PRICE IS MEASURED, NOT QUOTED. Every figure comes out of the installed
#      @aztec/merkle-tree tree under probe-mt/node_modules/, which is the last published nightly
#      that ships the package at all. A price copied out of the milestone text would agree with the
#      milestone text forever.
#   2. NOTHING HERE BUILDS ANYTHING, AND NOTHING HERE READS ANOTHER MILESTONE'S WORK DIRECTORY.
#      M16 has no work directory and takes no lock, because it compiles nothing. Where it relies on
#      a number another milestone measured — the checkpoint costs, the crossing count — it binds to
#      the DOCUMENT that milestone's own check re-derives, and says so, rather than reading a stale
#      artefact out of ~/.cache and calling it a measurement.
#
# Not to be executed directly: sourced by verification/verify_fallback_*.sh.

# The deleted package, as installed. probe-mt/ is the tree pins.json points at
# (`npm_consumers.probe-mt = deletion_era`, with @aztec/merkle-tree carried as a declared
# npm_exceptions entry because no later nightly ships it).
M16_PROBE_DIR="$REPO_ROOT/probe-mt"
M16_PKG_DIR="$M16_PROBE_DIR/node_modules/@aztec/merkle-tree"
M16_DOC="$REPO_ROOT/FALLBACK.md"
M16_PRICE="$VERIFY_DIR/_fallback_price.py"
M16_PARSER="$VERIFY_DIR/_fallback_parser.py"
export M16_PROBE_DIR M16_PKG_DIR M16_DOC M16_PRICE M16_PARSER

# m16_require_package: a check that cannot see the package FAILS, with the remedy in the message.
# It never skips: "the fallback could not be priced" is the one answer this milestone must not
# quietly return.
m16_require_package() {
  command -v node >/dev/null 2>&1 || die "node is not available"
  command -v python3 >/dev/null 2>&1 || die "python3 is not available"
  [ -f "$M16_DOC" ] || die "FALLBACK.md does not exist at $M16_DOC"
  [ -d "$M16_PROBE_DIR" ] || die "probe-mt/ does not exist at $M16_PROBE_DIR"
  [ -d "$M16_PKG_DIR" ] || die \
    "the deleted @aztec/merkle-tree is not installed at $M16_PKG_DIR
             It is the artefact this milestone prices; run \`npm install\` in probe-mt/.
             pins.json carries it as a declared npm_exceptions entry because upstream removed the
             package in e264dd4893 and no later nightly ships it."
}

# m16_key <keyvalue-file> <key>: read one `key=value` line. Empty if absent, which every caller
# then fails on rather than treating as a zero.
m16_key() { # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n1
}

# m16_doc_has <needle>: does FALLBACK.md carry this, with whitespace collapsed so a wrapped
# sentence still matches? Used to hold the document to the numbers the checks measured, in the
# direction that matters: the MEASUREMENT is the authority and the prose is held to it.
m16_doc_has() { # <needle>
  python3 - "$M16_DOC" "$1" <<'PY'
import re, sys
doc = re.sub(r"\s+", " ", open(sys.argv[1], encoding="utf-8").read())
sys.exit(0 if re.sub(r"\s+", " ", sys.argv[2]) in doc else 1)
PY
}

# m16_assert_doc_records <description> <needle>: the pair above, as an assertion.
m16_assert_doc_records() { # <description> <needle>
  if m16_doc_has "$2"; then
    pass "FALLBACK.md records $1  [$2]"
  else
    fail "FALLBACK.md does not record $1  — expected to find [$2]"
  fi
}

# m16_words <file...> : count word-boundary occurrences of a regex across files. The campaign has
# been bitten eleven times by a needle that could not match, so every "N occurrences" claim in
# M16's checks is paired with a POSITIVE control that runs the same regex over a file known to
# contain the word.
m16_words() { # <regex> <file...>
  local rx="$1"; shift
  # MULTILINE as well as IGNORECASE, because a pattern anchored with `^` and applied without it
  # matches only at the start of the file and then reports a confident zero. That is precisely the
  # failure this campaign has already shipped once, in a check that asserted a count of zero on a
  # needle which could never have matched anything.
  python3 - "$rx" "$@" <<'PY'
import re, sys
rx = re.compile(sys.argv[1], re.IGNORECASE | re.MULTILINE)
n = 0
for p in sys.argv[2:]:
    try:
        n += len(rx.findall(open(p, encoding="utf-8", errors="replace").read()))
    except OSError:
        pass
print(n)
PY
}
