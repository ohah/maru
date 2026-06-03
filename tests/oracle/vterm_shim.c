#include "vterm_shim.h"

uint32_t maru_vterm_cell_codepoint(VTermScreen *screen, int row, int col) {
    VTermScreenCell cell;
    VTermPos pos;
    pos.row = row;
    pos.col = col;
    vterm_screen_get_cell(screen, pos, &cell);
    return cell.chars[0];
}
