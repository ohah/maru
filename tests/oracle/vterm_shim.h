#ifndef MARU_VTERM_SHIM_H
#define MARU_VTERM_SHIM_H

#include <stdint.h>
#include <vterm.h>

// libvterm의 VTermScreenCell은 bitfield를 포함해 Zig translate-c에서 opaque로
// 처리된다. 그래서 Zig 쪽에서 직접 스택 할당하거나 필드에 접근할 수 없다.
// 이 shim은 셀의 첫 codepoint만 꺼내 주는 얇은 래퍼다(빈 셀은 0).
uint32_t maru_vterm_cell_codepoint(VTermScreen *screen, int row, int col);

#endif
