#include <cstddef>
#include <cstdint>
#include <string>

#include "../../src/bitboard.h"
#include "../../src/position.h"
#include "../../src/uci.h"

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

    std::string input(reinterpret_cast<const char*>(data), size);
    auto        split = input.find('\n');

    std::string fen  = split == std::string::npos ? std::string(Stockfish::StartFEN)
                                                  : input.substr(0, split);
    std::string move = split == std::string::npos ? input : input.substr(split + 1);

    if (fen.empty())
        fen = Stockfish::StartFEN;

    Stockfish::StateInfo state{};
    Stockfish::Position  position;

    if (!position.set(fen, false, &state))
        (void) Stockfish::UCIEngine::to_move(position, move);

    return 0;
}
