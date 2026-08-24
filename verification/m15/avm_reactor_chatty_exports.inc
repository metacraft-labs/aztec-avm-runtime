// ===========================================================================
// M15 — the chatty arm's entry points.
// ===========================================================================
//
// Appended to `avm_reactor.cpp` by M15's overlay patch. Kept as its own block so the resident
// arm's exports above are untouched: the two arms must differ by which DBs the AVM is handed and
// by nothing else, or a difference between their results is a difference between two programs
// rather than between two shapes.
//
// `avm_simulate_chatty` is `avm_simulate` with the two resident handles replaced by an
// `ImportedContractDB` and an `ImportedMerkleDB`. Same inputs type, same `AvmSimAPI::simulate`,
// same result type, same step retention. The whole delta is two lines.

// Input: msgpack `AvmFastSimulationInputs`. Result: msgpack `TxSimulationResult`.
// The DBs are the host's: every read the AVM makes leaves the module through `env.avm_host_db_call`.
WASM_EXPORT int32_t avm_simulate_chatty(const uint8_t* inputs, uint32_t len)
{
    return guarded([&] {
        bb::avm2::reactor::chatty_stats().reset();
        bb::avm2::reactor::ImportedContractDB cdb;
        bb::avm2::reactor::ImportedMerkleDB mdb;
        std::vector<uint8_t> bytes(inputs, inputs + len);
        const AvmFastSimulationInputs parsed = AvmFastSimulationInputs::from(bytes);
        AvmSimAPI api;
        const TxSimulationResult result = api.simulate(parsed, cdb, mdb, nullptr);
        g_steps = result.execution_steps.has_value() ? *result.execution_steps : std::vector<ExecutionStep>{};
        pack_result(result);
    });
}

// What that simulation cost at the boundary: crossings, request bytes and reply bytes, per op and
// in total, plus the retry count and the number of ops this module knows about.
//
// Reported by the module rather than counted by the host, deliberately. A host that counted its own
// invocations would be counting what it was asked to do; this counts what the AVM asked for, which
// is the quantity the decision turns on.
//
// result: msgpack `ChattyStats`.
WASM_EXPORT int32_t avm_chatty_stats()
{
    return guarded([&] { pack_result(bb::avm2::reactor::chatty_stats()); });
}

// Zero the counters without running anything, so a host can measure a segment of work rather than
// a whole simulation.
WASM_EXPORT int32_t avm_chatty_reset()
{
    return guarded([&] {
        bb::avm2::reactor::chatty_stats().reset();
        clear_result();
    });
}

// The NULL CROSSING, in the module-calls-host direction — the direction a chatty DB uses and the
// one M12 did not measure. `n` crossings that carry one integer and return nothing, so the cost of
// the crossing can be separated from the cost of what it carries.
//
// It exists because the two directions are not the same path through the engine and assuming they
// cost the same is the kind of assumption this milestone was told to measure instead. The host's
// implementation of `avm_host_probe` must do nothing, and that it does nothing is the host's to
// assert.
WASM_EXPORT int32_t avm_probe_host_crossings(uint32_t n)
{
    return guarded([&] {
        for (uint32_t i = 0; i < n; i++) {
            bb::avm2::reactor::chatty_host_probe(i);
        }
        clear_result();
    });
}
