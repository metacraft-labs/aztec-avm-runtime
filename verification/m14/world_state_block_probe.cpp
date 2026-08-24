// world_state_block_probe — ONE source, compiled and RUN against two trees.
//
// M14 asks whether `world_state_reference::MemoryMerkleDB` covers what block production needs, and
// it asks for the answer BY EXECUTION rather than by reading headers. This is the executable. It is
// compiled against the pinned anchor (where the archive tree is absent) and against the anchor plus
// M14's patch (where it is present), and it is the SAME source in both arms: what it can do is
// detected with `requires`-expressions and REPORTED, so neither arm is told which one it is.
//
// That matters more than it sounds. A probe with `#ifdef M14_ARCHIVE` around the archive half would
// be two programs sharing a file, and the base arm would be asserting something about a program
// that was never compiled. Here `archive_in_tree_roots=0` on the base tree is a statement the
// compiler made about the base tree's own header.
//
// THE ARCHIVE-DEPENDENT CODE IS IN TEMPLATES, and that is load-bearing rather than stylistic.
// `if constexpr` discards a branch only where the branch DEPENDS on a template parameter; in a
// plain function the discarded arm is still fully type-checked. The first version of this file put
// `if constexpr (TreeRootsHasArchive<TreeRoots>)` inside ordinary functions and failed to compile
// against the base tree with "no member named 'archive_tree' in 'bb::world_state::TreeRoots'" —
// which would have forced exactly the `#ifdef` this design exists to avoid.
//
// Everything is printed as `key=value` on stdout, one per line, for the shell to parse. Nothing is
// asserted here: this program reports, the check asserts. A probe that decided for itself whether it
// liked the answer would be a second, unreviewed set of expectations.
//
// It never exits 0 having printed nothing — the last line is `probe_complete=1`, and the shell both
// requires that line and counts the keys it got.

#include <cstdint>
#include <cstdio>
#include <exception>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "barretenberg/aztec/aztec_constants.hpp"
#include "barretenberg/world_state_reference/memory_merkle_db.hpp"

using bb::world_state::MemoryMerkleDB;
using bb::world_state::MerkleTreeId;
using bb::world_state::TreeRoots;
using bb::world_state::WorldStateRevision;
using FF = bb::fr;

namespace {

// ---- capability detection, the two arms' only difference -------------------------------------
template <typename T>
concept TreeRootsHasArchive = requires(T t) { t.archive_tree; };

template <typename T>
concept TreeRootsHasStateReferenceEquals = requires(const T& a, const T& b) {
    { a.state_reference_equals(b) } -> std::same_as<bool>;
};

template <typename T>
concept DbHasUpdateArchive = requires(T& db, const TreeRoots& r, const FF& h) { db.update_archive(r, h); };

template <typename T>
concept DbHasInitialBlockHeaderHash =
    requires(const TreeRoots& r) { T::compute_initial_block_header_hash(r, 0u, uint64_t{ 0 }); };

// bb::field has no to_string(); it has an ostream inserter, and that inserter produces the `0x` and
// sixty-four lowercase hex digits Tier D's capture and upstream's own constants are written in. The
// check asserts that shape rather than trusting it.
std::string hex(const FF& v)
{
    std::ostringstream os;
    os << v;
    return os.str();
}

void emit(const char* key, const std::string& value)
{
    printf("%s=%s\n", key, value.c_str());
}

void emit_u64(const char* key, uint64_t value)
{
    printf("%s=%llu\n", key, static_cast<unsigned long long>(value));
}

// Prints the four StateReference trees, and the archive only where the type has one. Templated for
// the reason in the header comment.
template <typename R> void emit_roots(const char* prefix, const R& r)
{
    auto one = [&](const char* name, const auto& snap) {
        printf("%s.%s.root=%s\n", prefix, name, hex(snap.root).c_str());
        printf("%s.%s.size=%llu\n", prefix, name, static_cast<unsigned long long>(snap.next_available_leaf_index));
    };
    one("l1_to_l2_message_tree", r.l1_to_l2_message_tree);
    one("note_hash_tree", r.note_hash_tree);
    one("nullifier_tree", r.nullifier_tree);
    one("public_data_tree", r.public_data_tree);
    if constexpr (TreeRootsHasArchive<R>) {
        one("archive_tree", r.archive_tree);
    }
}

// Calls `fn` and prints either the value it produced or the exception message it threw, so "this
// tree id is refused" is observed rather than inferred.
template <typename F> void emit_call(const char* key, F&& fn)
{
    try {
        std::string produced = fn();
        printf("%s.threw=0\n", key);
        printf("%s.value=%s\n", key, produced.c_str());
    } catch (const std::exception& e) {
        printf("%s.threw=1\n", key);
        printf("%s.message=%s\n", key, e.what());
    }
}

// ---- sections 6 and 7: a block sequence, and the archive inside the checkpoint stack ------------
// Templated on the database type so `if constexpr` genuinely discards it against the base tree.
template <typename DB> void emit_block_sequence()
{
    using Roots = std::remove_cvref_t<decltype(std::declval<const DB&>().get_tree_roots())>;
    if constexpr (TreeRootsHasArchive<Roots> && DbHasUpdateArchive<DB>) {
        DB chain;
        for (uint64_t block = 1; block <= 3; ++block) {
            // Move a tree the block header's state reference covers, so each block is a different
            // state and the archive leaves cannot coincide.
            const FF note_hashes[] = { FF(0x6000 + block) };
            chain.append_leaves(MerkleTreeId::NOTE_HASH_TREE, note_hashes);

            const Roots before = chain.get_tree_roots();
            chain.update_archive(before, FF(0xB10C0000ULL + block));
            const Roots after = chain.get_tree_roots();

            const std::string p = "block" + std::to_string(block);
            emit_roots(p.c_str(), after);
            emit_u64((p + ".state_reference_unchanged").c_str(), after.state_reference_equals(before) ? 1 : 0);
            emit((p + ".archive_leaf").c_str(), hex(chain.get_leaf_value(MerkleTreeId::ARCHIVE, block)));
            emit_u64((p + ".archive_sibling_path_levels").c_str(),
                     chain.get_sibling_path(MerkleTreeId::ARCHIVE, block).size());
        }

        // The state-reference refusal, and then the same call with the current reference accepted,
        // so the refusal is about the argument rather than about update_archive refusing everything.
        DB guard;
        const Roots stale = guard.get_tree_roots();
        const FF more_note_hashes[] = { FF(0x99) };
        guard.append_leaves(MerkleTreeId::NOTE_HASH_TREE, more_note_hashes);
        emit_call("update_archive.stale_state_reference", [&] {
            guard.update_archive(stale, FF(0x1234));
            return std::string("accepted");
        });
        emit_u64("update_archive.archive_size_after_refusal",
                 guard.get_tree_roots().archive_tree.next_available_leaf_index);
        emit_call("update_archive.current_state_reference", [&] {
            guard.update_archive(guard.get_tree_roots(), FF(0x1234));
            return std::string("accepted");
        });
        emit_u64("update_archive.archive_size_after_acceptance",
                 guard.get_tree_roots().archive_tree.next_available_leaf_index);

        // ---- section 7: the archive inside the checkpoint stack ---------------------------------
        DB cp;
        const Roots at_genesis = cp.get_tree_roots();
        cp.create_checkpoint();
        emit_u64("checkpoint.id_inside", cp.get_checkpoint_id());
        const FF inside_note_hashes[] = { FF(0x77) };
        cp.append_leaves(MerkleTreeId::NOTE_HASH_TREE, inside_note_hashes);
        cp.update_archive(cp.get_tree_roots(), FF(0xAAAA));
        const Roots inside = cp.get_tree_roots();
        emit_roots("checkpoint.inside", inside);
        emit_u64("checkpoint.archive_moved_inside", inside.archive_tree.root == at_genesis.archive_tree.root ? 0 : 1);
        cp.revert_checkpoint();
        emit_u64("checkpoint.id_after_revert", cp.get_checkpoint_id());
        emit_roots("checkpoint.after_revert", cp.get_tree_roots());
        emit_u64("checkpoint.everything_restored", cp.get_tree_roots() == at_genesis ? 1 : 0);

        cp.create_checkpoint();
        cp.update_archive(cp.get_tree_roots(), FF(0xBBBB));
        const Roots committed = cp.get_tree_roots();
        cp.commit_checkpoint();
        emit_u64("checkpoint.id_after_commit", cp.get_checkpoint_id());
        emit_u64("checkpoint.commit_preserved", cp.get_tree_roots() == committed ? 1 : 0);
        emit_roots("checkpoint.after_commit", cp.get_tree_roots());
    }
}

} // namespace

int main()
{
    // ---- section 1: what the type system says this tree has ----------------------------------
    emit_u64("archive_in_tree_roots", TreeRootsHasArchive<TreeRoots> ? 1 : 0);
    emit_u64("state_reference_equals_present", TreeRootsHasStateReferenceEquals<TreeRoots> ? 1 : 0);
    emit_u64("update_archive_present", DbHasUpdateArchive<MemoryMerkleDB> ? 1 : 0);
    emit_u64("compute_initial_block_header_hash_present", DbHasInitialBlockHeaderHash<MemoryMerkleDB> ? 1 : 0);

    // ---- section 2: the constants, as the compiler sees them ---------------------------------
    emit_u64("default_nullifier_prefill", MemoryMerkleDB::DEFAULT_NULLIFIER_TREE_PREFILL);
    emit_u64("default_public_data_prefill", MemoryMerkleDB::DEFAULT_PUBLIC_DATA_TREE_PREFILL);
    emit_u64("max_nullifiers_per_tx", MAX_NULLIFIERS_PER_TX);
    emit_u64("max_total_public_data_update_requests_per_tx", MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX);
    emit_u64("archive_height", ARCHIVE_HEIGHT);
    emit("genesis_archive_root_constant", std::string(GENESIS_ARCHIVE_ROOT));
    emit("genesis_block_header_hash_constant", std::string(GENESIS_BLOCK_HEADER_HASH));

    // ---- section 3: the WorldStateRevision sentinel, executed --------------------------------
    // The vocabulary lives in this component. Its documented contract is that block 0 is a valid
    // historical block and LATEST is a distinct sentinel, so these lines are the property the
    // comment claims, run rather than read.
    emit_u64("revision_latest", WorldStateRevision::LATEST);
    emit_u64("revision_default_is_historical", WorldStateRevision{}.is_historical() ? 1 : 0);
    emit_u64("revision_block0_is_historical", WorldStateRevision{ .blockNumber = 0 }.is_historical() ? 1 : 0);
    emit_u64("revision_committed_includes_uncommitted", WorldStateRevision::committed().includeUncommitted ? 1 : 0);
    emit_u64("revision_uncommitted_includes_uncommitted", WorldStateRevision::uncommitted().includeUncommitted ? 1 : 0);

    // ---- section 4: genesis, as this tree's implementation produces it ------------------------
    MemoryMerkleDB db;
    emit_roots("genesis", db.get_tree_roots());
    emit_u64("genesis_checkpoint_id", db.get_checkpoint_id());

    // ---- section 5: every ARCHIVE-taking entry point, called ---------------------------------
    // Called on a FRESH database, so what is reported is what a caller gets and not what a previous
    // line left behind.
    {
        MemoryMerkleDB probe;
        emit_call("archive.get_sibling_path", [&] {
            auto path = probe.get_sibling_path(MerkleTreeId::ARCHIVE, 0);
            return std::to_string(path.size());
        });
        emit_call("archive.get_leaf_value", [&] { return hex(probe.get_leaf_value(MerkleTreeId::ARCHIVE, 0)); });
        emit_call("archive.append_leaves", [&] {
            const FF leaves[] = { FF(1) };
            probe.append_leaves(MerkleTreeId::ARCHIVE, leaves);
            return std::string("appended");
        });
        emit_call("archive.pad_tree", [&] {
            probe.pad_tree(MerkleTreeId::ARCHIVE, 1);
            return std::string("padded");
        });
        emit_call("archive.get_low_indexed_leaf", [&] {
            auto r = probe.get_low_indexed_leaf(MerkleTreeId::ARCHIVE, FF(1));
            return std::to_string(r.index);
        });
    }

    // ---- sections 6 and 7 ---------------------------------------------------------------------
    emit_block_sequence<MemoryMerkleDB>();

    printf("probe_complete=1\n");
    return 0;
}
