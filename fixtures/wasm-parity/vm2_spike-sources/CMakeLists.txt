# SPIKE: a runnable driver over vm2_sim, built identically for native and wasm.
file(GLOB VM2_TESTING_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/../vm2/testing/*.cpp)
list(FILTER VM2_TESTING_SOURCES EXCLUDE REGEX ".*\\.(test|bench|fuzzer)\\.cpp$")
# fixtures.cpp pulls in tracegen (proving side), which vm2_sim deliberately excludes.
list(FILTER VM2_TESTING_SOURCES EXCLUDE REGEX ".*/fixtures\\.cpp$")

add_executable(avm_spike_runner ${CMAKE_CURRENT_SOURCE_DIR}/avm_run.cpp ${VM2_TESTING_SOURCES})
target_link_libraries(avm_spike_runner PRIVATE vm2_sim world_state_reference crypto_merkle_tree env)
add_dependencies(avm_spike_runner msgpack-c)

# SPIKE (fixtures-and-specs): upstream's OWN vm2 simulation test suite, built against vm2_sim so it
# can run under wasm32-wasi as well as native. Upstream never builds these: vm2_sim is declared with
# no TEST_SOURCE_FILES, and the vm2_tests binary that does carry them is gated on `if(AVM)`, which
# drags in the whole proving stack (sumcheck, stdlib_honk_verifier, goblin_avm) that the wasm build
# deliberately excludes. So this target is additive, not a re-enablement.
file(GLOB_RECURSE VM2_SIM_TEST_SOURCES
  ${CMAKE_CURRENT_SOURCE_DIR}/../vm2/simulation/*.test.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/../vm2/common/*.test.cpp
)
# bytecode_manager.test.cpp reaches into the proving side; excluded with the same rationale as
# fixtures.cpp above.
list(FILTER VM2_SIM_TEST_SOURCES EXCLUDE REGEX ".*/bytecode_manager\\.test\\.cpp$")
# avm_io.test.cpp is the only user of get_minimal_trace_with_pi(), which is tracegen-bound.
list(FILTER VM2_SIM_TEST_SOURCES EXCLUDE REGEX ".*/avm_io\\.test\\.cpp$")

add_executable(vm2_sim_tests ${VM2_SIM_TEST_SOURCES} ${VM2_TESTING_SOURCES}
  ${CMAKE_CURRENT_SOURCE_DIR}/spike_fixtures.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/spike_test_main.cpp)
target_link_libraries(vm2_sim_tests PRIVATE
  vm2_sim world_state_reference crypto_merkle_tree env
  GTest::gtest GTest::gmock)
add_dependencies(vm2_sim_tests msgpack-c)

# SPIKE (fixtures-and-specs) FINDING, recorded rather than fixed:
# 35 of the 59 suites here trap under wasm32-wasi ("memory access out of bounds" inside
# testing::Sequence::AddExpectation, or "unreachable"). The failures correlate EXACTLY with gmock
# usage -- every gmock-free suite passes, every suite using EXPECT_CALL/StrictMock fails. Root cause
# is gtest's threading layer against wasi-libc's pthread *stubs*: an earlier run surfaced
#   "Condition has_owner_ && pthread_equal(owner_, pthread_self()) failed"
# from MutexBase::AssertHeld() inside gmock's global expectation registry, after which the
# unguarded mutation corrupts linear memory. Rebuilding gtest+gmock with GTEST_HAS_PTHREAD=0 was
# tried and did NOT help (identical 24/59 suites, 141 tests). This is a TEST-FRAMEWORK limitation,
# not an AVM one: the AVM itself produces a byte-identical transcript native vs wasm, tree roots
# included. Fixing it means porting gmock's synchronisation to single-threaded wasm.
# 3 further suites are gtest DEATH tests, which fork and therefore can never run under WASI.
