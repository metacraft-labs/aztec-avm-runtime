#!/usr/bin/env python3
"""Turn a table of interleaved timing samples into assertions.

Input is a TSV of `<label>\\t<microseconds>` rows, one per timed simulation, in the order they were
taken. Two shapes are supported and they answer different questions:

  --disabled   Three labels: `patched`, `unpatched` and `control`. `control` is a byte-for-byte
               COPY of the patched binary, run in the same rotation.

               The assertion is an EQUIVALENCE claim, not a "the number is small" claim: the 95%
               bootstrap confidence interval of the patched-versus-unpatched difference in medians
               must lie entirely inside +/-budget. That is what "below measurement noise" has to
               mean if it is to be falsifiable — a point estimate near zero proves nothing, since
               a method with a wide enough interval produces one by accident.

               The control is what calibrates the interval. Two copies of the SAME bytes, run in
               the same rotation, must come out equivalent by the same test; if they did not, the
               method could not resolve anything and the patched-versus-unpatched result would be
               meaningless. Its own interval is required to be non-degenerate, because an interval
               of zero width would admit anything.

               Deliberately NOT asserted: that the observed difference is smaller than the
               control's. Measured across five independent sessions on this host the difference
               wandered over -1.61% to +0.80% on the median and -0.61% to +0.80% on the minimum,
               changing sign, while the control wandered over a comparable range — so an ordering
               between two draws from overlapping distributions is not a property to assert.

  --enabled    Two labels: `off` and `on`, interleaved inside one process. The assertion is that
               the traced overhead is within the budget, that it is POSITIVE and non-trivial (an
               observer that costs nothing while materialising 38,903 records would mean the
               records were not materialised), and that the budget leaves headroom rather than
               being the measurement.

Usage:
    _timing_compare.py --disabled <tsv> <budget-percent>
    _timing_compare.py --enabled  <tsv> <budget-percent> <label>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion and exits 0.
Exit 3 means the samples could not support any comparison at all.
"""

import random
import statistics as st
import sys

RESULTS = []
MIN_SAMPLES = 20


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def load(path):
    data = {}
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            label, _, value = ln.partition("\t")
            if not value.isdigit():
                continue
            data.setdefault(label, []).append(int(value))
    return data


def pct(a, b):
    return (a - b) * 100.0 / b


def boot_ci(a, b, resamples=4000, seed=20260822):
    """95% percentile-bootstrap CI of (median(a) - median(b)) / median(b), in percent.

    Assumption-free and deterministic: the seed is fixed so a re-run of the same samples gives the
    same interval and a reviewer can reproduce the number rather than a number like it.
    """
    rng = random.Random(seed)
    point = pct(st.median(a), st.median(b))
    diffs = []
    na, nb = len(a), len(b)
    for _ in range(resamples):
        ra = [a[rng.randrange(na)] for _ in range(na)]
        rb = [b[rng.randrange(nb)] for _ in range(nb)]
        mb = st.median(rb)
        if mb:
            diffs.append(pct(st.median(ra), mb))
    diffs.sort()
    lo = diffs[int(0.025 * len(diffs))]
    hi = diffs[int(0.975 * len(diffs)) - 1]
    return lo, hi, point


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    mode, path, budget = sys.argv[1], sys.argv[2], float(sys.argv[3])
    data = load(path)

    if mode == "--disabled":
        need = ("patched", "unpatched", "control")
    elif mode == "--enabled":
        need = ("off", "on")
    else:
        sys.stderr.write(__doc__)
        return 2

    missing = [k for k in need if len(data.get(k, [])) < MIN_SAMPLES]
    if missing:
        sys.stderr.write(
            f"not enough samples to compare: "
            + " ".join(f"{k}={len(data.get(k, []))}" for k in need)
            + f" (need {MIN_SAMPLES} each)\n")
        return 3

    for k in need:
        v = data[k]
        check(f"`{k}` has {len(v)} samples", len(v) >= MIN_SAMPLES, len(v))
        check(f"`{k}` samples are plausible simulation times (not a clock returning 0)",
              min(v) > 100, f"min={min(v)} median={st.median(v):.0f} max={max(v)}")

    if mode == "--disabled":
        p, u, c = data["patched"], data["unpatched"], data["control"]
        obs_lo, obs_hi, obs = boot_ci(p, u)
        ctl_lo, ctl_hi, ctl = boot_ci(c, p)
        check("the disabled path is equivalent to the unpatched build within "
              f"+/-{budget:.0f}% (95% bootstrap CI of the difference in medians)",
              obs_lo >= -budget and obs_hi <= budget,
              f"{obs:+.2f}%  CI [{obs_lo:+.2f}%, {obs_hi:+.2f}%]  budget +/-{budget:.0f}%")
        check("the same test calls two copies of the SAME binary equivalent, so it can resolve "
              "something at this scale", ctl_lo >= -budget and ctl_hi <= budget,
              f"{ctl:+.2f}%  CI [{ctl_lo:+.2f}%, {ctl_hi:+.2f}%]")
        check("the control's interval is non-degenerate, so it admits a difference rather than "
              "nothing", ctl_hi > ctl_lo, f"width {ctl_hi - ctl_lo:.2f}pp")
        check("the observed interval is non-degenerate too", obs_hi > obs_lo,
              f"width {obs_hi - obs_lo:.2f}pp")
        # The point estimates, as bounds, so the headline numbers are asserted and not only
        # computed: a CI inside the budget with a point estimate outside it is not possible, but
        # the minimum is a different statistic and is bounded separately.
        d_min = pct(min(p), min(u))
        check(f"the fastest patched run is within {budget:.0f}% of the fastest unpatched one",
              abs(d_min) <= budget, f"{d_min:+.2f}%")
        check("the disabled overhead, as measured", True,
              f"median {obs:+.2f}% CI [{obs_lo:+.2f}, {obs_hi:+.2f}]  min {d_min:+.2f}%  "
              f"same-bytes control {ctl:+.2f}% CI [{ctl_lo:+.2f}, {ctl_hi:+.2f}]")
    else:
        label = sys.argv[4] if len(sys.argv) > 4 else "target"
        off, on = data["off"], data["on"]
        d_min, d_med = pct(min(on), min(off)), pct(st.median(on), st.median(off))
        check(f"[{label}] the traced run is SLOWER than the untraced one "
              "(38,903 records really were materialised)", d_min > 0.2 and d_med > 0.2,
              f"min {d_min:+.2f}%  median {d_med:+.2f}%")
        check(f"[{label}] the traced overhead is within the {budget:.0f}% budget on the minimum",
              d_min <= budget, f"{d_min:+.2f}%")
        check(f"[{label}] the traced overhead is within the {budget:.0f}% budget on the median",
              d_med <= budget, f"{d_med:+.2f}%")
        # A budget equal to the measurement fails on any change at all and gets raised rather than
        # read; a budget so large nothing could exceed it is not a budget.
        check(f"[{label}] the budget leaves headroom", budget - d_med >= 1.0,
              f"budget {budget:.0f}%, measured {d_med:+.2f}%, margin {budget - d_med:.2f}pp")
        check(f"[{label}] the budget is small enough to be able to fail", budget <= 25.0, budget)
        check(f"[{label}] the traced overhead, as measured", True,
              f"min {d_min:+.2f}%  median {d_med:+.2f}%  "
              f"off min={min(off)}us median={st.median(off):.0f}us  "
              f"on min={min(on)}us median={st.median(on):.0f}us")

    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
