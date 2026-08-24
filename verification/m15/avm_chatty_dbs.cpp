// The chatty arm's transport and its twenty-two marshalled methods. See avm_chatty_dbs.hpp for
// why the shape is `WsdbIpcMerkleDB`'s and what the one imported function's contract is.
//
// EVERY METHOD IS THE SAME FOUR LINES, and that is on purpose: pack the arguments with upstream's
// own schema, cross, unpack the declared return type. A per-method hand-written encoding would be
// twenty-two places for the two arms to disagree about a field, and the identity check between the
// arms would then be checking this file rather than the boundary.
//
// `void` returns still cross and still cost — a `create_checkpoint` that the host must apply is a
// round trip whether or not it carries a value back — and they are counted like everything else.

#include "barretenberg/vm2/reactor/avm_chatty_dbs.hpp"

#include <cstring>
#include <span>
#include <stdexcept>
#include <tuple>
#include <type_traits>

#include "barretenberg/serialize/msgpack.hpp"
#include "barretenberg/serialize/msgpack_impl.hpp"

namespace bb::avm2::reactor {

namespace {

// The one import. Declared `extern "C"` and defined nowhere: wasm-ld resolves it to an import from
// the `env` module, which is where the host supplies it.
//
// Returns the number of bytes the reply needs. <= reply_cap means it has been written. A negative
// value is a host failure.
extern "C" int32_t avm_host_db_call(uint32_t op, uint32_t req_ptr, uint32_t req_len, uint32_t reply_ptr,
                                    uint32_t reply_cap);

// A crossing that carries nothing, so the cost of the crossing itself can be separated from the
// cost of what it carries. M12 measured 600-650 ns per crossing in the OTHER direction (host
// calling an export); this is the direction a chatty DB actually uses and they are not the same
// path through the engine.
extern "C" void avm_host_probe(uint32_t token);

ChattyStats g_stats;

// Reused across calls: a fresh vector per DB read would make the measurement an allocator
// benchmark. Grows on demand and never shrinks, which is what a long-lived host connection does.
std::vector<uint8_t> g_reply_buffer(4096);

uint32_t as_u32(const void* p)
{
    return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(p));
}

// The crossing. `request` may be empty, in which case a null-length request is sent rather than an
// empty msgpack value: a method with no arguments has nothing to encode and encoding `nil` for it
// would put a byte on the wire that no schema describes.
std::span<const uint8_t> cross(ChattyOp op, const msgpack::sbuffer& request)
{
    const auto idx = static_cast<uint32_t>(op);
    const auto req_len = static_cast<uint32_t>(request.size());
    ChattyStats& st = chatty_stats();

    auto count_one = [&](void) {
        st.calls[idx]++;
        st.totalCalls++;
        st.requestBytes[idx] += req_len;
        st.totalRequestBytes += req_len;
    };

    int32_t needed = avm_host_db_call(idx,
                                      as_u32(request.data()),
                                      req_len,
                                      as_u32(g_reply_buffer.data()),
                                      static_cast<uint32_t>(g_reply_buffer.size()));
    count_one();

    if (needed < 0) {
        throw std::runtime_error("chatty host DB call failed for op " + std::to_string(idx));
    }
    if (static_cast<size_t>(needed) > g_reply_buffer.size()) {
        // One retry, with a buffer that is big enough. Counted as a SECOND crossing, because an
        // uncounted extra crossing is exactly the kind of thing that makes a shape look cheaper
        // than it is.
        g_reply_buffer.resize(static_cast<size_t>(needed));
        const int32_t again = avm_host_db_call(idx,
                                               as_u32(request.data()),
                                               req_len,
                                               as_u32(g_reply_buffer.data()),
                                               static_cast<uint32_t>(g_reply_buffer.size()));
        st.retries++;
        count_one();
        if (again < 0 || static_cast<size_t>(again) > g_reply_buffer.size()) {
            throw std::runtime_error("chatty host DB call did not fit its own stated size for op " +
                                     std::to_string(idx));
        }
        needed = again;
    }
    st.replyBytes[idx] += static_cast<uint64_t>(needed);
    st.totalReplyBytes += static_cast<uint64_t>(needed);
    return std::span<const uint8_t>(g_reply_buffer.data(), static_cast<size_t>(needed));
}

template <typename R> R unpack_reply(std::span<const uint8_t> bytes, ChattyOp op)
{
    if (bytes.empty()) {
        throw std::runtime_error("chatty host DB call returned no value for op " +
                                 std::to_string(static_cast<uint32_t>(op)));
    }
    R out;
    msgpack::unpack(reinterpret_cast<const char*>(bytes.data()), bytes.size()).get().convert(out);
    return out;
}

// call<R>(op, args...) — pack, cross, unpack. The `void` specialisation crosses and discards.
template <typename R, typename... Args> R call(ChattyOp op, const Args&... args)
{
    msgpack::sbuffer buf;
    if constexpr (sizeof...(Args) == 1) {
        msgpack::pack(buf, std::get<0>(std::tie(args...)));
    } else if constexpr (sizeof...(Args) > 1) {
        msgpack::pack(buf, std::make_tuple(args...));
    }
    const auto reply = cross(op, buf);
    if constexpr (std::is_void_v<R>) {
        (void)reply;
    } else {
        return unpack_reply<R>(reply, op);
    }
}

} // namespace

ChattyStats& chatty_stats()
{
    if (g_stats.calls.size() != CHATTY_OP_COUNT) {
        // First use. Sized here rather than in a static initialiser, because a static vector
        // initialised before `_initialize` runs is a shape wasi-libc does not promise anything
        // about and this module has no other reason to find out.
        g_stats.reset();
    }
    return g_stats;
}

void chatty_host_probe(uint32_t token)
{
    avm_host_probe(token);
}

// ---------------------------------------------------------------------------
// ContractDBInterface — the eight, in declaration order.
// ---------------------------------------------------------------------------

std::optional<ContractInstance> ImportedContractDB::get_contract_instance(const AztecAddress& address) const
{
    return call<std::optional<ContractInstance>>(ChattyOp::ContractGetInstance, address);
}

std::optional<ContractClass> ImportedContractDB::get_contract_class(const ContractClassId& class_id) const
{
    return call<std::optional<ContractClass>>(ChattyOp::ContractGetClass, class_id);
}

std::optional<FF> ImportedContractDB::get_bytecode_commitment(const ContractClassId& class_id) const
{
    return call<std::optional<FF>>(ChattyOp::ContractGetBytecodeCommitment, class_id);
}

std::optional<std::string> ImportedContractDB::get_debug_function_name(const AztecAddress& address,
                                                                       const FunctionSelector& selector) const
{
    return call<std::optional<std::string>>(ChattyOp::ContractGetDebugFunctionName, address, selector);
}

void ImportedContractDB::add_contracts(const ContractDeploymentData& contract_deployment_data)
{
    call<void>(ChattyOp::ContractAddContracts, contract_deployment_data);
}

void ImportedContractDB::create_checkpoint()
{
    call<void>(ChattyOp::ContractCreateCheckpoint);
}

void ImportedContractDB::commit_checkpoint()
{
    call<void>(ChattyOp::ContractCommitCheckpoint);
}

void ImportedContractDB::revert_checkpoint()
{
    call<void>(ChattyOp::ContractRevertCheckpoint);
}

// ---------------------------------------------------------------------------
// LowLevelMerkleDBInterface — the fourteen, in declaration order.
// ---------------------------------------------------------------------------

TreeSnapshots ImportedMerkleDB::get_tree_roots() const
{
    return call<TreeSnapshots>(ChattyOp::MerkleGetTreeRoots);
}

simulation::SiblingPath ImportedMerkleDB::get_sibling_path(simulation::MerkleTreeId tree_id,
                                                           simulation::index_t leaf_index) const
{
    return call<simulation::SiblingPath>(
        ChattyOp::MerkleGetSiblingPath, tree_id, static_cast<uint64_t>(leaf_index));
}

simulation::GetLowIndexedLeafResponse ImportedMerkleDB::get_low_indexed_leaf(simulation::MerkleTreeId tree_id,
                                                                             const FF& value) const
{
    return call<simulation::GetLowIndexedLeafResponse>(ChattyOp::MerkleGetLowIndexedLeaf, tree_id, value);
}

FF ImportedMerkleDB::get_leaf_value(simulation::MerkleTreeId tree_id, simulation::index_t leaf_index) const
{
    return call<FF>(ChattyOp::MerkleGetLeafValue, tree_id, static_cast<uint64_t>(leaf_index));
}

simulation::IndexedLeaf<simulation::PublicDataLeafValue> ImportedMerkleDB::get_leaf_preimage_public_data_tree(
    simulation::index_t leaf_index) const
{
    return call<simulation::IndexedLeaf<simulation::PublicDataLeafValue>>(
        ChattyOp::MerkleGetLeafPreimagePublicData, static_cast<uint64_t>(leaf_index));
}

simulation::IndexedLeaf<simulation::NullifierLeafValue> ImportedMerkleDB::get_leaf_preimage_nullifier_tree(
    simulation::index_t leaf_index) const
{
    return call<simulation::IndexedLeaf<simulation::NullifierLeafValue>>(
        ChattyOp::MerkleGetLeafPreimageNullifier, static_cast<uint64_t>(leaf_index));
}

simulation::SequentialInsertionResult<simulation::PublicDataLeafValue>
ImportedMerkleDB::insert_indexed_leaves_public_data_tree(const simulation::PublicDataLeafValue& leaf_value)
{
    return call<simulation::SequentialInsertionResult<simulation::PublicDataLeafValue>>(
        ChattyOp::MerkleInsertIndexedPublicData, leaf_value);
}

simulation::SequentialInsertionResult<simulation::NullifierLeafValue>
ImportedMerkleDB::insert_indexed_leaves_nullifier_tree(const simulation::NullifierLeafValue& leaf_value)
{
    return call<simulation::SequentialInsertionResult<simulation::NullifierLeafValue>>(
        ChattyOp::MerkleInsertIndexedNullifier, leaf_value);
}

void ImportedMerkleDB::append_leaves(simulation::MerkleTreeId tree_id, std::span<const FF> leaves)
{
    // The span is materialised as a vector because a span has no msgpack schema and the wire has to
    // carry the values rather than a pointer into this module's memory.
    const std::vector<FF> values(leaves.begin(), leaves.end());
    call<void>(ChattyOp::MerkleAppendLeaves, tree_id, values);
}

void ImportedMerkleDB::pad_tree(simulation::MerkleTreeId tree_id, size_t num_leaves)
{
    call<void>(ChattyOp::MerklePadTree, tree_id, static_cast<uint64_t>(num_leaves));
}

void ImportedMerkleDB::create_checkpoint()
{
    call<void>(ChattyOp::MerkleCreateCheckpoint);
}

void ImportedMerkleDB::commit_checkpoint()
{
    call<void>(ChattyOp::MerkleCommitCheckpoint);
}

void ImportedMerkleDB::revert_checkpoint()
{
    call<void>(ChattyOp::MerkleRevertCheckpoint);
}

uint32_t ImportedMerkleDB::get_checkpoint_id() const
{
    return call<uint32_t>(ChattyOp::MerkleGetCheckpointId);
}

} // namespace bb::avm2::reactor
