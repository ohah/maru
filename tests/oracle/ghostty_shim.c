#include "ghostty_shim.h"

#include <stdbool.h>
#include <ghostty/vt.h>

// codepoint를 UTF-8로 인코딩해 o에 쓴다(여유 cap). 쓴 바이트 수, 부족하면 0.
static size_t enc_utf8(uint32_t cp, uint8_t *o, size_t cap) {
    if (cp < 0x80) {
        if (cap < 1) return 0;
        o[0] = (uint8_t)cp;
        return 1;
    }
    if (cp < 0x800) {
        if (cap < 2) return 0;
        o[0] = (uint8_t)(0xC0 | (cp >> 6));
        o[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (cap < 3) return 0;
        o[0] = (uint8_t)(0xE0 | (cp >> 12));
        o[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        o[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cap < 4) return 0;
    o[0] = (uint8_t)(0xF0 | (cp >> 18));
    o[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    o[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    o[3] = (uint8_t)(0x80 | (cp & 0x3F));
    return 4;
}

long maru_ghostty_dump(uint16_t cols, uint16_t rows,
                       const uint8_t *input, size_t input_len,
                       uint8_t *out, size_t out_cap) {
    GhosttyTerminal terminal;
    GhosttyTerminalOptions opts = {
        .cols = cols,
        .rows = rows,
        .max_scrollback = 0,
    };
    if (ghostty_terminal_new(NULL, &terminal, opts) != GHOSTTY_SUCCESS) return -1;

    ghostty_terminal_vt_write(terminal, input, input_len);

    size_t pos = 0;
    for (uint16_t row = 0; row < rows; row++) {
        if (row != 0) {
            if (pos >= out_cap) {
                ghostty_terminal_free(terminal);
                return -1;
            }
            out[pos++] = '\n';
        }
        for (uint16_t col = 0; col < cols; col++) {
            uint32_t cp = ' ';

            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {
                .tag = GHOSTTY_POINT_TAG_ACTIVE,
                .value = {.coordinate = {.x = col, .y = row}},
            };
            if (ghostty_terminal_grid_ref(terminal, pt, &ref) == GHOSTTY_SUCCESS) {
                GhosttyCell cell;
                if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) {
                    bool has_text = false;
                    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
                    if (has_text) {
                        uint32_t c = 0;
                        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &c);
                        cp = c;
                    }
                }
            }

            size_t n = enc_utf8(cp, out + pos, out_cap - pos);
            if (n == 0) {
                ghostty_terminal_free(terminal);
                return -1;
            }
            pos += n;
        }
    }

    ghostty_terminal_free(terminal);
    return (long)pos;
}
