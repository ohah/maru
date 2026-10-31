#ifndef MARU_RENDERER_NATIVE_CELL_RECT_H
#define MARU_RENDERER_NATIVE_CELL_RECT_H
#include <stdint.h>
/* Finite pixel metrics are the caller contract. Keep this leaf freestanding:
 * wasm builds must not acquire a libm/header dependency for native geometry. */
static inline float maru_cell_max(float a, float b) { return a != a ? b : b != b ? a : a > b ? a : b; }
static inline float maru_cell_min(float a, float b) { return a != a ? b : b != b ? a : a < b ? a : b; }
/* Existing Maru Metal strip geometry, shared by native renderer adapters.
 * Inputs and outputs are pixel edges, before glyph scaling and clipping. */
static inline void maru_native_cell_edges(uint16_t kind, float cw, float cell_h,
    float py_top, uint32_t divider_thickness_px, float *left, float *right,
    float *top, float *bottom) {
    float px_left=*left, px_right=*right, px_top=*top, px_bottom=*bottom;
    const float text_line = maru_cell_max(1.0f, cell_h * 0.075f); // 텍스트 장식선(밑줄·윗줄·취소선·2중선) 공통 두께
    if (kind == 2) {
        const float thickness = maru_cell_max(2.0f, cell_h * 0.15f);
        px_top = px_bottom - thickness;
    } else if (kind == 3) {
        const float thickness = maru_cell_max(2.0f, cw * 0.15f);
        px_right = px_left + thickness;
    } else if (kind == 4) {
        const float thickness = maru_cell_max(2.0f, cell_h * 0.15f);
        px_bottom = px_top + thickness;
    } else if (kind == 5) {
        const float thickness = maru_cell_max(2.0f, cw * 0.15f);
        px_left = px_right - thickness;
    } else if (kind == 9) {
        // 텍스트 밑줄(SGR 4)·링크 hover: 셀 하단에 가는 띠(커서 underline=2의 절반 두께).
        px_top = px_bottom - text_line;
    } else if (kind == 10) {
        // 텍스트 윗줄(SGR 53): 셀 상단에 가는 띠(테두리 상단=4와 분리된 가는 선).
        px_bottom = px_top + text_line;
    } else if (kind == 6) {
        // strikethrough(SGR 9): 셀 세로 중앙 가는 띠(밑줄은 하단, 이건 중앙).
        const float center = py_top + cell_h * 0.5f;
        px_top = center - text_line * 0.5f;
        px_bottom = center + text_line * 0.5f;
    } else if (kind == 7) {
        // double underline(SGR 21) 둘째 선: 하단 선(reserved 9) 위로 gap만큼 띄운 가는 띠. 둘이 합쳐 2중선.
        const float gap = maru_cell_max(1.0f, cell_h * 0.06f); // 두 선 사이 간격
        px_bottom = px_bottom - text_line - gap; // 하단 선 + gap 만큼 위로
        px_top = px_bottom - text_line;          // 둘째 선(첫째선과 같은 두께)
    } else if (kind == 8) {
        // OSC 133 거터 바: 셀 왼쪽 '바깥'(col 0 글자 시작 전 여백)에 세로 띠를 그린다 — bar(3)는 셀
        // 안 왼쪽이지만 이건 origin 왼쪽으로 빼 col 0 글자와 안 겹친다. 글자에 딱 붙지 않게 gap을 둬
        // 약간 띄운다. window padding 여백이 있으면 그 안에 들어가고, 없으면 사이드바 경계에 붙는다.
        const float thickness = maru_cell_max(2.0f, cw * 0.15f);
        const float gap = maru_cell_max(2.0f, cw * 0.12f); // 거터와 col 0 글자 사이 여백
        px_right = px_left - gap;        // 글자 시작에서 gap만큼 왼쪽
        px_left = px_right - thickness;  // 거기서 thickness만큼 바깥
        // window padding이 0이면 px_left(=origin_x-gap-thickness)가 음수(화면 밖)거나 사이드바를 침범할 수 있다.
        // 화면 왼쪽 밖으로 안 나가게 0 하한으로 clamp하고, px_right가 그보다 작아지면 폭 0으로 접는다. 사이드바
        // 폭은 .m이 모르니 0 하한만 둔다 — padding 0이면 거터가 좁아지거나 사이드바 경계에 붙을 수 있으나
        // 글자 침범보다 낫다.
        px_left = maru_cell_max(px_left, 0.0f);
        px_right = maru_cell_max(px_right, px_left);
    } else if (kind == 30) {
        // pane divider 세로선: 셀 origin이 경계(seam=px_left)라, 그 seam에 config 두께를 **중앙 정렬**하고 셀폭으로
        // clamp한다(두꺼운 값이 인접 pane 내용 위로 번지지 않게 — 최대 1셀, 좌/우 pane에 반씩). 커서 강조선 15%와 분리.
        const float t = maru_cell_min((float)divider_thickness_px, cw);
        const float seam = px_left;
        px_left = seam - t * 0.5f;
        px_right = seam + t * 0.5f;
    } else if (kind == 31) {
        // pane divider 가로선: 셀 origin이 경계(seam=px_top)라, 그 seam에 config 두께를 중앙 정렬하고 셀 높이로 clamp.
        const float t = maru_cell_min((float)divider_thickness_px, cell_h);
        const float seam = px_top;
        px_top = seam - t * 0.5f;
        px_bottom = seam + t * 0.5f;
    }
    *left=px_left; *right=px_right; *top=px_top; *bottom=px_bottom;
}
#endif
