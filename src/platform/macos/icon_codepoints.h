// 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).
// 등록된 maru chrome 아이콘(icon_glyph)의 Plane-15 PUA codepoint 집합. coretext_smoke.m의
// maru_is_synthesized_glyph가 이걸 써서 **등록 아이콘만** 합성으로 본다 — 미등록 in-range(Nerd Fonts v3가
// Plane-15 PUA로 옮긴 Material Design Icons U+F0001~ 등)는 폰트 글리프로 폴백한다. renderer/icon_glyph.zig의
// isRegisteredIcon과 동일 집합(같은 ICONS 소스 생성)이라 Zig 래스터와 C 셰이핑 게이트가 항상 일치한다.
#ifndef MARU_ICON_CODEPOINTS_H
#define MARU_ICON_CODEPOINTS_H

#include <stdbool.h>
#include <stdint.h>

// 이름 매크로 — Objective-C 렌더 경로도 codepoint 리터럴 대신 이름으로 아이콘을 고른다(Zig의
// src/icons.zig와 같은 규율). 자산이 재배치되면 이름은 그대로 새 cp를 가리키므로 조용히 어긋나지 않는다.
#define MARU_ICON_GIT_BRANCH 0xF0001u
#define MARU_ICON_GEAR 0xF0002u
#define MARU_ICON_PLUS 0xF0003u
#define MARU_ICON_SEARCH 0xF0004u
#define MARU_ICON_BELL 0xF0005u
#define MARU_ICON_SIDEBAR_COLLAPSE 0xF0006u
#define MARU_ICON_SPARKLE 0xF0007u
#define MARU_ICON_DIAMOND 0xF0008u
#define MARU_ICON_MARK_GITHUB 0xF0009u
#define MARU_ICON_FOLDER 0xF000Au
#define MARU_ICON_RESET 0xF000Bu
#define MARU_ICON_RECENT 0xF000Cu
#define MARU_ICON_FOLDER_OPEN 0xF000Du
#define MARU_ICON_FILE 0xF000Eu
#define MARU_ICON_FILE_CODE 0xF000Fu
#define MARU_ICON_DOCUMENT 0xF0011u
#define MARU_ICON_IMAGE 0xF0012u
#define MARU_ICON_FILE_CONFIG 0xF0013u
#define MARU_ICON_ARCHIVE 0xF0014u
#define MARU_ICON_PACKAGE 0xF0015u
#define MARU_ICON_WEB 0xF0016u
#define MARU_ICON_DATA 0xF0017u
#define MARU_ICON_FOLDER_SOURCE 0xF0018u
#define MARU_ICON_FOLDER_TEST 0xF0019u
#define MARU_ICON_FOLDER_DOCS 0xF001Au
#define MARU_ICON_FOLDER_ASSETS 0xF001Bu
#define MARU_ICON_FOLDER_CONFIG 0xF001Cu
#define MARU_ICON_FOLDER_DEPENDENCY 0xF001Du
#define MARU_ICON_FOLDER_OUTPUT 0xF001Eu
#define MARU_ICON_CHEVRON_DOWN 0xF001Fu
#define MARU_ICON_CHEVRON_RIGHT 0xF0020u
#define MARU_ICON_RESET_TIGHT 0xF0021u
#define MARU_ICON_SEARCH_TIGHT 0xF0022u
#define MARU_ICON_CHEVRON_DOWN_TIGHT 0xF0023u
#define MARU_ICON_CHEVRON_RIGHT_TIGHT 0xF0024u
#define MARU_ICON_HOST 0xF0025u
#define MARU_ICON_HOURGLASS 0xF0026u
#define MARU_ICON_ARROW_UP 0xF0027u
#define MARU_ICON_ARROW_DOWN 0xF0028u
#define MARU_ICON_ARROW_LEFT 0xF0029u
#define MARU_ICON_ARROW_RIGHT 0xF002Au
#define MARU_ICON_COLLAPSE_ALL 0xF002Bu
#define MARU_ICON_CLOUD_DOWNLOAD 0xF002Cu
#define MARU_ICON_PHONE 0xF002Du

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
        case 0xF0026u:
        case 0xF0027u:
        case 0xF0028u:
        case 0xF0029u:
        case 0xF002Au:
        case 0xF002Bu:
        case 0xF002Cu:
        case 0xF002Du:
            return true;
        default:
            return false;
    }
}

#endif  // MARU_ICON_CODEPOINTS_H
