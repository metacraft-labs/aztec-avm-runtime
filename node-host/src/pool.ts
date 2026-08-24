// Compiled once, instantiated many times.
//
// WHAT IS EXPENSIVE AND WHAT IS NOT. `WebAssembly.compile` on a 1.5 MB module is the expensive
// half; instantiation is cheap. A block of transactions that recompiled the module per transaction
// would pay the compile every time for nothing, so `ModuleCache` keeps the `WebAssembly.Module` —
// which V8 itself treats as a structured-cloneable, shareable artefact — keyed on the path it was
// read from.
//
// AND THE PART THAT IS NOT AN OPTIMISATION. An instance is REUSED across simulations, and that is
// only sound because of two properties this pool enforces rather than assumes:
//
//   * A TRAPPED INSTANCE IS NEVER HANDED OUT AGAIN. Its linear memory is in an undefined state, so
//     everything it would say afterwards is meaningless. `Reactor` poisons itself on a trap and
//     `acquire` refuses a poisoned instance, retiring it and building a fresh one. A pool that
//     recycled a trapped instance would turn one runtime bug into an unbounded number of wrong
//     answers — the exact failure the trap/revert distinction exists to prevent, one layer up.
//   * A REUSED INSTANCE MUST PRODUCE THE SAME ANSWERS AS A FRESH ONE. That is not asserted here,
//     because a claim about the module's own state belongs in a test rather than in a comment:
//     `test_node_loader_instance_reuse` runs the corpus both ways and compares, and also compares
//     `pages` before and after, so "no linear-memory growth across runs" is a measurement.
//
// The DB handles are NOT pooled. `avm_contract_db_create` / `avm_merkle_db_create` are the
// module's own lifecycle and a transaction wants its own; recycling them would be recycling
// transaction state, which is a different and much worse idea than recycling an instance.

import { compileAvm, instantiateAvm, type CompiledAvm, type InstantiateOptions } from './loader.ts';
import type { Reactor } from './reactor.ts';

export class ModuleCache {
  private readonly compiled = new Map<string, Promise<CompiledAvm>>();
  private hits = 0;
  private misses = 0;

  /** Compiles `path` once. Concurrent callers share the one in-flight compilation. */
  get(path: string): Promise<CompiledAvm> {
    const existing = this.compiled.get(path);
    if (existing) {
      this.hits++;
      return existing;
    }
    this.misses++;
    const p = compileAvm(path);
    this.compiled.set(path, p);
    return p;
  }

  /** Compilations served from the cache. */
  get hitCount(): number {
    return this.hits;
  }

  /** Compilations actually performed. One per distinct path, for the life of the cache. */
  get missCount(): number {
    return this.misses;
  }
}

export interface PoolStats {
  /** Instances constructed. One, unless a trap retired one. */
  readonly created: number;
  /** Acquisitions served by an existing instance. */
  readonly reused: number;
  /** Instances retired because they had trapped. */
  readonly retired: number;
}

/**
 * A pool of one instance per module, which is what a single-threaded host needs: the AVM is
 * single-threaded, `avm_result_ptr()` names ONE module-owned buffer, and two concurrent callers
 * through one instance would read each other's results. `acquire` is therefore not re-entrant and
 * says so by refusing rather than by convention.
 */
export class InstancePool {
  private readonly cache: ModuleCache;
  private readonly options: InstantiateOptions;
  private instance: Reactor | null = null;
  private inUse = false;
  private created = 0;
  private reused = 0;
  private retired = 0;

  constructor(cache: ModuleCache, options: InstantiateOptions = {}) {
    this.cache = cache;
    this.options = options;
  }

  get stats(): PoolStats {
    return { created: this.created, reused: this.reused, retired: this.retired };
  }

  /** Runs `body` on a pooled instance. The instance is released, or retired if it trapped. */
  async withInstance<T>(path: string, body: (reactor: Reactor) => T | Promise<T>): Promise<T> {
    const reactor = await this.acquire(path);
    try {
      return await body(reactor);
    } finally {
      this.release();
    }
  }

  private async acquire(path: string): Promise<Reactor> {
    if (this.inUse) {
      throw new Error(
        'InstancePool.acquire is not re-entrant: the reactor has ONE module-owned result buffer, ' +
          'so two callers through one instance would read each other’s results',
      );
    }
    if (this.instance && this.instance.poisoned) {
      this.retired++;
      this.instance = null;
    }
    if (!this.instance) {
      const compiled = await this.cache.get(path);
      this.instance = await instantiateAvm(compiled, this.options);
      this.created++;
    } else {
      this.reused++;
    }
    this.inUse = true;
    return this.instance;
  }

  private release(): void {
    this.inUse = false;
  }
}
