#!/bin/bash
# The three zones of src/, as name lists, shared by tests/depcheck.sh (which
# reads includes) and tests/linkcheck.sh (which reads symbols). One definition:
# two checks that disagreed about which file is engine would be worse than
# either alone.
#
# src/ is flat, so a zone is a NAME LIST rather than a directory. That is the
# weakness both checks inherit, and why each reports files belonging to no zone.

# The chess library: types, board, movegen, search, evaluation, tables.
ENGINE="attacks basetypes bitboard evaluate history movegen movepick position
        score search tt types nnue_accumulator nnue_architecture nnue_common
        nnue_feature_transformer nnue_misc network simd tbprobe nnz_helper
        full_threats half_ka_v2_hm pp_3wide affine_transform clipped_relu
        affine_transform_sparse_input sqr_clipped_relu"

# The OS runtime that hosts it: clock, memory, threads, NUMA, shared memory.
PLATFORM="memory misc numa numa_shared platform shm shm_unix thread thread_native
          entry_arm64 entry_riscv64 entry_x86 nnue_embed"

# Vendored third-party code. It is in the tree but not ours to zone.
VENDOR="incbin"

# The process: main, the UCI loop, the option table, bench, tuning.
SHELL_Z="benchmark engine main perft timeman tune uci ucioption"

zone_of() {
    local stem=$1
    # $(echo ...) collapses the newlines in the lists above; without it a name
    # sitting at a line break is followed by \n rather than a space and matches
    # nothing, which silently exempts it.
    case " $(echo $ENGINE) "   in *" $stem "*) echo engine;   return ;; esac
    case " $(echo $PLATFORM) " in *" $stem "*) echo platform; return ;; esac
    case " $(echo $SHELL_Z) "  in *" $stem "*) echo shell;    return ;; esac
    case " $(echo $VENDOR) "   in *" $stem "*) echo vendor;   return ;; esac
    echo unassigned
}
