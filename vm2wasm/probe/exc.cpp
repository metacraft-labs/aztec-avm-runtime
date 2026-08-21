#include <cstdio>
#include <stdexcept>
#include <string>

struct AvmRevert : std::runtime_error {
    explicit AvmRevert(const std::string& m) : std::runtime_error(m) {}
};

__attribute__((noinline)) void opcode(int x) {
    if (x == 42) throw AvmRevert("out of gas");
    printf("opcode ok %d\n", x);
}

int main() {
    for (int i : {1, 42, 7}) {
        try { opcode(i); }
        catch (const AvmRevert& e) { printf("reverted: %s\n", e.what()); }
        catch (...) { printf("unknown\n"); }
    }
    printf("survived\n");
    return 0;
}
