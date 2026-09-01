// runner.js — the smallest test runner that can honestly say a contract test ran.
//
//   THE ONE DEFECT THIS FILE IS BUILT AGAINST
//   -----------------------------------------
// "A test that passes because it never ran is worse than no runner." This campaign has found
// seventeen instances of machinery that was present, correct and never called, and a checker that
// printed `ok: 0/0 published files match` and exited 0 while checking nothing. A test runner is a
// *particularly* good place for that defect to hide, because the natural report of a suite that
// failed to load is an empty list of failures — which prints identically to a suite that passed.
//
// So four things here are structural rather than conventional, and each has a mutation arm in
// `verification/e2e_contract_tests_run_in_browser.sh` that reddens IT and not its neighbours:
//
//   1. `expect()` INCREMENTS A COUNTER whether it passes or fails. The count is reported and the
//      check asserts it, so "the suite ran" is a number rather than an absence of complaints.
//   2. A TEST THAT MADE NO EXPECTATIONS FAILS, by name, with reason `no-expectations`. A body that
//      returned early, or whose await threw somewhere a `catch` swallowed, lands here instead of
//      in a green count.
//   3. A SUITE THAT REGISTERED NO TESTS IS AN ERROR, not an empty pass — `status: 'error'`,
//      `reason: 'no-tests'`. This is the `0/0 … exited 0` shape, refused by name.
//   4. A SUITE THAT FAILED TO LOAD IS AN ERROR carrying the throw. `import()` of a missing module,
//      a syntax error, a top-level await that rejected: all of them arrive as `load-failed` with
//      the message, and none of them can produce `status: 'ok'`.
//
//   WHY `executed` AND `completed` ARE TWO COUNTERS
//   -----------------------------------------------
// `executed` is stamped when a test body is ENTERED and `completed` when it returns. Their
// difference is the number of bodies that were entered and did not come back — which a
// try/catch around the body cannot distinguish from a body that threw, because a rejected promise
// nobody awaited settles later and quietly. The check requires `executed === completed`, so a
// suspended body is a red rather than a silence. This is `WORKER-NODE.md`'s serial/finished pair,
// one level up.
//
//   WHAT THIS IS NOT
//   ----------------
// It is not jest. There is no module resolution, no TypeScript transform, no `node:fs`, no
// `worker_threads`, no npm. A suite is an ES module the page imports; the runtime it tests is the
// SHIPPED `testing.js`, byte for byte as `browser/build.mjs` emitted it. That is the whole of the
// "minimal" in "minimal support for executing javascript-based smart contract test suites in the
// browser", and its cost is this file.

/** Thrown by a failing expectation. Carries the pieces so a report can show both sides. */
export class ExpectationFailed extends Error {
  constructor(matcher, expected, actual) {
    super(`expected ${matcher} ${format(expected)}, got ${format(actual)}`);
    this.name = 'ExpectationFailed';
    this.matcher = matcher;
    this.expected = format(expected);
    this.actual = format(actual);
  }
}

// A formatter that never throws and never returns `[object Object]` — the value that once made a
// report field look like a measurement while carrying nothing.
function format(v) {
  if (typeof v === 'bigint') return `${v}n`;
  if (typeof v === 'string') return JSON.stringify(v);
  if (v === null || v === undefined) return String(v);
  if (typeof v === 'object') {
    try {
      return JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? `${x}n` : x));
    } catch {
      return Object.prototype.toString.call(v);
    }
  }
  return String(v);
}

/**
 * A suite under construction. `describe`/`it` push onto it; nothing runs during registration, so a
 * suite that throws while REGISTERING is distinguishable from one that throws while EXECUTING.
 */
class Registry {
  constructor() {
    this.tests = [];
    this.stack = [];
  }

  describe(name, body) {
    if (typeof name !== 'string' || name.length === 0) throw new Error('describe needs a name');
    if (typeof body !== 'function') throw new Error(`describe(${name}) needs a function`);
    this.stack.push(name);
    try {
      body();
    } finally {
      this.stack.pop();
    }
  }

  it(name, body) {
    if (typeof name !== 'string' || name.length === 0) throw new Error('it needs a name');
    if (typeof body !== 'function') throw new Error(`it(${name}) needs a function`);
    this.tests.push({ name: [...this.stack, name].join(' > '), body });
  }
}

/**
 * The expectation surface. Deliberately six matchers: every one of them is used by the suite in
 * this directory, and an unused matcher is a line nothing would notice the loss of.
 *
 * `counter` is the run's assertion tally. It is bumped BEFORE the comparison, so a failing
 * expectation is counted too — a tally that only counted successes would fall as a suite got
 * worse, which is the wrong direction for the number that says how much ran.
 */
function makeExpect(counter) {
  return function expect(actual) {
    return {
      toBe(expected) {
        counter.bump();
        if (!Object.is(actual, expected)) throw new ExpectationFailed('toBe', expected, actual);
      },
      toEqual(expected) {
        counter.bump();
        const a = format(actual);
        const b = format(expected);
        if (a !== b) throw new ExpectationFailed('toEqual', expected, actual);
      },
      toBeGreaterThan(expected) {
        counter.bump();
        if (!(actual > expected)) throw new ExpectationFailed('toBeGreaterThan', expected, actual);
      },
      toBeLessThan(expected) {
        counter.bump();
        if (!(actual < expected)) throw new ExpectationFailed('toBeLessThan', expected, actual);
      },
      toContain(expected) {
        counter.bump();
        const ok =
          (typeof actual === 'string' && actual.includes(expected)) ||
          (Array.isArray(actual) && actual.some((x) => Object.is(x, expected)));
        if (!ok) throw new ExpectationFailed('toContain', expected, actual);
      },
      toBeDefined() {
        counter.bump();
        if (actual === undefined || actual === null) {
          throw new ExpectationFailed('toBeDefined', 'a value', actual);
        }
      },
    };
  };
}

/**
 * Load a suite module and run it.
 *
 * @param {string} moduleUrl  the suite, imported by the page. A relative URL is resolved against
 *                            the page, which is what lets an arm serve a mutated copy.
 * @param {unknown} context   handed to the suite's default export. This runner knows nothing about
 *                            Aztec; the context is where the runtime comes from.
 * @returns a report. `status` is `ok` only when a suite loaded, registered at least one test, and
 *          every entered body came back.
 */
export async function runSuite(moduleUrl, context) {
  const started = Date.now();
  const base = {
    moduleUrl,
    startedAt: new Date(started).toISOString(),
    total: 0,
    executed: 0,
    completed: 0,
    passed: 0,
    failed: 0,
    assertions: 0,
    tests: [],
  };

  let module_;
  try {
    module_ = await import(moduleUrl);
  } catch (err) {
    return { ...base, status: 'error', reason: 'load-failed', message: messageOf(err), ms: Date.now() - started };
  }

  const register = module_.default;
  if (typeof register !== 'function') {
    return {
      ...base,
      status: 'error',
      reason: 'no-default-export',
      message: `${moduleUrl} has no default export; a suite is a module whose default export registers tests`,
      ms: Date.now() - started,
    };
  }

  const registry = new Registry();
  try {
    await register({ describe: (n, b) => registry.describe(n, b), it: (n, b) => registry.it(n, b) }, context);
  } catch (err) {
    return {
      ...base,
      status: 'error',
      reason: 'registration-failed',
      message: messageOf(err),
      ms: Date.now() - started,
    };
  }

  base.total = registry.tests.length;
  // THE `0/0 … exited 0` SHAPE, REFUSED BY NAME. A suite that registered nothing is the exact
  // report a suite that failed to load half way would produce, and the two must not both be green.
  if (base.total === 0) {
    return {
      ...base,
      status: 'error',
      reason: 'no-tests',
      message: `${moduleUrl} registered 0 tests. An empty suite is a failure to load, not a pass.`,
      ms: Date.now() - started,
    };
  }

  const counter = { n: 0, bump() { this.n += 1; } };
  const expect = makeExpect(counter);

  for (const test of registry.tests) {
    const before = counter.n;
    const t0 = Date.now();
    base.executed += 1;
    let outcome = { name: test.name, status: 'passed', assertions: 0, ms: 0 };
    try {
      await test.body({ expect, ...(typeof context === 'object' && context !== null ? context : {}) });
      const made = counter.n - before;
      if (made === 0) {
        // A BODY THAT ASSERTED NOTHING IS NOT A PASS. It is the commonest shape of a test that
        // silently stopped doing its job — an early `return`, a renamed field read as `undefined`,
        // a helper that swallowed. It cannot be told from a real pass by the count of failures.
        outcome = { name: test.name, status: 'failed', assertions: 0, ms: 0, reason: 'no-expectations',
          message: 'the test body completed without making a single expectation' };
      } else {
        outcome.assertions = made;
      }
    } catch (err) {
      outcome = {
        name: test.name,
        status: 'failed',
        assertions: counter.n - before,
        ms: 0,
        reason: err instanceof ExpectationFailed ? 'expectation' : 'threw',
        message: messageOf(err),
        ...(err instanceof ExpectationFailed ? { matcher: err.matcher, expected: err.expected, actual: err.actual } : {}),
      };
    }
    outcome.ms = Date.now() - t0;
    base.completed += 1;
    base.tests.push(outcome);
    if (outcome.status === 'passed') base.passed += 1;
    else base.failed += 1;
  }

  base.assertions = counter.n;
  base.ms = Date.now() - started;
  // `executed === completed` is the suspended-body check; `assertions > 0` is the did-anything-run
  // check. Neither is implied by `failed === 0`, which is why both are here.
  const intact = base.executed === base.completed && base.assertions > 0;
  return {
    ...base,
    status: base.failed === 0 && intact ? 'ok' : base.failed > 0 ? 'failed' : 'error',
    ...(intact ? {} : { reason: 'incomplete', message: `executed ${base.executed}, completed ${base.completed}, assertions ${base.assertions}` }),
  };
}

function messageOf(err) {
  if (err === null || err === undefined) return String(err);
  const m = err.message ?? String(err);
  const stack = typeof err.stack === 'string' ? err.stack.slice(0, 900) : '';
  return stack.startsWith(String(m)) ? stack : `${m}\n${stack}`;
}
