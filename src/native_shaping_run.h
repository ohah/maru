/* Shared native run adjacency policy. No OS handles or native font types.
 * Keep CoreText and DirectWrite on the same row/face/cursor boundaries. */
#ifndef MARU_NATIVE_SHAPING_RUN_H
#define MARU_NATIVE_SHAPING_RUN_H
#include <stdint.h>
#include <stdbool.h>
static inline bool maru_native_run_continues(
    uint32_t previous_row, uint32_t previous_col, uint32_t previous_width,
    uint32_t previous_key, uint32_t current_row, uint32_t current_col,
    uint32_t current_key) {
    const uint32_t width = previous_width == 0 ? 1 : previous_width;
    return previous_row == current_row && previous_key == current_key &&
        (uint64_t)previous_col + width == current_col;
}
#endif
