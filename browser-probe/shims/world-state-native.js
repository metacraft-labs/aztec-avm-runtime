// Stand-in for the one symbol public_processor.ts uses from @aztec/world-state/native.
// The upstream ForkCheckpoint is 45 lines of pure TypeScript over
// MerkleTreeCheckpointOperations, with no native dependency at all.
export class ForkCheckpoint {
  #fork; #completed = false; depth;
  constructor(fork, depth) { this.#fork = fork; this.depth = depth; }
  static async new(fork) { return new ForkCheckpoint(fork, await fork.createCheckpoint()); }
  async commit() { if (!this.#completed) { await this.#fork.commitCheckpoint(); this.#completed = true; } }
  async revert() { if (!this.#completed) { await this.#fork.revertCheckpoint(); this.#completed = true; } }
  async revertToCheckpoint() { if (!this.#completed) { await this.#fork.revertAllCheckpointsTo(this.depth - 1); this.#completed = true; } }
}
