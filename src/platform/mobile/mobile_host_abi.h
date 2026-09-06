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
/// **지금 구울 크기는 코어에게 묻는다.** 위 매크로는 이제 *기본값*일 뿐이다 — `font.size` 를
/// 바꾸면 이 값이 따라가고, 매크로를 그대로 쓰면 22px 로 구운 그림을 확대해 **흐려진다**.
/// host 는 글자를 굽기 직전에 이것을 부른다(셀에 안 넘치게 코어가 이미 잘라서 준다).
unsigned int maru_mobile_atlas_text_px(void);
/// 표시 주기(comfort). **두 플랫폼이 같은 값을 써야 한다** — 다르면 같은 손짓이 기기마다
/// 다르게 미끄러진다(관성 감쇠가 그리는 횟수를 탄다). 흩어져 있으면 정책을 바꿀 때 한쪽만
/// 고치게 되므로 여기가 단일 출처다: iOS 는 Hz 로 OS 에 선언하고, Android 는 ns 로 경과를
/// 재고, 두 host 의 `MARU_PACE` 로그와 판정은 ms 로 쓴다 — **표현이 셋이지 값은 하나다.**
/// 데스크톱(`render.frame-rate` 기본 60)과는 다른 값이다([계약 §3.2](../../../docs/mobile-platform.md)).
#define MARU_FRAME_TARGET_HZ 30
#define MARU_FRAME_TARGET_NS (1000000000LL / MARU_FRAME_TARGET_HZ)
#define MARU_FRAME_TARGET_MS (1000.0 / MARU_FRAME_TARGET_HZ)
/// `MARU_PACE` 가 PASS 로 볼 창. 목표를 바꾸면 창도 따라 움직이게 **곱으로** 적는다.
/// 폭은 vsync 지터와, 목표가 패널 주기의 정수배가 아닐 때 생기는 **반 주기 오차**를 품는다 —
/// 144Hz→34.7ms · 72Hz→27.8ms · 48Hz→41.7ms 가 전부 참이어야 해서 위쪽이 1.3 이다.
/// **주사율이 목표의 배수가 아니면 목표에 못 닿는다**: 45Hz 패널은 45 나 22.5 뿐이라 30 이
/// 없고, 그 기기는 FAIL 로 나온다 — 회귀가 아니라 사실이다(그때는 이 창이 아니라 그 기기의
/// 도달 가능한 값을 봐야 한다).
#define MARU_FRAME_PACE_MIN_MS (MARU_FRAME_TARGET_MS * 0.75)
#define MARU_FRAME_PACE_MAX_MS (MARU_FRAME_TARGET_MS * 1.30)
/// 그 창에 넣을 표본을 **어떻게 고르는가**. 여기도 두 플랫폼이 같아야 한다 — 판정 기준만
/// 같고 표본이 다르면 두 수를 나란히 놓는 것 자체가 무의미하다(실제로 Android 는 첫
/// 프레임들을 버렸고 iOS 는 안 버려, 같은 이름의 로그가 다른 것을 재고 있었다).
/// **시계까지 같을 필요는 없다** — iOS 는 `CADisplayLink.timestamp`, Android 는
/// `CLOCK_MONOTONIC` 이 각자 가장 정확하고, 둘 다 표시 간격을 잰다.
/// 워밍업은 첫 프레임들을 버린다 — 아틀라스를 굽고 스왑체인이 서는 동안의 간격은 정상
/// 주기가 아니다. 표본은 짝수 개를 모아 위쪽 중앙값(`/2`)을 쓴다.
#define MARU_FRAME_PACE_WARMUP 20
#define MARU_FRAME_PACE_SAMPLES 60
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
/// 구운 글자를 등록한다. **코드포인트 열을 통째로 받는다** — 단일 코드포인트면 `n=1` 이다.
/// `cps` 는 `maru_mobile_missing_cp_at` 로 읽은 **그 열**이어야 한다(다른 열을 넘기면 구운 그림과
/// 등록부가 어긋나 엉뚱한 글리프가 그려진다). 한 글자의 상한은 `MARU_MAX_CLUSTER` 다.
void maru_mobile_atlas_add(const unsigned int *cps, unsigned int n, unsigned int style,
                           unsigned int col, unsigned int row, unsigned int advance);

/// 한 글자가 실을 수 있는 코드포인트 수. 가족 이모지(👨‍👩‍👧‍👦)가 7, 스킨톤이 붙으면 더 길어진다.
#define MARU_MAX_CLUSTER 12

/// 아직 아틀라스에 없어 못 그린 **글자**들. 플랫폼이 그것만 구워 넣는다.
/// 고정 집합으로 두면 처음 보는 글자가 **조용히** 안 그려진다(실측으로 드러났다).
unsigned int maru_mobile_missing_count(void);
/// i번째 놓친 글자의 코드포인트 **개수**. 1이면 단일, 2 이상이면 클러스터다.
unsigned int maru_mobile_missing_len(unsigned int i);
/// i번째 놓친 글자의 j번째 코드포인트.
///
/// **`0..missing_len(i)` 를 이어 붙여 문자열 하나로 구워야 한다.** 코드포인트를 따로 구우면
/// 결합이 안 일어난다 — `❤`(U+2764)와 `❤️`(U+2764 U+FE0F)가 host 에게 같아 보여 VS16 결합이
/// 단색으로 그려지던 것이 그 결함이었다.
unsigned int maru_mobile_missing_cp_at(unsigned int i, unsigned int j);
/// i번째 놓친 것의 스타일 비트. 코드포인트와 **함께** 읽어야 어느 폰트로 구울지 안다.
unsigned int maru_mobile_missing_style(unsigned int i);
/// i번째 놓친 것이 **컬러 글리프**(이모지)인가. 1이면 커버리지 아틀라스가 아니라 **컬러
/// 아틀라스**에 구워 `maru_mobile_color_atlas_add` 로 등록한다 — 커버리지에 구우면 실루엣이
/// 되고, 그 반대는 색이 사라진다. 판정은 **열 전체**를 본다(base 는 코어의
/// `width.isEmojiPresentation`, 그 위에 VS16/VS15 가 표현을 뒤집는다).
unsigned int maru_mobile_missing_is_color(unsigned int i);
/// 컬러 아틀라스 등록·슬롯 배정(글자 아틀라스의 add/next_slot 과 짝, 같은 열 규약).
void maru_mobile_color_atlas_add(const unsigned int *cps, unsigned int n, unsigned int style,
                                 unsigned int col, unsigned int row, unsigned int advance);
unsigned int maru_mobile_next_color_slot(unsigned int cols);
unsigned int maru_mobile_color_atlas_count(void);
/// 합성 글리프를 슬롯 버퍼에 채운다. **폰트 경로보다 먼저 부른다** — 박스 드로잉·블록·
/// 브라유·파워라인은 maru 가 절차 합성해 셀을 가장자리까지 채운다(폰트 글리프는 셀에 안 맞아
/// 끊기고 이음매가 보인다). 반환값은 잉크 픽셀 수이고 **0 이면 합성 대상이 아니다**(폰트로).
/// 합성은 슬롯의 **왼쪽 절반**만 쓴다 — 대상이 전부 단폭이고 그리는 쪽도 절반만 샘플링한다.
unsigned int maru_mobile_synthesize(unsigned int cp, unsigned char *out, unsigned int stride);

/// 다음 슬롯 — 상위 16비트=열, 하위 16비트=행.
///
/// **꽉 차면 가장 안 쓰인 슬롯을 재사용하라고 내준다**(축출). host 는 빈 자리인지 재사용인지
/// 구분할 필요가 없다 — 어느 쪽이든 그 자리에 굽고 `atlas_add` 로 등록하면 된다. 다만 **그 자리의
/// 옛 글리프는 사라지므로 부분 업로드가 슬롯을 완전히 덮어써야 한다**(잔상 방지).
///
/// `0xFFFFFFFF` 는 **이번 프레임에 그려진 글자만 남아 버릴 것이 없다**는 뜻이다(한 화면이 용량을
/// 넘겼다). 그땐 host 가 이번 프레임에 그 글자를 못 그린다.
unsigned int maru_mobile_next_slot(unsigned int cols);
/// 등록된 글자 글리프 수. 축출이 들어온 뒤로는 `next_slot` 만으로 "찼다"를 못 본다(진단·테스트용).
unsigned int maru_mobile_atlas_count(void);
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
/// config 파일 바이트. **파일을 여는 것은 host** 다 — 브리지엔 OS 호출이 없다(docs/mobile-config.md §7).
/// 자리는 iOS `Library/Application Support/maru/config`, Android `filesDir/config`. 파일이 없으면
/// 안 부르면 된다(기본값으로 돈다). 다시 부르면 통째로 갈아 끼운다.
void maru_mobile_load_config(const unsigned char *bytes, unsigned long len);

/* 시스템 외관(다크/라이트)을 코어에 알린다 — `is_dark != 0` 이면 다크. **생성 직후 한 번, 그리고
   바뀔 때마다** 부른다(데스크톱 F2-9 의 `maru_app_set_system_appearance` 와 같은 계약).
   `theme.follow-system` 이 꺼져 있으면 코어가 무시한다 — host 는 그 설정을 안 본다. */
void maru_mobile_set_system_appearance(unsigned int is_dark);

/* 이번 `maru_mobile_build` 가 낸 그림이 **지난 프레임과 다른가**(1=그려야 한다). build 뒤에 읽는다.
   0 이면 host 는 GPU 작업(획득·제출·프레젠트)을 통째로 건너뛴다 — 터미널은 대부분의 시간이
   정지 화면이라 여기서 얻는 것이 가장 크다(M14).

   **페이싱을 재는 동안에는 안 쉰다.** `MARU_PACE` 는 프레젠트 간격을 재는 판정자인데, 쉰 간격이
   섞이면 그 판정이 죽는다(정지 화면에서도 표본을 채우고 있었다). 그 측정은 시작할 때 정해진
   표본 수만 채우고 끝나므로, host 는 **끝난 뒤부터** 쉰다 — 판정자도 살고 테스트 전용 스위치도
   필요 없다. 건너뛴 tick 은 기준(`last_ms`)도 끊어 다음 프레임이 «쉰 만큼» 을 간격으로 안 세게 한다.

   빌드 자체는 매 tick 그대로 돈다 — 관성 감쇠·길게 누름 승격이 멈추면 안 되기 때문이다. */
unsigned int maru_mobile_frame_changed(void);

/* ── 접근성 서술자(M9) ─────────────────────────────────────────────────────────
   누를 수 있는 면을 스크린 리더에게 넘길 형태로 낸다. 계약은 데스크톱 것을 그대로 쓴다
   (CIM §3 — `chrome/ui/semantics.zig` 의 `Role`·`Semantics`).

   **build 뒤에 읽는다.** 프레임마다 다시 만들어지므로 index 는 그 프레임 안에서만 뜻이 있다.
   없는 index 는 정직하게 답한다(rect 0 · role 0xFFFFFFFF · state 0 · label 길이 0) — 옛 자리를
   돌려주면 없는 버튼이 읽힌다.

   host 는 이것을 네이티브 요소로 투영한다: iOS `UIAccessibilityElement`,
   Android `AccessibilityNodeInfo`. **그 어댑터가 서기 전까지는 아무도 못 듣는다.** */
unsigned int maru_mobile_a11y_count(void);

/* 자리. `maru_mobile_keybar_rect` 와 **같은 꾸림**이다: (x<<48)|(y<<32)|(w<<16)|h. */
unsigned long long maru_mobile_a11y_rect(unsigned int index);

/* 역할 — `chrome/ui/semantics.zig` 의 `Role` 순번(0=button, 1=tree_item, 2=list_item,
   3=tab, 4=scroll_view, 5=text, 6=group). */
unsigned int maru_mobile_a11y_role(unsigned int index);

/* 상태 비트. **한 번에 읽어 간다** — 항목마다 호출을 넷 하면 그 사이에 프레임이 바뀌어 서로 다른
   프레임의 값을 섞는다. bit0 enabled · bit1 selected · bit2 focusable ·
   bit3 「펼침이라는 개념이 있는가」 · bit4 그 값. */
unsigned int maru_mobile_a11y_state(unsigned int index);

/* 이름을 `out` 에 **복사**하고 길이를 답한다(잘리면 잘린 길이). 가리키는 것은 다음 프레임에
   사라질 수 있어서 포인터를 안 준다. */
unsigned long maru_mobile_a11y_label(unsigned int index, unsigned char *out, unsigned long cap);
/// config 파일 크기 상한. **헤더가 단일 출처다** — host 마다 숫자를 적으면 갈린다(실제로 갈렸다:
/// Android 64KB 잘라 쓰기 · iOS 무제한 · 데스크톱 1MB). 데스크톱과 같은 값으로 둔다.
///
/// **넘치면 안 읽는다 — 자른 앞부분을 쓰지 않는다.** 잘린 config 는 "절반만 적용된 설정" 이라
/// 사용자가 무엇이 먹었는지 알 수 없다. 계약은 "없음·권한·크기 초과는 전부 기본값" 이다
/// (docs/mobile-config.md §7).
#define MARU_CONFIG_MAX_BYTES (1u << 20)

/// **관성은 코어가 든다.** 전에는 이 헤더가 감쇠·상한을 host 에 나눠 줬는데, 그러려면 host 가
/// "이 제스처가 본문 것인가" 를 알아야 했다 — 그 지식을 R2 가 걷어내자 **가드만 사라지고 재는
/// 코드가 남아** 키바를 비스듬히 튕겨도 본문이 흘렀다. 지금은 본문·키바·설정이 모두
/// `chrome.ui.scroll_area.Touch` 의 값 하나로 흐르고 host 는 좌표만 나른다(§3.1).

/// 코어가 실제로 들고 있는 스크롤백 줄 수(진단·테스트용). config 가 코어에 **닿았는지**는
/// 코어에 물어야 안다 — 파싱된 값을 되읽으면 "닿았다" 를 재는 것이 아니다. host 는 안 쓴다.
unsigned int maru_mobile_scrollback_lines(void);
/// 저장할 config 본문을 가져간다(한 번 가져가면 요청이 사라진다 — `take_copy` 와 같은 규율).
/// 0 이면 저장할 것이 없다. **버퍼가 모자라면 0** 이고 `last_error` 에 남는다 — 잘린 config 를
/// 쓰면 설정이 반만 남는다. host 는 이 바이트를 §2 경로에 **통째로** 쓴다.
unsigned long maru_mobile_take_config_write(unsigned char *out, unsigned long cap);
/// 지금 무엇을 입력받고 있나 — **키보드 종류를 host 가 이 값으로 고른다**. 0=글자(터미널),
/// 1=숫자(설정의 숫자 칸), 2=문자열(설정의 글자 칸). 브리지가 정하는 이유는 "무엇을 누르고
/// 있나" 를 아는 쪽이 거기라서다.
///
/// **1 과 2 를 가르는 것은 키보드 배열이고, 0 과 2 를 가르는 것은 목적지다.** 둘을 같은 0 으로
/// 말하면 host 는 "설정 칸을 편집 중" 을 못 본다 — 하드웨어 키보드로 친 글자가 터미널로 갈지
/// 설정 칸으로 갈지 고를 수 없어 **조용히 사라졌다**(블루투스 키보드로 색을 못 쳤다).
///
/// **터미널은 계속 글자다** — 거기서 ASCII 배열을 요구하면 한글 입력이 불편해진다
/// (docs/mobile-platform.md §IME). 숫자 칸만 숫자 패드로 바꾼다: 조합이 없어 IME 위험도 없다.
///
/// 값이 바뀌면 host 는 **이미 떠 있는 키보드를 갈아 끼워야** 한다(iOS `reloadInputViews`,
/// Android `restartInput`). 안 그러면 종류만 바뀌고 화면의 키보드는 그대로다.
unsigned int maru_mobile_input_kind(void);
/// 키보드를 올려 달라는 요청을 가져간다(1=올려라, 0=없음 — 한 번 가져가면 사라진다).
/// 앱은 시작할 때 입력 대상을 잡고 그 뒤로 키보드 상태를 안 건드리므로, 사용자가 한 번 내리면
/// **다시 올릴 길이 없다** — 숫자 칸을 눌렀는데 키보드가 없으면 칠 수가 없다.
unsigned int maru_mobile_take_keyboard_raise(void);
/// 키보드를 내려 달라는 요청을 가져간다(1=내려라, 0=없음 — 한 번 가져가면 사라진다).
/// 앱은 터미널을 위해 키보드를 늘 띄워 두는데, 그대로 다른 화면에 가면 **쓸 데가 없는 자판이
/// 화면 절반을 먹는다**. 터미널과 비밀번호 물음은 예외다(들어가자마자 치는 자리).
unsigned int maru_mobile_take_keyboard_hide(void);
/// 원격 연결을 끊어 달라는 요청을 가져간다(1=끊어라, 0=없음 — 한 번 가져가면 사라진다).
/// 브리지는 소켓을 모른다(§2) — 사용자가 앱 바의 그 자리를 눌렀다는 사실만 여기로 넘기고,
/// 펌프를 세우는 것은 host 가 한다.
///
/// **뒤로가기와 다르다.** 뒤로가기는 화면만 빠져나오고 연결은 그대로 두므로(목록으로 돌아가도
/// 세션은 산다), 사용자 뜻으로 놓을 길이 따로 필요하다.
unsigned int maru_mobile_take_disconnect(void);
/// 소프트 키보드가 사라졌다고 알린다. 편집 중이던 칸이 있으면 확정하고 거둔다 —
/// 키보드 없이 편집만 남으면 **칠 수 없는 편집 중**이 된다.
void maru_mobile_keyboard_hidden(void);

/// 커서(캐럿) 자리를 논리 px 로. **IME 후보창이 이걸 보고 따라온다** — 조합 중 후보 목록이
/// 엉뚱한 자리에 뜨면 글자를 가린다. x·y·w·h 를 각각 16비트로 담는다(화면 밖이면 0).
unsigned long long maru_mobile_caret_rect(void);
/// **손가락 델타를 받는 자리는 없다.** 전에는 `maru_mobile_scroll(float)` 이 있었고 host 의
/// 관성 루프가 그것을 불렀다 — 관성이 코어로 오면서 부르는 host 가 하나도 안 남아 내렸다.
/// 손가락이 넣는 것은 **원시 포인터 이벤트뿐**이다(§3.1).
///
/// **마우스·트랙패드는 다르다.** 그쪽은 `down`/`up` 이 없고 델타가 곧 이벤트라 아래 진입점으로
/// 받는다. `precise != 0` 이면 델타가 **논리 px**(트랙패드), 0 이면 **노치**(휠)다 — 노치가 몇
/// 줄인지는 코어가 정한다(macOS 는 그 수를 이벤트에 이미 실어 보내고 Android 는 1 만 준다).
/// 부호는 손가락과 같다: 양수면 과거(위)로 간다. **가로(`delta_x`)는 아직 안 쓴다** — 모바일의
/// 가로 스크롤 면은 키바뿐이고 마우스로 그것을 굴릴 이유가 없다(서명을 두 번 안 바꾸려고 받아만 둔다).
/// `x`·`y` 는 가리키는 자리(논리 px) — 어느 면을 굴릴지는 코어가 정한다.
void maru_mobile_wheel(float delta_y, float delta_x, unsigned int precise, float x, float y);


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
/// **관성도 코어가 든다** — 손을 뗀 뒤 흘리는 것은 프레임(`maru_mobile_build`)에서 돈다.
/// host 가 들면 목적지를 몰라 남의 제스처까지 흘린다(그 결함을 실제로 겪었다).
/// `pointer_id`: **host 가 주는 불투명한 정수.** 보장은 하나뿐이다 — `down` 부터 그 손가락의
/// `up`/`cancel` 까지 같다. 값의 범위도 재사용 규칙도 코어가 가정하지 않는다(Android 슬롯 id 는
/// 재사용되고, iOS `UITouch` 는 숫자 id 가 없어 host 가 매핑을 든다). 소유권·이어받기 규칙은
/// **코어가 갖는다**(docs/mobile-platform.md §3.1) — host 에 두면 두 벌이 되고 두 벌은 갈린다.
void maru_mobile_pointer(unsigned int phase, unsigned int pointer_id, float x, float y, unsigned long long time_ms);

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
/// **터치 진입점은 하나뿐이다**(R2). 전에는 `keybar_pointer`·`chrome_pointer` 가 따로 있고
/// host 가 "누가 먹었나" 를 들고 골랐는데, 같은 사실을 두 층이 들다 보니 정리도 두 곳에서 해야
/// 했고 한쪽을 빠뜨려 **복귀 후 첫 손짓이 통째로 삼켜지는** 결함이 났다(같은 모양을 세 번 겪었다).
/// 지금은 `maru_mobile_pointer` 하나가 받고 **어디로 갈지는 코어가 정한다**
/// (docs/mobile-platform.md §3.1 — chrome → 키바 → 본문 순).

/// 밀린 화면을 하나 뺀다(Android 하드웨어 뒤로가기 · iOS 좌측 가장자리 스와이프).
/// 1=뺐다, 0=뺄 것이 없다 — 0이면 host 가 자기 관례대로 처리한다(Android 는 앱을 내린다).
unsigned int maru_mobile_pop_screen(void);

/// 눌러 둔 수정자(sticky). 0=없음. 화면 표시는 브리지가 이미 하므로 host 가 꼭 볼 필요는
/// 없고, 계측·접근성 라벨에 쓴다.
unsigned int maru_mobile_armed_mods(void);

/// 키바 키 개수와 `index` 번째 사각형(논리 px, x·y·w·h 를 각각 16비트). 아직 안 섰으면 0.
/// 자리를 밖에서 다시 계산하지 말라고 내주는 값이다.
unsigned int maru_mobile_keybar_count(void);
unsigned long long maru_mobile_keybar_rect(unsigned int index);

/// 터치 지점(논리 px) → 셀. 상위 16비트=열, 하위 16비트=행. 본문 밖이면 0xFFFFFFFF.
unsigned int maru_mobile_hit_cell(float x, float y);

/// ── SSH 세션 ────────────────────────────────────────────────────────────────
///
/// **브리지는 소켓을 모른다**(§3 — 이 층에 OS 호출이 0이다). host 가 TCP 를 들고, 읽은 바이트를
/// `feed` 로 밀어 넣고 `out` 에 쌓인 바이트를 내보낸다. 프로토콜 판단은 전부 코어가 한다
/// (계약: docs/ssh-client.md §2).
///
/// **여기만 핸들을 쓴다.** 나머지 모바일 ABI 는 화면이 하나라는 전제의 싱글턴이지만, 원격 세션은
/// 여러 개일 수 있고 **재접속은 새 세션**이다(SSH 에는 재개가 없다 — 계약 §4.1). 핸들에는 세대가
/// 섞여 있어, 닫은 뒤 남은 옛 핸들로 새 세션을 건드릴 수 없다.
///
/// **스레드는 host 가 든다**(§3). Android 는 소켓 스레드와 그리기 스레드가 다르므로 브리지 호출을
/// 같은 자물쇠로 직렬화해야 한다 — 이 함수들도 그 자물쇠 안이다.
/// 동시에 들 수 있는 세션 수. **자리는 미리 잡아 둔다**(고정 주소가 필요하다 — 코어가 교환
/// 해시에 쓸 원문을 안에 들고 있어 복사·이동하면 어긋난다). 실측으로 세션 하나가 약 109KiB,
/// 넷이면 약 435KiB 다 — 늘리면 그만큼 상주 메모리가 는다.
#define MARU_SSH_MAX_SESSIONS 4
/// `seed(32) ‖ public(32)`. host 가 Keychain·Keystore 에서 꺼내 온다(계약 §3.4).
#define MARU_SSH_SECRET_KEY_BYTES 64
/// **난수의 근원은 host 다.** 이 층은 OS 를 못 부르는데 SSH 는 임시키·패딩·cookie 에 예측
/// 불가능한 바이트가 필요하다 — `SecRandomCopyBytes`(iOS) · `SecureRandom`(Android)에서 채운다.
/// 예측 가능한 값을 주면 그 세션의 비밀이 통째로 깨진다.
#define MARU_SSH_ENTROPY_BYTES 32
#define MARU_SSH_MAX_USER 64
#define MARU_SSH_MAX_TERM 32
/// 등록할 수 있는 서버 수. **자리를 미리 잡아 두므로 숫자가 곧 상주 메모리다**(브리지엔 할당이
/// 없다). config 의 `ssh.server.<n>.*` 에서 오고, 넘는 번호는 무시한다
/// (단일 출처: docs/mobile-config.md §4.3).
#define MARU_MAX_SERVERS 16

/// `maru_mobile_server_field` 가 무엇을 달라는지. **포트는 여기 없다** — 숫자라
/// `maru_mobile_server_port` 가 따로 답한다(문자열로 주면 host 가 다시 파싱해야 한다).
#define MARU_SERVER_NAME 0
#define MARU_SERVER_HOST 1
#define MARU_SERVER_USER 2
#define MARU_SERVER_FINGERPRINT 3
/// 세션 하나가 드는 버퍼. **선(out)은 최소 한 걸음(4KiB)보다 넉넉해야** 하고, 화면은 채널 패킷
/// 하나(32KiB)가 들어가야 한다 — 못 담으면 코어가 한 발도 못 나간다(계약 §3.5).
#define MARU_SSH_OUT_BYTES 32768
#define MARU_SSH_SCREEN_BYTES 65536
/// 컨트롤 채널이 받아 둘 자리. 코어가 그 채널에 광고하는 한 패킷(8KiB)의 **두 배**다 —
/// 한 패킷 몫만 대면 `feed` 한 번에 패킷 하나씩만 지난다(계약 docs/ssh-client.md §3.4.1).
#define MARU_SSH_CONTROL_BYTES 16384
/// 컨트롤 채널이 돌릴 명령의 최대 길이. **자르지 않는다** — 넘으면 `MARU_SSH_ERR_BAD_ARG`.
#define MARU_SSH_CONTROL_COMMAND_BYTES 512

/// 컨트롤 채널 상태. **터미널 상태(`MARU_SSH_STATE_*`)와 다른 축이다** — 컨트롤이 어떻게 되든
/// 터미널은 산다(계약 docs/control-plane.md §4a).
#define MARU_SSH_CONTROL_NONE 0
#define MARU_SSH_CONTROL_OPENING 1
#define MARU_SSH_CONTROL_REQUESTING_EXEC 2
#define MARU_SSH_CONTROL_READY 3
#define MARU_SSH_CONTROL_CLOSED 4

/// 상태. **숫자는 이 헤더가 단일 출처다** — 브리지가 코어 enum 을 여기 값으로 명시적으로
/// 옮기므로 Zig 쪽 선언 순서가 바뀌어도 host 가 읽는 값은 안 움직인다(계약 테스트가 대조한다).
#define MARU_SSH_STATE_IDLE 0
#define MARU_SSH_STATE_VERSION_EXCHANGE 1
#define MARU_SSH_STATE_NEGOTIATING 2
#define MARU_SSH_STATE_KEY_EXCHANGE 3
/// **사용자에게 물어야 한다**(TOFU — 계약 §4). 답하기 전에는 한 발도 안 나간다.
#define MARU_SSH_STATE_HOST_KEY_DECISION 4
#define MARU_SSH_STATE_AWAITING_NEW_KEYS 5
#define MARU_SSH_STATE_REQUESTING_SERVICE 6
#define MARU_SSH_STATE_AUTHENTICATING 7
#define MARU_SSH_STATE_OPENING_CHANNEL 8
#define MARU_SSH_STATE_REQUESTING_PTY 9
#define MARU_SSH_STATE_STARTING_SHELL 10
/// 셸이 떴다 — 화면 바이트가 오고 키 입력을 보낼 수 있다.
#define MARU_SSH_STATE_READY 11
#define MARU_SSH_STATE_CLOSED 12
/// **비밀번호를 사용자에게 물어야 한다.** 키가 거절됐고 서버가 `password` 를 열어 뒀다 —
/// `maru_mobile_ssh_password` 를 부르기 전에는 한 발도 안 나간다(호스트키 승인과 같은 모양).
/// 비밀번호를 코어가 안 들고 있기 때문이다(계약 §3.4: 저장하지 않는다 — 묻고 지운다).
#define MARU_SSH_STATE_PASSWORD_NEEDED 13
/// 핸들이 틀렸다(이미 닫았거나 세대가 지났다).
#define MARU_SSH_STATE_INVALID 0xFFFFFFFFu

/// 결과 코드. 0=성공, 음수=실패. **이름 문자열만으로는 부족하다** — 호스트키 승인과 인증 실패는
/// UI 가 다르고, host 가 그 둘을 코드로 갈라야 한다(나머지 모바일 ABI 의 `last_error` 관례는
/// 진단용으로 그대로 있다: `maru_mobile_ssh_last_error`).
#define MARU_SSH_OK 0
#define MARU_SSH_ERR_BAD_HANDLE (-1)
#define MARU_SSH_ERR_NO_SLOT (-2)
#define MARU_SSH_ERR_BAD_ARG (-3)
/// 호스트키를 아직 승인 안 했거나, 서명이 안 맞는다 — 사용자에게 지문을 보이고 물어야 한다.
#define MARU_SSH_ERR_HOST_KEY (-4)
#define MARU_SSH_ERR_AUTH (-5)
#define MARU_SSH_ERR_PROTOCOL (-6)
/// 아직 셸이 안 떴다(또는 `open` 전이다).
#define MARU_SSH_ERR_NOT_READY (-7)
/// 버퍼가 찼다 — **오류가 아니라 배압이다.** `out`·`screen` 을 비우고 다시 부른다.
#define MARU_SSH_ERR_BUFFER (-8)
/// **서버가 비밀번호를 바꾸라고 한다**(RFC 4252 §8 — 만료된 계정). `MARU_SSH_ERR_AUTH` 와
/// 가르는 이유는 사용자가 할 일이 다르기 때문이다 — 다시 쳐도 안 되고, 서버에서 바꿔야 한다.
#define MARU_SSH_ERR_PASSWORD_CHANGE (-9)

/// 세션을 연다. 성공이면 `*out_handle` 에 핸들이 들어가고 **버전 줄이 이미 `out` 에 쌓여 있다** —
/// 여는 것과 첫 바이트를 내는 것을 나누면 host 가 한쪽을 잊는다.
///
/// `secret_key`(64B)와 `entropy`(32B)는 **복사한 뒤 호출자가 지운다.** 브리지도 `close` 에서 지운다.
/// `window` 0=기본(2MiB). `pty` 0 이면 stdout·stderr 가 따로 온다(계약 §3.5).
/// **`secret` 은 NULL 일 수 있다** — 키가 아직 없는 기기다. 그때는 `none` 으로 방법 목록만 물어
/// (RFC 4252 §5.2) 비밀번호만 여는 서버에 붙는다. 키가 없다고 시작조차 안 하면 그 서버에는
/// 영영 못 붙는다(iOS 가 그랬다).
int maru_mobile_ssh_open(const unsigned char *user, unsigned int user_len,
                         const unsigned char *secret_key, const unsigned char *entropy,
                         const unsigned char *term, unsigned int term_len,
                         unsigned int cols, unsigned int rows, unsigned int window,
                         unsigned int pty, unsigned int *out_handle);
/// **사용자가 친 비밀번호를 넣는다**(`MARU_SSH_STATE_PASSWORD_NEEDED` 에서만 뜻이 있다).
/// 코어는 그 값을 **안 들고 있는다** — 요청 패킷으로 만들어 `out` 에 내보내고 만든 자리를 지운다.
/// host 도 넘긴 뒤 자기 버퍼를 지운다(계약 §3.4).
///
/// 그 자리가 아니면 `MARU_SSH_ERR_NOT_READY`. 보낼 바이트는 `out` 에 쌓이므로 평소처럼
/// `out_ptr`/`out_len`/`out_consume` 로 내보낸다.
int maru_mobile_ssh_password(unsigned int handle, const unsigned char *password, unsigned int len);

/// 닫는다. **비밀을 지운다**(개인키·세션키). 이미 닫힌 핸들이면 `MARU_SSH_ERR_BAD_HANDLE`.
int maru_mobile_ssh_close(unsigned int handle);
/// 지금 상태(`MARU_SSH_STATE_*`). 핸들이 틀리면 `MARU_SSH_STATE_INVALID`.
unsigned int maru_mobile_ssh_state(unsigned int handle);

/// 소켓에서 읽은 바이트를 먹인다. `*consumed` 에 **먹은 만큼**이 들어가고, 나머지는 host 가
/// 다음에 다시 준다(덜 온 패킷은 못 먹는다). 버퍼가 차면 `MARU_SSH_ERR_BUFFER` — 비우고 다시.
int maru_mobile_ssh_feed(unsigned int handle, const unsigned char *bytes, unsigned int len,
                         unsigned int *consumed);
/// 키 입력을 보낸다. **상대가 허락한 만큼만 나간다**(흐름 제어 — 계약 §3.1). `*sent` 가 보낸 양이고
/// 나머지는 호출자가 다음에 다시 준다.
int maru_mobile_ssh_write(unsigned int handle, const unsigned char *bytes, unsigned int len,
                          unsigned int *sent);
/// 창 크기가 바뀌었다(`window-change`).
int maru_mobile_ssh_resize(unsigned int handle, unsigned int cols, unsigned int rows);
/// 더 보낼 것이 없다(`CHANNEL_EOF`).
int maru_mobile_ssh_eof(unsigned int handle);

/// 선에 내보낼 바이트. **`consume` 을 부를 때까지 남아 있다** — 소켓이 부분만 받아도 잃지 않는다.
const unsigned char *maru_mobile_ssh_out_ptr(unsigned int handle);
unsigned int maru_mobile_ssh_out_len(unsigned int handle);
int maru_mobile_ssh_out_consume(unsigned int handle, unsigned int n);
/// 화면에 그릴 바이트(원격 stdout·stderr). 규칙은 `out` 과 같다.
const unsigned char *maru_mobile_ssh_screen_ptr(unsigned int handle);
unsigned int maru_mobile_ssh_screen_len(unsigned int handle);
int maru_mobile_ssh_screen_consume(unsigned int handle, unsigned int n);

/// **두 번째 채널** — 같은 연결 위에서 원격 명령 하나를 돌린다(계약 docs/control-plane.md §4a).
/// 폰이 세션 목록을 받는 길이고, 터미널 채널과 **서로를 안 죽인다**.
///
/// 여는 것은 **사용자가 목록을 보려 할 때**다 — 채널을 여는 것은 그 서버에서 명령을 하나
/// 실행하는 일이라 감사 로그에 남는다. 터미널만 쓰는 접속에서는 열지 않는다.
///
/// `MARU_SSH_STATE_READY` 에서만 열 수 있고, 재키잉 중이면 `MARU_SSH_ERR_NOT_READY` 다
/// (그때는 아무것도 안 나갔으니 **다시 부르면 된다**).
///
/// **순서 실수는 세션을 죽이는 코드로 안 온다.** 이미 열려 있으면 `MARU_SSH_ERR_BAD_ARG`
/// (`control_already_open`), 닫는 중이면 `MARU_SSH_ERR_NOT_READY`(`control_closing`) 다 —
/// 둘 다 연결은 멀쩡하다. `MARU_SSH_ERR_PROTOCOL` 은 "세션은 못 산다" 는 뜻이므로 이 자리에
/// 오면 host 가 **멀쩡한 연결을 접는다**.
int maru_mobile_ssh_open_control(unsigned int handle, const unsigned char *cmd,
                                 unsigned int cmd_len);
/// 컨트롤 채널로 보낸다. 터미널 `write` 와 같은 규약 — 보낸 만큼을 `sent` 로 알려 준다.
int maru_mobile_ssh_write_control(unsigned int handle, const unsigned char *bytes,
                                  unsigned int len, unsigned int *sent);
/// 컨트롤 채널을 닫는다. **터미널은 그대로 산다.**
int maru_mobile_ssh_close_control(unsigned int handle);
/// 컨트롤 채널 상태(`MARU_SSH_CONTROL_*`). 핸들이 틀리면 `MARU_SSH_STATE_INVALID`.
unsigned int maru_mobile_ssh_control_state(unsigned int handle);
/// 컨트롤 채널이 받은 바이트(ndjson). **화면과 섞이지 않는다.** 규칙은 `out`·`screen` 과 같다 —
/// `consume` 을 부를 때까지 남아 있고, **줄 경계가 아니다**(host 가 줄 단위로 이어 붙인다).
const unsigned char *maru_mobile_ssh_control_ptr(unsigned int handle);
unsigned int maru_mobile_ssh_control_len(unsigned int handle);
int maru_mobile_ssh_control_consume(unsigned int handle, unsigned int n);
/// 컨트롤 명령의 종료 코드. **`127` 이면 그 서버에 `maru` 가 없다**(채널 요청 자체는 성공한다).
/// 아직 안 끝났으면 `MARU_SSH_ERR_NOT_READY`.
int maru_mobile_ssh_control_exit_status(unsigned int handle, unsigned int *code);
/// 컨트롤 명령이 stderr 로 낸 첫 조각(진단용). 화면에도 wire 에도 안 섞인 것이다.
const char *maru_mobile_ssh_control_stderr(unsigned int handle);

/// 호스트키 지문(`SHA256:...`). `MARU_SSH_STATE_HOST_KEY_DECISION` 에서 사용자에게 보인다.
/// 아직 없으면 빈 문자열. 다음 호출까지 산다.
const char *maru_mobile_ssh_host_key_fingerprint(unsigned int handle);
/// 사용자가 승인했다. 이 뒤에야 다음 발이 나간다.
int maru_mobile_ssh_accept_host_key(unsigned int handle);

/// 지금까지 키를 몇 번 갈았나(재키잉). 오래 산 세션은 반드시 이 길을 지난다 — 검증이 "쟀다" 고
/// 말하려면 이 값이 0 이 아니어야 하고, 기기 로그에서는 세션 수명의 가늠자다.
unsigned int maru_mobile_ssh_rekeys(unsigned int handle);
/// 서버가 끊은 이유(RFC 4253 §11.1). 0=안 끊겼다. 설명은 **이미 걸러져 있다**(제어문자 제거).
unsigned int maru_mobile_ssh_disconnect_reason(unsigned int handle);
const char *maru_mobile_ssh_disconnect_description(unsigned int handle);
/// 서버 배너(법적 고지 등). 없으면 빈 문자열. 이것도 걸러져 있다.
const char *maru_mobile_ssh_banner(unsigned int handle);
/// 셸이 끝났으면 `MARU_SSH_OK` 와 `*code`, 아직이면 `MARU_SSH_ERR_NOT_READY`.
int maru_mobile_ssh_exit_status(unsigned int handle, unsigned int *code);
/// 신호로 죽었으면 그 이름(`SIG` 접두 없이). 아니면 빈 문자열.
const char *maru_mobile_ssh_exit_signal(unsigned int handle);

/// 마지막 실패 이름(코어 오류 이름 그대로). **읽은 쪽이 비운다** — §5 의 규율을 따른다.
const char *maru_mobile_ssh_last_error(unsigned int handle);
void maru_mobile_ssh_clear_error(unsigned int handle);

/// **기기에서 키쌍을 만든다**(계약 §3.4 — 키는 앱이 만들고 개인키는 기기 밖으로 안 나간다).
///
/// `entropy`(32B)가 곧 개인키의 씨앗이다 — 예측 가능한 값을 주면 그 키로 지킬 수 있는 것이
/// 없다. 0 은 거절한다. 나오는 것은 `open` 에 넘길 64바이트와, 사용자가 서버
/// `authorized_keys` 에 붙일 한 줄(`ssh-ed25519 <base64> maru`, NUL 로 끝난다)이다.
/// 자리가 모자라면 실패한다 — 잘린 공개키는 붙여도 안 먹는다.
int maru_mobile_ssh_generate_key(const unsigned char *entropy, unsigned char *out_secret,
                                 unsigned char *out_line, unsigned int line_cap);

/// **이미 있는 키의 한 줄**을 만든다(`seed ‖ public` 64바이트 → `ssh-ed25519 <base64> maru`).
/// 만들 때만 한 줄을 내주면 **다시 켠 기기에서는 그 줄을 영영 못 본다** — 그때는 만드는 일이
/// 안 일어나기 때문이다(Keystore 복원·파일 읽기). 실패 이유는 `maru_mobile_ssh_last_load_error`.
int maru_mobile_ssh_public_key_line(const unsigned char *secret, unsigned char *out_line,
                                    unsigned int line_cap);

/// 개인키 파일 내용(PEM 텍스트)에서 `seed(32) ‖ public(32)` 를 만든다. **파일은 host 가 읽는다** —
/// 이 층은 OS 를 모른다. 나온 64바이트를 `open` 에 넘긴 뒤 host 는 **자기 사본을 지운다**.
/// 암호 걸린 키면 `passphrase` 를 준다(없으면 길이 0). 실패하면 `MARU_SSH_ERR_BAD_ARG` 이고
/// 이유는 `maru_mobile_ssh_last_load_error`.
int maru_mobile_ssh_load_key(const unsigned char *pem, unsigned int pem_len,
                             const unsigned char *passphrase, unsigned int pass_len,
                             unsigned char *out_secret);
/// 키 읽기 실패 이름(세션이 아직 없어 세션별 자리에 못 남긴다).
const char *maru_mobile_ssh_last_load_error(void);

/// 원격 출력을 화면에 넣는다. `maru_mobile_ssh_screen_*` 에서 가져온 바이트를 그대로 준다.
/// 반환값은 **코어에 닿은 누적 바이트** — 안 늘면 안 닿은 것이고 이유는 `maru_mobile_last_error`.
unsigned long maru_mobile_term_write(const unsigned char *bytes, unsigned long len);
/// 확정된 입력이 **어디로 가나**. 0=로컬 코어(기본), 1=host 가 가져간다(원격 세션).
///
/// **원격에 붙으면 입력은 코어로 가면 안 된다.** 코어에 쓰는 것은 *출력*을 그리는 일이라,
/// 그렇게 두면 사용자가 친 글자가 화면에 한 번 찍히고 원격에는 영영 안 간다. 인코딩(수정자·
/// 특수키·IME 확정)은 코어 몫이므로 그대로 두고 **목적지만** 가른다.
void maru_mobile_set_input_sink(unsigned int sink);
unsigned int maru_mobile_input_sink(void);
/// 원격으로 보낼 바이트를 가져간다. **가져가면 사라진다.** 자리가 모자라면 0 이고 아무것도
/// 안 지운다 — 잘라 보내면 명령이 반만 나간다. 셸이 뜨기 전에 친 글자도 여기 모였다가 함께
/// 나간다(type-ahead).
unsigned long maru_mobile_take_input(unsigned char *out, unsigned long cap);

/// ── 등록한 서버 목록 ────────────────────────────────────────────────────────
///
/// **접속 정보는 config 가 든다**(`ssh.server.<n>.*` — docs/mobile-config.md §4.3). 브리지가
/// 파싱해 들고 host 는 이 함수들로만 본다. host 가 파일을 다시 해석하면 화면이 고른 것과 갈린다.
///
/// **이름이 `maru_mobile_ssh_*` 가 아닌 이유**: 그 계열은 *세션 하나*를 다루고 전부
/// `mobile_ssh.zig` 에 산다(계약 테스트가 그 전제로 개수까지 센다). 여기 있는 것은 세션이 아니라
/// **config 에서 나온 목록**이라 브리지가 답한다 — 같은 이름표를 붙이면 그 게이트가 거짓이 된다.

/// 등록된 서버 수(0..`MARU_MAX_SERVERS`). **번호는 순서다** — config 의 번호가 아니라
/// 목록에서의 자리다(빈 번호는 읽을 때 앞으로 당겨진다).
unsigned int maru_mobile_server_count(void);
/// 그 서버의 문자열 값(`MARU_SERVER_*`)을 채운다. 반환값은 채운 바이트 수. **끝에 0 을
/// 안 붙인다** — 길이로 다룬다(다른 take 계열과 같은 규율). 자리가 모자라거나 번호·종류가
/// 틀리면 0 이고 아무것도 안 쓴다.
unsigned long maru_mobile_server_field(unsigned int index, unsigned int field,
                                           unsigned char *out, unsigned long cap);
/// 그 서버의 포트. 번호가 틀리면 0 이다(0 은 붙을 수 없는 포트라 그대로 오류 신호가 된다).
unsigned int maru_mobile_server_port(unsigned int index);
/// **어느 서버에 붙어 달라는 요청**을 가져간다(0=없음, 아니면 **번호+1**). 한 번 가져가면
/// 사라진다 — 두 번 붙으면 세션이 둘 생긴다.
///
/// 요청을 세우는 쪽이 브리지인 이유는 **누르는 화면이 거기**라서다. 지금은 목록 화면이 없어
/// 첫 config 를 읽을 때 온전한 첫 서버를 **한 번만** 자동으로 요청한다(임시 — S9b-2b 가 그
/// 자리를 화면 탭으로 바꾼다). 매번 요청하면 배경에서 돌아올 때마다 다시 붙는다.
unsigned int maru_mobile_take_server_connect(void);

/// **이 기기의 공개키 한 줄**을 알린다(`ssh-ed25519 <base64> maru`). 키는 host 가 들고
/// (Keystore·앱 전용 파일) 브리지는 화면에 보여 주고 클립보드로 넘기는 일만 한다.
///
/// **접속 전에 알려야 한다** — 사용자는 그 줄을 서버 `authorized_keys` 에 붙여야 처음 붙을 수
/// 있다. 접속할 때 처음 열면 순서가 거꾸로다(붙어야 볼 수 있고, 보려면 붙어야 한다).
/// 길이가 자리보다 길면 **안 받고** `public_key_too_long` 을 남긴다 — 반쪽 공개키를 서버에
/// 붙이면 조용히 안 먹는다.
void maru_mobile_set_public_key(const unsigned char *bytes, unsigned long len);

/// **비밀번호를 물어야 한다고 알린다**(1=물어라, 0=끝났다). host 가 세션 상태
/// (`MARU_SSH_STATE_PASSWORD_NEEDED`)를 보고 켜고, 세션이 그 자리를 벗어나면 끈다 —
/// **끄는 것도 host 몫**이다: 세션이 끝났는데 화면만 남으면 사용자는 안 가는 곳에 계속 친다.
void maru_mobile_set_password_prompt(unsigned int wanted);

/// **처음 보는 서버의 지문을 물어라**(길이 0 이면 화면을 거둔다). host 가 세션이
/// `MARU_SSH_STATE_HOST_KEY_DECISION` 에 서고 **config 에 지문이 없을 때** 부른다 —
/// 지문이 이미 있으면 펌프가 그것만 보고 판정하므로 물을 일이 없다(아는 서버가 다른 키를
/// 내밀면 **묻지 않고 끊는다**, SSH 계약 §4).
///
/// 길이가 자리보다 길면 **안 받는다**: 반쪽 지문을 보여 주면 사용자가 확인할 수 없는 것을
/// 확인한 셈이 된다.
void maru_mobile_set_host_key_prompt(const unsigned char *fingerprint, unsigned long len);

/// **지금 접속이 어떻게 되고 있나**를 알린다(`state` 는 `MARU_SSH_STATE_*`, `err` 는 펌프의
/// 실패 이름 — 없으면 길이 0). 화면이 이것으로 말한다: 실패는 사용자가 있는 자리(터미널)에
/// 사람 말로 뜬다 — 로그로만 남기면 무엇을 고쳐야 하는지 알 길이 없다.
///
/// **이름을 그대로 보이지 않는다.** `connect_failed` 는 우리 말이고, 사용자가 할 일은
/// "주소와 포트를 확인" 이다 — 그 번역은 브리지가 한다(host 마다 문구를 적으면 갈린다).
void maru_mobile_set_ssh_status(unsigned int state, const unsigned char *err, unsigned long len);

/// 사용자의 답을 가져간다(0=아직, 1=승인, 2=거절). **가져가면 사라진다.** 승인이면 브리지가
/// 그 지문을 **그 서버 줄에 적어 둔다** — 안 적으면 다음에도 또 묻고, 매번 묻는 물음은 사람이
/// 안 읽는다.
unsigned int maru_mobile_take_host_key_decision(void);

/// 사용자가 친 비밀번호를 가져간다(없으면 0). **가져가면 사라진다** — 브리지에도 안 남는다
/// (계약 §3.4: 저장하지 않는다). 자리가 모자라면 **0 이고 아무것도 안 준다**: 자르면 틀린
/// 비밀번호를 보내는 셈이라 사용자는 맞게 쳤는데 실패한다.
unsigned long maru_mobile_take_password(unsigned char *out, unsigned long cap);

/// 지금 터미널 격자(열·행). 원격에 알릴 pty 크기는 **코어가 들고 있는 값**이어야 한다 —
/// host 가 따로 세면 그리는 격자와 원격이 믿는 크기가 갈린다. 화면이 아직 없으면 0.
unsigned int maru_mobile_term_cols(void);
unsigned int maru_mobile_term_rows(void);
/// 코어가 만든 답(DSR·DA 등)을 가져간다. **가져가면 사라진다.** host 는 이것을
/// `maru_mobile_ssh_write` 로 원격에 돌려보낸다 — 안 돌려보내면 묻는 프로그램이 멈춘다.
/// 자리가 모자라면 **0 이고 아무것도 안 지운다**(잘라 보내면 원격 화면이 어긋난다).
unsigned long maru_mobile_take_response(unsigned char *out, unsigned long cap);

/// ── 컨트롤 축(S10d-2) ────────────────────────────────────────────────────────
///
/// 폰이 그 PC 의 세션 목록을 받는 길이다(계약 docs/control-plane.md §4a). host 는 SSH **컨트롤
/// 채널**에서 읽은 바이트를 여기 넣고(`maru_mobile_ssh_control_ptr/len` → 아래 `feed`), 우리가
/// 만든 요청을 가져가 그 채널로 보낸다(`maru_mobile_ssh_write_control`).
///
/// **터미널 흐름과 섞지 않는다** — 합치면 ndjson 파서가 사람 화면을 읽게 된다.

/// **그릴 수 있는 논리 크기.** 창 크기에서 시스템이 가리는 만큼과 소프트 키보드를 빼고 배율로
/// 나눈다. host 는 **잰 값을 그대로** 준다 — 보정은 코어가 한 번만 한다.
///
/// `keyboard_from_bottom` 은 **화면 하단부터** 잰 높이다(0 이면 키보드가 없다). 그래서 하단
/// inset(제스처 바·3버튼 바·홈 인디케이터)과 **겹치는데, 그 겹침을 코어가 접는다** — host 가
/// 미리 빼서 주면 안 된다. 그 보정이 예전에는 두 host 에 각자 있었다.
///
/// `scale_milli` 는 논리 단위당 픽셀 × 1000: iOS 는 UIKit 이 이미 pt 를 주므로 `1000`,
/// Android 는 px 라 `density/160*1000`. 0 이면 1000 으로 본다.
///
/// 결과는 **최소 1** 이다 — 0 칸 격자는 그리는 쪽을 죽인다.
void maru_mobile_available_logical(unsigned int extent_w, unsigned int extent_h,
                                   unsigned int inset_top, unsigned int inset_bottom,
                                   unsigned int inset_left, unsigned int inset_right,
                                   unsigned int keyboard_from_bottom, unsigned int scale_milli,
                                   unsigned int *out_w, unsigned int *out_h);

/* ── 컨트롤 축: 정책은 코어가 정한다 ────────────────────────────────────────────
   이번 tick 에 host 가 할 일. **하나뿐이다** — 「열고 나서 닫기」는 표현 자체가 없다.
   예전에는 순서·가드·분류·마감이 두 host 의 tick 안에 흩어져 있어 ⑴ 플랫폼이 갈릴 수 있었고
   ⑵ 헤드리스로 못 쟀다. 실제로 iOS 가 열기를 닫기보다 먼저 해, 열자마자 닫기를 무한히
   되풀이하며 아무 세션도 안 떴다(실기 2026-09-04). */
#define MARU_MOBILE_CONTROL_ACTION_NONE 0
#define MARU_MOBILE_CONTROL_ACTION_CLOSE 1
#define MARU_MOBILE_CONTROL_ACTION_OPEN 2

/// **이번 tick 에 무엇을 할까.** `ssh_ready` 는 SSH 세션이 `MARU_SSH_STATE_READY` 인가(1/0),
/// `channel_state` 는 `MARU_SSH_CONTROL_*`, `now_ms` 는 단조 시각이다. 돌려받은 행동 **하나**를
/// 그대로 실행한다 — 닫기면 `maru_ssh_pump_close_control`, 열기면 `maru_mobile_control_command`
/// 로 만든 명령을 `maru_ssh_pump_open_control` 에 싣고 결과를 `maru_mobile_control_note_open`
/// 에 알린다. **닫기가 먼저다**(§4a — 한 번에 control 하나).
int maru_mobile_control_tick(int ssh_ready, unsigned int channel_state, unsigned long long now_ms);
/// 열기의 결과를 알린다. **「아직 때가 아니다」(`MARU_SSH_ERR_NOT_READY`)와 「졌다」를 코어가
/// 가른다** — 그 분류가 host 에 있으면 두 플랫폼이 갈리고 마감도 각자 세게 된다.
/// **왜 졌는지를 갈라 돌려준다**: `0` 아직 간다 / `1` 재시도 마감(§4a — 5초)을 넘겨 포기 /
/// `2` 딱딱한 실패. host 는 0 이 아닐 때만 찍되 **그 둘을 다른 문구로** 찍는다 — 뭉뚱그리면
/// 사용자가 고칠 자리(예: 그 기계에 `maru` 가 없다)를 못 가른다.
int maru_mobile_control_note_open(int rc, unsigned long long now_ms);
/// 열어 둔 명령이 그냥 끝났다 — 기다리던 답을 접고 `code` 를 화면에 알린다(§4a).
void maru_mobile_control_note_exit_at(unsigned int code);
/// 열린 명령의 답을 아직 기다리는가 — host 가 종료 코드를 볼 자격이 있나(1/0).
int maru_mobile_control_awaiting_reply(void);

/// 컨트롤 채널이 돌릴 **명령 한 줄**을 만든다(그 서버 설정의 `maru-path` 를 쓴다). 자리가
/// 모자라면 0 — **자르지 않는다**(잘린 명령은 다른 명령이다).
///
/// **인용은 코어가 한다.** `exec` 문자열은 원격 셸이 낱말로 쪼개므로 공백이 든 경로는 인용해야
/// 하고, 그 규칙을 host 두 곳에 두면 갈린다.
///
/// **무엇을 원하는지가 명령을 정한다**(§4a): 목록이면 `control --stdio`, 고른 세션의 화면이면
/// `attach --stream <32-hex>`. 아무것도 안 원하면 **0 이다** — 그 상태에서 열면 그 서버에서
/// 뜻 없는 명령이 하나 돈다.
unsigned long maru_mobile_control_command(unsigned char *out, unsigned long cap);
/// 컨트롤 채널에서 읽은 바이트를 넣는다. **먹은 만큼**을 돌려준다(0 이면 축이 꺼진 것이다).
unsigned long maru_mobile_control_feed(const unsigned char *bytes, unsigned long len);
/// 우리가 만든 요청을 가져간다. **가져가면 사라진다**(take-once). 자리가 모자라면 0 이고
/// `maru_mobile_last_error` 에 이름이 남는다 — 자르지 않는다.
unsigned long maru_mobile_take_control_request(unsigned char *out, unsigned long cap);
/// `hello` 시한을 넘겼다고 알린다(계약 §4a — 5초). **시계는 코어에 없다.**
void maru_mobile_control_timeout(void);
/// 원격 명령이 **그냥 끝났다**고 알린다 — `code` 는 그 종료 코드다(계약 §4a).
///
/// 시한과 다른 말이다: 답할 것이 이미 죽었으므로 화면이 **고칠 자리**를 말할 수 있다.
/// 이미 선 축이 닫힌 것은 정상 종료라 아무 일도 안 일어난다.
void maru_mobile_control_note_exit(unsigned int code);
/// 컨트롤 축 상태.
#define MARU_MOBILE_CONTROL_WAITING 0
#define MARU_MOBILE_CONTROL_READY 1
#define MARU_MOBILE_CONTROL_OFF 2
unsigned int maru_mobile_control_state(void);
/// 왜 껐나. **화면은 브리지가 직접 그린다**(코어 안에서 값을 본다) — 이 함수들은 **host 진단용**
/// 이다. 로그에 남기면 기기에서 "왜 목록이 안 뜨나" 를 그 자리에서 가를 수 있다.
#define MARU_MOBILE_CONTROL_OFF_NONE 0
#define MARU_MOBILE_CONTROL_OFF_HELLO_TIMEOUT 1
#define MARU_MOBILE_CONTROL_OFF_TOO_MUCH_NOISE 2
#define MARU_MOBILE_CONTROL_OFF_PROTOCOL_MISMATCH 3
#define MARU_MOBILE_CONTROL_OFF_FRAME_TOO_LARGE 4
/// 채널 자체를 못 열었다(앞의 넷과 달리 `hello` 를 기다려 볼 자리에도 못 갔다).
#define MARU_MOBILE_CONTROL_OFF_OPEN_FAILED 5
#define MARU_MOBILE_CONTROL_OFF_COMMAND_FAILED 6
unsigned int maru_mobile_control_off_reason(void);
/// **열기가 졌다고 host 가 알린다.** 여는 것은 host 가 하므로(소켓이 그쪽에 있다) 실패도 그쪽만
/// 안다 — 안 알리면 화면은 이유를 모른 채 기다린다(계약 §4a: 실패하면 그 화면에서 말한다).
void maru_mobile_control_open_failed(void);
/// **아직 때가 아니라서 못 열었다고 host 가 알린다**(`maru_ssh_pump_open_control` 이
/// `MARU_SSH_ERR_NOT_READY`(-7)를 냈을 때 — 예: 이전 채널이 아직 닫히는 중).
///
/// `maru_mobile_control_open_failed` 와 **다르다**: 화면에 실패를 말하지 않고 「열자」는 뜻만
/// 되돌려 다음 tick 이 다시 집게 한다. 이걸 안 부르고 실패로 접으면 그 뜻은 이미
/// `maru_mobile_control_tick` 이 가져가서 사라졌으므로 **그 화면이 영영 「받는 중」** 이
/// 된다(실측 2026-09-03: 세션 화면 재진입이 그렇게 죽었다).
void maru_mobile_control_open_retry(void);
/// 조립된 **원격 화면**의 상태(0=첫 프레임 대기, 1=선다, 2=껐다). 없으면 0.
///
/// 컨트롤 축과 **다른 소비자**다(§4a "소비자도 원하는 것이 정한다") — 화면을 원할 때 오는
/// 바이트는 ndjson 이 아니라 §8 `MRSS` 프레임이고, 화면 조립기가 읽는다.
unsigned int maru_mobile_remote_screen_state(void);
/// 받은 덩어리 수(진단용). 상위 16비트=snapshot, 하위 16비트=delta. 기기에서 "화면이 멈췄다" 를
/// **안 온다** 와 **와도 안 그린다** 로 가르는 자리다.
unsigned int maru_mobile_remote_screen_frames(void);
/// 지금 아는 세션 수.
unsigned int maru_mobile_control_session_count(void);
/// 목록을 한 번이라도 받았나. **"세션이 없다" 와 "아직 모른다" 는 화면에서 다른 말이다.**
int maru_mobile_control_listed(void);
/// 세션이 새 연결에서 다시 시작한다 — 목록도 축도 처음부터. 남겨 두면 죽은 세션을 살아 있는
/// 것처럼 보여 준다.
void maru_mobile_control_reset(void);

#ifdef __cplusplus
}
#endif
#endif
