// SPIKE (fixtures-and-specs): explicit gtest entry point.
// GTest::gtest_main supplies main() from a static archive; under wasm-ld that archive member is not
// pulled in (main resolves to an undefined-weak stub and traps at `unreachable`). Defining main in
// an object file that is always linked fixes it. Identical behaviour to gtest_main.
#include <gmock/gmock.h>
#include <gtest/gtest.h>

int main(int argc, char** argv)
{
    ::testing::InitGoogleMock(&argc, argv);
    return RUN_ALL_TESTS();
}
