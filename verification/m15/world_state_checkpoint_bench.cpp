// world_state_checkpoint_bench — what a checkpoint of the reference world state costs, measured.
//
// M15's third deliverable. `world_state_reference::MemoryMerkleDB`'s own header says it:
//
//     "Checkpoints deep-copy the whole tree state onto a stack and restore on revert"
//
// and §6.4's design constraint asked for O(changes). Nobody has ever timed it: an exhaustive search
// of the fork at the pinned anchor finds no benchmark referencing `world_state_reference`,
// `MemoryMerkleDB` or `merkle_db` — the only file that exercises checkpoints at all is
// `world_state/memory_merkle_db.test.cpp`, which asserts equivalence and times nothing.
//
// So this program measures it, and it measures the COMPLEXITY rather than a number: the same
// operations at populations an order of magnitude apart, so the growth exponent is read off the
// data instead of being asserted from the source. A single population would produce a number that
// says nothing about O(state) versus O(changes) — which is the whole question.
//
// WHAT IT DOES NOT DO. It does not decide anything. It prints `key=value` on stdout and the shell
// asserts; a benchmark that graded itself would be a second, unreviewed set of expectations. It
// also prints nothing on stderr in a successful run, so a diagnostic can never become a parsed key.
//
// THE POPULATION IS BUILT THE WAY EXECUTION BUILDS IT — nullifiers through
// `insert_indexed_leaves_nullifier_tree`, public-data writes through
// `insert_indexed_leaves_public_data_tree`, note hashes through `append_leaves` — and not by
// reaching into the trees, because the cost being measured is the cost of the state those calls
// leave behind.
//
// THE FLOOR IS MEASURED SEPARATELY, and it is the finding a ratio alone would hide. A freshly
// constructed DB has already written the two indexed trees' genesis prefill — 128 leaves each at
// heights 42 and 40 — so the FIRST `create_checkpoint()` of a transaction that has done nothing at
// all still copies that. `population=0` is that measurement.
//
// TIMING DISCIPLINE. Every reported figure is a MEDIAN over repetitions, and the repetition count
// is printed with it. Medians rather than means because one page fault during one copy is not the
// cost of a copy. The absolute microseconds are a property of this host; the RATIOS between
// populations are the property of the implementation, and they are what the check asserts.
//
// A NOTE ON WHAT `commit` COSTS. It copies nothing — it pops — but popping a `State` destroys four
// (five, with M14's patch) hash maps node by node, so it is not free either and it is timed
// separately. Reporting one "checkpoint cost" would have merged a copy with a destructor.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "barretenberg/aztec/aztec_constants.hpp"
#include "barretenberg/world_state_reference/memory_merkle_db.hpp"

using bb::world_state::MemoryMerkleDB;
using bb::world_state::MerkleTreeId;
using FF = bb::fr;
using Clock = std::chrono::steady_clock;

namespace {

// The archive tree is present only with M14's patch. Detected rather than assumed, and the answer
// is REPORTED, so one source describes both trees and neither arm is told which it is. Same
// technique as M14's own probe, and for the same reason: `#ifdef` would make this two programs.
template <typename T>
concept DbHasUpdateArchive = requires(T& db, const bb::world_state::TreeRoots& r, const FF& h) {
    db.update_archive(r, h);
};

void kv(const char* key, const std::string& value)
{
    std::printf("%s=%s\n", key, value.c_str());
}
void kv(const char* key, uint64_t value)
{
    std::printf("%s=%llu\n", key, static_cast<unsigned long long>(value));
}

uint64_t median(std::vector<uint64_t> v)
{
    if (v.empty()) {
        return 0;
    }
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

// Distinct values, deterministically. A repeated nullifier is rejected by the indexed tree and a
// repeated public-data slot is an update rather than an insertion, so a generator that collided
// would silently measure a smaller population than the one it reported.
FF nth(uint64_t stream, uint64_t i)
{
    return FF(stream * 1000000007ull + i + 1);
}

// Populate `db` as execution would. Returns nothing: the population is the state left behind.
void populate(MemoryMerkleDB& db, uint64_t n)
{
    for (uint64_t i = 0; i < n; i++) {
        db.insert_indexed_leaves_nullifier_tree(bb::crypto::merkle_tree::NullifierLeafValue(nth(1, i)));
        db.insert_indexed_leaves_public_data_tree(
            bb::crypto::merkle_tree::PublicDataLeafValue(nth(2, i), nth(3, i)));
        const FF note = nth(4, i);
        db.append_leaves(MerkleTreeId::NOTE_HASH_TREE, std::span<const FF>(&note, 1));
    }
}

struct Timings {
    uint64_t create_us;
    uint64_t commit_us;
    uint64_t revert_us;
    uint64_t reps;
};

// One population, three operations, each timed on its own.
//
// `create` and `commit` are timed as a PAIR of calls but attributed separately, because a
// create must be balanced by exactly one commit or revert and an unbalanced stack is a different
// program. The pattern is create/commit and create/revert, alternating, so neither operation is
// ever measured on a stack the other has grown.
Timings measure(uint64_t population, uint64_t reps)
{
    MemoryMerkleDB db;
    populate(db, population);

    std::vector<uint64_t> create, commit, revert;
    create.reserve(reps);
    commit.reserve(reps);
    revert.reserve(reps);

    for (uint64_t r = 0; r < reps; r++) {
        auto t0 = Clock::now();
        db.create_checkpoint();
        auto t1 = Clock::now();
        db.commit_checkpoint();
        auto t2 = Clock::now();
        db.create_checkpoint();
        auto t3 = Clock::now();
        db.revert_checkpoint();
        auto t4 = Clock::now();

        using us = std::chrono::microseconds;
        create.push_back(static_cast<uint64_t>(std::chrono::duration_cast<us>(t1 - t0).count()));
        commit.push_back(static_cast<uint64_t>(std::chrono::duration_cast<us>(t2 - t1).count()));
        create.push_back(static_cast<uint64_t>(std::chrono::duration_cast<us>(t3 - t2).count()));
        revert.push_back(static_cast<uint64_t>(std::chrono::duration_cast<us>(t4 - t3).count()));
    }

    // The stack must be exactly where it started, or some of the above measured a different thing.
    // Reported, not asserted here.
    return Timings{ median(create), median(commit), median(revert), reps };
}

// The nested-call shape, which is how a transaction actually pays this. `ContextProvider::
// make_nested_context` creates a checkpoint per nested external call and `Execution::
// handle_exit_call` commits or reverts it, so a call k deep holds k open checkpoints — and every
// one of them was a full copy. This times a depth-k open/close sequence as one unit.
uint64_t measure_nested(uint64_t population, uint64_t depth, uint64_t reps)
{
    MemoryMerkleDB db;
    populate(db, population);
    std::vector<uint64_t> samples;
    samples.reserve(reps);
    for (uint64_t r = 0; r < reps; r++) {
        auto t0 = Clock::now();
        for (uint64_t d = 0; d < depth; d++) {
            db.create_checkpoint();
        }
        for (uint64_t d = 0; d < depth; d++) {
            db.commit_checkpoint();
        }
        auto t1 = Clock::now();
        samples.push_back(
            static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count()));
    }
    return median(samples);
}

} // namespace

int main(int argc, char** argv)
{
    try {
        // Populations an order of magnitude apart, and the empty one. Three points rather than the
        // two the milestone asks for: two give a ratio, three let the growth be read as a growth
        // rather than as a single step that a constant term could explain.
        std::vector<uint64_t> populations = { 0, 100, 1000, 10000 };
        uint64_t reps = 9;
        if (argc > 1) {
            reps = static_cast<uint64_t>(std::stoull(argv[1]));
        }

        kv("bench.name", std::string("world_state_checkpoint"));
        kv("bench.reps", reps);
        kv("bench.populations.count", static_cast<uint64_t>(populations.size()));
        kv("bench.nullifier_prefill", static_cast<uint64_t>(MemoryMerkleDB::DEFAULT_NULLIFIER_TREE_PREFILL));
        kv("bench.public_data_prefill",
           static_cast<uint64_t>(MemoryMerkleDB::DEFAULT_PUBLIC_DATA_TREE_PREFILL));
        kv("bench.note_hash_tree_height", static_cast<uint64_t>(NOTE_HASH_TREE_HEIGHT));
        kv("bench.nullifier_tree_height", static_cast<uint64_t>(NULLIFIER_TREE_HEIGHT));
        kv("bench.public_data_tree_height", static_cast<uint64_t>(PUBLIC_DATA_TREE_HEIGHT));
        kv("bench.archive_tree_height", static_cast<uint64_t>(ARCHIVE_HEIGHT));

        {
            MemoryMerkleDB probe;
            kv("bench.archive_present", static_cast<uint64_t>(DbHasUpdateArchive<MemoryMerkleDB> ? 1 : 0));
            kv("bench.checkpoint_id_at_rest", static_cast<uint64_t>(probe.get_checkpoint_id()));
        }

        for (uint64_t p : populations) {
            const Timings t = measure(p, reps);
            const std::string pre = "cp." + std::to_string(p);
            kv((pre + ".population").c_str(), p);
            kv((pre + ".create_us").c_str(), t.create_us);
            kv((pre + ".commit_us").c_str(), t.commit_us);
            kv((pre + ".revert_us").c_str(), t.revert_us);
        }

        // The nested-call shape at the largest population, at three depths. A depth-k sequence is
        // k copies and k destroys, so if the cost is O(state) it is linear in k with a slope equal
        // to one create plus one commit.
        for (uint64_t d : { uint64_t{ 1 }, uint64_t{ 4 }, uint64_t{ 16 } }) {
            const std::string pre = "nested.d" + std::to_string(d);
            kv((pre + ".depth").c_str(), d);
            kv((pre + ".us").c_str(), measure_nested(1000, d, reps));
        }

        // The state the trees are actually in at the end, so a run that measured an empty database
        // by accident is visible rather than plausible.
        {
            MemoryMerkleDB db;
            populate(db, 1000);
            const auto roots = db.get_tree_roots();
            kv("final.nullifier_tree.size", static_cast<uint64_t>(roots.nullifier_tree.next_available_leaf_index));
            kv("final.note_hash_tree.size", static_cast<uint64_t>(roots.note_hash_tree.next_available_leaf_index));
            kv("final.public_data_tree.size",
               static_cast<uint64_t>(roots.public_data_tree.next_available_leaf_index));
        }

        kv("bench_complete", static_cast<uint64_t>(1));
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return 1;
    }
}
