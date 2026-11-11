#!/usr/bin/env python3
"""List backticks that open a command substitution inside a double-quoted shell string.

    verification/_dq_backticks.py <file.sh>...   -> one `path:line: text` per site, exit 0

A check's assertion text is prose, and prose quotes code the way Markdown does:
"…and `fn` one". Inside double quotes bash reads that backtick as a command substitution, so
the shell RUNS `fn`, the description loses the word, and whatever the name happens to be on
PATH is executed. Escaping it (\\`) is the whole fix; this finds the sites.

The walker tracks single quotes, double quotes and `$( … )` nesting on each line (a `$(`
inside double quotes starts a fresh context, in which single quotes are literal again), skips
comment lines, and skips here-document bodies, which are another language's source.
"""
import re
import sys


def scan_line(line, stack):
    found = False
    i = 0
    while i < len(line):
        c = line[i]
        st = stack[-1]
        if st in ("top", "sub"):
            if c == "#" and (i == 0 or line[i - 1] in " \t"):
                return found
            if c == "\\":
                i += 2
                continue
            if c == "'":
                stack.append("sq")
            elif c == '"':
                stack.append("dq")
            elif c == ")" and st == "sub":
                stack.pop()
            elif line.startswith("$(", i):
                stack.append("sub")
                i += 2
                continue
        elif st == "sq":
            if c == "'":
                stack.pop()
        elif st == "dq":
            if c == "\\":
                i += 2
                continue
            if c == '"':
                stack.pop()
            elif line.startswith("$(", i):
                stack.append("sub")
                i += 2
                continue
            elif c == "`":
                found = True
        i += 1
    return found


def scan(path):
    hits = []
    heredoc = None
    # The quoting state CARRIES ACROSS LINES: a `python3 -c '…'` body or a multi-line double-quoted
    # message spans many, and reading each line from a fresh state would take a Python string's
    # backtick for a shell one.
    stack = ["top"]
    for n, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = raw.rstrip("\n")
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        if stack[-1] in ("top", "sub") and line.lstrip().startswith("#"):
            continue
        if scan_line(line, stack):
            hits.append(f"{path}:{n}: {line.strip()[:140]}")
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z_0-9]*)['\"]?", line)
        if m and "<<<" not in line and stack[-1] in ("top", "sub"):
            heredoc = m.group(1)
    return hits


if __name__ == "__main__":
    for p in sys.argv[1:]:
        for h in scan(p):
            print(h)
