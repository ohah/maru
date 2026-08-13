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
/// 그 셀에 글자를 **굽는** 크기(px). 셀 크기와 짝이라 여기 함께 둔다 — 네 곳(iOS 2·Android 2)에
/// 따로 적혀 있었고, 한쪽만 고치면 두 플랫폼이 서로 다른 굵기로 구워 픽셀 대조가 조용히
/// 무의미해진다. 셀 높이(32)에 어센더·디센더가 들어갈 만큼이어야 한다.
#define MARU_ATLAS_TEXT_PX 22
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
    /// 0=단색 quad · 1=아틀라스 글리프(슬롯 전체) · 2=아이콘 coverage
    /// · 3=아틀라스 글리프의 **왼쪽 절반**
    /// · 4=**컬러** 아틀라스 글리프(슬롯 전체) · 5=컬러 아틀라스 글리프의 왼쪽 절반
    ///
    /// 컬러(4·5)는 **다른 텍스처**다. 글자 아틀라스는 커버리지(R8)라 컬러 비트맵을 넣으면
    /// 실루엣이 되므로 이모지는 RGBA 아틀라스를 따로 쓴다(아이콘 아틀라스와 같은 모양).
    /// 커버리지는 전경색을 곱해 그리고, 컬러는 아틀라스 색을 그대로 쓴다.
    ///
    /// 슬롯 하나는 **양폭(한글) 상자**라, 단폭 글자는 그 왼쪽 절반만 쓴다. 셰이더는 안 고친다 —
    /// `uv = (cell.xy + t) / cell.zw` 이므로 host 가 **열과 나누는 수를 함께 2배** 로 주면
    /// 그대로 왼쪽 절반이 나온다(`2*col / 2*cols`). 셰이더에는 kind=1 로 넘긴다.
    unsigned int kind;
    /// kind=1 이면 아틀라스 셀(열, 행). kind=2 면 아이콘 슬롯 인덱스.
    unsigned int cell_x, cell_y;
} MaruQuad;

/// 논리 크기를 주고 그릴 quad 개수를 받는다. 목록은 `maru_mobile_quads()`.
/// `time_ms` 는 **단조 증가하는 프레임 시각**이다. 코어에 시계가 없어서 시간이 걸린 판정을
/// 여기서 받는다 — 길게 누름이 그것이다. move 이벤트에서만 보면 **손가락이 가만히 있을 때
/// 이벤트가 안 와서 영영 안 잡힌다**(2초를 눌러도 아무 일도 안 났다, 실측).
unsigned int maru_mobile_build(unsigned int width, unsigned int height, unsigned long long time_ms);
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
///
/// `style` 은 굵게(1)·기울임(2) 비트다 — **Android `Typeface` 상수와 같은 값**이라 그쪽은
/// 그대로 넘기고, iOS 는 이 비트로 번들 폰트 파일을 고른다. 같은 글자라도 굵은 판은 **다른
/// 글리프**라 슬롯이 따로 있어야 한다(등록부 키가 코드포인트+스타일인 이유).
#define MARU_STYLE_BOLD 1
#define MARU_STYLE_ITALIC 2
void maru_mobile_atlas_geometry(unsigned int cell_w, unsigned int cell_h);
void maru_mobile_atlas_add(unsigned int cp, unsigned int style,
                           unsigned int col, unsigned int row, unsigned int advance);

/// 아직 아틀라스에 없어 못 그린 코드포인트들. 플랫폼이 그것만 구워 넣는다.
/// 고정 집합으로 두면 처음 보는 글자가 **조용히** 안 그려진다(실측으로 드러났다).
unsigned int maru_mobile_missing_count(void);
unsigned int maru_mobile_missing_cp(unsigned int i);
/// i번째 놓친 것의 스타일 비트. 코드포인트와 **함께** 읽어야 어느 폰트로 구울지 안다.
unsigned int maru_mobile_missing_style(unsigned int i);
/// i번째 놓친 것이 **컬러 글리프**(이모지)인가. 1이면 커버리지 아틀라스가 아니라 **컬러
/// 아틀라스**에 구워 `maru_mobile_color_atlas_add` 로 등록한다 — 커버리지에 구우면 실루엣이
/// 되고, 그 반대는 색이 사라진다. 판정은 코어(`width.isEmojiPresentation`)가 단일 출처다.
unsigned int maru_mobile_missing_is_color(unsigned int i);
/// 컬러 아틀라스 등록·슬롯 배정(글자 아틀라스의 add/next_slot 과 짝, 같은 인코딩).
void maru_mobile_color_atlas_add(unsigned int cp, unsigned int style,
                                 unsigned int col, unsigned int row, unsigned int advance);
unsigned int maru_mobile_next_color_slot(unsigned int cols);
unsigned int maru_mobile_color_atlas_count(void);
/// 합성 글리프를 슬롯 버퍼에 채운다. **폰트 경로보다 먼저 부른다** — 박스 드로잉·블록·
/// 브라유·파워라인은 maru 가 절차 합성해 셀을 가장자리까지 채운다(폰트 글리프는 셀에 안 맞아
/// 끊기고 이음매가 보인다). 반환값은 잉크 픽셀 수이고 **0 이면 합성 대상이 아니다**(폰트로).
/// 합성은 슬롯의 **왼쪽 절반**만 쓴다 — 대상이 전부 단폭이고 그리는 쪽도 절반만 샘플링한다.
unsigned int maru_mobile_synthesize(unsigned int cp, unsigned char *out, unsigned int stride);

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

/// 키 입력(**인코딩 전**). 문자·특수키·수정자를 그대로 넘기면 코어의 `encodeKey` 가
/// 터미널 바이트로 만든다 — DECCKM(커서키 모드)·수정자·kitty 프로토콜·application keypad 가
/// 전부 거기 있다. 손으로 `\r`·`0x7F` 를 적어 넣으면 그 전부가 빠진다.
///
/// **이 숫자가 단일 출처다.** 브리지의 매핑과 함께 바꾼다 — 계약 테스트가 헤더를 읽어
/// 미러를 검사하므로, 한쪽만 고치면 테스트가 잡는다.
#define MARU_KEY_CHAR      0   /* codepoint 인자를 쓴다 */
#define MARU_KEY_ENTER     1
#define MARU_KEY_ESCAPE    2
#define MARU_KEY_TAB       3
#define MARU_KEY_BACKSPACE 4
#define MARU_KEY_UP        5
#define MARU_KEY_DOWN      6
#define MARU_KEY_LEFT      7
#define MARU_KEY_RIGHT     8
#define MARU_KEY_HOME      9
#define MARU_KEY_END       10
#define MARU_KEY_INSERT    11
#define MARU_KEY_DELETE    12
#define MARU_KEY_PAGE_UP   13
#define MARU_KEY_PAGE_DOWN 14
/// F1~F12 는 100+n-1 (F1=100 … F12=111).
#define MARU_KEY_F(n)      (99 + (n))

#define MARU_MOD_SHIFT 1
#define MARU_MOD_CTRL  2
#define MARU_MOD_ALT   4
#define MARU_MOD_CMD   8

/// 반환값은 `maru_mobile_input` 과 같은 **코어에 전달한 누적 바이트**다.
unsigned int maru_mobile_key(unsigned int key_id, unsigned int codepoint, unsigned int mods);

/// 포커스 변화를 코어에 알린다(DEC 1004). 켜져 있으면 `CSI I`/`CSI O` 가 흐른다 — vim 의
/// FocusGained/Lost 가 그걸 본다. 모바일은 배경↔복귀가 데스크톱보다 훨씬 잦다.
void maru_mobile_report_focus(int focused);

/// 조합 중 문자열(IME preedit). **코어에 넣지 않는다** — 확정 전에 PTY 로 흘리면 셸이
/// 자모를 명령어 일부로 받는다. 화면 커서 자리에 흐리게 그릴 겉치레다.
void maru_mobile_set_preedit(const char *bytes, unsigned long len);

/// 커서(캐럿) 자리를 논리 px 로. **IME 후보창이 이걸 보고 따라온다** — 조합 중 후보 목록이
/// 엉뚱한 자리에 뜨면 글자를 가린다. x·y·w·h 를 각각 16비트로 담는다(화면 밖이면 0).
unsigned long long maru_mobile_caret_rect(void);
/// 스크롤. **플랫폼은 논리 px 만 넘긴다** — 줄로 환산하려면 셀 높이를 알아야 하는데 그것은
/// 코어 쪽 값이다(플랫폼은 배치를 모른다, docs/mobile-platform.md §3). 한 줄이 안 되는
/// 나머지는 코어가 누적해 두므로 **작은 델타를 여러 번 보내도 잃지 않는다**.
///
/// `dy_px` 는 **손가락이 움직인 방향**이다 — 아래로 끌면 양수이고 과거(위)로 간다.
///
/// 관성·러버밴딩은 플랫폼이 갖는다(§3.1). 코어는 clamp 와 **alt screen 변환**만 한다 —
/// alt + DECSET 1007 이면 뷰포트 대신 화살표 키가 나가고 선택이 풀린다.
void maru_mobile_scroll(float dy_px);

/// 뷰포트를 바닥(활성 화면)으로 되돌린다. 입력이 들어오면 브리지가 **스스로** 부르므로
/// host 가 따로 부를 일은 제스처 취소 같은 자리뿐이다.
void maru_mobile_scroll_to_bottom(void);

/// 지금 스크롤백을 보고 있는가(0=바닥). host 가 스크롤 인디케이터를 그릴 때 쓴다.
unsigned int maru_mobile_view_offset(void);

/// 손가락 하나의 원시 이벤트(논리 px). **무엇으로 해석할지는 코어가 정한다**(§3.1) —
/// 끌면 스크롤이고 길게 누르면 선택이라는 판단이 플랫폼마다 갈리면 안 된다.
///
/// `phase`: 0=down · 1=move · 2=up · 3=cancel.
/// `time_ms`: 단조 증가하는 밀리초. **길게 누름 판정에 쓴다** — 코어에는 시계가 없다.
///
/// 관성만 플랫폼이 갖는다: 손을 뗀 뒤 흘리는 것은 여전히 `maru_mobile_scroll` 로 넣는다.
void maru_mobile_pointer(unsigned int phase, float x, float y, unsigned long long time_ms);

/// **길게 누름 지연을 OS 값으로 맞춘다.** 두 플랫폼 다 사용자 접근성 설정으로 바꿀 수 있어
/// (Android "길게 누르기 지연", iOS "터치 조절 → 유지 시간") 코어가 박아 두면 그 설정을
/// 무시하게 된다. Android 는 `ViewConfiguration.getLongPressTimeout()`, iOS 는
/// `UILongPressGestureRecognizer` 기본값(0.5초)이다. 0 이면 무시(폴백 유지).
void maru_mobile_set_long_press_ms(unsigned int ms);
/// 코어가 실제로 들고 있는 값. host 가 보낸 값을 스스로 로그하는 것으로는 **닿았다는 증명이
/// 안 된다** — 되물어야 안다.
unsigned int maru_mobile_long_press_ms(void);

/// 복사할 것이 있으면 `out` 에 채우고 바이트 수를 답한다(없으면 0). **추출은 코어가 한다** —
/// soft-wrap 잇기·줄끝 개행·2셀 뒷칸 제외가 전부 거기 있다. 플랫폼은 **클립보드에 쓰기만**
/// 한다(브리지엔 OS 호출이 없다, §3).
///
/// 한 번 가져가면 요청은 사라진다. 버퍼가 모자라면 자르고 `copy_truncated` 를 남긴다 —
/// 조용히 자르지 않는다.
unsigned int maru_mobile_take_copy(unsigned char *out, unsigned int cap);

/// 선택 범위(뷰포트 기준, 각 16비트: start_row·start_col·end_row·end_col). **끝 열은 포함**
/// 이다. 선택이 없으면 전부 1. host 가 복사 버튼 자리를 잡을 때 쓴다.
unsigned long long maru_mobile_selection_span(void);

/// 선택이 살아 있는가(1/0). host 가 복사 버튼을 띄울지 정할 때 쓴다.
unsigned int maru_mobile_has_selection(void);

/// 보조 키바 탭(논리 px). **소프트 키보드에는 Ctrl·Esc·Tab·화살표가 없다** — 그것 없이는
/// 프로세스를 못 멈추고(Ctrl+C) vim 에서 못 빠져나온다.
///
/// 1=키바가 먹었다(플랫폼은 더 할 일이 없다), 0=키바 밖이니 본문 처리로 넘어가라.
/// **좌표 해석은 코어 쪽이 한다** — 그리는 자리와 판정하는 자리가 갈리면 눌러도 다른 키가
/// 나간다(docs/mobile-platform.md §3).
unsigned int maru_mobile_keybar_tap(float x, float y);

/// 눌러 둔 수정자(sticky). 0=없음. 화면 표시는 브리지가 이미 하므로 host 가 꼭 볼 필요는
/// 없고, 계측·접근성 라벨에 쓴다.
unsigned int maru_mobile_armed_mods(void);

/// 키바 키 개수와 `index` 번째 사각형(논리 px, x·y·w·h 를 각각 16비트). 아직 안 섰으면 0.
/// 자리를 밖에서 다시 계산하지 말라고 내주는 값이다.
unsigned int maru_mobile_keybar_count(void);
unsigned long long maru_mobile_keybar_rect(unsigned int index);

/// 터치 지점(논리 px) → 셀. 상위 16비트=열, 하위 16비트=행. 본문 밖이면 0xFFFFFFFF.
unsigned int maru_mobile_hit_cell(float x, float y);

#ifdef __cplusplus
}
#endif
#endif
