// 모바일 host(iOS·Android)와 코어 사이의 C ABI 단일 출처.
//
// **플랫폼은 배치를 모른다.** 쓸 수 있는 크기를 논리 px 로 넘기고 quad 목록을 받는다.
// 셀 판정도 코어가 한다 — 플랫폼은 점만 넘긴다(docs/mobile-platform.md §3).
//
// 이 헤더는 `platform/mobile/mobile_bridge.zig` 의 export 와 짝이다. 한쪽만 고치면
// 링크는 되고 동작만 어긋나므로 **필드 순서·타입을 함께** 바꾼다.
#ifndef MARU_MOBILE_HOST_ABI_H
#define MARU_MOBILE_HOST_ABI_H

#ifdef __cplusplus
extern "C" {
#endif

/// 글리프 아틀라스의 셀 기하. **두 플랫폼이 같은 값을 써야 한다** — 다르면 같은 폰트를
/// 써도 대조가 조용히 무의미해지고(픽셀 비교가 서로 다른 격자를 보게 된다), 아틀라스를
/// 굽는 쪽과 좌표를 계산하는 쪽이 어긋난다. 네 곳에 흩어져 있던 것을 여기로 모았다.
#define MARU_ATLAS_CELL_W 24
#define MARU_ATLAS_CELL_H 32
/// 아틀라스 격자 크기는 **Zig 가 소유한다**(`maru_mobile_atlas_cols/rows`). 매크로로 두면
/// 등록부보다 큰 슬롯을 약속하게 되고, 남는 슬롯은 등록이 안 된 채 매 프레임 다시 구워진다.
/// 셀 크기만 매크로로 남긴다 — 스택 배열 크기에 쓰이기 때문이다.
unsigned int maru_mobile_atlas_cols(void);
unsigned int maru_mobile_atlas_rows(void);

/// 앱이 뜨자마자 보일 글자만 미리 굽는다(나머지는 온디맨드 성장이 맡는다). **두 플랫폼이
/// 같은 집합을 써야** 픽셀 대조가 의미를 갖는다 — 예전에는 두 host 에 같은 문자열이
/// 따로 있어, 한쪽만 고치면 서로 다른 아틀라스를 비교하게 됐다.
#define MARU_ATLAS_PREBAKE \
    "$ zig build test All 11 passed.git status --short" \
    "M src/chrome/ui/tree.zigmaru 0.1.0 (arm64)zshvimlogswebdocsinfrascratch" \
    "한글 터미널 세션 목록 설정 검색 알림"

/// 그릴 것 하나. ChromeDraw 의 op 은 union 이라 C 에서 다루기 번거로워 rect+색+radius 로
/// 낮춰 넘긴다. **`float4` 배수로 맞춘다** — Metal 셰이더 구조체가 `float2` 에 8바이트
/// 정렬을 요구해 필드가 밀리고 NDC 가 깨진 적이 있다(실측).
typedef struct {
    float x, y, w, h;
    float r, g, b, a;
    float radius;
    /// 0=단색 quad · 1=아틀라스 글리프 · 2=아이콘 coverage
    unsigned int kind;
    /// kind=1 이면 아틀라스 셀(열, 행). kind=2 면 아이콘 슬롯 인덱스.
    unsigned int cell_x, cell_y;
} MaruQuad;

/// 논리 크기를 주고 그릴 quad 개수를 받는다. 목록은 `maru_mobile_quads()`.
unsigned int maru_mobile_build(unsigned int width, unsigned int height);
const MaruQuad *maru_mobile_quads(void);
/// build 가 낼 수 있는 **최대** quad 수. GPU 버퍼를 이만큼 잡으면 잘릴 일이 없다. 상한을
/// host 마다 손으로 적으면 어긋난다 — iOS 는 늘리고 Android 는 4096 에서 조용히 자르고 있었다.
unsigned int maru_mobile_max_quads(void);
/// 0 quad 가 나왔을 때 **무엇이 실패했는지** 플랫폼이 볼 수 있어야 한다.
///
/// **읽은 쪽이 비운다.** build 가 프레임마다 비우면 프레임 *사이*에 난 실패(입력의 core
/// write)가 아무도 읽기 전에 지워진다. 호스트는 매 프레임 읽고, 값이 있으면 비운다.
const char *maru_mobile_last_error(void);
void maru_mobile_clear_error(void);

/// 아틀라스 등록부. 플랫폼이 글리프를 굽고 그 자리를 알려 준다.
void maru_mobile_atlas_geometry(unsigned int cell_w, unsigned int cell_h);
void maru_mobile_atlas_add(unsigned int cp, unsigned int col, unsigned int row, unsigned int advance);

/// 아직 아틀라스에 없어 못 그린 코드포인트들. 플랫폼이 그것만 구워 넣는다.
/// 고정 집합으로 두면 처음 보는 글자가 **조용히** 안 그려진다(실측으로 드러났다).
unsigned int maru_mobile_missing_count(void);
unsigned int maru_mobile_missing_cp(unsigned int i);
/// 다음 빈 슬롯 — 상위 16비트=열, 하위 16비트=행.
unsigned int maru_mobile_next_slot(unsigned int cols);
void maru_mobile_missing_clear(void);

/// 아이콘 coverage 는 Zig 가 만든다(등록 SVG 자산). 플랫폼은 텍스처로 올려 샘플링만 한다.
unsigned int maru_mobile_icon_build(void);
const unsigned char *maru_mobile_icon_atlas(void);
unsigned int maru_mobile_icon_slot_px(void);
unsigned int maru_mobile_icon_count(void);

/// 키 입력(확정된 문자). 코어는 이 바이트를 PTY 에서 온 것과 구분하지 않는다.
///
/// **반환값은 코어에 전달한 누적 바이트다.** 예전에는 내부 기록 길이를 돌려줬는데, 기록
/// 버퍼가 차면 같은 수가 계속 나와 **입력이 죽은 것을 로그로 알 수 없었다**(실제로 512에서
/// 멈춘 채 모든 키가 사라지고 있었다). 이 값이 안 늘면 입력이 안 닿은 것이다.
unsigned int maru_mobile_input(const char *bytes, unsigned long len);

/// 조합 중 문자열(IME preedit). **코어에 넣지 않는다** — 확정 전에 PTY 로 흘리면 셸이
/// 자모를 명령어 일부로 받는다. 화면 커서 자리에 흐리게 그릴 겉치레다.
void maru_mobile_set_preedit(const char *bytes, unsigned long len);

/// 터치 지점(논리 px) → 셀. 상위 16비트=열, 하위 16비트=행. 본문 밖이면 0xFFFFFFFF.
unsigned int maru_mobile_hit_cell(float x, float y);

#ifdef __cplusplus
}
#endif
#endif
