// 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).
// 등록된 maru chrome 아이콘(icon_glyph)의 Plane-15 PUA codepoint 집합. coretext_smoke.m의
// maru_is_synthesized_glyph가 이걸 써서 **등록 아이콘만** 합성으로 본다 — 미등록 in-range(Nerd Fonts v3가
// Plane-15 PUA로 옮긴 Material Design Icons U+F0001~ 등)는 폰트 글리프로 폴백한다. renderer/icon_glyph.zig의
// isRegisteredIcon과 동일 집합(같은 ICONS 소스 생성)이라 Zig 래스터와 C 셰이핑 게이트가 항상 일치한다.
#ifndef MARU_ICON_CODEPOINTS_H
#define MARU_ICON_CODEPOINTS_H

#include <stdbool.h>
#include <stdint.h>

static inline bool maru_is_registered_icon_cp(uint32_t cp) {
    switch (cp) {
        case 0xF0001u:
        case 0xF0002u:
        case 0xF0003u:
        case 0xF0004u:
        case 0xF0005u:
        case 0xF0006u:
        case 0xF0007u:
        case 0xF0008u:
        case 0xF0009u:
        case 0xF000Au:
        case 0xF000Bu:
        case 0xF000Cu:
        case 0xF000Du:
        case 0xF000Eu:
        case 0xF000Fu:
        case 0xF0010u:
        case 0xF0011u:
        case 0xF0012u:
        case 0xF0013u:
        case 0xF0014u:
        case 0xF0015u:
        case 0xF0016u:
        case 0xF0017u:
        case 0xF0018u:
        case 0xF0019u:
        case 0xF001Au:
        case 0xF001Bu:
        case 0xF001Cu:
        case 0xF001Du:
        case 0xF001Eu:
        case 0xF001Fu:
        case 0xF0020u:
        case 0xF0021u:
        case 0xF0022u:
        case 0xF0023u:
        case 0xF0024u:
        case 0xF0025u:
            return true;
        default:
            return false;
    }
}

#endif  // MARU_ICON_CODEPOINTS_H
