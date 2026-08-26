#!/usr/bin/env python3
"""Rewrite `TRACE-ABI.md`'s measured figures from the comparator's own output.

    scratchpad/campaign/m24-render-trace-abi.py <arms.tsv> <margin>

WHY THIS EXISTS RATHER THAN A HAND EDIT. `CARRY-LEDGER.md` drifted from its own measurement
because a number was rendered out of a sentence, and this campaign's rule is that a document
quoting a measurement must be produced FROM the measurement. Every figure this touches is one
`verify_trace_event_abi_batched_faster` re-derives and compares on every run, so a hand edit that
transposed a digit would redden — but reddening after the fact is not the same as not being able
to get it wrong.

It is in `scratchpad/` and not in `tools/` deliberately: it is an authoring aid used when the
benchmark is re-measured, not part of the verification path. The CHECK is what holds the document
to the data.
"""

import re
import statistics as st
import sys
from collections import defaultdict

ARMS = ("batched", "perEvent", "control", "nopBatched", "nopPerEvent")
DOC = "TRACE-ABI.md"


def load(path):
    sessions, config = defaultdict(lambda: defaultdict(list)), {}
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if ln.startswith("#CONFIG"):
            for kv in ln.split("\t")[1:]:
                k, _, v = kv.partition("=")
                config[k] = v
            continue
        p = ln.split("\t")
        if len(p) == 3 and p[2].isdigit():
            sessions[p[0]][p[1]].append(int(p[2]))
    return sessions, config


def main(tsv, margin):
    sessions, config = load(tsv)
    complete = [s for s in sessions if all(len(sessions[s].get(a, [])) >= 4 for a in ARMS)]
    complete.sort(key=lambda s: int(s) if s.isdigit() else s)
    med = {a: st.median([st.median(sessions[s][a]) for s in complete]) for a in ARMS}
    mn = {a: min(min(sessions[s][a]) for s in complete) for a in ARMS}

    def pct(x, y):
        return (x - y) * 100.0 / y

    obs = [pct(st.median(sessions[s]["perEvent"]), st.median(sessions[s]["batched"])) for s in complete]
    ctl = [pct(st.median(sessions[s]["control"]), st.median(sessions[s]["batched"])) for s in complete]
    nop = [pct(st.median(sessions[s]["nopPerEvent"]), st.median(sessions[s]["nopBatched"])) for s in complete]

    # The comparator owns the interval; this only needs the point estimates for the prose, and the
    # intervals are read back out of the comparator run the caller passes in through stdin.
    ci = {}
    for ln in sys.stdin:
        p = ln.rstrip("\n").split("\t")
        if len(p) == 3 and p[0] == "NUMBER":
            ci[p[1]] = p[2]

    def num(k):
        return ci[k]

    def fmt(x):
        return f"{int(round(x)):,}"

    crossings = {a: ci.get(f"crossings.{a}", "?") for a in ARMS}
    bytes_ = {a: ci.get(f"containerBytes.{a}", "?") for a in ARMS}

    text = open(DOC, encoding="utf-8").read()

    # --- the headline ------------------------------------------------------
    text = re.sub(
        r"is \*\*[+-][0-9.]+ %\*\* with a 95 % interval of \*\*\[[^\]]*\] %\*\*, against a declared margin of [0-9]+ %\.",
        f"is **{num('perEvent_vs_batched.median_pct')} %** with a 95 % interval of "
        f"**[{num('perEvent_vs_batched.ci').strip('[]').replace(',', ', ')}] %**, against a declared "
        f"margin of {int(float(margin))} %.",
        text, count=1)

    # --- the session/engine line -------------------------------------------
    text = re.sub(
        r"\*\*[0-9]+ sessions × [0-9]+ ABBA blocks, [0-9,]+ events, batch [0-9,]+, node [^ ]+ / V8 [^*]*\*\*",
        f"**{num('sessions')} sessions × {config['reps']} ABBA blocks, {int(config['events']):,} events, "
        f"batch {int(config['batch']):,}, node {config['node']} / V8 {config['v8']}.**",
        text, count=1)

    # --- the per-arm table --------------------------------------------------
    for a in ARMS:
        text = re.sub(
            rf"^\| `{a}` \| [0-9,]+ \| [0-9,]+ \| [0-9,]+ \| [0-9,]+ \|$",
            f"| `{a}` | {fmt(med[a])} | {fmt(mn[a])} | {int(crossings[a]):,} | {int(bytes_[a]):,} |",
            text, count=1, flags=re.M)

    # --- the comparison table ----------------------------------------------
    def row(label, key, tail):
        lo, hi = num(key + ".ci").strip("[]").split(",")
        return f"| `{label}` | **{num(key + '.median_pct')} %** | **[{lo}, {hi}] %** | {tail} |"

    text = re.sub(r"^\| `perEvent - batched` \|.*$",
                  row("perEvent - batched", "perEvent_vs_batched", "within noise"),
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| `control - batched` \|.*$",
                  f"| `control - batched` | {num('control_vs_batched.median_pct')} % | "
                  f"[{num('control_vs_batched.ci').strip('[]').replace(',', ', ')}] % | "
                  "the instrument is calibrated |",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| `nopPerEvent - nopBatched` \|.*$",
                  f"| `nopPerEvent - nopBatched` | {num('nopPerEvent_vs_nopBatched.median_pct')} % | "
                  f"[{num('nopPerEvent_vs_nopBatched.ci').strip('[]').replace(',', ', ')}] % | "
                  "the crossing, priced alone |",
                  text, count=1, flags=re.M)

    # --- the derived prose --------------------------------------------------
    extra_cross = int(config["events"]) - int(crossings["batched"])
    delta_us = med["nopPerEvent"] - med["nopBatched"]
    ns_each = delta_us * 1000.0 / extra_cross
    share = delta_us * 100.0 / med["batched"]
    ratio = med["batched"] / delta_us
    text = re.sub(
        r"crossings cost [0-9,]+ µs where [0-9,]+ cost [0-9,]+ µs: \*\*[0-9,]+ µs for [0-9,]+\n"
        r"extra crossings, or ~[0-9.]+ ns\neach\*\* — against §9\.3's ~33 ns prior, and \*\*[0-9.]+ % of a [0-9,]+ µs recording\*\*\. The writer work\n"
        r"outweighs the boundary by about \*\*[0-9]+×\*\*",
        f"crossings cost {fmt(med['nopPerEvent'])} µs where {int(crossings['nopBatched'])} cost "
        f"{fmt(med['nopBatched'])} µs: **{fmt(delta_us)} µs for {extra_cross:,}\nextra crossings, or "
        f"~{ns_each:.1f} ns\neach** — against §9.3's ~33 ns prior, and **{share:.2f} % of a "
        f"{fmt(med['batched'])} µs recording**. The writer work\noutweighs the boundary by about "
        f"**{int(round(ratio))}×**",
        text, count=1)

    # §4 and §8 quote the same derived figures.
    text = re.sub(r"^[0-9.]+ ns per crossing is \*V8-in-node-[0-9]+\*'s number\.",
                  f"{ns_each:.1f} ns per crossing is *V8-in-node-{config['node'].lstrip('v').split('.')[0]}*'s number.",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| `perEvent - batched`, median \| [+-][0-9.]+ % \| §2 \|$",
                  f"| `perEvent - batched`, median | {num('perEvent_vs_batched.median_pct')} % | §2 |",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| its 95 % interval \| \[[^\]]*\] % \| §2 \|$",
                  f"| its 95 % interval | [{num('perEvent_vs_batched.ci').strip('[]').replace(',', ', ')}] % | §2 |",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| cost of one boundary crossing in V8 \| ~[0-9.]+ ns \| §2 \|$",
                  f"| cost of one boundary crossing in V8 | ~{ns_each:.1f} ns | §2 |",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| the crossing's share of a 100k-event recording \| [0-9.]+ % \| §2 \|$",
                  f"| the crossing's share of a 100k-event recording | {share:.2f} % | §2 |",
                  text, count=1, flags=re.M)
    text = re.sub(r"^\| writer work versus boundary work \| ~[0-9]+× \| §2 \|$",
                  f"| writer work versus boundary work | ~{int(round(ratio))}× | §2 |",
                  text, count=1, flags=re.M)
    text = re.sub(r"The minimum agrees in sign with the median \(\+?-?[0-9.]+ %\)\.",
                  f"The minimum agrees in sign with the median ({num('perEvent_vs_batched.min_pct')} %).",
                  text, count=1)

    open(DOC, "w", encoding="utf-8").write(text)
    print("rendered TRACE-ABI.md from", tsv)
    for a in ARMS:
        print(f"  {a:12s} median {fmt(med[a]):>10s}  min {fmt(mn[a]):>10s}")
    print(f"  perEvent-batched {num('perEvent_vs_batched.median_pct')} % "
          f"CI {num('perEvent_vs_batched.ci')}")
    print(f"  crossing ~{ns_each:.1f} ns, share {share:.2f} %, ratio {int(round(ratio))}x")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
