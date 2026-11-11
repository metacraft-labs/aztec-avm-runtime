// Real published SRS APIs, no mocks. Provisioning permits acquisition only in
// this exclusive directory; original test factories retain allow_download=false.
#include "barretenberg/srs/factories/get_bn254_crs.hpp"
#include "barretenberg/srs/factories/get_grumpkin_crs.hpp"
#include <cassert>
#include <filesystem>
#include <iostream>
int main(int argc, char** argv) {
  assert(argc == 2);
  std::filesystem::path path(argv[1]);
  assert(std::filesystem::is_directory(path));
  auto g2 = bb::get_bn254_g2_data(path);
  assert(g2.on_curve());
  auto bn = bb::get_bn254_g1_data(path, size_t(1) << 22, true);
  assert(bn.size() == (size_t(1) << 22));
  auto grumpkin = bb::get_grumpkin_g1_data(path, size_t(1) << 18, true);
  assert(grumpkin.size() == (size_t(1) << 18));
  std::cout << "bn254=" << bn.size() << " grumpkin=" << grumpkin.size() << "\n";
}
