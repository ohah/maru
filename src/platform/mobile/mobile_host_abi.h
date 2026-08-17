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
/// 1=숫자(설정의 숫자 칸). 브리지가 정하는 이유는 "무엇을 누르고 있나" 를 아는 쪽이 거기라서다.
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

#ifdef __cplusplus
}
#endif
#endif
