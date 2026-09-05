#!/usr/bin/env bash
# The dev shell provides every command CI drives it with.
#
#   verification/verify_devshell_provides_ci_commands.sh   (or: just verify-devshell-commands)
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS. From the first workflow in this repository to 2026-09-04 — 141 runs on `dev`,
# 67 cancelled, 74 failure, 0 success — not one job reached a single assertion. `just` was not in
# `devShells.default.packages` and never had been (`git log -S'pkgs.just' -- flake.nix` is empty),
# so every job entered the shell, resolved nothing, and died:
#
#     /tmp/nix-shell.Ri0deR: line 2423: exec: just: not found
#     ##[error]Process completed with exit code 127
#
# Everything upstream of that worked. The checkouts succeeded, `setup-dev-env` succeeded, the nix
# shell built. The one thing that never happened was the work.
#
# WHAT MADE IT SURVIVE 141 RUNS. The M28 gate asserts its own CI wiring by reading the workflow
# YAML: that the job is declared, that it invokes the recipe BY NAME, that it triggers on
# `pull_request`, that it carries no event filter. Every one of those assertions is TRUE, and was
# true throughout — while the job it describes had never got past `just: not found`. A gate that
# certifies a job EXISTS cannot notice that CI cannot START it. The workflow was not wrong; the
# shell it invoked was empty of the one binary the workflow's every step is written in terms of.
#
# So this check is deliberately not another reading of the workflow. It is the JOIN between the two
# files that were each internally consistent and jointly broken: the set of commands `avm-wasm.yml`
# and `carry.yml` hand to `dev-exec`, resolved against the PATH of the shell those workflows
# actually get. It is a static check with no network and no build, and it fails in under a second.
#
# WHAT IT DOES AND DOES NOT COVER. It runs INSIDE the dev shell, so it cannot catch the removal of
# `just` itself — that kills CI upstream of every check, this one included. It catches the NEXT
# instance of the class, which is the reachable one: a workflow step that starts driving the shell
# with a tool nobody added to it. `just` is asserted anyway, explicitly and by name, so that the
# original defect has a named guard rather than an implied one, and so this file records what the
# 141 runs cost.
#
# THE CONTROLS ARE THE POINT. Two ways this check could pass while measuring nothing: the workflow
# parser could return an empty command set, and `command -v` could be unable to say "no". Both are
# asserted against, in both directions, as ASSERTIONS rather than bare guards — a control that
# prints nothing when it passes is a control nobody can audit, and it does not reach the count
# either. `lib.sh`'s `finish` already refuses a zero-assertion pass; these make the count MEAN
# something rather than merely be non-zero.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=verify_devshell_provides_ci_commands
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

summary_on_abnormal_exit

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
assert_dir "the workflow directory exists" "$WORKFLOW_DIR"

# ---------------------------------------------------------------------------
# 1. THE PARSER, AND THE CONTROL THAT IT PARSES
# ---------------------------------------------------------------------------
#
# `dev-exec` takes the command to run in the dev shell as its argument vector; the first token
# after it is the binary that must resolve. Trailing `2>&1 | tee …` is the step's redirection, not
# the command, so only the first token is taken.
dev_exec_commands() { # <text> -> one command name per line, sorted, unique
  printf '%s\n' "$1" \
    | grep -oE '(^|[^[:alnum:]_-])dev-exec[[:space:]]+[A-Za-z_][A-Za-z0-9_.-]*' \
    | grep -oE '[A-Za-z_][A-Za-z0-9_.-]*$' \
    | sort -u
}

assert_eq "control: the parser finds the command after dev-exec" "just" \
  "$(dev_exec_commands 'run: dev-exec just verify-m7 2>&1 | tee verify-m7.log')"
assert_eq "control: …and is not fooled by a hyphenated look-alike step name" "" \
  "$(dev_exec_commands 'run: not-dev-exec-wrapper just verify-m7')"
assert_eq "control: …and reads both of two different commands, not just the first" \
  "$(printf 'just\nnpm')" \
  "$(dev_exec_commands 'a: dev-exec npm ci
b: dev-exec just verify-m16')"

WF_TEXT=""
WF_COUNT=0
for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -f "$wf" ] || continue
  WF_TEXT="$WF_TEXT
$(cat "$wf")"
  WF_COUNT=$((WF_COUNT + 1))
done
assert_ge "there are workflow files to read" 2 "$WF_COUNT"
assert_ge "…and they read back as a substantial body of text, not an empty glob" \
  20000 "$(printf '%s' "$WF_TEXT" | wc -c)"

CI_COMMANDS="$(dev_exec_commands "$WF_TEXT")"
note "commands the workflows hand to dev-exec: $(printf '%s' "$CI_COMMANDS" | tr '\n' ' ')"

# THE COUNT IS ASSERTED BEFORE THE LOOP. A parser that silently returned nothing would otherwise
# run zero iterations and this file would report a green with no subject — which is precisely the
# shape of failure it was written about.
assert_ge "the workflows drive the dev shell with at least one command" 1 \
  "$(printf '%s\n' "$CI_COMMANDS" | grep -c . || true)"
assert_true "…and \`just\` is among them, which is what every verify-mNN step is written in" \
  str_has_line "$CI_COMMANDS" "just"

# ---------------------------------------------------------------------------
# 2. THE INSTRUMENT DISCRIMINATES
# ---------------------------------------------------------------------------
#
# `command -v` answering "present" for everything is a real failure mode of this check, and one
# that would restore exactly the silence the 141 runs had. The negative control is a name that
# cannot exist on any PATH.
resolves() { command -v "$1" >/dev/null 2>&1; }

assert_true  "control: the resolver finds a command that is certainly present" resolves bash
assert_false "control: …and does NOT find one that cannot exist, so its yes means something" \
  resolves this-command-does-not-exist-4f3a9c

# ---------------------------------------------------------------------------
# 3. THE JOIN
# ---------------------------------------------------------------------------
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  assert_true "the dev shell provides \`$cmd\`, which a workflow step hands to dev-exec" \
    resolves "$cmd"
done <<EOF
$CI_COMMANDS
EOF

# `just` by name as well as by parse, so the defect this file was written about has a guard that
# survives a workflow rewrite that renames or restructures the steps.
assert_true "\`just\` resolves in the dev shell — the 141-run defect, asserted directly" \
  resolves just
assert_ge "…and it is a real just, which answers with a version" 1 \
  "$(just --version 2>/dev/null | grep -c '^just ' || true)"

# The flake is the thing that has to carry it. Asserted separately from the PATH check because a
# shell can inherit `just` from the caller's environment and still leave CI broken.
FLAKE="$REPO_ROOT/flake.nix"
assert_file "the flake exists" "$FLAKE"
assert_true "…and IT declares just, so the shell does not depend on inheriting one" \
  str_has_re "$(cat "$FLAKE")" 'pkgs\.just'

finish
