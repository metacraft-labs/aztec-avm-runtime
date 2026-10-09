// M7, force-included (`-include`) ONLY into the wasm32 replay build of upstream's
// `world_state/memory_merkle_db.test.cpp` -- NOT an upstream file.
//
// That test includes `crypto/merkle_tree/fixtures.hpp` for `random_temp_directory()`. The same header
// also defines `make_thread_pool()`, which names `bb::ThreadPool`, and `common/thread_pool.hpp`
// declares nothing at all under NO_MULTITHREADING (a wasm32 configure). The test never calls
// `make_thread_pool()`; this declaration exists only so the header compiles. Its constructor is
// declared and never defined, so anything that did construct one would fail to LINK rather than
// run. It is the same cause that keeps `crypto_merkle_tree_tests` out of the wasm build.
#pragma once
#ifdef NO_MULTITHREADING
#include <cstddef>
namespace bb {
class ThreadPool {
  public:
    explicit ThreadPool(size_t num_threads);
};
} // namespace bb
#endif
