#include <cstddef>
#include <cstdint>
#include <string>

#include "../../src/bitboard.h"
#include "../../src/position.h"

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size);

namespace {

void ensure_initialized() {
    static const bool initialized = [] {
        Stockfish::Bitboards::init();
        Stockfish::Position::init();
        return true;
    }();

    (void) initialized;
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) {
    ensure_initialized();

    std::string fen(reinterpret_cast<const char*>(data), size);

    Stockfish::StateInfo state{};
    Stockfish::Position  position;
    (void) position.set(fen, false, &state);

    return 0;
}
