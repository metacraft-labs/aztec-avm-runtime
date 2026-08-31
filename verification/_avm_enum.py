#!/usr/bin/env python3
"""Read a C++ enum's member names out of a header, for checks that must not type an opcode number.

    _avm_enum.py <header-file> <enum-declaration> [member-name]

With a member name it prints that member's INDEX, or `ABSENT`. Without one it prints the member
COUNT. A declaration it cannot find prints `NO-ENUM`, which is a refusal and not a zero — a check
that read 0 for "how many opcodes are there" would then compare two absences, which is the first
form on `CAMPAIGN-BRIEF.md`'s list of assertions that cannot fail.

WHY IT IS A FILE AND NOT A HEREDOC. The first version of `test_custom_bytecode_unhappy_paths` piped
the header into `python3 - <<'PY'`, and the heredoc IS the script on stdin — so `sys.stdin.read()`
returned nothing and every derived number came back `NO-ENUM`. It went red on its own first run,
which is the cheap direction, and this file is the fix.

It is deliberately a SECOND implementation of the parse `tools/run_token_block_arms.mjs` performs in
JavaScript. Two independent derivations of a number that decides an arm is corroboration this
campaign almost never gets, and the check asserts the two agree.
"""

import re
import sys

MEMBER = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*(=[^,]*)?,\s*(//.*)?$")


def members(source: str, declaration: str) -> list[str] | None:
    start = source.find(declaration)
    if start < 0:
        return None
    names = []
    for line in source[start:].split("\n")[1:]:
        if line.strip().startswith("};"):
            break
        m = MEMBER.match(line)
        if m:
            names.append(m.group(1))
    return names


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: _avm_enum.py <header-file> <declaration> [member]")
    source = open(sys.argv[1], encoding="utf-8").read()
    names = members(source, sys.argv[2])
    if names is None or not names:
        print("NO-ENUM")
        return
    if len(sys.argv) == 3:
        print(len(names))
        return
    print(names.index(sys.argv[3]) if sys.argv[3] in names else "ABSENT")


if __name__ == "__main__":
    main()
