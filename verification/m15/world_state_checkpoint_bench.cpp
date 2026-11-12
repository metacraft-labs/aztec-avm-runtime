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
// TIMING DISCIPLINE, AND WHY BOTH TREES ARE MEASURED INSIDE ONE PROCESS. The question this program
// answers is "what does the fifth tree add to a checkpoint", a difference of a few microseconds
// between two builds of `MemoryMerkleDB`. Run as two processes, that difference sits UNDER the
// process-to-process noise of a shared runner: a whole process runs 15-30 us faster or slower than
// its partner depending on the core it landed on, the frequency that core was at and where its heap
// happened to be placed, and no amount of batching inside a process removes a shift that is the
// same for every batch of that process. So the two builds are linked into ONE executable and
// measured against each other in the same process, on the same core, from the same heap, in
// alternating batches. A process-level shift then moves both arms and cancels in the difference.
//
// HOW TWO BUILDS OF THE SAME CLASS SHARE A PROCESS. This file is compiled in two roles, and the
// role is chosen by the compiler command line, so there is still one source:
//
//   -DM15_ARM=<base|ext>   the ARM: everything that touches `MemoryMerkleDB`. It is compiled against
//                          ONE tree's headers, linked (`ld -r`) with that tree's static libraries
//                          into one relocatable object, and every symbol except the six `extern "C"`
//                          entry points is then made local (`objcopy --keep-global-symbol`), so the
//                          two trees' `bb::world_state::MemoryMerkleDB` do not collide at the final
//                          link and no inline function of one arm can be silently replaced by the
//                          other's (COMDAT groups are dissolved with `--force-group-allocation` for
//                          the same reason). Both arms call the one process-wide allocator.
//   -DM15_DRIVER           the DRIVER: it includes no barretenberg header at all, only the arms'
//                          C ABI, and owns the schedule, the clock, the pinning and the arithmetic.
//
// THE SCHEDULE. A measurement is a series of ROUNDS. In each round both arms run one batch of
// operations, long enough (>= 20 ms) that one batch mean resolves a few microseconds per call, and
// the order of the two arms alternates with the round (ext first, then base, ...). Two consecutive
// rounds are an ABBA BLOCK; the block's effect is the mean of its two paired differences, so
// whatever the second batch of a round gains or loses from the first one's cache and allocator
// footprint cancels inside the block. The reported effect is the MEDIAN over blocks, and the same
// median over the first and the second half of the blocks is reported too, because the check asks
// that the sign replicate across the run. For populations whose construction is cheap (<= 100
// leaves) both databases are rebuilt in every round, in that round's arm order, so that heap
// placement is drawn again each round instead of being one constant bias carried by the whole run.
//
// All figures are in NANOSECONDS: batch means, not single-call readings, so one page fault inside
// one copy is not the cost of a copy, and a 5 us effect is not rounded to a 5 us grid.
//
// A NOTE ON WHAT `commit` COSTS. It copies nothing — it pops — but popping a `State` destroys four
// (five, with M14's patch) hash maps node by node, so it is not free either and it is timed
// separately. Reporting one "checkpoint cost" would have merged a copy with a destructor.

#include <cstdint>

#define M15_CAT4(a, b, c, d) a##b##c##d
#define M15_FN2(arm, name) M15_CAT4(m15_, arm, _, name)
#define M15_FN(name) M15_FN2(M15_ARM, name)

// The arms' C ABI is the set of `extern "C"` functions named `m15_<arm>_<name>` below; the driver
// declares the same set. `M15Cycle` carries the three per-call sums of one batch of
// create/commit/create/revert. It is a plain struct so both roles agree on it without sharing a header.
struct M15Cycle {
    uint64_t create_ns; // sum over 2 * iters create_checkpoint calls
    uint64_t commit_ns; // sum over iters commit_checkpoint calls
    uint64_t revert_ns; // sum over iters revert_checkpoint calls
};

#ifdef M15_ARM
// ===========================================================================================
// THE ARM
// ===========================================================================================
#include <chrono>
#include <cstdio>
#include <exception>
#include <span>
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

uint64_t ns_between(Clock::time_point a, Clock::time_point b)
{
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(b - a).count());
}

} // namespace

extern "C" {

int M15_FN(archive_present)(void)
{
    return DbHasUpdateArchive<MemoryMerkleDB> ? 1 : 0;
}

int M15_FN(checkpoint_id_at_rest)(void)
{
    try {
        MemoryMerkleDB probe;
        return static_cast<int>(probe.get_checkpoint_id());
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return -1;
    }
}

// Prefill sizes and tree heights, so the driver can print them without including this tree's headers.
int M15_FN(constants)(uint64_t* out8)
{
    out8[0] = static_cast<uint64_t>(MemoryMerkleDB::DEFAULT_NULLIFIER_TREE_PREFILL);
    out8[1] = static_cast<uint64_t>(MemoryMerkleDB::DEFAULT_PUBLIC_DATA_TREE_PREFILL);
    out8[2] = static_cast<uint64_t>(NOTE_HASH_TREE_HEIGHT);
    out8[3] = static_cast<uint64_t>(NULLIFIER_TREE_HEIGHT);
    out8[4] = static_cast<uint64_t>(PUBLIC_DATA_TREE_HEIGHT);
    out8[5] = static_cast<uint64_t>(ARCHIVE_HEIGHT);
    out8[6] = 0;
    out8[7] = 0;
    return 0;
}

void* M15_FN(db_new)(uint64_t population)
{
    try {
        auto* db = new MemoryMerkleDB();
        populate(*db, population);
        return db;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return nullptr;
    }
}

void M15_FN(db_free)(void* db)
{
    delete static_cast<MemoryMerkleDB*>(db);
}

// `iters` repetitions of create/commit and create/revert, alternating so neither operation is ever
// measured on a stack the other has grown. A create is balanced by exactly one commit or revert, so
// the stack is back where it started when this returns. Every call is timed on its own and summed:
// the sum divided by the call count is the batch MEAN, which is what the driver compares.
int M15_FN(run_cycle)(void* dbp, uint64_t iters, M15Cycle* out)
{
    try {
        auto& db = *static_cast<MemoryMerkleDB*>(dbp);
        uint64_t create = 0, commit = 0, revert = 0;
        for (uint64_t r = 0; r < iters; r++) {
            const auto t0 = Clock::now();
            db.create_checkpoint();
            const auto t1 = Clock::now();
            db.commit_checkpoint();
            const auto t2 = Clock::now();
            db.create_checkpoint();
            const auto t3 = Clock::now();
            db.revert_checkpoint();
            const auto t4 = Clock::now();
            create += ns_between(t0, t1) + ns_between(t2, t3);
            commit += ns_between(t1, t2);
            revert += ns_between(t3, t4);
        }
        *out = M15Cycle{ create, commit, revert };
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return 1;
    }
}

// The nested-call shape, which is how a transaction actually pays this. `ContextProvider::
// make_nested_context` creates a checkpoint per nested external call and `Execution::
// handle_exit_call` commits or reverts it, so a call k deep holds k open checkpoints — and every
// one of them was a full copy. This times `iters` depth-k open/close sequences as one unit.
int M15_FN(run_nested)(void* dbp, uint64_t depth, uint64_t iters, uint64_t* total_ns)
{
    try {
        auto& db = *static_cast<MemoryMerkleDB*>(dbp);
        const auto t0 = Clock::now();
        for (uint64_t r = 0; r < iters; r++) {
            for (uint64_t d = 0; d < depth; d++) {
                db.create_checkpoint();
            }
            for (uint64_t d = 0; d < depth; d++) {
                db.commit_checkpoint();
            }
        }
        *total_ns = ns_between(t0, Clock::now());
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return 1;
    }
}

// The state the trees are actually in after `population`, so a run that measured an empty database
// by accident is visible rather than plausible.
int M15_FN(final_sizes)(uint64_t population, uint64_t* out3)
{
    try {
        MemoryMerkleDB db;
        populate(db, population);
        const auto roots = db.get_tree_roots();
        out3[0] = static_cast<uint64_t>(roots.nullifier_tree.next_available_leaf_index);
        out3[1] = static_cast<uint64_t>(roots.note_hash_tree.next_available_leaf_index);
        out3[2] = static_cast<uint64_t>(roots.public_data_tree.next_available_leaf_index);
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return 1;
    }
}

} // extern "C"
#endif // M15_ARM

#ifdef M15_DRIVER
// ===========================================================================================
// THE DRIVER
// ===========================================================================================
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#if defined(__linux__)
#include <sched.h>
#endif
#include <chrono>

extern "C" {
#define M15_DECLARE_ARM(arm)                                                                               \
    int m15_##arm##_archive_present(void);                                                                 \
    int m15_##arm##_checkpoint_id_at_rest(void);                                                           \
    int m15_##arm##_constants(uint64_t* out8);                                                             \
    void* m15_##arm##_db_new(uint64_t population);                                                         \
    void m15_##arm##_db_free(void* db);                                                                    \
    int m15_##arm##_run_cycle(void* db, uint64_t iters, M15Cycle* out);                                    \
    int m15_##arm##_run_nested(void* db, uint64_t depth, uint64_t iters, uint64_t* total_ns);              \
    int m15_##arm##_final_sizes(uint64_t population, uint64_t* out3);
M15_DECLARE_ARM(base)
M15_DECLARE_ARM(ext)
}

namespace {

struct Arm {
    const char* name;
    int (*archive_present)(void);
    int (*checkpoint_id_at_rest)(void);
    int (*constants)(uint64_t*);
    void* (*db_new)(uint64_t);
    void (*db_free)(void*);
    int (*run_cycle)(void*, uint64_t, M15Cycle*);
    int (*run_nested)(void*, uint64_t, uint64_t, uint64_t*);
    int (*final_sizes)(uint64_t, uint64_t*);
};

#define M15_ARM_ROW(arm)                                                                                   \
    Arm{ #arm,                                                                                             \
         &m15_##arm##_archive_present,                                                                     \
         &m15_##arm##_checkpoint_id_at_rest,                                                               \
         &m15_##arm##_constants,                                                                           \
         &m15_##arm##_db_new,                                                                              \
         &m15_##arm##_db_free,                                                                             \
         &m15_##arm##_run_cycle,                                                                           \
         &m15_##arm##_run_nested,                                                                          \
         &m15_##arm##_final_sizes }
// Index 0 is `base` (four trees), index 1 is `ext` (five). The roles are fixed; the ORDER in which
// they are timed within a round is what alternates.
const Arm kArms[2] = { M15_ARM_ROW(base), M15_ARM_ROW(ext) };

// One batch is at least this long, so a per-call mean carries the clock's ~25 ns overhead over
// thousands of calls rather than one, and a single page fault or interrupt is a small fraction.
constexpr uint64_t kBatchNs = 20'000'000;
// Populations whose database is rebuilt in EVERY round, so heap placement is drawn again each time.
// Above this a build costs more than the measurement it would decorrelate.
constexpr uint64_t kFreshPopulationMax = 100;
constexpr uint64_t kMaxIters = 5'000'000;

void kv(const std::string& key, const std::string& value)
{
    std::printf("%s=%s\n", key.c_str(), value.c_str());
}
void kv(const std::string& key, uint64_t value)
{
    std::printf("%s=%llu\n", key.c_str(), static_cast<unsigned long long>(value));
}
void kv(const std::string& key, int64_t value)
{
    std::printf("%s=%lld\n", key.c_str(), static_cast<long long>(value));
}

[[noreturn]] void die(const char* what)
{
    std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", what);
    std::exit(1);
}

// Median of a copy. An even count takes the mean of the two middle values, so a pair of blocks does
// not silently report its larger member.
int64_t median(std::vector<int64_t> v)
{
    if (v.empty()) {
        return 0;
    }
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

// Median absolute deviation about the median: the run's own noise, in the same unit as the effect.
int64_t mad(const std::vector<int64_t>& v)
{
    const int64_t m = median(v);
    std::vector<int64_t> dev;
    dev.reserve(v.size());
    for (int64_t x : v) {
        dev.push_back(x > m ? x - m : m - x);
    }
    return median(dev);
}

std::vector<int64_t> slice(const std::vector<int64_t>& v, size_t from, size_t to)
{
    return std::vector<int64_t>(v.begin() + static_cast<std::ptrdiff_t>(from),
                                v.begin() + static_cast<std::ptrdiff_t>(to));
}

int64_t mean_ns(uint64_t sum, uint64_t calls)
{
    return static_cast<int64_t>((sum + calls / 2) / calls);
}

// Pin the process to the CPU it is running on, so the arms cannot be separated by a migration
// between batches. Best effort: returns the CPU, or -1 where the platform or the sandbox does not
// allow it, and the result is REPORTED so a reader can tell which case a number came from.
int pin_to_current_cpu()
{
#if defined(__linux__)
    const int cpu = sched_getcpu();
    if (cpu < 0) {
        return -1;
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(static_cast<size_t>(cpu), &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        return -1;
    }
    return cpu;
#else
    return -1;
#endif
}

struct Dbs {
    void* db[2] = { nullptr, nullptr };
};

// Build both databases, in `order` (the round's arm order, so the second-built arm is not always
// the same one).
Dbs build_dbs(uint64_t population, const int order[2])
{
    Dbs d;
    for (int k = 0; k < 2; k++) {
        const int a = order[k];
        d.db[a] = kArms[a].db_new(population);
        if (d.db[a] == nullptr) {
            die("could not build a database");
        }
    }
    return d;
}

void free_dbs(Dbs& d, const int order[2])
{
    for (int k = 0; k < 2; k++) {
        kArms[order[k]].db_free(d.db[order[k]]);
        d.db[order[k]] = nullptr;
    }
}

struct CycleMeans {
    int64_t create, commit, revert;
};

CycleMeans run_cycle(int arm, void* db, uint64_t iters)
{
    M15Cycle c{};
    if (kArms[arm].run_cycle(db, iters, &c) != 0) {
        die("a cycle batch failed");
    }
    return CycleMeans{ mean_ns(c.create_ns, 2 * iters), mean_ns(c.commit_ns, iters),
                       mean_ns(c.revert_ns, iters) };
}

// Iterations per batch such that the FASTER arm's batch still lasts kBatchNs: the arms must run the
// same number of iterations for the pairing to mean anything, and "at least 20 ms" has to hold for
// both. Estimated from three single-iteration batches (their median), on the databases passed in.
uint64_t calibrate_cycle(const Dbs& d)
{
    uint64_t best = UINT64_MAX;
    for (int a = 0; a < 2; a++) {
        run_cycle(a, d.db[a], 2); // warm: first touch of this arm's code and allocator arenas
        std::vector<int64_t> per;
        for (int i = 0; i < 3; i++) {
            M15Cycle c{};
            if (kArms[a].run_cycle(d.db[a], 1, &c) != 0) {
                die("a calibration batch failed");
            }
            per.push_back(static_cast<int64_t>(c.create_ns + c.commit_ns + c.revert_ns));
        }
        const uint64_t m = static_cast<uint64_t>(std::max<int64_t>(median(per), 1));
        best = std::min(best, m);
    }
    return std::clamp<uint64_t>((kBatchNs + best - 1) / best, 1, kMaxIters);
}

struct PopulationResult {
    // Per round, per arm.
    std::vector<CycleMeans> rounds[2];
    // Per round: ext minus base, create only is what the check asserts; commit and revert are
    // reported for the record.
    std::vector<int64_t> d_create, d_commit, d_revert;
    uint64_t iters = 0;
};

PopulationResult measure_population(uint64_t population, uint64_t rounds)
{
    PopulationResult res;
    const bool fresh = population <= kFreshPopulationMax;

    const int natural[2] = { 0, 1 };
    // Calibrate on a database pair that is then thrown away when each round builds its own, and on
    // the long-lived pair itself otherwise, so a 10,000-leaf population is built once, not twice.
    Dbs shared = build_dbs(population, natural);
    res.iters = calibrate_cycle(shared);
    const uint64_t warm = std::max<uint64_t>(1, res.iters / 5);
    if (fresh) {
        free_dbs(shared, natural);
    } else {
        // Discarded rounds: the first batches on a long-lived database pay for faulting in its
        // maps and for the allocator settling, which is not what is being measured.
        for (int w = 0; w < 3; w++) {
            for (int a = 0; a < 2; a++) {
                run_cycle(a, shared.db[a], res.iters);
            }
        }
    }

    for (uint64_t r = 0; r < rounds; r++) {
        // ABBA across rounds: even rounds time base first, odd rounds ext first.
        const int order[2] = { static_cast<int>(r % 2), static_cast<int>(1 - r % 2) };
        Dbs d = fresh ? build_dbs(population, order) : shared;
        CycleMeans got[2] = {};
        if (fresh) {
            for (int k = 0; k < 2; k++) {
                run_cycle(order[k], d.db[order[k]], warm);
            }
        }
        for (int k = 0; k < 2; k++) {
            got[order[k]] = run_cycle(order[k], d.db[order[k]], res.iters);
        }
        if (fresh) {
            free_dbs(d, order);
        }
        res.rounds[0].push_back(got[0]);
        res.rounds[1].push_back(got[1]);
        res.d_create.push_back(got[1].create - got[0].create);
        res.d_commit.push_back(got[1].commit - got[0].commit);
        res.d_revert.push_back(got[1].revert - got[0].revert);
    }
    if (!fresh) {
        free_dbs(shared, natural);
    }
    return res;
}

// The per-block effect: the mean of the two paired differences of an ABBA block (rounds 2i, 2i+1).
// Order effects enter the two differences with opposite sign and cancel in the mean.
std::vector<int64_t> block_means(const std::vector<int64_t>& d)
{
    std::vector<int64_t> out;
    for (size_t i = 0; i + 1 < d.size(); i += 2) {
        out.push_back((d[i] + d[i + 1]) / 2);
    }
    return out;
}

std::vector<int64_t> arm_column(const PopulationResult& r, int arm, int64_t CycleMeans::*field)
{
    std::vector<int64_t> v;
    for (const CycleMeans& m : r.rounds[arm]) {
        v.push_back(m.*field);
    }
    return v;
}

void report_diff(const std::string& pre, const std::string& what, const std::vector<int64_t>& rounds_diff)
{
    const std::vector<int64_t> blocks = block_means(rounds_diff);
    const size_t half = blocks.size() / 2;
    kv(pre + "." + what + "_diff_ns", median(blocks));
    kv(pre + "." + what + "_diff_h1_ns", median(slice(blocks, 0, half)));
    kv(pre + "." + what + "_diff_h2_ns", median(slice(blocks, half, blocks.size())));
    kv(pre + "." + what + "_diff_mad_ns", mad(blocks));
    kv(pre + "." + what + "_diff_min_ns", *std::min_element(blocks.begin(), blocks.end()));
    kv(pre + "." + what + "_diff_max_ns", *std::max_element(blocks.begin(), blocks.end()));
    // The order effect the ABBA blocks cancel, reported so it is visible rather than assumed small:
    // mean paired difference of the base-first rounds minus that of the ext-first rounds.
    std::vector<int64_t> even, odd;
    for (size_t i = 0; i < rounds_diff.size(); i++) {
        (i % 2 == 0 ? even : odd).push_back(rounds_diff[i]);
    }
    kv(pre + "." + what + "_order_gap_ns", median(even) - median(odd));
}

// The nested shape, both arms at one population, alternating order each round like the rest.
void measure_nested(uint64_t population, uint64_t depth, uint64_t rounds)
{
    const int natural[2] = { 0, 1 };
    Dbs d = build_dbs(population, natural);
    // Calibrate on the faster arm so both batches last at least kBatchNs.
    uint64_t best = UINT64_MAX;
    for (int a = 0; a < 2; a++) {
        uint64_t t = 0;
        kArms[a].run_nested(d.db[a], depth, 2, &t); // warm
        std::vector<int64_t> per;
        for (int i = 0; i < 3; i++) {
            if (kArms[a].run_nested(d.db[a], depth, 1, &t) != 0) {
                die("a nested calibration batch failed");
            }
            per.push_back(static_cast<int64_t>(t));
        }
        best = std::min(best, static_cast<uint64_t>(std::max<int64_t>(median(per), 1)));
    }
    const uint64_t iters = std::clamp<uint64_t>((kBatchNs + best - 1) / best, 1, kMaxIters);
    for (int w = 0; w < 3; w++) {
        for (int a = 0; a < 2; a++) {
            uint64_t t = 0;
            kArms[a].run_nested(d.db[a], depth, iters, &t);
        }
    }
    std::vector<int64_t> per_arm[2];
    for (uint64_t r = 0; r < rounds; r++) {
        const int order[2] = { static_cast<int>(r % 2), static_cast<int>(1 - r % 2) };
        for (int k = 0; k < 2; k++) {
            uint64_t t = 0;
            if (kArms[order[k]].run_nested(d.db[order[k]], depth, iters, &t) != 0) {
                die("a nested batch failed");
            }
            per_arm[order[k]].push_back(mean_ns(t, iters));
        }
    }
    free_dbs(d, natural);
    const std::string pre = "nested.d" + std::to_string(depth);
    kv(pre + ".depth", depth);
    kv(pre + ".iters", iters);
    for (int a = 0; a < 2; a++) {
        kv(std::string(kArms[a].name) + "." + pre + ".ns", median(per_arm[a]));
    }
}

} // namespace

int main(int argc, char** argv)
{
    try {
        // Rounds, rounded UP to a multiple of four so there is an even number of ABBA blocks and the
        // two halves of the run have the same size.
        uint64_t rounds = 96;
        if (argc > 1) {
            rounds = static_cast<uint64_t>(std::stoull(argv[1]));
        }
        rounds = std::max<uint64_t>(4, (rounds + 3) / 4 * 4);
        // The populations whose database is long-lived and expensive to build get a fixed 12 rounds:
        // only within-arm ratios and the nested depth bands are asserted there, far above the noise,
        // and no claim about the fifth tree is made at them. The cheap populations (0 and 100) are
        // where the sign assertion lives, so they get all `rounds` (96 by default: 24 blocks per half).
        const uint64_t rounds_big = 12;
        // Populations an order of magnitude apart, and the empty one. Three points rather than the
        // two the milestone asks for: two give a ratio, three let the growth be read as a growth
        // rather than as a single step that a constant term could explain.
        const std::vector<uint64_t> populations = { 0, 100, 1000, 10000 };

        const int cpu = pin_to_current_cpu();

        kv("bench.name", std::string("world_state_checkpoint"));
        kv("bench.design", std::string("two arms, one process, one core, alternating ABBA batches"));
        kv("bench.rounds", rounds);
        kv("bench.blocks", rounds / 2);
        kv("bench.rounds_long_lived_populations", rounds_big);
        kv("bench.batch_ns_min", kBatchNs);
        kv("bench.fresh_population_max", kFreshPopulationMax);
        kv("bench.pinned_cpu", static_cast<int64_t>(cpu));
        kv("bench.populations.count", static_cast<uint64_t>(populations.size()));

        for (int a = 0; a < 2; a++) {
            const std::string arm = kArms[a].name;
            uint64_t c[8] = {};
            if (kArms[a].constants(c) != 0) {
                die("an arm could not report its constants");
            }
            kv(arm + ".bench.nullifier_prefill", c[0]);
            kv(arm + ".bench.public_data_prefill", c[1]);
            kv(arm + ".bench.note_hash_tree_height", c[2]);
            kv(arm + ".bench.nullifier_tree_height", c[3]);
            kv(arm + ".bench.public_data_tree_height", c[4]);
            kv(arm + ".bench.archive_tree_height", c[5]);
            kv(arm + ".bench.archive_present", static_cast<uint64_t>(kArms[a].archive_present()));
            kv(arm + ".bench.checkpoint_id_at_rest", static_cast<int64_t>(kArms[a].checkpoint_id_at_rest()));
        }

        for (uint64_t p : populations) {
            const auto t_start = std::chrono::steady_clock::now();
            const uint64_t pop_rounds = p <= kFreshPopulationMax ? rounds : rounds_big;
            const PopulationResult r = measure_population(p, pop_rounds);
            const std::string pre = "cp." + std::to_string(p);
            kv("pair." + pre + ".population", p);
            kv("pair." + pre + ".iters", r.iters);
            kv("pair." + pre + ".rounds", pop_rounds);
            kv("pair." + pre + ".fresh_dbs_per_round", static_cast<uint64_t>(p <= kFreshPopulationMax ? 1 : 0));
            for (int a = 0; a < 2; a++) {
                const std::string arm = kArms[a].name;
                kv(arm + "." + pre + ".create_ns", median(arm_column(r, a, &CycleMeans::create)));
                kv(arm + "." + pre + ".commit_ns", median(arm_column(r, a, &CycleMeans::commit)));
                kv(arm + "." + pre + ".revert_ns", median(arm_column(r, a, &CycleMeans::revert)));
            }
            report_diff("pair." + pre, "create", r.d_create);
            report_diff("pair." + pre, "commit", r.d_commit);
            report_diff("pair." + pre, "revert", r.d_revert);
            kv("pair." + pre + ".elapsed_ms",
               static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                         std::chrono::steady_clock::now() - t_start)
                                         .count()));
        }

        // The nested-call shape at one population, at three depths. A depth-k sequence is k copies
        // and k destroys, so if the cost is O(state) it is linear in k.
        for (uint64_t d : { uint64_t{ 1 }, uint64_t{ 4 }, uint64_t{ 16 } }) {
            measure_nested(1000, d, rounds_big);
        }

        // The state the trees are actually in at the end, so a run that measured an empty database
        // by accident is visible rather than plausible.
        for (int a = 0; a < 2; a++) {
            uint64_t sz[3] = {};
            if (kArms[a].final_sizes(1000, sz) != 0) {
                die("an arm could not report its final tree sizes");
            }
            const std::string arm = kArms[a].name;
            kv(arm + ".final.nullifier_tree.size", sz[0]);
            kv(arm + ".final.note_hash_tree.size", sz[1]);
            kv(arm + ".final.public_data_tree.size", sz[2]);
        }

        kv("bench_complete", static_cast<uint64_t>(1));
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "world_state_checkpoint_bench: %s\n", e.what());
        return 1;
    }
}
#endif // M15_DRIVER

#if !defined(M15_ARM) && !defined(M15_DRIVER)
#error "compile with -DM15_ARM=<base|ext> (an arm) or -DM15_DRIVER (the driver); see the header"
#endif
