#ifndef MARU_PLATFORM_MACOS_METAL_CELL_POLICY_H
#define MARU_PLATFORM_MACOS_METAL_CELL_POLICY_H

#include <stdint.h>

enum {
    MaruAppHostMetalCellRoleDockToggle = 32,
};

typedef struct MaruMetalCellGlyphPolicy {
    uint32_t is_dock_toggle;
    float scale_x;
    float scale_y;
} MaruMetalCellGlyphPolicy;

/* NativeMetalCell의 명시적 role과 producer가 굳힌 atlas extent를 Metal glyph 정책으로 내린다.
   codepoint·좌표·별도 1.7 상수는 재추론하지 않는다. 일반 pane의 같은 PUA는 scale 1을 유지한다. */
static inline MaruMetalCellGlyphPolicy maru_metal_cell_glyph_policy(
    uint16_t reserved,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    uint32_t cell_width_px,
    uint32_t cell_height_px
) {
    const uint32_t is_dock_toggle = reserved == MaruAppHostMetalCellRoleDockToggle;
    MaruMetalCellGlyphPolicy policy = {is_dock_toggle, 1.0f, 1.0f};
    if (is_dock_toggle && cell_width_px > 0u && cell_height_px > 0u &&
        atlas_width_px > 0u && atlas_height_px > 0u) {
        policy.scale_x = (float)atlas_width_px / (float)cell_width_px;
        policy.scale_y = (float)atlas_height_px / (float)cell_height_px;
    }
    return policy;
}

#endif
