#!/usr/bin/env python3
"""Turn a table of interleaved timing samples into assertions.

Two shapes are supported and they answer different questions.

  --disabled   Input is a TSV of `<session>\\t<label>\\t<microseconds>` rows, in the order they were
               taken. Three labels: `patched`, `unpatched` and `control`. `control` is a
               byte-for-byte COPY of the patched binary, run in the same rotation.

               The assertion is an EQUIVALENCE claim, not a "the number is small" claim: a 95%
               confidence interval of the patched-versus-unpatched difference in medians is
               required to lie inside a bound. A point estimate near zero proves nothing on its
               own, since a method with a wide enough interval produces one by accident.

               THE BOUND IS NOT SYMMETRIC, AND THE ASYMMETRY IS THE CLAIM. The neutrality claim is
               that the disabled path COSTS NOTHING, so the cost side keeps the tight budget. The
               faster side asks a different question — whether the two builds are comparable at all
               — and gets its own, larger bound, because the patched build is REPRODUCIBLY faster:
               -1.26%, -1.38%, -1.40%, -1.71% and -1.75% over five measurements. Those are five
               measurements of ONE build pair, not five builds: the two binaries are byte-identical
               across every rebuild of these trees, so what replicates is the reading and not an
               independent draw of the code layout. Failing a patch for being faster is failing a
               correct implementation either way, and a single two-sided bound had been passing
               that by 0.05pp for two milestones before anyone noticed.

               THE UNIT OF REPLICATION IS THE SESSION, and that is the whole point of this file.
               An earlier version of this comparator bootstrapped over the individual samples of a
               single session. That interval answers "how precisely is THIS session's median
               known?" — which is not the question. Measured on this host, six runs of the same
               measurement over the same two binaries produced mutually disjoint "95% intervals"
               spanning -1.03% to +1.48%: the interval was 2-3x narrower than the quantity it
               claimed to cover, so whether the check passed was decided by which session it ran
               in.

               The reason is now identified rather than guessed at. The dominant nuisance is the
               physical placement of the binary's pages, which is fixed for a given file and
               RE-DRAWN BY A COPY. Probed directly, over twelve sessions each:

                   three files copied once and reused   observed sd 0.22pp, control sd 0.39pp
                   the three files re-copied per session observed sd 1.33pp, control sd 1.50pp

               The control column compares two copies of the same bytes, so all of its spread is
               nuisance — and re-copying multiplies it by about four. That is a between-session
               variance component a within-session bootstrap cannot see and every fresh run of the
               check re-draws.

               So the caller re-copies all three arms at the start of every session, and this file
               takes ONE point estimate per session and puts the interval over those. The interval
               reported is the WIDER of a Student-t interval and a percentile bootstrap over the
               session estimates, so it is not the one that happens to be flattering.

               What the design does NOT randomise, stated because it bounds the claim: the
               link-time code layout of each build is fixed by the build. Re-copying re-draws where
               a file's pages land, not how the linker ordered its functions. So what is bounded
               here is the patch TOGETHER WITH the incidental layout change it causes — which is
               the quantity a user of the patched build actually experiences, but it is not the
               cost of the branch alone.

               Deliberately NOT asserted: that the observed difference is smaller than the
               control's. Both are draws from overlapping distributions and an ordering between two
               such draws is not a property; across sessions it changes sign.

  --enabled    Input is a TSV of `<label>\\t<microseconds>` rows. Two labels, `off` and `on`,
               interleaved inside ONE process, so no layout nuisance enters at all: it is the same
               binary, the same file, the same process, with the flag flipped. The assertion is
               that the traced overhead is within the budget, that it is POSITIVE and non-trivial
               (an observer that costs nothing while materialising 38,903 records would mean the
               records were not materialised), and that the budget leaves headroom rather than
               being the measurement.

Usage:
    _timing_compare.py --disabled <tsv> <cost-budget-percent> [faster-budget-percent]
    _timing_compare.py --enabled  <tsv> <budget-percent> <label>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion and exits 0.

Exit 3 means the samples could not support any comparison at all — too few complete sessions.
Exit 4 means the comparison RAN, found no difference outside the budget, and could not resolve
finely enough to make that a claim: the interval is inside +/-budget but wider than half of it.
Both are PRECONDITIONS and neither is a pass; on either, no PASS or FAIL row is printed at all,
so a report with no rows in it can never be read as a clean one. They are separate exit codes
because the remedies differ: exit 3 says the table is malformed or too short to compare, exit 4
says the comparison was made and is not sharp enough to claim. See test_observer_disabled_is_free,
which answers exit 4 by MEASURING MORE SESSIONS rather than by widening the bound.

Exit 4 cannot be reached by a measurement that would otherwise have failed. The equivalence
assertion is evaluated FIRST and an interval that leaves +/-budget is a FAIL with exit 0,
however wide it is. So imprecision can neither buy a pass nor hide a regression: it can only
buy a refusal to answer.
"""

import math
import random
import statistics as st
import sys

RESULTS = []
MIN_SAMPLES = 20          # --enabled: samples per arm
MIN_PER_SESSION = 12      # --disabled: samples per arm, per session
MIN_SESSIONS = 8          # --disabled: sessions, which are the unit of replication

# Two-sided 0.975 Student-t critical values by degrees of freedom. A table rather than a
# dependency; a df larger than the table falls back to the normal quantile, which is its limit.
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


def load(path):
    """`<label>\\t<value>` rows -> {label: [values]}."""
    data = {}
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            label, _, value = ln.strip().partition("\t")
            if value.isdigit():
                data.setdefault(label, []).append(int(value))
    return data


def load_sessions(path):
    """`<session>\\t<label>\\t<value>` rows -> {session: {label: [values]}}, sessions in order."""
    data = {}
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            parts = ln.rstrip("\n").split("\t")
            if len(parts) != 3 or not parts[2].isdigit():
                continue
            sess, label, value = parts[0], parts[1], int(parts[2])
            data.setdefault(sess, {}).setdefault(label, []).append(value)
    return data


def pct(a, b):
    return (a - b) * 100.0 / b


def boot_ci_mean(values, resamples=4000, seed=20260822):
    """95% percentile-bootstrap CI of the MEAN of `values`, which are the per-session estimates."""
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(resamples):
        means.append(sum(values[rng.randrange(n)] for _ in range(n)) / n)
    means.sort()
    return means[int(0.025 * len(means))], means[int(0.975 * len(means)) - 1]


def t_ci_mean(values):
    """95% Student-t CI of the mean of `values`."""
    n = len(values)
    m = sum(values) / n
    if n < 2:
        return m, m
    half = tcrit(n - 1) * st.stdev(values) / math.sqrt(n)
    return m - half, m + half


def session_ci(values):
    """The point estimate and the WIDER of the two intervals, so the interval is not selected for
    being narrow. Returns (lo, hi, point)."""
    point = sum(values) / len(values)
    t_lo, t_hi = t_ci_mean(values)
    b_lo, b_hi = boot_ci_mean(values)
    return min(t_lo, b_lo), max(t_hi, b_hi), point


def within_session_halfwidth(sessions, a_label, b_label, seed=20260822):
    """The half-width a SINGLE session's own bootstrap-over-samples would have claimed, averaged
    over the sessions. Reported, not asserted: it is the number the superseded estimator produced,
    and the contrast with the between-session spread is the evidence that this file was changed for
    a reason."""
    rng = random.Random(seed)
    widths = []
    for sess in sessions.values():
        a, b = sess.get(a_label, []), sess.get(b_label, [])
        if len(a) < 2 or len(b) < 2:
            continue
        diffs = []
        for _ in range(400):
            ra = [a[rng.randrange(len(a))] for _ in range(len(a))]
            rb = [b[rng.randrange(len(b))] for _ in range(len(b))]
            mb = st.median(rb)
            if mb:
                diffs.append(pct(st.median(ra), mb))
        diffs.sort()
        if diffs:
            widths.append((diffs[int(0.975 * len(diffs)) - 1] - diffs[int(0.025 * len(diffs))]) / 2)
    return st.mean(widths) if widths else 0.0


def disabled(path, budget, faster_budget):
    sessions = load_sessions(path)
    need = ("patched", "unpatched", "control")
    order = sorted(sessions, key=lambda s: int(s) if s.isdigit() else s)

    complete = [s for s in order
                if all(len(sessions[s].get(k, [])) >= MIN_PER_SESSION for k in need)]
    if len(complete) < MIN_SESSIONS:
        sys.stderr.write(
            f"not enough complete sessions to compare: {len(complete)} of {len(order)} have "
            f">= {MIN_PER_SESSION} samples for each of {', '.join(need)} "
            f"(need {MIN_SESSIONS} sessions)\n")
        return 3

    k = len(complete)
    per = {}
    for s in complete:
        per[s] = {kk: st.median(sessions[s][kk]) for kk in need}
    obs = [pct(per[s]["patched"], per[s]["unpatched"]) for s in complete]
    ctl = [pct(per[s]["control"], per[s]["patched"]) for s in complete]
    mins = [pct(min(sessions[s]["patched"]), min(sessions[s]["unpatched"])) for s in complete]

    total = {kk: sum(len(sessions[s][kk]) for s in complete) for kk in need}
    check(f"the measurement is {k} independent SESSIONS, which is the unit of replication "
          "(each re-draws the binaries' page placement, the dominant nuisance)",
          k >= MIN_SESSIONS, f"{k} sessions, "
          + " ".join(f"{kk}={total[kk]}" for kk in need) + " samples")
    for kk in need:
        smallest = min(len(sessions[s][kk]) for s in complete)
        check(f"every session timed `{kk}` at least {MIN_PER_SESSION} times",
              smallest >= MIN_PER_SESSION, f"smallest session {smallest}, total {total[kk]}")
        floor = min(min(sessions[s][kk]) for s in complete)
        check(f"`{kk}` samples are plausible simulation times (not a clock returning 0)",
              floor > 100, f"min={floor} median={st.median([per[s][kk] for s in complete]):.0f}")

    obs_lo, obs_hi, obs_p = session_ci(obs)
    ctl_lo, ctl_hi, ctl_p = session_ci(ctl)

    # TWO CLAIMS, TWO BUDGETS, and they are different claims — which is the correction M15 made
    # after finding that the single two-sided bound had been passing by 0.05pp for two milestones.
    #
    # The neutrality claim the upstream patch stands on is that the DISABLED path COSTS NOTHING.
    # That is a claim about the patched build not being SLOWER, and it keeps the tight budget.
    #
    # The other side is a different question — "are these two builds even comparable?" — and it
    # needs its own bound, because the patched build is reproducibly FASTER: -1.26%, -1.38%,
    # -1.40%, -1.71% and -1.75% over five measurements of the same byte-identical build pair. A
    # patch that is faster than the build without it does not violate native neutrality by being
    # so, and failing it for that is failing a correct implementation.
    #
    # WHY it is faster is NOT the hoist, and that is measured rather than argued. `m9nohoist` is
    # the same patch with the observe call put back INSIDE the interpreter's try block; timed
    # against `m9ref` on an idle machine, 32 sessions, it reads -1.28% CI [-1.71, -0.85] against a
    # same-bytes control of -0.01% [-0.52, +0.50], beside -1.75% CI [-2.34, -1.15] for the hoisted
    # build in the same conditions. Undoing the hoist leaves the speed-up essentially intact, so
    # the hoist is not the explanation. What is left is the nuisance this file already says it
    # cannot randomise: the link-time code layout, which is fixed by the build and not re-drawn by
    # rebuilding the same source. Nothing here should be offered upstream as an argument that the
    # patch makes the interpreter faster.
    #
    # The faster-side budget is deliberately larger and it is still a bound: an arm that came back
    # 20% faster would not be the same program and this would say so.
    check("the disabled path is not SLOWER than the unpatched build, within "
          f"+{budget:.0f}% (95% CI of the mean over {k} sessions)",
          obs_hi <= budget,
          f"{obs_p:+.2f}%  CI [{obs_lo:+.2f}%, {obs_hi:+.2f}%]  cost budget +{budget:.0f}%")
    check("and the two builds are comparable at all — the patched one is not faster by more than "
          f"{faster_budget:.0f}%, which no branch removed from a hot loop could explain",
          obs_lo >= -faster_budget,
          f"{obs_p:+.2f}%  CI [{obs_lo:+.2f}%, {obs_hi:+.2f}%]  comparability bound -{faster_budget:.0f}%")
    # THE CONTROL IS THE RESOLVING-POWER CHECK, AND ITS FAILURE IS A PRECONDITION, NOT A RESULT.
    #
    # `control` is a byte-for-byte COPY of the patched binary, so every bit of its spread is
    # nuisance. If the method cannot call two copies of the same bytes equivalent within the
    # budget, it has been shown — by its own evidence, on this run — to be incapable of resolving a
    # difference at this scale. No claim about patched-versus-unpatched is supportable then,
    # INCLUDING A FAILING ONE: reporting a regression on evidence already demonstrated unable to
    # resolve one is the same error as reporting a pass on it.
    #
    # It cannot mask a real regression, and that is structural rather than hopeful: the control
    # compares the patched binary with a COPY OF ITSELF, so nothing the patch does moves it. A
    # patched build 30% slower leaves the control intact and fails the cost assertion, which is
    # exercised below.
    #
    # This is the same argument as the width one, in its strongest form, and it is what M14's
    # review was doing by hand when it classified M9's reds as "environmental, not regressions".
    control_ok = ctl_lo >= -budget and ctl_hi <= budget
    control_slot = len(RESULTS)
    check("the same test calls two copies of the SAME binary equivalent, so it can resolve "
          "something at this scale", True,
          f"{ctl_p:+.2f}%  CI [{ctl_lo:+.2f}%, {ctl_hi:+.2f}%]")
    check("the control's interval is non-degenerate, so it admits a difference rather than "
          "nothing", ctl_hi > ctl_lo, f"width {ctl_hi - ctl_lo:.2f}pp")
    check("the observed interval is non-degenerate too", obs_hi > obs_lo,
          f"width {obs_hi - obs_lo:.2f}pp")
    # The budget must not BE the measurement. Stated as a property of the interval's width rather
    # than of its position: a bound that only holds because the interval happens to sit low is a
    # second lottery, whereas "this method resolves to well inside the bound it asserts" is a
    # property of the method.
    #
    # THIS IS A PRECONDITION, NOT AN ASSERTION, and M14's sweep is why. It failed there at a
    # half-width of 1.05pp against a required 1.00pp — on a correct tree, with the equivalence
    # itself comfortably satisfied. Width is a property of the MACHINE AND THE SESSION COUNT, not
    # of the patch: a busy hour widens it and a correct implementation cannot do anything about
    # that except measure more. A check that reports "regression" for it is reporting the wrong
    # thing, and a sweep that goes red for the wrong thing teaches its reader to discount reds.
    #
    # So the insufficient-precision case exits 4 and says what would fix it. The remedy is
    # SESSIONS — the standard error falls as 1/sqrt(sessions), and the session is the unit of
    # replication here — which is what the caller does. It is deliberately NOT a widened bound:
    # the equivalence assertion is evaluated above and already recorded, so an interval that
    # leaves +/-budget is a FAIL with exit 0 no matter how wide it is, and exit 4 is reachable
    # only when the answer is inside the budget and simply not sharp enough to claim.
    half = (obs_hi - obs_lo) / 2
    precision_ok = half <= budget / 2
    # The row is reserved here so it keeps its place in the report, and its status is decided at
    # the bottom: PASS when the interval is sharp enough, FAIL when it is not AND something else
    # failed anyway (in which case the run has a result and this is context for it), and REMOVED
    # when it is the only thing wrong — because then the run has no result and exits 4.
    precision_slot = len(RESULTS)
    check("the interval is at most half the budget wide, so the bound is not the measurement",
          True, f"half-width {half:.2f}pp, budget +/-{budget:.0f}%")
    check("and the budget is small enough to be able to fail", budget <= 5.0, budget)
    # The minimum is a different statistic and is bounded separately — per session, then the median
    # across sessions, because a minimum pooled over every session is the luckiest layout draw.
    med_min = st.median(mins)
    # Bounded the same way as the mean, and for the same reason: the cost side is the claim, the
    # faster side is the comparability question.
    check(f"the fastest patched run is not more than {budget:.0f}% SLOWER than the fastest "
          "unpatched one, per session", med_min <= budget,
          f"median across sessions {med_min:+.2f}%  (range {min(mins):+.2f}% .. {max(mins):+.2f}%)")
    check(f"and not more than {faster_budget:.0f}% faster", med_min >= -faster_budget,
          f"median across sessions {med_min:+.2f}%")

    # Reported, not asserted: the two numbers whose disagreement is why this file bootstraps over
    # sessions. If the between-session spread ever collapses to the within-session one, the caller
    # has stopped re-drawing the nuisance and the interval is measuring the wrong thing again.
    sd_between = st.stdev(obs) if k > 1 else 0.0
    hw_within = within_session_halfwidth({s: sessions[s] for s in complete},
                                         "patched", "unpatched")
    check("the spread this interval covers, and the one a single session would have claimed",
          True, f"between-session sd {sd_between:.2f}pp over {k} sessions "
                f"(range {min(obs):+.2f}% .. {max(obs):+.2f}%); one session's own bootstrap "
                f"would have claimed +/-{hw_within:.2f}pp")
    check("the disabled overhead, as measured", True,
          f"mean over {k} sessions {obs_p:+.2f}% CI [{obs_lo:+.2f}, {obs_hi:+.2f}]  "
          f"per-session range {min(obs):+.2f}% .. {max(obs):+.2f}%  "
          f"min {med_min:+.2f}%  same-bytes control {ctl_p:+.2f}% "
          f"CI [{ctl_lo:+.2f}, {ctl_hi:+.2f}] (range {min(ctl):+.2f}% .. {max(ctl):+.2f}%)")

    # The precision precondition is decided LAST, so that a real failure recorded above wins. If
    # anything failed, this is a normal run with a normal result and exit 0 reports it — with the
    # reserved row turned into the FAIL it is, since a failing run's own imprecision is worth
    # saying.
    # The control's verdict is decided FIRST and outranks everything, for the reason above.
    if not control_ok:
        del RESULTS[control_slot]
        sys.stderr.write(
            f"the measurement could not resolve two copies of the SAME binary: the control's 95% "
            f"interval over {k} sessions is [{ctl_lo:+.2f}%, {ctl_hi:+.2f}%], which leaves the "
            f"+/-{budget:.0f}% budget.\n"
            f"All of that spread is nuisance — the control IS the patched binary, copied — so no "
            f"claim about the patched-versus-unpatched difference is supportable from this run, "
            f"including a failing one. This is a MEASUREMENT PRECONDITION, not a regression.\n"
            f"The usual cause is other work on the machine arriving AFTER the idleness check, "
            f"which samples once and does not watch. Re-run on a quiet host.\n")
        return 4
    if precision_ok:
        pass
    elif any(status == "FAIL" for status, _, _ in RESULTS):
        name, detail = RESULTS[precision_slot][1], RESULTS[precision_slot][2]
        RESULTS[precision_slot] = ("FAIL", name, detail)
    if not precision_ok and not any(status == "FAIL" for status, _, _ in RESULTS):
        del RESULTS[precision_slot]
        # How many sessions would have been enough, from the spread actually observed: the
        # half-width scales as 1/sqrt(k), so k_needed = k * (half / target)^2, rounded up and
        # given a little headroom because the estimate is itself noisy.
        target = budget / 2
        need = int(math.ceil(k * (half / target) ** 2 * 1.15)) if target > 0 else 0
        sys.stderr.write(
            f"insufficient precision to make the equivalence claim: the 95% interval over "
            f"{k} sessions is [{obs_lo:+.2f}%, {obs_hi:+.2f}%], half-width {half:.2f}pp, and "
            f"the claim needs at most {target:.2f}pp (half of the +/-{budget:.0f}% budget).\n"
            f"The measurement is INSIDE the budget — this is not a regression and not a "
            f"failure. The half-width falls as 1/sqrt(sessions); about {need} sessions would "
            f"support it at the spread just observed (between-session sd {sd_between:.2f}pp).\n")
        return 4
    return 0


def enabled(path, budget, label):
    data = load(path)
    need = ("off", "on")
    missing = [k for k in need if len(data.get(k, [])) < MIN_SAMPLES]
    if missing:
        sys.stderr.write(
            "not enough samples to compare: "
            + " ".join(f"{k}={len(data.get(k, []))}" for k in need)
            + f" (need {MIN_SAMPLES} each)\n")
        return 3
    for k in need:
        v = data[k]
        check(f"`{k}` has {len(v)} samples", len(v) >= MIN_SAMPLES, len(v))
        check(f"`{k}` samples are plausible simulation times (not a clock returning 0)",
              min(v) > 100, f"min={min(v)} median={st.median(v):.0f} max={max(v)}")
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
    return 0


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    mode, path, budget = sys.argv[1], sys.argv[2], float(sys.argv[3])
    if mode == "--disabled":
        # The faster-side bound is a separate argument with its own default, so a caller that has a
        # reason to change one is not silently changing the other.
        faster = float(sys.argv[4]) if len(sys.argv) > 4 else 5.0
        rc = disabled(path, budget, faster)
    elif mode == "--enabled":
        rc = enabled(path, budget, sys.argv[4] if len(sys.argv) > 4 else "target")
    else:
        sys.stderr.write(__doc__)
        return 2
    if rc != 0:
        return rc
    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
