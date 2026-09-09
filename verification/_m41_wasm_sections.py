#!/usr/bin/env python3
"""Read a wasm module's import and memory sections, or emit a one-import control module.

    _m41_wasm_sections.py <module.wasm>          -> KEY<TAB>VALUE rows
    _m41_wasm_sections.py --emit-control <path>  -> write a module with exactly one import

WHY READ THE BINARY WHEN THE ENGINE WILL ANSWER. `WebAssembly.Module.imports()` reports each
import's module name, field name and kind, and nothing else. It does NOT report whether an
imported or exported memory is SHARED, and a shared memory would invalidate the `static mut` the
writer module's session lives in -- the module is single-threaded by assumption, and that
assumption is in the binary's memory limits flags rather than in its import list. So the section
is read directly, and the two readings are asserted separately.

WHY EMIT A CONTROL RATHER THAN POINT AT ONE. "The import list is empty" is equally true of a
reader that cannot see imports at all, which is this campaign's most-repeated defect shape. A
control has to be a module that DOES import something; taking one from another build makes this
check depend on that build having happened. Twenty-odd bytes assembled here depends on nothing.

Rows printed:

    IMPORT_SECTION   present | absent
    IMPORT_COUNT     <n>                 (0 when the section is absent)
    IMPORT           <module>.<field>    one row each
    MEMORY_SECTION   present | absent
    SHARED_MEMORY    yes | no

A module that is not a wasm binary at all is a non-zero exit naming the first four bytes, never a
report of zero imports: "not a module" and "a module with no imports" must not read the same.
"""

import sys

MAGIC = b"\0asm"
SECTION_IMPORT = 2
SECTION_MEMORY = 5


def uleb(data, i):
    """One unsigned LEB128 at `i`. Returns (value, next-index)."""
    result = 0
    shift = 0
    while True:
        if i >= len(data):
            raise ValueError("a LEB128 runs off the end of the module")
        b = data[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7
        if shift > 63:
            raise ValueError("a LEB128 is longer than 64 bits")


def sections(data):
    """(id, payload) for every section, in order."""
    i = 8
    while i < len(data):
        sid = data[i]
        i += 1
        size, i = uleb(data, i)
        yield sid, data[i : i + size]
        i += size


def read(path):
    data = open(path, "rb").read()
    if data[:4] != MAGIC:
        print(
            f"_m41_wasm_sections: {path} does not start with the wasm magic "
            f"(first four bytes are {data[:4]!r})",
            file=sys.stderr,
        )
        return 1

    rows = []
    imports = []
    have_import = False
    have_memory = False
    shared = False

    for sid, payload in sections(data):
        if sid == SECTION_IMPORT:
            have_import = True
            n, i = uleb(payload, 0)
            for _ in range(n):
                mlen, i = uleb(payload, i)
                mod = payload[i : i + mlen].decode("utf-8", "replace")
                i += mlen
                flen, i = uleb(payload, i)
                field = payload[i : i + flen].decode("utf-8", "replace")
                i += flen
                kind = payload[i]
                i += 1
                if kind == 0x00:  # func
                    _, i = uleb(payload, i)
                elif kind == 0x01:  # table
                    i += 1
                    limits = payload[i]
                    i += 1
                    _, i = uleb(payload, i)
                    if limits & 0x01:
                        _, i = uleb(payload, i)
                elif kind == 0x02:  # memory
                    limits = payload[i]
                    i += 1
                    # Bit 1 of the limits flags is the shared bit (threads proposal). An imported
                    # shared memory is the case `Module.imports()` cannot report.
                    if limits & 0x02:
                        shared = True
                    _, i = uleb(payload, i)
                    if limits & 0x01:
                        _, i = uleb(payload, i)
                elif kind == 0x03:  # global
                    i += 2
                else:
                    raise ValueError(f"unknown import kind {kind}")
                imports.append(f"{mod}.{field}")
        elif sid == SECTION_MEMORY:
            have_memory = True
            n, i = uleb(payload, 0)
            for _ in range(n):
                limits = payload[i]
                i += 1
                if limits & 0x02:
                    shared = True
                _, i = uleb(payload, i)
                if limits & 0x01:
                    _, i = uleb(payload, i)

    rows.append(("IMPORT_SECTION", "present" if have_import else "absent"))
    rows.append(("IMPORT_COUNT", str(len(imports))))
    for name in imports:
        rows.append(("IMPORT", name))
    rows.append(("MEMORY_SECTION", "present" if have_memory else "absent"))
    rows.append(("SHARED_MEMORY", "yes" if shared else "no"))
    for k, v in rows:
        print(f"{k}\t{v}")
    return 0


def emit_control(path):
    """A module whose only content is one imported function. Hand-assembled, so it depends on
    nothing that could fail to be built."""
    body = bytearray()
    body += MAGIC + bytes([1, 0, 0, 0])
    # type section: one type, () -> ()
    body += bytes([0x01, 0x04, 0x01, 0x60, 0x00, 0x00])
    # import section: "m"."f" as func type 0
    import_payload = bytes([0x01, 0x01, ord("m"), 0x01, ord("f"), 0x00, 0x00])
    body += bytes([0x02, len(import_payload)]) + import_payload
    open(path, "wb").write(bytes(body))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--emit-control":
        return emit_control(argv[2])
    if len(argv) == 2:
        return read(argv[1])
    print("usage: _m41_wasm_sections.py <module.wasm> | --emit-control <path>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
