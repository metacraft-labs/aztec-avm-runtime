// SPIKE DRIVER — runs the REAL C++ AVM (vm2_sim) over hand-built AVM bytecode and prints a
// deterministic transcript of the result. Built for BOTH native and wasm32-wasi from identical
// sources, so the two transcripts can be diffed byte for byte.
//
// No mocks: PublicTxSimulationTester is upstream's own in-memory harness (in-process world state,
// in-memory contract DB) and drives AvmSimAPI exactly as the node's simulator does.

#include <cstdint>
#include <iomanip>
#include <chrono>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "barretenberg/vm2/common/avm_io.hpp"
#include "barretenberg/vm2/common/memory_types.hpp"
#include "barretenberg/vm2/common/opcodes.hpp"
#include "barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
#include "barretenberg/vm2/simulation/lib/serialization.hpp"
#include "barretenberg/vm2/testing/bytecode_builder.hpp"
#include "barretenberg/vm2/testing/instruction_builder.hpp"
#include "barretenberg/vm2/testing/public_tx_simulation_tester.hpp"

namespace {

using namespace bb::avm2;
using bb::avm2::simulation::Instruction;
using bb::avm2::testing::BytecodeBuilder;
using bb::avm2::testing::InstructionBuilder;
using bb::avm2::testing::PublicTxSimulationTester;
using bb::avm2::testing::TestEnqueuedCall;

Instruction set8(uint8_t dst, MemoryTag tag, uint8_t value)
{
    return InstructionBuilder(WireOpCode::SET_8).operand(dst).operand(tag).operand(value).build();
}
Instruction set32(uint16_t dst, MemoryTag tag, uint32_t value)
{
    return InstructionBuilder(WireOpCode::SET_32).operand(dst).operand(tag).operand(value).build();
}
Instruction setff(uint16_t dst, MemoryTag tag, const FF& value)
{
    return InstructionBuilder(WireOpCode::SET_FF).operand(dst).operand(tag).operand(value).build();
}
Instruction ret(uint16_t copy_size_offset, uint16_t return_offset)
{
    return InstructionBuilder(WireOpCode::RETURN).operand(copy_size_offset).operand(return_offset).build();
}

std::string hex(const FF& f)
{
    const auto v = static_cast<bb::numeric::uint256_t>(f);
    static const char* D = "0123456789abcdef";
    std::string out = "0x";
    for (int limb = 3; limb >= 0; --limb) {
        const uint64_t w = v.data[limb];
        for (int nib = 15; nib >= 0; --nib) {
            out += D[(w >> (nib * 4)) & 0xF];
        }
    }
    return out;
}

void dump(const std::string& label, const TxSimulationResult& r)
{
    std::cout << "== " << label << "\n";
    std::cout << "  revertCode      " << static_cast<int>(r.revert_code) << "\n";
    std::cout << "  totalGas        " << r.gas_used.total_gas.l2_gas << "/" << r.gas_used.total_gas.da_gas << "\n";
    std::cout << "  publicGas       " << r.gas_used.public_gas.l2_gas << "/" << r.gas_used.public_gas.da_gas << "\n";
    std::cout << "  billedGas       " << r.gas_used.billed_gas.l2_gas << "/" << r.gas_used.billed_gas.da_gas << "\n";
    std::cout << "  txFee           " << hex(r.public_tx_effect.transaction_fee) << "\n";
    std::cout << "  nullifiers      " << r.public_tx_effect.nullifiers.size() << "\n";
    for (const auto& n : r.public_tx_effect.nullifiers) {
        std::cout << "    " << hex(n) << "\n";
    }
    std::cout << "  noteHashes      " << r.public_tx_effect.note_hashes.size() << "\n";
    for (const auto& n : r.public_tx_effect.note_hashes) {
        std::cout << "    " << hex(n) << "\n";
    }
    std::cout << "  dataWrites      " << r.public_tx_effect.public_data_writes.size() << "\n";
    std::cout << "  publicLogs      " << r.public_tx_effect.public_logs.size() << "\n";
    std::cout << "  callFrames      " << r.call_stack_metadata.size() << "\n";
    // TREE ROOTS. Everything above is an *effect*; a root is the committed state those effects
    // produced. Two implementations can agree on every effect and still disagree on the resulting
    // tree — a wrong merkle hash, a wrong domain separator or a wrong indexed-leaf linkage shows up
    // here and nowhere else. Requires config.collect_public_inputs.
    if (r.public_inputs.has_value()) {
        const auto& pi = *r.public_inputs;
        const auto snap = [](const char* label, const AppendOnlyTreeSnapshot& s) {
            std::cout << "  " << label << " " << hex(s.root) << " next=" << s.next_available_leaf_index << "\n";
        };
        snap("startNoteHashRoot ", pi.start_tree_snapshots.note_hash_tree);
        snap("startNullifierRoot", pi.start_tree_snapshots.nullifier_tree);
        snap("startPublicDataRt ", pi.start_tree_snapshots.public_data_tree);
        snap("startL1ToL2Root   ", pi.start_tree_snapshots.l1_to_l2_message_tree);
        snap("endNoteHashRoot   ", pi.end_tree_snapshots.note_hash_tree);
        snap("endNullifierRoot  ", pi.end_tree_snapshots.nullifier_tree);
        snap("endPublicDataRoot ", pi.end_tree_snapshots.public_data_tree);
        snap("endL1ToL2Root     ", pi.end_tree_snapshots.l1_to_l2_message_tree);
    }
    for (const auto& [k, v] : std::map<std::string, std::string>(r.stats.begin(), r.stats.end())) {
        std::cout << "  stat " << k << " = " << v << "\n";
    }
}

// (1) ADD two U32s and RETURN the result. The canonical smoke program.
std::vector<uint8_t> program_add()
{
    return BytecodeBuilder()
        .add(set8(0, MemoryTag::U32, 1))
        .add(set8(1, MemoryTag::U32, 2))
        .add(InstructionBuilder(WireOpCode::ADD_8).operand<uint8_t>(0).operand<uint8_t>(1).operand<uint8_t>(2).build())
        .add(ret(0, 2))
        .build();
}

// (2) A deliberate revert: exercises the throw/catch revert path that -fwasm-exceptions must carry.
std::vector<uint8_t> program_revert()
{
    return BytecodeBuilder()
        .add(set8(0, MemoryTag::U32, 0))
        .add(InstructionBuilder(WireOpCode::REVERT_8).operand<uint8_t>(0).operand<uint8_t>(0).build())
        .build();
}

// (3) Field arithmetic + a loop: 64 iterations of MUL/ADD over U64, ending in RETURN.
//     Exercises the interpreter loop, jumps, tag checking and gas accounting for real.
std::vector<uint8_t> program_loop()
{
    BytecodeBuilder b;
    b.add(set8(0, MemoryTag::U32, 0));      // return copy size
    b.add(set8(1, MemoryTag::U64, 1));      // acc
    b.add(set8(2, MemoryTag::U64, 3));      // k
    for (int i = 0; i < 64; ++i) {
        b.add(InstructionBuilder(WireOpCode::MUL_8).operand<uint8_t>(1).operand<uint8_t>(2).operand<uint8_t>(1).build());
        b.add(InstructionBuilder(WireOpCode::ADD_8).operand<uint8_t>(1).operand<uint8_t>(2).operand<uint8_t>(1).build());
    }
    b.add(ret(0, 1));
    return b.build();
}

// (4) SHA256COMPRESSION: 8 U32 state words + 16 U32 input words -> 8 U32 digest words.
//     Pulls the real crypto gadget into the executed path.
std::vector<uint8_t> program_sha256()
{
    BytecodeBuilder b;
    b.add(set8(0, MemoryTag::U32, 0)); // return copy size
    for (uint8_t i = 0; i < 8; ++i) {
        b.add(set32(static_cast<uint16_t>(10 + i), MemoryTag::U32, 0x6a09e667u + i));
    }
    for (uint8_t i = 0; i < 16; ++i) {
        b.add(set32(static_cast<uint16_t>(26 + i), MemoryTag::U32, 0x01020304u * (i + 1)));
    }
    b.add(InstructionBuilder(WireOpCode::SHA256COMPRESSION)
              .operand<uint16_t>(200)
              .operand<uint16_t>(10)
              .operand<uint16_t>(26)
              .build());
    b.add(set8(1, MemoryTag::U32, 8));
    b.add(ret(1, 200));
    return b.build();
}

// (5) POSEIDON2PERM: the hash the protocol itself is built on.
std::vector<uint8_t> program_poseidon2()
{
    BytecodeBuilder b;
    b.add(set8(0, MemoryTag::U32, 0));
    for (uint8_t i = 0; i < 4; ++i) {
        b.add(setff(static_cast<uint16_t>(10 + i), MemoryTag::FF, FF(i + 1)));
    }
    b.add(InstructionBuilder(WireOpCode::POSEIDON2PERM).operand<uint16_t>(10).operand<uint16_t>(20).build());
    b.add(set8(1, MemoryTag::U32, 4));
    b.add(ret(1, 20));
    return b.build();
}

// (6) Public storage write then read-back: exercises the merkle DB and public data tree.
std::vector<uint8_t> program_storage()
{
    BytecodeBuilder b;
    b.add(set8(0, MemoryTag::U32, 0));
    b.add(setff(1, MemoryTag::FF, FF(7)));    // slot
    b.add(setff(2, MemoryTag::FF, FF(1234)));  // value
    b.add(InstructionBuilder(WireOpCode::SSTORE).operand<uint16_t>(2).operand<uint16_t>(1).build());
    b.add(set8(4, MemoryTag::U32, 1));
    b.add(ret(4, 2));
    return b.build();
}

// (7) Throughput probe: a tight ADD loop that runs until it exhausts the gas limit.
//     Gives instructions/second for native vs wasm on identical work.
std::vector<uint8_t> program_burn()
{
    BytecodeBuilder b;
    b.add(set8(0, MemoryTag::U64, 1));
    b.add(set8(1, MemoryTag::U64, 1));
    const size_t loop_start = b.size();
    for (int i = 0; i < 16; ++i) {
        b.add(InstructionBuilder(WireOpCode::ADD_8).operand<uint8_t>(0).operand<uint8_t>(1).operand<uint8_t>(0).build());
    }
    b.add(InstructionBuilder(WireOpCode::JUMP_32).operand(static_cast<uint32_t>(loop_start)).build());
    return b.build();
}

// A CodeTracer-shaped step recorder: one record per executed AVM instruction.
class StepRecorder : public bb::avm2::simulation::ExecutionObserverInterface {
  public:
    struct Step {
        uint32_t context_id;
        uint32_t pc;
        uint8_t opcode;
        uint32_t l2_gas_used;
    };

    void on_instruction(uint32_t context_id,
                        const AztecAddress& /*contract_address*/,
                        PC pc,
                        const Instruction& instruction,
                        const Gas& gas_used) override
    {
        steps.push_back({ context_id, pc, static_cast<uint8_t>(instruction.opcode), gas_used.l2_gas });
    }

    std::vector<Step> steps;
};

} // namespace

int main()
{
    std::cout << "avm-spike-runner: pointer=" << (sizeof(void*) * 8) << "bit\n";

    const std::vector<std::pair<std::string, std::vector<uint8_t>>> programs = {
        { "add", program_add() },
        { "revert", program_revert() },
        { "loop", program_loop() },
        { "sha256", program_sha256() },
        { "poseidon2", program_poseidon2() },
        { "storage", program_storage() },
        { "burn", program_burn() },
    };

    for (const auto& [name, bytecode] : programs) {
        std::cout << "-- program " << name << " bytes=" << bytecode.size() << "\n";
        PublicTxSimulationTester tester;
        auto contract = tester.deploy_contract(bytecode);
        std::cout << "  address         " << hex(contract.address) << "\n";
        auto config = PublicTxSimulationTester::default_config();
        config.collect_statistics = true;
        config.collect_public_inputs = true; // carries start/end tree snapshots — see dump()
        // Pass 1: no observer attached (the shipping configuration).
        const auto t0 = std::chrono::steady_clock::now();
        auto result = tester.simulate_tx({ TestEnqueuedCall{ .contract_address = contract.address } }, config);
        const auto t1 = std::chrono::steady_clock::now();
        dump(name, result);
        // Timing is intentionally NOT part of the diffed transcript.
        std::cerr << "TIMING " << name << " simulate_us="
                  << std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count() << "\n";

        // Pass 2: identical simulation with a per-instruction step recorder attached.
        StepRecorder recorder;
        PublicTxSimulationTester tester2;
        auto contract2 = tester2.deploy_contract(bytecode);
        bb::avm2::simulation::g_execution_observer = &recorder;
        const auto t2 = std::chrono::steady_clock::now();
        auto traced = tester2.simulate_tx({ TestEnqueuedCall{ .contract_address = contract2.address } }, config);
        const auto t3 = std::chrono::steady_clock::now();
        bb::avm2::simulation::g_execution_observer = nullptr;
        std::cerr << "TRACED " << name << " simulate_us="
                  << std::chrono::duration_cast<std::chrono::microseconds>(t3 - t2).count()
                  << " steps=" << recorder.steps.size() << " sameResult=" << (traced == result ? 1 : 0) << "\n";
        if (!recorder.steps.empty()) {
            std::cerr << "  first steps:";
            for (size_t i = 0; i < recorder.steps.size() && i < 6; ++i) {
                std::cerr << " (ctx" << recorder.steps[i].context_id << " pc" << recorder.steps[i].pc << " op"
                          << static_cast<int>(recorder.steps[i].opcode) << " gas" << recorder.steps[i].l2_gas_used
                          << ")";
            }
            std::cerr << "\n";
        }
    }

#ifdef __wasm__
    // Peak linear memory actually touched, against the 4 GiB wasm32 ceiling.
    std::cout << "peakLinearMemoryPages " << __builtin_wasm_memory_size(0) << " ("
              << (__builtin_wasm_memory_size(0) * 64) << " KiB)\n";
#endif
    std::cout << "avm-spike-runner: done\n";
    return 0;
}
