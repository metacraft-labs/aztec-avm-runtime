// chain_clock.ts — DD-4's two injected things, and how little of either is ours.
//
// DD-4: "the clock is injected, always. No `Date.now()` and no `setInterval` anywhere in the
// runtime." Three reasons, all of which bite: a test must run a hundred simulated blocks without
// waiting a hundred seconds; a wall-clock timestamp inside a trace is a reproducibility bug; and a
// backgrounded browser tab gets its timers throttled, so a runtime that assumes even ticks
// produces a lumpy chain and blames itself.
//
// THE CLOCK IS UPSTREAM'S AND IS NOT REDECLARED HERE. `@aztec/foundation/timer` ships
// `DateProvider` (`now()` in milliseconds, `nowInSeconds()`, `nowAsDate()`), `TestDateProvider`
// (an OFFSET over real time) and `ManualDateProvider` (a frozen clock advanced only by explicit
// calls). That is exactly DD-4's hierarchy, already published, already a dependency of this
// package — `block_assembly.ts` has taken a `DateProvider` since M22 — and already what upstream's
// own `AutomineSequencer` injects. So this file declares NO `Clock` interface: it re-exports
// upstream's three and names which one each situation wants. Declaring one would be the
// `TreeSnapshot` mistake M23's own deliverables forbid, one directory over.
//
// The milestone states the timestamp rule as
// `max(prevTimestamp + minBlockSpacingSeconds, floor(clock.nowMs() / 1000))`. `clock.nowMs()` is
// `DateProvider.now()` and `floor(… / 1000)` is `DateProvider.nowInSeconds()`, whose body is
// `Math.floor(this.now() / 1000)`. `nextBlockTimestamp` below is that formula in upstream's
// vocabulary, and `wallClockSeconds` is carried beside every block so the DEVIATION from the wall
// clock is declared rather than hidden.
//
// THE TICKER IS OURS AND IT IS TWENTY LINES, because the thing upstream ticks on cannot be the
// thing a fake-clock test ticks on. `RunningPromise` (`@aztec/foundation/running-promise`) is what
// `Sequencer` and `AutomineSequencer` both use and it is the real-time implementation here,
// unchanged and unwrapped except by the three-method interface below. What it cannot be is the
// test one: it sleeps against the host's own timers, so a hundred blocks at a one-second interval
// is a hundred seconds no matter what clock is injected. `ManualTicker` is the other
// implementation and it is the reason `test_fake_clock_hundred_blocks` finishes.
//
// NOTHING IN THIS FILE — OR ANYWHERE IN `orchestration/src` — CALLS `Date.now`, `setInterval` OR
// `setTimeout`. `test_no_ambient_clock_or_timer` asserts that structurally over every source file,
// with a planted call as its control. `RunningPromise` does use timers, in `node_modules`, which
// is the point: the timer is a dependency the runtime names rather than a call the runtime makes.

import { DateProvider, ManualDateProvider, TestDateProvider } from '@aztec/foundation/timer';
import { RunningPromise } from '@aztec/foundation/running-promise';

export { DateProvider, ManualDateProvider, TestDateProvider };

/**
 * The next block's timestamp, in seconds.
 *
 * `max(prev + minSpacing, clock.nowInSeconds())`. With `minSpacing >= 1` this is STRICTLY
 * increasing by construction and no measurement of the host clock can make it repeat or regress —
 * which is what `test_timestamps_strictly_monotonic_subsecond` asks of a sub-second interval and
 * of a throttled timer, the two cases where the wall clock does not move between blocks.
 *
 * `minSpacing` of 0 is accepted and is NOT silently corrected: a caller who asks for it gets a
 * chain whose timestamps can repeat, and `BlockProductionConfig`'s default is 1. Correcting it
 * here would make the guarantee a property of a default rather than of the formula.
 */
export function nextBlockTimestamp(
  previousTimestamp: bigint,
  clock: DateProvider,
  minBlockSpacingSeconds: number,
): bigint {
  const floor = previousTimestamp + BigInt(minBlockSpacingSeconds);
  const wall = BigInt(clock.nowInSeconds());
  return wall > floor ? wall : floor;
}

/**
 * What drives block production.
 *
 * Three methods and no more, because that is what `RunningPromise` already gives and adding a
 * fourth would be inventing a scheduler rather than naming one.
 */
export interface BlockTicker {
  /** Begin calling `onTick`. Calling twice is a caller error and throws. */
  start(onTick: () => Promise<void>): void;
  /** Stop, and wait for an in-flight tick to finish. */
  stop(): Promise<void>;
  /** Run one tick NOW, ahead of the interval. `automine` and manual production use it. */
  trigger(): Promise<void>;
  readonly running: boolean;
  /** Ticks delivered so far. A count, so "the timer fired" is measured and not assumed. */
  readonly ticks: number;
}

/**
 * The real-time ticker: upstream's `RunningPromise`, unchanged.
 *
 * It owns the sleeping, the coalescing of concurrent `trigger()` callers and the interruptible
 * `stop()`. None of that is reimplemented here — this class holds one and forwards.
 */
export class RunningPromiseTicker implements BlockTicker {
  private promise: RunningPromise | null = null;
  private counted = 0;
  readonly intervalMs: number;

  constructor(intervalMs: number) {
    if (!Number.isFinite(intervalMs) || intervalMs <= 0) {
      throw new Error(`RunningPromiseTicker needs a positive interval, got ${intervalMs}`);
    }
    this.intervalMs = intervalMs;
  }

  start(onTick: () => Promise<void>): void {
    if (this.promise) {
      throw new Error('this ticker is already running');
    }
    this.promise = new RunningPromise(
      async () => {
        this.counted += 1;
        await onTick();
      },
      // `RunningPromise` logs through a logger; the runtime's telemetry replacement supplies one
      // shaped like it. `debug`/`error` are the only two it calls.
      { debug: () => {}, error: () => {}, warn: () => {}, info: () => {}, verbose: () => {} } as never,
      this.intervalMs,
    );
    this.promise.start();
  }

  async stop(): Promise<void> {
    const p = this.promise;
    this.promise = null;
    if (p) {
      await p.stop();
    }
  }

  async trigger(): Promise<void> {
    if (!this.promise) {
      throw new Error('this ticker is not running');
    }
    await this.promise.trigger();
  }

  get running(): boolean {
    return this.promise !== null;
  }

  get ticks(): number {
    return this.counted;
  }
}

/**
 * The fake-clock ticker.
 *
 * NO TIMER OF ANY KIND. `tick()` runs the callback on the caller's stack and returns its promise,
 * so a hundred blocks cost a hundred awaits and no wall-clock time at all. This is what makes
 * DD-4's first reason real rather than aspirational: `test_fake_clock_hundred_blocks` runs a
 * hundred blocks on a `ManualDateProvider` and a `ManualTicker` and compares the result against a
 * run on a real interval.
 */
export class ManualTicker implements BlockTicker {
  private onTick: (() => Promise<void>) | null = null;
  private counted = 0;

  start(onTick: () => Promise<void>): void {
    if (this.onTick) {
      throw new Error('this ticker is already running');
    }
    this.onTick = onTick;
  }

  stop(): Promise<void> {
    this.onTick = null;
    return Promise.resolve();
  }

  async trigger(): Promise<void> {
    await this.tick();
  }

  /** Deliver one tick. Throws if the ticker was never started, rather than doing nothing. */
  async tick(): Promise<void> {
    if (!this.onTick) {
      throw new Error('this ticker is not running');
    }
    this.counted += 1;
    await this.onTick();
  }

  /** Deliver `n` ticks, in order, each awaited before the next. */
  async tickTimes(n: number): Promise<void> {
    for (let i = 0; i < n; i++) {
      await this.tick();
    }
  }

  get running(): boolean {
    return this.onTick !== null;
  }

  get ticks(): number {
    return this.counted;
  }
}

/**
 * A ticker that never fires.
 *
 * `intervalMs: 0` is the manual mode `BlockProductionConfig` documents, and this is what it
 * produces. `trigger()` still works — manual mode means "no timer", not "no block production" —
 * so `produceBlock()` goes through exactly the same path as a timed one.
 */
export class DisabledTicker implements BlockTicker {
  private onTick: (() => Promise<void>) | null = null;
  private counted = 0;

  start(onTick: () => Promise<void>): void {
    this.onTick = onTick;
  }

  stop(): Promise<void> {
    this.onTick = null;
    return Promise.resolve();
  }

  async trigger(): Promise<void> {
    if (!this.onTick) {
      throw new Error('this ticker is not running');
    }
    this.counted += 1;
    await this.onTick();
  }

  get running(): boolean {
    return this.onTick !== null;
  }

  get ticks(): number {
    return this.counted;
  }
}
