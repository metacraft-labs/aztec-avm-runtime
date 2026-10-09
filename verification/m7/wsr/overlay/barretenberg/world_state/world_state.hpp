// M7 overlay for upstream's `world_state/memory_merkle_db.test.cpp` -- NOT an upstream file.
//
// That test is upstream's canonical-fidelity gate for `world_state_reference::MemoryMerkleDB`: seven
// `MemoryMerkleDBEquivalenceTest` cases drive an LMDB-backed `world_state::WorldState` (`ws`) and a
// `MemoryMerkleDB` (`mem`) through one sequence and compare them after every step. `world_state` is
// LMDB-backed and is not part of a wasm32 build, so the test cannot be compiled for wasm as written.
//
// This header SPLITS each case into its two halves without changing a line of the test. The test is
// compiled byte-for-byte from the tree with this directory first on the quote-include path
// (`-iquote`), so its `#include "barretenberg/world_state/world_state.hpp"` lands here, and the last
// line below renames the test's `WorldState` to `TranscriptWorldState`. Every call the test makes on
// `ws` goes through that class, in one of two modes:
//
//   WSR_TRANSCRIPT_RECORD  (native only) the real header is pulled in with `#include_next`, every
//                          call is FORWARDED to a real, LMDB-backed WorldState, and the call's method,
//                          its arguments and its answer are appended to the transcript ($WSR_TRANSCRIPT).
//                          The test's own comparisons run against the real answers, so a recording
//                          run is upstream's gate passing natively.
//
//   WSR_TRANSCRIPT_REPLAY  (wasm, and natively as the control) no WorldState exists. Each call must
//                          be the next one recorded for this test, with the SAME method and
//                          byte-identical arguments, and it returns the RECORDED answer. The test's
//                          own comparisons therefore run the wasm-built MemoryMerkleDB against what
//                          the real LMDB WorldState answered.
//
// A replay fails, naming the test and the record, when the sequence diverges (wrong method, or no
// record left), when an argument differs from what was recorded (`mem` and `ws` are fed the same
// values by the test, so this is the wasm side's INPUT being checked), or when a test ends with
// records unconsumed. Arguments and answers are msgpack (upstream's own SERIALIZATION_FIELDS) as hex.
//
// Transcript line:  <Suite.Test> TAB <seq> TAB <method> TAB <args hex> TAB <answer hex>
#pragma once

#if defined(WSR_TRANSCRIPT_RECORD) == defined(WSR_TRANSCRIPT_REPLAY)
#error "define exactly one of WSR_TRANSCRIPT_RECORD and WSR_TRANSCRIPT_REPLAY"
#endif

#ifdef WSR_TRANSCRIPT_RECORD
#include_next "barretenberg/world_state/world_state.hpp"
#endif

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

#include <gtest/gtest.h>

#include "barretenberg/crypto/merkle_tree/indexed_tree/indexed_leaf.hpp"
#include "barretenberg/crypto/merkle_tree/response.hpp"
#include "barretenberg/ecc/curves/bn254/fr.hpp"
#include "barretenberg/serialize/msgpack.hpp"
#include "barretenberg/serialize/msgpack_impl.hpp"
#include "barretenberg/world_state_reference/merkle_tree_id.hpp"

namespace bb::world_state {

#ifdef WSR_TRANSCRIPT_REPLAY
// world_state/types.hpp's value; it is an ARGUMENT of every checkpoint call, so a replay against a
// transcript recorded with a different value fails on the argument check.
inline constexpr uint64_t CANONICAL_FORK_ID = 0;
#endif

namespace wsr_transcript {

inline std::string to_hex(const char* data, size_t size)
{
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(size * 2);
    for (size_t i = 0; i < size; ++i) {
        auto c = static_cast<unsigned char>(data[i]);
        out += digits[c >> 4];
        out += digits[c & 15];
    }
    return out;
}

template <typename T> std::string pack(const T& value)
{
    msgpack::sbuffer buffer;
    msgpack::pack(buffer, value);
    return to_hex(buffer.data(), buffer.size());
}

template <typename T> T unpack(const std::string& hex)
{
    if (hex.size() % 2 != 0) {
        throw std::runtime_error("wsr transcript: odd-length hex field");
    }
    std::vector<char> bytes(hex.size() / 2);
    for (size_t i = 0; i < bytes.size(); ++i) {
        bytes[i] = static_cast<char>(std::stoi(hex.substr(2 * i, 2), nullptr, 16));
    }
    msgpack::object_handle handle = msgpack::unpack(bytes.data(), bytes.size());
    T value;
    handle.get().convert(value);
    return value;
}

// How an answer is written and read back. Upstream's own msgpack fields wherever a type has them.
template <typename T> struct Codec {
    static std::string enc(const T& v) { return pack(v); }
    static T dec(const std::string& h) { return unpack<T>(h); }
};
template <> struct Codec<crypto::merkle_tree::TreeMetaResponse> {
    static std::string enc(const crypto::merkle_tree::TreeMetaResponse& v) { return pack(v.meta); }
    static crypto::merkle_tree::TreeMetaResponse dec(const std::string& h)
    {
        crypto::merkle_tree::TreeMetaResponse r;
        r.meta = unpack<crypto::merkle_tree::TreeMeta>(h);
        return r;
    }
};
template <typename T> struct Codec<std::optional<T>> {
    static std::string enc(const std::optional<T>& v) { return pack(std::make_pair(v.has_value(), v.value_or(T{}))); }
    static std::optional<T> dec(const std::string& h)
    {
        auto p = unpack<std::pair<bool, T>>(h);
        return p.first ? std::optional<T>(p.second) : std::nullopt;
    }
};

template <typename V> std::vector<std::pair<int, V>> sorted(const std::unordered_map<MerkleTreeId, V>& m)
{
    std::vector<std::pair<int, V>> out;
    for (const auto& [k, v] : m) {
        out.emplace_back(static_cast<int>(k), v);
    }
    std::sort(out.begin(), out.end());
    return out;
}

inline std::string current_test()
{
    const auto* info = ::testing::UnitTest::GetInstance()->current_test_info();
    if (info == nullptr) {
        throw std::runtime_error("wsr transcript: used outside a running test");
    }
    return std::string(info->test_suite_name()) + "." + info->name();
}

inline std::string transcript_path()
{
    const char* p = std::getenv("WSR_TRANSCRIPT");
    if (p == nullptr || *p == '\0') {
        throw std::runtime_error("wsr transcript: WSR_TRANSCRIPT is not set");
    }
    return p;
}

struct Record {
    std::string method;
    std::string args;
    std::string answer;
};

class Session {
  public:
    Session()
        : test_(current_test())
    {
#ifdef WSR_TRANSCRIPT_REPLAY
        std::ifstream in(transcript_path());
        if (!in) {
            ADD_FAILURE() << "wsr replay: cannot open transcript " << transcript_path() << ": "
                          << std::strerror(errno);
            return;
        }
        std::string line;
        while (std::getline(in, line)) {
            std::vector<std::string> f;
            std::stringstream ss(line);
            std::string field;
            while (std::getline(ss, field, '\t')) {
                f.push_back(field);
            }
            if (f.size() != 5) {
                ADD_FAILURE() << "wsr replay: malformed transcript line (" << f.size() << " fields)";
                continue;
            }
            if (f[0] != test_) {
                continue;
            }
            if (std::stoul(f[1]) != records_.size()) {
                ADD_FAILURE() << "wsr replay: " << test_ << " record " << f[1] << " is out of order";
            }
            records_.push_back(Record{ f[2], f[3], f[4] });
        }
        if (records_.empty()) {
            ADD_FAILURE() << "wsr replay: the transcript holds no records for " << test_;
        }
#endif
    }

    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    ~Session()
    {
#ifdef WSR_TRANSCRIPT_RECORD
        std::cout << "[wsr-record] " << test_ << " records=" << cursor_ << std::endl;
#else
        if (cursor_ != records_.size()) {
            ADD_FAILURE() << "wsr replay: " << test_ << " consumed " << cursor_ << " of " << records_.size()
                          << " recorded calls";
        }
        std::cout << "[wsr-replay] " << test_ << " consumed=" << cursor_ << " recorded=" << records_.size()
                  << " args_mismatches=" << args_mismatches_ << std::endl;
#endif
    }

#ifdef WSR_TRANSCRIPT_RECORD
    void write(const char* method, const std::string& args, const std::string& answer)
    {
        std::ofstream out(transcript_path(), std::ios::app);
        out << test_ << '\t' << cursor_ << '\t' << method << '\t' << args << '\t' << answer << '\n';
        if (!out) {
            throw std::runtime_error("wsr record: could not append to " + transcript_path());
        }
        ++cursor_;
    }
#else
    const std::string& next(const char* method, const std::string& args)
    {
        if (cursor_ >= records_.size()) {
            ADD_FAILURE() << "wsr replay: " << test_ << " called " << method << " after its " << records_.size()
                          << " recorded calls";
            throw std::runtime_error("wsr replay: transcript exhausted");
        }
        const Record& r = records_[cursor_];
        if (r.method != method) {
            ADD_FAILURE() << "wsr replay: " << test_ << " record " << cursor_ << " is " << r.method
                          << " but the test called " << method;
            throw std::runtime_error("wsr replay: call sequence diverged");
        }
        if (r.args != args) {
            ++args_mismatches_;
            ADD_FAILURE() << "wsr replay: " << test_ << " record " << cursor_ << " (" << method
                          << "): the arguments differ from the recorded ones";
        }
        ++cursor_;
        return r.answer;
    }
#endif

  private:
    std::string test_;
    size_t cursor_ = 0;
#ifdef WSR_TRANSCRIPT_REPLAY
    std::vector<Record> records_;
    size_t args_mismatches_ = 0;
#endif
};

} // namespace wsr_transcript

#ifdef WSR_TRANSCRIPT_RECORD
#define WSR_FORWARD(...) [&]() { return __VA_ARGS__; }
#else
#define WSR_FORWARD(...) nullptr
#endif

class TranscriptWorldState {
  public:
    TranscriptWorldState(uint64_t thread_pool_size,
                         [[maybe_unused]] const std::string& data_dir,
                         uint64_t map_size,
                         const std::unordered_map<MerkleTreeId, uint32_t>& tree_heights,
                         const std::unordered_map<MerkleTreeId, index_t>& tree_prefill,
                         uint32_t initial_header_generator_point)
    {
#ifdef WSR_TRANSCRIPT_RECORD
        real_ = std::make_unique<WorldState>(
            thread_pool_size, data_dir, map_size, tree_heights, tree_prefill, initial_header_generator_point);
#endif
        // data_dir is a random temporary path and is deliberately not part of the record.
        call_void("construct",
                  std::make_tuple(thread_pool_size,
                                  map_size,
                                  wsr_transcript::sorted(tree_heights),
                                  wsr_transcript::sorted(tree_prefill),
                                  initial_header_generator_point),
                  WSR_FORWARD(0));
    }

    crypto::merkle_tree::TreeMetaResponse get_tree_info(const WorldStateRevision& revision, MerkleTreeId tree_id) const
    {
        return call<crypto::merkle_tree::TreeMetaResponse>("get_tree_info",
                                                           std::make_tuple(revision, static_cast<int>(tree_id)),
                                                           WSR_FORWARD(real_->get_tree_info(revision, tree_id)));
    }

    crypto::merkle_tree::fr_sibling_path get_sibling_path(const WorldStateRevision& revision,
                                                          MerkleTreeId tree_id,
                                                          index_t leaf_index) const
    {
        return call<crypto::merkle_tree::fr_sibling_path>(
            "get_sibling_path",
            std::make_tuple(revision, static_cast<int>(tree_id), leaf_index),
            WSR_FORWARD(real_->get_sibling_path(revision, tree_id, leaf_index)));
    }

    template <typename T>
    std::optional<T> get_leaf(const WorldStateRevision& revision, MerkleTreeId tree_id, index_t leaf_index) const
    {
        return call<std::optional<T>>("get_leaf",
                                      std::make_tuple(revision, static_cast<int>(tree_id), leaf_index),
                                      WSR_FORWARD(real_->template get_leaf<T>(revision, tree_id, leaf_index)));
    }

    crypto::merkle_tree::GetLowIndexedLeafResponse find_low_leaf_index(const WorldStateRevision& revision,
                                                                       MerkleTreeId tree_id,
                                                                       const bb::fr& leaf_key) const
    {
        return call<crypto::merkle_tree::GetLowIndexedLeafResponse>(
            "find_low_leaf_index",
            std::make_tuple(revision, static_cast<int>(tree_id), leaf_key),
            WSR_FORWARD(real_->find_low_leaf_index(revision, tree_id, leaf_key)));
    }

    template <typename T>
    std::optional<crypto::merkle_tree::IndexedLeaf<T>> get_indexed_leaf(const WorldStateRevision& revision,
                                                                        MerkleTreeId tree_id,
                                                                        index_t leaf_index) const
    {
        return call<std::optional<crypto::merkle_tree::IndexedLeaf<T>>>(
            "get_indexed_leaf",
            std::make_tuple(revision, static_cast<int>(tree_id), leaf_index),
            WSR_FORWARD(real_->template get_indexed_leaf<T>(revision, tree_id, leaf_index)));
    }

    template <typename T>
    void append_leaves(MerkleTreeId tree_id, const std::vector<T>& leaves, uint64_t fork_id = CANONICAL_FORK_ID)
    {
        call_void("append_leaves",
                  std::make_tuple(static_cast<int>(tree_id), leaves, fork_id),
                  WSR_FORWARD((real_->template append_leaves<T>(tree_id, leaves, fork_id), 0)));
    }

    template <typename T>
    crypto::merkle_tree::SequentialInsertionResult<T> insert_indexed_leaves(MerkleTreeId tree_id,
                                                                             const std::vector<T>& leaves,
                                                                             uint64_t fork_id = CANONICAL_FORK_ID)
    {
        return call<crypto::merkle_tree::SequentialInsertionResult<T>>(
            "insert_indexed_leaves",
            std::make_tuple(static_cast<int>(tree_id), leaves, fork_id),
            WSR_FORWARD(real_->template insert_indexed_leaves<T>(tree_id, leaves, fork_id)));
    }

    uint32_t checkpoint(const uint64_t& fork_id)
    {
        return call<uint32_t>("checkpoint", std::make_tuple(fork_id), WSR_FORWARD(real_->checkpoint(fork_id)));
    }

    void commit_checkpoint(const uint64_t& fork_id)
    {
        call_void(
            "commit_checkpoint", std::make_tuple(fork_id), WSR_FORWARD((real_->commit_checkpoint(fork_id), 0)));
    }

    void revert_checkpoint(const uint64_t& fork_id)
    {
        call_void(
            "revert_checkpoint", std::make_tuple(fork_id), WSR_FORWARD((real_->revert_checkpoint(fork_id), 0)));
    }

  private:
    template <typename R, typename Args, typename Forward>
    R call(const char* method, const Args& args, [[maybe_unused]] Forward&& forward) const
    {
#ifdef WSR_TRANSCRIPT_RECORD
        R answer = forward();
        session_.write(method, wsr_transcript::pack(args), wsr_transcript::Codec<R>::enc(answer));
        return answer;
#else
        return wsr_transcript::Codec<R>::dec(session_.next(method, wsr_transcript::pack(args)));
#endif
    }

    template <typename Args, typename Forward>
    void call_void(const char* method, const Args& args, [[maybe_unused]] Forward&& forward) const
    {
#ifdef WSR_TRANSCRIPT_RECORD
        forward();
        session_.write(method, wsr_transcript::pack(args), wsr_transcript::pack(0));
#else
        session_.next(method, wsr_transcript::pack(args));
#endif
    }

    mutable wsr_transcript::Session session_;
#ifdef WSR_TRANSCRIPT_RECORD
    std::unique_ptr<WorldState> real_;
#endif
};

#undef WSR_FORWARD

} // namespace bb::world_state

// The one rename that turns upstream's test into a recording or a replaying run. Every other token of
// the test is compiled as upstream wrote it.
#define WorldState TranscriptWorldState
