#!/usr/bin/env bash
# verify_advertised_systems_construct — every system a campaign flake advertises can be constructed.
#
# THE RULE. Each of the campaign's two flakes (this repository's, and the sibling fork's at
# ../aztec-packages) names its platforms in flake-parts' `systems` list. A system belongs in that
# list only when the flake can actually be built for it: every output it defines for that system
# evaluates at the nixpkgs revision `flake.lock` pins, the resulting shell carries the toolchain
# versions `pins.json` records, and a native machine exists on which the gates can run. The last
# two are reviewed when a system is added; the first is mechanical, and this check enforces it.
#
# WHY IT IS A CHECK. Both flakes advertised `x86_64-darwin` from their first commit until
# 2026-10-23, while the nixpkgs they lock (26.11) had already dropped that platform: every output
# for it ended in `error: Nixpkgs 26.11 has dropped support for x86_64-darwin.` Nothing noticed,
# because nothing evaluated a system other than the host's — `nix develop` only ever constructs the
# shell of the machine it runs on, and no runner is Intel Darwin. A list of platforms that no
# command reads is a claim with no test behind it. This check is the test: it reads the list and
# evaluates all of it, on whatever host it runs.
#
# WHAT IT DOES, per flake:
#   1. Reads the advertised systems as the attribute names of `devShells` and `packages` (the
#      outputs flake-parts transposes from `systems`). Each name list is evaluated on its own, so
#      the per-system VALUES — which is where nixpkgs' platform refusal lives — are not forced
#      here. An empty list, a failed evaluation, or two outputs that disagree is a failure: a flake
#      that advertises nothing, or whose list cannot be read, proves nothing by passing.
#   2. For every advertised system, lists `devShells.<system>`, `packages.<system>`,
#      `checks.<system>` and `apps.<system>` and evaluates EVERY member in them (`.drvPath`, or an
#      app's `.program`). That is `nix eval` only — instantiation, no build, no download beyond the
#      locked inputs — so a host of any platform can check every advertised system. Each member is
#      a separate `nix eval`, so one refusal does not hide the next.
#   3. Fails if any OTHER top-level output (`legacyPackages`, `formatter`, …) is non-empty for an
#      advertised system, because that output would be advertised without being evaluated here.
#   4. Fails naming the flake, the system, the output and the first `error:` line nix printed.
#
# The flakes are evaluated as `<checkout>` (git+file), which is what `nix develop` in that checkout
# uses: tracked modifications are seen, untracked files are not. `--no-update-lock-file` makes an
# evaluation that would need a different lock a failure rather than a silent re-lock.
#
# Up to VERIFY_SYSTEMS_JOBS (default 4) per-system evaluations run at once.
#
# Run: just verify-advertised-systems   (also run by `just check-repo-hygiene`)

TEST_NAME="verify_advertised_systems_construct"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_nix

JOBS="${VERIFY_SYSTEMS_JOBS:-4}"
case "$JOBS" in '' | *[!0-9]* | 0) die "VERIFY_SYSTEMS_JOBS must be a positive integer, got [$JOBS]" ;; esac

# The per-system outputs whose every member must instantiate. `devShells`, `packages` and `checks`
# are derivation-valued, so `.drvPath` is the whole of "it constructs" without building anything;
# an `apps` member is `{ type = "app"; program = "<store path>"; }`, and forcing `program` forces
# the derivation it names. Both flakes define only devShells and packages today; checks and apps
# are covered because flake-parts gives them a slot for every system, and the first one added
# must not be the first output nobody evaluates.
OUTPUT_KINDS="devShells packages checks apps"

# Per-system outputs this check does NOT evaluate member by member. `legacyPackages` may be a whole
# nixpkgs, so enumerating it is not an option, and `formatter.<system>` is a single derivation.
# Rather than being silently uncovered, each of them must be EMPTY for every advertised system:
# a flake that starts using one fails here until this check is taught to evaluate it.
# Every other top-level output whose value is keyed by an advertised system is held to the same
# rule (see uncovered_outputs).
COVERED_KINDS_NIX='[ "devShells" "packages" "checks" "apps" ]'

# member_attr <kind>: the attribute of one member whose evaluation is "it constructs", and the
# shape its value must have.
member_attr() {
  case "$1" in
    apps) printf 'program' ;;
    *)    printf 'drvPath' ;;
  esac
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/verify-advertised-systems.XXXXXX")" \
  || die "could not create a scratch directory under ${TMPDIR:-/tmp}"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

# nix_eval <out-file> <err-file> <args...>: one `nix eval`, nothing shared between calls.
nix_eval() {
  local outf="$1" errf="$2"; shift 2
  nix eval --no-update-lock-file "$@" >"$outf" 2>"$errf"
}

# first_error_line <err-file>: the first line of nix's diagnostic that carries a message.
# nix prints a bare `error:` header, then `…` trace frames, then the real `error: <message>`; the
# header alone says nothing, so it is skipped. Falls back to the last non-blank line, so a failure
# with an unexpected shape is still reported with SOMETHING rather than an empty reason.
first_error_line() {
  local line found=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "error: "?*) found="$line"; break ;;
    esac
  done <"$1"
  if [ -z "$found" ]; then
    found="$(sed '/^[[:space:]]*$/d' "$1" | tail -1)"
    found="${found#"${found%%[![:space:]]*}"}"
  fi
  printf '%s' "${found:-<nix printed no diagnostic>}"
}

# json_names <file>: a JSON array of strings, one per line. python3 is in both dev shells and on
# every host these checks run on; a hand-rolled JSON split would be the kind of parser that passes
# on the happy path only.
json_names() {
  python3 -c 'import json,sys; [print(n) for n in json.load(open(sys.argv[1]))]' "$1"
}

# check_system <flake-label> <flake-ref> <system> <record-file>
#
# Runs in a background job, so it cannot touch the parent's counters: it writes `ok <text>` /
# `FAIL <text>` records that the parent replays through pass/fail in a fixed order.
check_system() {
  local label="$1" ref="$2" sys="$3" rec="$4"
  local kind name n out err drv attr names_json names_list total=0
  : >"$rec"
  for kind in $OUTPUT_KINDS; do
    attr="$(member_attr "$kind")"
    names_json="$SCRATCH/$label.$sys.$kind.names"; err="$names_json.err"
    if ! nix_eval "$names_json" "$err" --json "$ref#$kind.$sys" --apply builtins.attrNames; then
      printf 'FAIL %s: %s.%s cannot be listed: %s\n' \
        "$label" "$kind" "$sys" "$(first_error_line "$err")" >>"$rec"
      continue
    fi
    # Decoded to a file first, and its status checked: a decoder failure inside a process
    # substitution would read as "no members", which for `packages` is a silent pass.
    names_list="$names_json.list"
    if ! json_names "$names_json" >"$names_list" 2>"$names_list.err"; then
      printf 'FAIL %s: %s.%s member names could not be decoded: %s\n' \
        "$label" "$kind" "$sys" "$(first_error_line "$names_list.err")" >>"$rec"
      continue
    fi
    n=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      n=$((n + 1))
      out="$SCRATCH/$label.$sys.$kind.$name.$attr"; err="$out.err"
      if nix_eval "$out" "$err" --raw "$ref#$kind.$sys.\"$name\".$attr"; then
        drv="$(cat "$out")"
        case "$kind:$drv" in
          apps:/nix/store/?* | *:/nix/store/*.drv)
            total=$((total + 1))
            printf 'ok %s: %s.%s.%s instantiates  [%s]\n' "$label" "$kind" "$sys" "$name" "$drv" >>"$rec" ;;
          *)
            printf 'FAIL %s: %s.%s.%s.%s evaluated to something that is not a store path of the expected kind [%s]\n' \
              "$label" "$kind" "$sys" "$name" "$attr" "$drv" >>"$rec" ;;
        esac
      else
        printf 'FAIL %s: %s.%s.%s does not evaluate: %s\n' \
          "$label" "$kind" "$sys" "$name" "$(first_error_line "$err")" >>"$rec"
      fi
    done <"$names_list"
    # Every flake here defines a default shell; a system with no shell at all is advertised for
    # nothing. Packages may legitimately be empty for a system, so only devShells is held to it.
    if [ "$kind" = devShells ] && [ "$n" -eq 0 ]; then
      printf 'FAIL %s: devShells.%s is empty — the system is advertised with no shell\n' \
        "$label" "$sys" >>"$rec"
    fi
  done
  printf 'COUNT %s\n' "$total" >>"$rec"
}

# advertised_systems <flake-label> <flake-ref>: asserts the system list is readable, non-empty and
# the same for every output kind, and leaves it in ADVERTISED (space-separated). It runs in the
# calling shell, not in a command substitution, because its assertions must reach the counters.
ADVERTISED=""
advertised_systems() {
  local label="$1" ref="$2" kind out err names first="" first_kind=""
  for kind in $OUTPUT_KINDS; do
    out="$SCRATCH/$label.$kind.systems"; err="$out.err"
    if ! nix_eval "$out" "$err" --json "$ref#$kind" --apply builtins.attrNames; then
      fail "$label: the systems of $kind cannot be read: $(first_error_line "$err")"
      continue
    fi
    names="$(json_names "$out" | sort | tr '\n' ' ')"
    names="${names% }"
    if [ -z "$names" ]; then
      fail "$label: $kind advertises no systems at all"
      continue
    fi
    pass "$label: $kind advertises  [$names]"
    if [ -z "$first_kind" ]; then
      first="$names"; first_kind="$kind"
    else
      assert_eq "$label: $kind advertises the same systems as $first_kind" "$first" "$names"
    fi
  done
  ADVERTISED="$first"
}

# uncovered_outputs <flake-label> <flake-ref> <systems>: fails if any top-level output other than
# the covered kinds has a non-empty value for an advertised system. Such an output would be
# advertised for that system without this check ever evaluating it. Comparing a value with `{}`
# forces it only to its top-level attribute set, so a `legacyPackages` that is a whole nixpkgs
# costs nothing here, while one that is refused for the system fails, as it should.
uncovered_outputs() {
  local label="$1" ref="$2" systems="$3" sys nix_systems="" out err found
  for sys in $systems; do nix_systems="$nix_systems \"$sys\""; done
  out="$SCRATCH/$label.uncovered"; err="$out.err"
  if ! nix_eval "$out" "$err" --json "$ref#." --apply "
    f: let
      systems = [ $nix_systems ];
      covered = $COVERED_KINDS_NIX;
      perSystem = k: let v = f.\${k}; in
        builtins.isAttrs v && builtins.any (s: v ? \${s} && v.\${s} != {}) systems;
    in builtins.filter perSystem
      (builtins.filter (k: !(builtins.elem k covered)) (builtins.attrNames f))"; then
    fail "$label: the per-system outputs outside [$OUTPUT_KINDS] cannot be read: $(first_error_line "$err")"
    return
  fi
  if ! found="$(json_names "$out" 2>"$out.dec.err")"; then
    fail "$label: the uncovered-output list could not be decoded: $(first_error_line "$out.dec.err")"
    return
  fi
  found="$(printf '%s' "$found" | tr '\n' ' ')"
  found="${found% }"
  assert_eq "$label: no per-system output outside [$OUTPUT_KINDS] is defined, so none goes unevaluated" "" "$found"
}

check_flake() { # <label> <checkout-root>
  local label="$1" root="$2" ref sys systems running=0 count total=0 line
  note "--- $label  ($root)"
  [ -d "$root" ] || { fail "$label: no checkout at $root"; return; }
  assert_file "$label: has flake.nix" "$root/flake.nix"
  assert_file "$label: has flake.lock" "$root/flake.lock"
  [ -f "$root/flake.nix" ] || return
  ref="$root"

  advertised_systems "$label" "$ref"
  systems="$ADVERTISED"
  [ -n "$systems" ] || { fail "$label: no advertised system to evaluate"; return; }
  uncovered_outputs "$label" "$ref" "$systems"

  for sys in $systems; do
    check_system "$label" "$ref" "$sys" "$SCRATCH/$label.$sys.rec" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
  done
  wait

  for sys in $systems; do
    count=""
    while IFS= read -r line; do
      case "$line" in
        "ok "*)    pass "${line#ok }" ;;
        "FAIL "*)  fail "${line#FAIL }" ;;
        "COUNT "*) count="${line#COUNT }" ;;
      esac
    done <"$SCRATCH/$label.$sys.rec"
    # A record without its COUNT line means the job died before finishing: that is a failure,
    # never an absence of failures.
    if [ -z "$count" ]; then
      fail "$label: the evaluation of $sys did not complete"
    else
      total=$((total + count))
    fi
  done
  assert_ge "$label: outputs instantiated across all advertised systems" 1 "$total"
}

check_flake "aztec-avm-runtime" "$REPO_ROOT"
check_flake "aztec-packages" "$FORK_ROOT"

finish
