#!/usr/bin/env bash
# File the wasi-sdk 27 -> 33 toolchain bump upstream, as a pull request against
# AztecProtocol/aztec-packages, from the branch our fork already carries.
#
# One command. It checks its own preconditions, runs the tracker search the
# contribution requires, refuses to file twice, and records the URL afterwards.
# Add --dry-run to see exactly what it would send without sending it.
#
# This patch is standalone: nothing in the series needs to be filed before it.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
submit_main p2 "$@"
