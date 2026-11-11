#!/usr/bin/env bash
# lib_subshell_die.sh — a precondition failure that is not lost inside a command substitution.
#
# Not to be executed directly: sourced after lib.sh by the milestone libraries whose data helpers
# are CALLED INSIDE `$( … )` or `<( … )` — `m20_anchor_file`, `m22_vendor_anchor_file`,
# `m22_vendor_diff`, `m23_anchor_file`, `m21_field` and their siblings.
#
# THE DEFECT IT CLOSES. `die` is `exit 1`, and inside a command substitution `exit` leaves only the
# SUBSHELL. `FILE="$(m22_vendor_anchor_file x)"` whose lookup fails prints the refusal on stderr
# and then the check carries on with FILE empty. Every assertion below it is then asked of an empty
# string, and an ABSENCE asked of an empty string passes: `m22_vendor_diff` on a vendored file that
# was not there produced an empty diff, and "carries NO local edit at all" printed `ok`. A helper
# documented as "fails LOUDLY rather than yielding empty" did both.
#
# THE MECHANISM. `die_even_in_subshell` refuses exactly as `die` does, and when it is running in a
# subshell it also appends the refusal to a file named for the TOP-LEVEL shell (`$$` is the same in
# every subshell of one script). `finish` is wrapped once so that, before it totals the run, each
# recorded refusal becomes a counted FAILURE — the run is red, and the reason is printed where the
# assertions are rather than only in the stderr scroll.

_SUBSHELL_DIE_MARK="${TMPDIR:-/tmp}/aztec-subshell-die.$$"

die_even_in_subshell() { # <message>
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    printf '%s\n' "$*" | head -1 >>"$_SUBSHELL_DIE_MARK"
  fi
  die "$*"
}

_subshell_deaths_to_failures() {
  [ -s "$_SUBSHELL_DIE_MARK" ] || { rm -f "$_SUBSHELL_DIE_MARK"; return 0; }
  local line
  while IFS= read -r line; do
    fail "a precondition died inside a command substitution, so what followed read an empty value: $line"
  done <"$_SUBSHELL_DIE_MARK"
  rm -f "$_SUBSHELL_DIE_MARK"
}

# Wrapped once, however many libraries source this file.
if ! declare -F _finish_before_subshell_deaths >/dev/null; then
  eval "_finish_before_subshell_deaths() $(declare -f finish | tail -n +2)"
  finish() {
    _subshell_deaths_to_failures
    _finish_before_subshell_deaths
  }
  # A run that exits before `finish` is already reported as a failure by the abnormal-exit summary;
  # the mark is only removed so it cannot outlive the process.
  rm -f "$_SUBSHELL_DIE_MARK"
fi
