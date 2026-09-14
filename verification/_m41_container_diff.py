#!/usr/bin/env python3
"""Compare the two writers' containers stream by stream, with every difference NAMED.

    _m41_container_diff.py <work-dir>

`<work-dir>` holds, for each of `path-a` and `path-b`:

    <arm>/container.ct          the container
    <arm>/report.json           the driving module's own counters
    <arm>/probe-reader.tsv      ct-split-probe        (the READER anchor)
    <arm>/probe-writer.tsv      ct-split-probe-writer (the WRITER anchor)
    <arm>/full-reader.json      ct-print --full at the reader anchor, or absent
    <arm>/full-writer.json      ct-print --full at the writer anchor, or absent

Prints `SAME <key> <value>` and `DIFF <key> <a> <b>` rows, then a verdict.

---------------------------------------------------------------------------
WHY A CATALOGUE AND NOT A DIFF
---------------------------------------------------------------------------

M41's deliverable is "container equivalence characterised, NOT assumed byte-identical: say exactly
which streams differ and why". A bare diff satisfies neither half — it neither explains nor fails.
So every differing key must appear in CATALOGUE below with a reason, and:

  * a DIFF whose key is NOT catalogued is an ERROR. That is the direction a reviewer expects.
  * a catalogued key that comes back SAME is ALSO an error. That is the direction a catalogue rots
    in: a reason written for a difference that has since gone away reads as current, and the next
    reader believes it. A stale entry is a wrong statement about the artefact, which is the same
    defect as a missing one pointing the other way.

Keys that are expected to differ TRIVIALLY -- the module path each arm was driven from -- are not
compared at all rather than catalogued, and the ignore list is short and explicit.
"""

import json
import os
import sys

# ---------------------------------------------------------------------------
# THE CATALOGUE. Every difference between the two containers, named, with the reason it exists.
# ---------------------------------------------------------------------------
CATALOGUE = {
    "report.writerKind": (
        "By construction. `ct_writer_kind()` returns the ACTIVE BACKEND's constant, so the two "
        "modules must disagree here or the field would be a literal. 1 is DD-7's Path A, 2 is "
        "Path B."
    ),
    "report.containerBytes": (
        "Path A's container carries an `events.log` that Path B's does not (see "
        "`internal.events_log`), and the two writers pack their split streams under different "
        "meta.dat schema versions. The figure is reported rather than bounded: CTFS allocates in "
        "blocks, so a byte count cannot tell two traces apart in either direction and is not "
        "evidence of anything on its own."
    ),
    "header.ctfs_version": (
        "The CTFS CONTAINER format version, byte 5 of the header. Path A writes 3; Path B writes "
        "4. A v4 reader accepts 2, 3 and 4, so this byte alone is not what makes Path A's "
        "container unreadable to the current reader -- `meta.schema_version` is."
    ),
    "header.max_shards": (
        "Byte 7 of the CTFS header. Path A writes 0, Path B writes 1. A sharding parameter of the "
        "container layer, chosen by each writer's own constructor; neither container is sharded."
    ),
    "probe.VALUES0_COUNT": (
        "Path A's first step is the first AVM step and carries its six values; Path B's first step "
        "is the start-step, which carries none. The values are present in both containers -- "
        "`report.eventsWritten` is asserted EQUAL, and it is the MODULE's own count of the events "
        "it wrote -- they are attached one step later."
    ),
    "probe.VALUES0_NAMES": ("The same cause as `probe.VALUES0_COUNT`."),
    "probe.VALUES0_BYTES": ("The same cause as `probe.VALUES0_COUNT`."),
    "probe.VALUES0_COUNT": (
        "WHERE A CALL'S ARGUMENT ATTACHES, and it is the one substantive difference left between "
        "the two writers. Path A emits a non-toplevel call's arguments as `Value` events BEFORE the "
        "`Call` -- `ctfs_sink.rs`'s override, which `backend_rust.rs` mirrors -- so the driver's "
        "`ct_call` puts `contractAddress` on whichever step is current, which is the entry step. "
        "Path B hands the same argument to `trace_writer_register_call_arg`, which carries it "
        "INSIDE the call record, so no value lands on the entry step. Both containers hold the "
        "argument and both readers surface it; they disagree about which stream it travels in. "
        "`probe.VALUES1_*` -- the recorder's first real step -- is asserted EQUAL, which is what "
        "says this is about the call argument and not about the step variables."
    ),
    "probe.VALUES0_NAMES": ("The same cause as `probe.VALUES0_COUNT`."),
    "probe.VALUES0_BYTES": ("The same cause as `probe.VALUES0_COUNT`."),
    "meta.flags": (
        "Path A's capability flags are NOT REPORTED AT ALL by the reader that can read its "
        "container, and Path B's are. That is a consequence of `internal.events_log`: `ct-print` "
        "sends a container carrying an `events.log` down its legacy combined-stream reader, which "
        "reconstructs `program`, `args` and `workdir` and knows nothing about meta.dat capability "
        "bits. So this row is not 'Path A declares different flags' -- it is 'nothing that reads "
        "Path A's container reports flags for it'. What both containers ARE measured to agree on "
        "is `probe.COLUMN_AWARE`, which each container's own working reader answers from the "
        "stream rather than from the flag."
    ),
    "internal.events_log": (
        "THE DIFFERENCE THE MILESTONE NAMED IN ADVANCE, and it is larger than the eight-byte "
        "header it was described as. Path A's `CtfsTraceWriter` writes a combined `events.log` "
        "stream IN ADDITION to the split streams, prefixed with an 8-byte CodeTracer file header; "
        "the Nim multi-stream writer writes no `events.log` at all. The consequence is not "
        "cosmetic: `ct-print` diverts any container carrying an `events.log` to its LEGACY "
        "combined-stream reader, so the two containers are read by two different code paths in the "
        "same binary -- and that behaviour is how this row is MEASURED, since the container's "
        "internal file names are base40-encoded and not greppable. A decode with a populated "
        "`events` array and no `counts` object is the legacy path and therefore an `events.log`; "
        "one with `counts` is the split-stream path and therefore none."
    ),
}

# Compared for equality is the default; these are not compared at all.
IGNORED = {"report.module"}


def read_tsv(path):
    rows = {}
    if not os.path.exists(path):
        return rows
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            rows.setdefault(parts[0], "\t".join(parts[1:]))
    return rows


def read_json(path):
    if not os.path.exists(path):
        return None
    try:
        return json.load(open(path, encoding="utf-8"))
    except Exception:
        return None


def facts(work, arm):
    """Every comparable fact about one arm, as a flat dict."""
    out = {}

    report = read_json(os.path.join(work, arm, "report.json")) or {}
    for k, v in report.items():
        if k == "moduleExports":
            # The export SET is compared by `verify_all_abi_functions_served`, which is where that
            # comparison belongs. Restating it here would make one property two assertions that
            # can disagree.
            continue
        out[f"report.{k}"] = json.dumps(v) if isinstance(v, (list, dict)) else str(v)

    blob = open(os.path.join(work, arm, "container.ct"), "rb").read()
    out["header.magic"] = " ".join("%02x" % b for b in blob[:5])
    out["header.ctfs_version"] = str(blob[5])
    out["header.encryption"] = str(blob[6])
    out["header.max_shards"] = str(blob[7])

    # Which reader can read this container, and what it said. `OPEN` is the probe's first row and
    # is `ok` or an error string; the two are collapsed to a verdict so the row compares.
    for label, tsv in (("reader_anchor", "probe-reader.tsv"), ("writer_anchor", "probe-writer.tsv")):
        rows = read_tsv(os.path.join(work, arm, tsv))
        opened = rows.get("OPEN", "<no probe>")
        if opened != "ok":
            out[f"reads.{label}"] = "refused"
        elif any(v.startswith("ERR:") for v in rows.values()):
            out[f"reads.{label}"] = "partial"
        else:
            out[f"reads.{label}"] = "complete"

    # The probe rows themselves, taken from whichever reader read this container COMPLETELY. A
    # comparison that took Path A's rows from one reader and Path B's from the same one would be
    # comparing a complete decode against a broken one and calling the difference the writer's.
    chosen = None
    for tsv in ("probe-reader.tsv", "probe-writer.tsv"):
        rows = read_tsv(os.path.join(work, arm, tsv))
        if rows.get("OPEN") == "ok" and not any(v.startswith("ERR:") for v in rows.values()):
            chosen = rows
            out["probe.source"] = tsv
            break
    if chosen is None:
        out["probe.source"] = "NONE"
    else:
        for k, v in chosen.items():
            if k in ("OPEN", "DONE"):
                continue
            out[f"probe.{k}"] = v

    # meta.dat, from whichever `ct-print --full` decoded this container with a populated program
    # name. An empty program is how a reader reports a meta.dat it misparsed rather than refused.
    meta = None
    for name in ("full-writer.json", "full-reader.json"):
        doc = read_json(os.path.join(work, arm, name))
        if doc and doc.get("metadata", {}).get("program"):
            meta = doc["metadata"]
            out["meta.source"] = name
            break
    if meta is None:
        out["meta.source"] = "NONE"
    else:
        out["meta.program"] = str(meta.get("program", ""))
        out["meta.workdir"] = str(meta.get("workdir", ""))
        # ONE ROW FOR ALL THE FLAGS, not one row each. The two arms differ in whether flags are
        # reported AT ALL -- see the catalogue -- and eight rows saying `<absent>` against `True`
        # would be eight statements of one fact, each needing its own reason, and a ninth flag
        # added upstream would arrive uncatalogued for no reason of its own.
        flags = meta.get("flags")
        out["meta.flags"] = (
            "not reported by the reader that reads this container"
            if not flags
            else json.dumps(flags, sort_keys=True)
        )

    # `events.log`, detected from which of `ct-print`'s two code paths the READER-ANCHOR build
    # took. See the catalogue entry for why this is behavioural rather than a name lookup.
    legacy = read_json(os.path.join(work, arm, "full-reader.json"))
    if legacy is None:
        out["internal.events_log"] = "unknown (the reader-anchor ct-print produced no decode)"
    elif "counts" in legacy:
        out["internal.events_log"] = "absent (ct-print took its split-stream path)"
    else:
        n = len(legacy.get("events") or [])
        out["internal.events_log"] = (
            f"present (ct-print took its legacy combined-stream path and decoded {n} events)"
        )

    # The schema version, taken from the writer-anchor reader's refusal when it refuses and from
    # the container's own acceptance when it does not. Stated as a number either way.
    rows = read_tsv(os.path.join(work, arm, "probe-writer.tsv"))
    opened = rows.get("OPEN", "")
    if "schema version 3" in opened:
        out["meta.schema_version"] = "3"
    elif opened == "ok":
        out["meta.schema_version"] = "4"
    else:
        out["meta.schema_version"] = "unknown"

    return out


def main(work):
    a = facts(work, "path-a")
    b = facts(work, "path-b")

    keys = sorted(set(a) | set(b))
    same, diff, uncatalogued = [], [], []
    for k in keys:
        if k in IGNORED:
            continue
        va, vb = a.get(k, "<absent>"), b.get(k, "<absent>")
        if va == vb:
            same.append((k, va))
            print(f"SAME\t{k}\t{va}")
        else:
            diff.append((k, va, vb))
            print(f"DIFF\t{k}\t{va}\t{vb}")
            if k not in CATALOGUE:
                uncatalogued.append(k)

    stale = [k for k in CATALOGUE if k in {s[0] for s in same}]

    print(f"SUMMARY\tsame={len(same)}\tdiff={len(diff)}")
    for k, va, vb in diff:
        why = CATALOGUE.get(k)
        if why:
            print(f"WHY\t{k}\t{' '.join(why.split())}")

    rc = 0
    for k in uncatalogued:
        print(f"UNCATALOGUED\t{k}\tthis difference has no recorded reason", file=sys.stderr)
        rc = 1
    for k in stale:
        print(
            f"STALE\t{k}\tthe catalogue explains a difference that is no longer there",
            file=sys.stderr,
        )
        rc = 1
    if not diff:
        print(
            "NO_DIFFERENCES\tthe two containers compared identical on every key, which this "
            "milestone measured as false; the comparison is not reading what it thinks it is",
            file=sys.stderr,
        )
        rc = 1
    print(f"VERDICT\t{'ok' if rc == 0 else 'failed'}")
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: _m41_container_diff.py <work-dir>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
