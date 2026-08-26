#!/usr/bin/env python3
"""Turn OQ-6's interleaved arm table into assertions, and into a VERDICT.

    _oq6_compare.py <arms.tsv> <margin-percent>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion, plus
`VERDICT\\t<value>` and `NUMBER\\t<key>\\t<value>` rows the caller reads, and exits 0.

THE EXIT CODES, STATED AS WHAT THIS FILE ACTUALLY DOES rather than as what its ancestor does,
because a docstring that describes a neighbouring file's behaviour is the drift this campaign
keeps catching in prose:

    0   the comparison ran and RESOLVED: `batched-faster` or `per-event-faster`. Rows printed.
    4   the comparison ran and did NOT resolve: `within-noise`, and no assertion failed. Rows
        printed, verdict printed. **This is a result, not a failure** — see below.
    3   the comparison could not be made at all: too few complete sessions. Rows printed (the
        precondition itself is a FAIL row), no verdict.

`_timing_compare.py` reserves exit 4 for "ran, found nothing, cannot claim it" and prints NO rows,
because for an *equivalence* claim an unresolvable interval is a failed measurement. OQ-6 asks a
DIFFERENCE question whose answer is allowed to be "no difference", so exit 4 here still prints
every row and every number: the caller asserts on the verdict, not on the exit code.

What is kept unchanged from that file is the ORDER the decisions are made in: every assertion is
evaluated and recorded BEFORE the verdict is computed, and a recorded FAIL is visible whatever the
verdict. A table carrying a scattered control and a resolved difference reports both.

WHAT IS DIFFERENT HERE, AND IT IS THE WHOLE POINT OF THE FILE.
`_timing_compare.py` asserts an EQUIVALENCE — that a disabled code path costs nothing. OQ-6 asks a
DIFFERENCE question and the answer is allowed to be "no difference". So `verdict` is one of

    batched-faster | per-event-faster | within-noise

and it is computed from the data. There is no arrangement of these three under which the check
fails for reporting one of them: a measurement that fails to discriminate is a RESULT. What the
check refuses is a verdict that does not follow from the numbers, and a recorded decision that
does not follow from the verdict.

THE UNIT OF REPLICATION IS THE SESSION, and a session is a separate PROCESS. Within one node
process, which tier V8 put each loop in, where the heap landed and what the inline caches learned
are fixed; they are the dominant nuisance and only a fresh process re-draws them. An interval
bootstrapped over the samples of a single session answers a question nobody asked, and
`_timing_compare.py`'s header records six such intervals over one subject coming out mutually
disjoint.

BOTH THE MEDIAN AND THE MINIMUM ARE REPORTED PER ARM PER SESSION. The minimum of "true cost plus
non-negative noise" is the better estimate of the true cost; the median says whether the
distribution behaved. The verdict is taken on the MEDIAN and the minimum is asserted to AGREE
with it in sign whenever the verdict is not `within-noise` — a difference that reverses between
the two statistics is not a difference.
"""

import math
import random
import statistics as st
import sys

RESULTS = []
NUMBERS = []
MIN_PER_SESSION = 4      # samples per arm per session (the driver's --reps)
MIN_SESSIONS = 8         # sessions, which are the unit of replication

ARMS = ("batched", "perEvent", "control", "nopBatched", "nopPerEvent")

TCRIT = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306,
    9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
    16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086, 21: 2.080, 22: 2.074,
    23: 2.069, 24: 2.064, 25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045,
    30: 2.042, 35: 2.030, 40: 2.021, 50: 2.009, 60: 2.000, 80: 1.990, 100: 1.984,
}


def tcrit(df):
    if df in TCRIT:
        return TCRIT[df]
    below = [k for k in TCRIT if k <= df]
    return TCRIT[max(below)] if below else 12.706


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def number(key, value):
    NUMBERS.append((key, str(value)))


def load(path):
    """-> (sessions, config, meta, incidents)."""
    sessions, config, meta, incidents = {}, {}, {}, []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if ln.startswith("#CONFIG"):
                for kv in ln.split("\t")[1:]:
                    k, _, v = kv.partition("=")
                    config[k] = v
                continue
            if ln.startswith("#META"):
                parts = ln.split("\t")
                if len(parts) >= 3:
                    d = {}
                    for kv in parts[2:]:
                        k, _, v = kv.partition("=")
                        d[k] = v
                    meta[parts[1]] = d
                continue
            if ln.startswith("#TIMEOUT") or ln.startswith("#FAILED"):
                incidents.append(ln)
                continue
            parts = ln.split("\t")
            if len(parts) != 3 or not parts[2].isdigit():
                continue
            sessions.setdefault(parts[0], {}).setdefault(parts[1], []).append(int(parts[2]))
    return sessions, config, meta, incidents


def pct(a, b):
    return (a - b) * 100.0 / b


def boot_ci_mean(values, resamples=4000, seed=20260826):
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(resamples):
        means.append(sum(values[rng.randrange(n)] for _ in range(n)) / n)
    means.sort()
    return means[int(0.025 * len(means))], means[int(0.975 * len(means)) - 1]


def t_ci_mean(values):
    n = len(values)
    m = sum(values) / n
    if n < 2:
        return m, m
    half = tcrit(n - 1) * st.stdev(values) / math.sqrt(n)
    return m - half, m + half


def session_ci(values):
    """Point estimate and the WIDER of the two intervals, so the interval is not selected for
    being narrow. Returns (lo, hi, point)."""
    point = sum(values) / len(values)
    t_lo, t_hi = t_ci_mean(values)
    b_lo, b_hi = boot_ci_mean(values)
    return min(t_lo, b_lo), max(t_hi, b_hi), point


def main(path, margin):
    sessions, config, meta, incidents = load(path)
    order = sorted(sessions, key=lambda s: int(s) if s.isdigit() else s)
    complete = [s for s in order
                if all(len(sessions[s].get(a, [])) >= MIN_PER_SESSION for a in ARMS)]

    # ---- the assertions, recorded BEFORE any precondition is consulted -----
    for inc in incidents:
        check("no session timed out or failed (a hang must be a finding, never a silence)",
              False, inc)

    if len(complete) >= MIN_SESSIONS:
        k = len(complete)
        med = {s: {a: st.median(sessions[s][a]) for a in ARMS} for s in complete}
        mn = {s: {a: min(sessions[s][a]) for a in ARMS} for s in complete}

        obs = [pct(med[s]["perEvent"], med[s]["batched"]) for s in complete]
        obs_min = [pct(mn[s]["perEvent"], mn[s]["batched"]) for s in complete]
        ctl = [pct(med[s]["control"], med[s]["batched"]) for s in complete]
        nop = [pct(med[s]["nopPerEvent"], med[s]["nopBatched"]) for s in complete]

        totals = {a: sum(len(sessions[s][a]) for s in complete) for a in ARMS}
        check(f"the measurement is {k} independent SESSIONS, each a separate process, which is "
              "the unit of replication",
              k >= MIN_SESSIONS,
              f"{k} sessions, " + " ".join(f"{a}={totals[a]}" for a in ARMS) + " samples")
        for a in ARMS:
            smallest = min(len(sessions[s][a]) for s in complete)
            check(f"every session timed `{a}` at least {MIN_PER_SESSION} times",
                  smallest >= MIN_PER_SESSION, f"smallest {smallest}, total {totals[a]}")
            floor = min(mn[s][a] for s in complete)
            check(f"`{a}` samples are plausible ingest times (not a clock returning 0)",
                  floor > 0, f"min={floor}us median={st.median([med[s][a] for s in complete]):.0f}us")

        # THE DATA MUST NOT BE DEGENERATE. M23's review: an identity asserted only where every
        # term is zero passed a whole milestone green. Here the equivalent degeneracy is every
        # arm reading the same number because nothing ran, so the SPREAD is asserted non-zero.
        spread = max(st.median([med[s][a] for s in complete]) for a in ARMS) - \
                 min(st.median([med[s][a] for s in complete]) for a in ARMS)
        check("the arms are not all reading the same number (the comparison is not degenerate)",
              spread > 0, f"spread across arms {spread:.0f}us")

        obs_lo, obs_hi, obs_p = session_ci(obs)
        ctl_lo, ctl_hi, ctl_p = session_ci(ctl)
        nop_lo, nop_hi, nop_p = session_ci(nop)
        obsmin_p = sum(obs_min) / len(obs_min)

        number("sessions", k)
        number("events", config.get("events", "?"))
        number("batch", config.get("batch", "?"))
        number("node", config.get("node", "?"))
        number("v8", config.get("v8", "?"))
        for a in ARMS:
            number(f"median_us.{a}", f"{st.median([med[s][a] for s in complete]):.0f}")
            number(f"min_us.{a}", f"{min(mn[s][a] for s in complete)}")
        number("perEvent_vs_batched.median_pct", f"{obs_p:+.2f}")
        number("perEvent_vs_batched.ci", f"[{obs_lo:+.2f},{obs_hi:+.2f}]")
        number("perEvent_vs_batched.min_pct", f"{obsmin_p:+.2f}")
        number("control_vs_batched.median_pct", f"{ctl_p:+.2f}")
        number("control_vs_batched.ci", f"[{ctl_lo:+.2f},{ctl_hi:+.2f}]")
        number("nopPerEvent_vs_nopBatched.median_pct", f"{nop_p:+.2f}")
        number("nopPerEvent_vs_nopBatched.ci", f"[{nop_lo:+.2f},{nop_hi:+.2f}]")
        for a, m in meta.items():
            number(f"crossings.{a}", m.get("crossings", "?"))
            number(f"containerBytes.{a}", m.get("containerBytes", "?"))

        # THE CONTROL. It must not show a difference outside the margin; if it does, the
        # instrument moved and no verdict about the arms is worth anything.
        check("the negative control (`ct_ingest_control`, a byte-for-byte duplicate of "
              "`ct_ingest`) shows no difference outside the margin",
              abs(ctl_p) <= margin and ctl_lo > -margin * 2 and ctl_hi < margin * 2,
              f"control - batched = {ctl_p:+.2f}% CI [{ctl_lo:+.2f},{ctl_hi:+.2f}], margin {margin}%")

        # The crossing pair must show SOMETHING, or the crossing was not exercised at all.
        check("the crossing-only pair moved, so the boundary was actually crossed 1-per-event "
              "on one side and 1-per-batch on the other",
              abs(nop_p) > 0.0,
              f"nopPerEvent - nopBatched = {nop_p:+.2f}% CI [{nop_lo:+.2f},{nop_hi:+.2f}]")

        # ---- the verdict, computed rather than chosen ----------------------
        resolves = obs_lo > margin or obs_hi < -margin
        if resolves and obs_p > 0:
            verdict = "batched-faster"
        elif resolves and obs_p < 0:
            verdict = "per-event-faster"
        else:
            verdict = "within-noise"

        # A DIFFERENCE THAT REVERSES BETWEEN THE MEDIAN AND THE MINIMUM IS NOT A DIFFERENCE.
        if verdict != "within-noise":
            check("the minimum agrees in sign with the median, so the difference is not an "
                  "artefact of one statistic",
                  (obsmin_p > 0) == (obs_p > 0),
                  f"median {obs_p:+.2f}%, min {obsmin_p:+.2f}%")

        number("verdict", verdict)
        number("margin_pct", margin)
        print_rows()
        if verdict == "within-noise" and not any(r[0] == "FAIL" for r in RESULTS):
            # NOT an error. Exit 4 lets the caller distinguish "no difference found" from "a
            # difference found" without parsing; both are measurements and the caller asserts on
            # the VERDICT row either way.
            return 4
        return 0

    check("enough complete sessions to compare", False,
          f"{len(complete)} of {len(order)} sessions have >= {MIN_PER_SESSION} samples for each "
          f"of {', '.join(ARMS)} (need {MIN_SESSIONS})")
    print_rows()
    return 3


def print_rows():
    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    for key, value in NUMBERS:
        print(f"NUMBER\t{key}\t{value}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], float(sys.argv[2])))
