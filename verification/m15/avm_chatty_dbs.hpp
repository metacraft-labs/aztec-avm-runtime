#pragma once

// The CHATTY arm of M15's boundary-shape decision: the two AVM host interfaces implemented over
// wasm IMPORTS, so every read the AVM makes leaves the module.
//
// WHY THIS SHAPE IS UPSTREAM'S AND NOT OURS. Aztec already ships a chatty
// `LowLevelMerkleDBInterface`: `WsdbIpcMerkleDB`, in `barretenberg/vm2_wsdb/wsdb_ipc_merkle_db.hpp`
// — a barretenberg subdirectory PARALLEL to `vm2/`, which is why the campaign's earlier
// enumerations kept missing that whole family. It translates each of the fourteen interface calls
// into a WSDB IPC command over a Unix domain socket, holding a `WsdbIpcClient&` and a
// `WorldStateRevision`. It cannot reach `wasm32-wasip1` — it links `wsdb` and `ipc_runtime` — but
// its SHAPE is exactly the shape this file needs, and copying the shape of a maintained upstream
// class is not the same thing as inventing one. The differences are named where they occur:
// there is no revision (the AVM's interface has no parameter to carry one, which is M14's
// "block-pinned reads: not needed"), and the transport is a wasm import rather than a socket.
//
// THE TRANSPORT, in one function, because a foreign-call surface should be one thing a reader can
// audit rather than twenty-two:
//
//     int32_t avm_host_db_call(uint32_t op, uint32_t req_ptr, uint32_t req_len,
//                              uint32_t reply_ptr, uint32_t reply_cap);
//
//   * `op` is one of the `ChattyOp` values below — the eight `ContractDBInterface` methods and the
//     fourteen `LowLevelMerkleDBInterface` ones, numbered in the order they are declared in
//     `vm2/simulation/interfaces/db.hpp`, so the numbering is derived from the interface and not
//     from the order somebody happened to write them here.
//   * the request at `[req_ptr, req_ptr + req_len)` is msgpack of UPSTREAM'S OWN schemas: the
//     argument type for a one-argument method, a msgpack array of them (msgpack-c's `std::tuple`
//     adaptor) for more than one, and nothing at all for none. Identical to what the resident
//     arm's exports already accept, so the two arms marshal the same bytes and a difference
//     between them cannot be a difference of encoding.
//   * the return is the number of bytes the reply NEEDS. If it is at most `reply_cap` the reply
//     has been written; otherwise nothing has, and the module grows its buffer and calls again.
//     A negative return is a host-side failure and is turned into a C++ exception here, which
//     the AVM then treats exactly as it treats any other DB failure.
//
// A RETURN-BY-CAPACITY PROTOCOL RATHER THAN A HOST ALLOCATION, deliberately. The host cannot
// allocate inside the module without calling back into it, and a callback that runs while the
// module is inside a call is the one shape that can corrupt this module's own allocator state.
// Growing on the host's word costs at most one extra crossing per oversized reply, and how often
// that happens is REPORTED (`avm_chatty_stats`) rather than assumed to be never.
//
// THE COUNTERS ARE THE POINT. This arm exists to be measured against the resident one, so it
// counts every crossing, every request byte and every reply byte, by op. A crossing count that
// came from reasoning about the AVM's source would be the estimate this milestone was told not
// to make.

#include <cstdint>
#include <string>
#include <vector>

#include "barretenberg/serialize/msgpack.hpp"
#include "barretenberg/vm2/simulation/interfaces/db.hpp"

namespace bb::avm2::reactor {

// The operation ids, in interface-declaration order. `ContractDBInterface` first because
// `AvmSimAPI::simulate` takes it first.
enum class ChattyOp : uint32_t {
    // ContractDBInterface, db.hpp:20..30
    ContractGetInstance = 0,
    ContractGetClass = 1,
    ContractGetBytecodeCommitment = 2,
    ContractGetDebugFunctionName = 3,
    ContractAddContracts = 4,
    ContractCreateCheckpoint = 5,
    ContractCommitCheckpoint = 6,
    ContractRevertCheckpoint = 7,
    // LowLevelMerkleDBInterface, db.hpp:49..73
    MerkleGetTreeRoots = 8,
    MerkleGetSiblingPath = 9,
    MerkleGetLowIndexedLeaf = 10,
    MerkleGetLeafValue = 11,
    MerkleGetLeafPreimagePublicData = 12,
    MerkleGetLeafPreimageNullifier = 13,
    MerkleInsertIndexedPublicData = 14,
    MerkleInsertIndexedNullifier = 15,
    MerkleAppendLeaves = 16,
    MerklePadTree = 17,
    MerkleCreateCheckpoint = 18,
    MerkleCommitCheckpoint = 19,
    MerkleRevertCheckpoint = 20,
    MerkleGetCheckpointId = 21,
};

constexpr uint32_t CHATTY_OP_COUNT = 22;
constexpr uint32_t CHATTY_CONTRACT_OP_COUNT = 8;
constexpr uint32_t CHATTY_MERKLE_OP_COUNT = 14;

// What the last chatty simulation cost at the boundary. Per op, so a shape rejected on its
// crossing count can be rejected on WHICH crossings rather than on a total.
//
// `std::vector` rather than `std::array` for the three per-op tallies: msgpack-c has adaptors for
// both, but a vector is what every other schema this module crosses uses, and one container shape
// on the wire is one fewer thing for a host decoder to special-case. They are sized once, in
// `reset()`, and their length is itself the assertion that the op table did not change under a
// host that was written against it.
struct ChattyStats {
    std::vector<uint64_t> calls;
    std::vector<uint64_t> requestBytes;
    std::vector<uint64_t> replyBytes;
    uint64_t totalCalls = 0;
    uint64_t totalRequestBytes = 0;
    uint64_t totalReplyBytes = 0;
    // How often a reply did not fit the buffer and the call had to be repeated. An extra crossing
    // that nobody counted would make the chatty arm look cheaper than it is.
    uint64_t retries = 0;
    // The number of ops this module knows about, so a host cannot silently decode a shorter table
    // as a complete one.
    uint64_t opCount = CHATTY_OP_COUNT;

    void reset()
    {
        calls.assign(CHATTY_OP_COUNT, 0);
        requestBytes.assign(CHATTY_OP_COUNT, 0);
        replyBytes.assign(CHATTY_OP_COUNT, 0);
        totalCalls = 0;
        totalRequestBytes = 0;
        totalReplyBytes = 0;
        retries = 0;
        opCount = CHATTY_OP_COUNT;
    }

    SERIALIZATION_FIELDS(calls, requestBytes, replyBytes, totalCalls, totalRequestBytes, totalReplyBytes, retries, opCount);
};

ChattyStats& chatty_stats();

// The null crossing, in the direction a chatty DB actually uses: the module calling the host.
// Declared here so the reactor's export can reach the import without a second `extern "C"`
// declaration of it, which is how two declarations of one symbol drift apart.
void chatty_host_probe(uint32_t token);

// The two adapters. `final` for the same reason upstream marks its own: nothing derives from them
// and a devirtualised call is one less thing between the measurement and the boundary.
class ImportedContractDB final : public simulation::ContractDBInterface {
  public:
    std::optional<ContractInstance> get_contract_instance(const AztecAddress& address) const override;
    std::optional<ContractClass> get_contract_class(const ContractClassId& class_id) const override;
    std::optional<FF> get_bytecode_commitment(const ContractClassId& class_id) const override;
    std::optional<std::string> get_debug_function_name(const AztecAddress& address,
                                                       const FunctionSelector& selector) const override;
    void add_contracts(const ContractDeploymentData& contract_deployment_data) override;
    void create_checkpoint() override;
    void commit_checkpoint() override;
    void revert_checkpoint() override;
};

class ImportedMerkleDB final : public simulation::LowLevelMerkleDBInterface {
  public:
    TreeSnapshots get_tree_roots() const override;
    simulation::SiblingPath get_sibling_path(simulation::MerkleTreeId tree_id,
                                             simulation::index_t leaf_index) const override;
    simulation::GetLowIndexedLeafResponse get_low_indexed_leaf(simulation::MerkleTreeId tree_id,
                                                               const FF& value) const override;
    FF get_leaf_value(simulation::MerkleTreeId tree_id, simulation::index_t leaf_index) const override;
    simulation::IndexedLeaf<simulation::PublicDataLeafValue> get_leaf_preimage_public_data_tree(
        simulation::index_t leaf_index) const override;
    simulation::IndexedLeaf<simulation::NullifierLeafValue> get_leaf_preimage_nullifier_tree(
        simulation::index_t leaf_index) const override;
    simulation::SequentialInsertionResult<simulation::PublicDataLeafValue> insert_indexed_leaves_public_data_tree(
        const simulation::PublicDataLeafValue& leaf_value) override;
    simulation::SequentialInsertionResult<simulation::NullifierLeafValue> insert_indexed_leaves_nullifier_tree(
        const simulation::NullifierLeafValue& leaf_value) override;
    void append_leaves(simulation::MerkleTreeId tree_id, std::span<const FF> leaves) override;
    void pad_tree(simulation::MerkleTreeId tree_id, size_t num_leaves) override;
    void create_checkpoint() override;
    void commit_checkpoint() override;
    void revert_checkpoint() override;
    uint32_t get_checkpoint_id() const override;
};

} // namespace bb::avm2::reactor
