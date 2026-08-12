//! Test-only Chrome Lab fixture seam.
//!
//! This module owns synthetic UI inputs and recorded actions only. It deliberately does not
//! import AppSession, session, PTY, provider, filesystem, or a platform window host.

const std = @import("std");
const maru = @import("maru");
const lowering = @import("metal_lowering.zig");

const chrome = maru.chrome;
const session_dock = chrome.components.session_dock;
const archive_detail = chrome.components.archive_detail;

/// A three-card dock specimen emits component text (five runs per card), header/search controls,
/// and generic tree paint. Both the unit fixture and the product Metal smoke must use this one
/// bound; otherwise a new affordance can pass the former while the latter fails before capture.
///
/// sticky 시나리오는 그룹 둘·카드 넷에 상단 고정 헤더까지 그리므로 여기가 가장 많이 든다. 상한을
/// 시나리오마다 나누지 않는 이유는 위와 같다 — 하나만 넉넉하면 다른 쪽이 캡처 전에 죽는다.
pub const frame_op_capacity = 256;
pub const frame_run_capacity = 256;

pub const ScenarioId = enum {
    empty,
    loading,
    retained_list,
    font_specimen,
    partial_scroll,
    partial_group_scroll,
    scrollbar,
    // sticky 헤더의 세 상태(§4.7). clamp가 한 줄이라 셋이 같은 식에서 나오므로, 하나만 캡처하면
    // 나머지 둘이 무판정으로 남는다.
    sticky_at_rest,
    sticky_pinned,
    sticky_pushed,
    detail_loading,
    detail_ready,
    detail_stale,
    detail_unavailable,
    /// SB1 §5.2 — 사이드바 배경 strip이 창 바닥까지 가지 않고 **상태바 위에서 끊기는지**를 픽셀로 본다.
    /// 도크 내용은 필요 없다(strip은 `.m`이 직접 그린다) — 빈 프레임에 사이드바 폭·상태바 높이만 실어 준다.
    sidebar_status_strip,
    /// N1 §4.1 — 편집기 gutter 기하를 픽셀로 본다. 줄 번호가 **우측 정렬**로 같은 오른쪽 끝에 서는지,
    /// 자릿수가 늘어도(9→10) 본문 시작 열이 흔들리지 않는지가 단위 테스트로 안 보이는 부분이다.
    /// 좌표계를 셀↔픽셀로 오갈 때 어긋나는 회귀는 캡처로만 드러난다(탭 제목 이관 때 실제로 그랬다).
    editor_gutter,
    /// N1 §4 — 뷰포트 컬링. 문서 중간으로 스크롤한 상태를 픽셀로 본다. **줄 번호가 1이 아니라
    /// first_row+1에서 시작하는지**가 핵심이고, gutter 폭이 자릿수를 따라 넓어지는지도 함께 나온다.
    editor_scrolled,
    /// N1 §4.1 — **폰트 크기를 키운 화면.** 셀 크기가 곧 폰트 크기이므로(`chrome_lab_smoke.cellSizeFor`)
    /// 이 시나리오는 실제로 1.5배 큰 글자를 그린다. gutter가 함께 커지는지가 계약의 핵심 근거인데
    /// (§4.1 — 그래서 measured가 아니라 셀 경로다), 기본 크기 캡처만으로는 그것이 증명되지 않는다.
    editor_font_large,
    /// N1 §3.8 — **적대적 입력**. 화면에 보이는 것과 파일 내용이 달라지게 만드는 문자들이
    /// 실제로 가시화되는지 픽셀로 본다. 가시화가 꺼지면 그 줄들이 멀쩡해 보이므로(그것이 공격의
    /// 목적이다) 골든이 유일한 자동 가드다.
    editor_hazard,
    /// N1 §4.2 — **표시 폭**. 이모지 ZWJ 시퀀스·스킨톤·국기·VS16·동그란 번호가 각각 몇 칸을
    /// 차지하는지 픽셀로 본다. 줄마다 같은 열에 `|`를 두었으므로 **폭 계산이 틀리면 그 막대가
    /// 어긋난다** — 숫자를 읽지 않아도 캡처만으로 회귀가 보이는 것이 이 fixture의 요점이다.
    editor_wide_glyph,
    /// N1 §4 세로 축 — **랩**. 본문 폭을 넘는 줄이 다음 시각 행으로 이어지는지, 그리고 **이어진
    /// 행에 줄 번호가 비는지**를 픽셀로 본다. 후자가 단위 테스트로 안 보이는 부분이다 — 본문과
    /// gutter가 각자 행을 세면 숫자는 다 그려지지만 **본문과 어긋난다**.
    ///
    /// fixture에 **한글 줄을 넣은 이유**가 있다. ASCII만이면 `ceil(폭/열수)` 근사와 실제 분할이
    /// 일치해서, 분할이 틀려도 캡처가 같다. 2칸 글자는 행 끝에 한 칸을 남기므로 그 차이를 드러낸다.
    editor_wrap,
    /// N1 §4 — **가로 스크롤.** 랩이 꺼진 상태에서 본문을 `first_col`만큼 밀어 그린다. 같은 fixture를
    /// 쓰는 `editor-wrap`과 나란히 놓으면 두 방식(접기 / 밀기)이 같은 줄을 어떻게 다루는지 갈린다.
    ///
    /// **gutter가 함께 밀리지 않는지**가 이 시나리오의 핵심이다 — 줄 번호와 diff 색 띠는 늘 보여야
    /// 하는데(§7), 본문과 같은 오프셋을 먹이면 화면 밖으로 나간다.
    editor_hscroll,
    /// N1 §4 — **랩된 줄의 중간 행부터 시작하는 화면.** 세로 스크롤이 논리 줄 단위이면 만들 수 없는
    /// 상태다: 랩된 줄 하나가 화면보다 길면 그 줄 머리에서만 멈출 수 있어 **아래를 볼 방법이 없다.**
    ///
    /// `visual_map.RowIndex`가 시각 행을 논리 줄+조각으로 풀고, `content.first_piece`가 그 조각부터
    /// 그린다. 첫 행에 **줄 번호가 없는 것**이 그 증거다 — 이어지는 조각이기 때문이다.
    editor_wrap_scrolled,
    /// N1 §4 — **낡은 스크롤 위치가 들어왔을 때.** 뷰 폭·탭 폭·랩 토글이 바뀌면 인덱스가 무효가
    /// 되는데(§2) 그 전에 만든 스크롤 위치가 살아남으면 `first_piece`가 실제 조각 수를 넘는다.
    ///
    /// **그때 첫 논리 줄이 통째로 사라지면 안 된다** — 사라지면 다음 줄이 y=0에 자기 번호를 달고
    /// 올라와, 사용자에게는 리사이즈 한 번에 화면이 문서의 다른 곳으로 튄 것처럼 보인다. 코드
    /// 리뷰가 지적한 자리이고, 화면에 보이는 결함이므로 캡처로 고정한다.
    editor_wrap_stale_scroll,
    /// N1 §3.5 — **디스크에서 읽은 파일이 화면에 뜬다.** 앞의 편집기 시나리오들은 전부 소스에 박은
    /// 배열을 그리므로, `openPath`가 실제로 무엇을 돌려주는지는 증명하지 않는다. 여기서는 호출자가
    /// 파일을 써서 `openPath`로 읽고 그 줄들을 그대로 넘긴다(`Scenario.lines`).
    ///
    /// **읽은 문자열 자체는 단위 테스트가 판정한다**(`session/editor/open.zig`). 이 시나리오가 더하는
    /// 것은 그 다음 구간이다 — 읽은 줄이 셀 격자에 놓이기까지 경로가 이어져 있는가. BOM을 안 떼면
    /// §3.8 가시화가 `<U+FEFF>`를 첫 줄에 그리고, 탭 전개가 틀리면 들여쓴 행의 열이 어긋난다.
    editor_real_file,
};

/// sticky 시나리오인가. 그룹이 둘 이상이어야 "다음 헤더가 밀어낸다"를 만들 수 있다.
pub fn isSticky(id: ScenarioId) bool {
    return switch (id) {
        .sticky_at_rest, .sticky_pinned, .sticky_pushed => true,
        else => false,
    };
}

pub const Scenario = struct {
    id: ScenarioId,
    viewport_px: chrome.ui.layout.UiSize,
    now_ns: u64,
    /// 이 캡처의 셀 크기. 호출자가 `cellSizeFor`로 정해 넘긴다 — Lab이 자체 상수를 들면 렌더러가
    /// 쓰는 값과 갈려서, 글자는 커졌는데 배치는 안 커지는 캡처가 나온다.
    cell_w_px: u16 = 8,
    cell_h_px: u16 = 16,
    /// 이 캡처의 폰트 크기(device px). **제품은 사용자 `font.size`에서 오고 셀이 그 폰트에서
    /// 파생되지만**, Lab은 실제 폰트 메트릭을 재지 않으므로 셀에서 근사 역산해 넘긴다
    /// (`chrome_lab_smoke.fontPxFor`). 그 근사가 픽스처 쪽에 있는 것이 요점이다 — 백엔드는
    /// 폰트 크기를 그대로 받고 역산을 모른다.
    font_px: u16 = 13,
    /// 그릴 줄들. **`null`이면 시나리오가 자기 픽스처를 고른다** — 기존 시나리오는 전부 그쪽이라
    /// 캡처가 바이트 그대로다.
    ///
    /// `editor_real_file`만 이것을 채운다. Lab은 "deterministic, effect-free"가 계약이라 여기서
    /// 파일을 읽을 수 없고(읽으면 캡처가 디스크 상태에 딸린다), 그래서 **읽기는 호출자 몫**이다 —
    /// 호출자가 `openPath`로 연 줄들을 넘기면 Lab은 받은 것을 그리기만 한다.
    lines: ?[]const []const u8 = null,
};

pub const Result = struct {
    raster: lowering.OverlayRaster,
    recorded_action: ?chrome.ui.tree.UiActionId = null,
};

/// Caller-owned fixed storage. A Lab scenario cannot allocate a layout cache or retain a previous
/// frame; the next scenario rebuild overwrites this candidate exactly like the normal Chrome path.
pub const FrameBuffers = struct {
    entries: []chrome.ui.tree.RectEntry,
    items: []chrome.ui.layout.Item,
    flex_scratch: []chrome.ui.layout.FlexScratch,
    child_rects: []chrome.ui.layout.UiRect,
    ops: []chrome.draw.Op,
    dock_nodes: []chrome.ui.tree.UiNode,
    dock_actions: []session_dock.ids.Entry,
    detail_nodes: []chrome.ui.tree.UiNode = &.{},
    detail_actions: []archive_detail.ids.Entry = &.{},
    text_runs: []chrome.draw.Run,
    text_bytes: []u8,
};

pub const Frame = struct {
    tree: chrome.ui.tree.UiRectTree,
    draws: chrome.ChromeDraw,
};

/// Produces a deterministic, effect-free Chrome component through the product UI tree and paint
/// path. Detail fixtures carry only synthetic/redacted strings; the Lab cannot import an archive
/// provider or an AppSession merely to make a visual regression test pass.
pub fn buildFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    // strip은 `.m`이 직접 그린다(승인 예외). 여기서 도크를 그리면 **전폭으로** 깔려 strip 경계에 걸치는데,
    // 제품에서는 사이드바와 도크가 그렇게 겹치지 않는다 — 리뷰어가 보는 그림이 제품을 오도한다.
    // 그래서 chrome을 **아무것도 내지 않고** strip과 배경만 남긴다(골든이 보려는 것도 그 경계 하나다).
    if (scenario.id == .sidebar_status_strip) return .{
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = .sidebar, .ops = buffers.ops[0..0] },
    };
    return switch (scenario.id) {
        .detail_loading, .detail_ready, .detail_stale, .detail_unavailable => buildDetailFrame(scenario, tokens, buffers),
        .editor_gutter, .editor_scrolled, .editor_font_large, .editor_hazard, .editor_wide_glyph, .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll, .editor_real_file => buildEditorGutterFrame(scenario, buffers),
        // 위 early return이 처리한다 — 여기 오면 분기가 갈린 것이다.
        .sidebar_status_strip => unreachable,
        .empty,
        .loading,
        .retained_list,
        .font_specimen,
        .partial_scroll,
        .partial_group_scroll,
        .scrollbar,
        .sticky_at_rest,
        .sticky_pinned,
        .sticky_pushed,
        => buildDockFrame(scenario, tokens, buffers),
    };
}

/// N1 §4.1 — 편집기 gutter를 실제 draw op으로 내려 픽셀까지 보낸다.
///
/// **문서를 읽지 않는다.** Lab은 filesystem·session을 import하지 않으므로(이 파일 머리말) 줄 수만
/// 합성해 넣는다. 이 시나리오가 증명하려는 것은 문서 내용이 아니라 **기하**다 — 줄 번호가 우측
/// 정렬로 같은 오른쪽 끝에 서는가, 자릿수가 9에서 10으로 넘어가도 본문 시작 열이 그대로인가.
///
/// 그래서 줄 수를 **12로 둔다**: 한 화면에 1자리(1~9)와 2자리(10~12)가 함께 나와 우측 정렬이
/// 실제로 작동하는지 한 캡처에서 보인다. 자릿수가 하나뿐이면 정렬이 틀려도 그림이 같다.
/// 합성 소스 fixture. **실제 파일을 읽지 않는다**(Lab은 filesystem을 import하지 않는다) — 대신 이
/// 시나리오가 증명해야 하는 것을 한 화면에 모은다.
///
/// 각 줄이 맡은 역할이 있다: 탭 들여쓰기(탭스톱 전개), 한글(다중 byte + 폰트 fallback), 빈 줄(op을
/// 만들지 않아도 다음 줄이 안 당겨지는지), 긴 줄(본문 폭에서 잘리는지), 그리고 9→10 자릿수 경계를
/// 넘기는 줄 수.
/// §3.8 "초장문 단일 줄" 회귀 가드. **탭이 앞에 있어야 전개 경로를 탄다** — 탭이 없으면
/// `expandTabs`가 원본을 빌려주고 지나가므로 scratch를 쓰지 않는다.
///
/// 길이가 Lab의 `text_bytes`(2048)를 넘도록 잡았다: 상한이 없으면 이 줄 하나가 저장소를 삼켜
/// `build` **전체**가 OutOfSpace로 죽고 **편집기가 통째로 안 그려진다**(그 줄만이 아니다).
/// 상한이 있으면 화면 폭까지만 만들고 나머지는 애초에 만들지 않는다.
const long_line = "\t" ++ ("longline " ** 260); // 2340자

const editor_fixture_lines = [_][]const u8{
    // 8칸마다 `|`인 자. **격자 배치의 회귀 가드다** — 격자면 파이프 간격이 정확히 cell_w의
    // 8배로 일정하고(실측 64·64·64·64·64), advance 누적으로 돌아가면 폰트 advance가 실수라
    // 반올림 오차가 쌓여 62/63으로 흔들린다(실측). 골든이 그 차이를 잡는다.
    "|.......|.......|.......|.......|.......|",
    "const std = @import(\"std\");",
    "",
    "pub fn main() !void {",
    "\tconst greeting = \"hello\";",
    "\tconst 인사말 = \"안녕하세요\";",
    "",
    // 줄 **중간** 탭이 있어야 탭스톱과 고정 폭이 갈린다. 그런데 그것만으로는 부족하다 — 탭이 시작하는
    // 열이 `tab_width`의 배수면 두 방식이 여전히 같은 칸 수를 낸다. 이 줄은 탭이 **열 17**에서 시작해
    // 탭스톱은 3칸(→20), 고정 폭은 4칸(→21)으로 갈린다. 두 번 다 골든이 회귀를 놓친 뒤 계산해서 고른
    // 값이므로 `const n = 12;`의 길이를 바꾸면 이 case가 다시 무력해진다.
    "\tconst n = 12;\t// 정렬용 탭",
    // **한글 뒤에 탭**이 있어야 셀 폭 계산이 걸린다. 글자 수로 세면 열 18(탭 2칸), 셀 폭으로 세면
    // 열 20(탭 4칸)이라 정렬이 눈에 띄게 갈린다 — 한글이 2칸이라는 것을 반영하지 않으면 여기서
    // 주석이 왼쪽으로 밀린다.
    "\tconst 한글 = 12;\t// 뒤 탭",
    // 리거처 추적용. 지금은 `!=`·`=>`가 합쳐지지 않으며 그 원인이 셀 격자가 아님을 실측으로
    // 확인했다(§3.8 인접 서술). 나중에 리거처가 켜지면 이 줄의 골든이 바뀌어 알려준다.
    "\tif (a != b) x => y;  // 리거처",
    "\tif (greeting.len > 0) {",
    "\t\ttry stdout.print(\"{s}\\n\", .{greeting});",
    "\t}",
    "",
    "\treturn;",
    "}",
    long_line,
    // **오른쪽 경계에 2칸 글자가 걸치는 줄**(랩이 꺼진 화면). `expandTabs`의 상한은 cluster의
    // **시작** 열만 보므로 걸친 글자가 통째로 들어가고, 자르는 것은 렌더러의 픽셀 예산이다 —
    // 그 결과가 반쪽인지 통째인지 빈칸인지는 **캡처로만** 보인다. 본문이 50열이므로 z를 49개 두면
    // 한글이 열 49~50을 요구하는데 50은 화면 밖이다 — 정확히 걸치는 자리다(폭이 바뀌면 함께 옮긴다).
    ("z" ** 49) ++ "한글",
};

/// §3.8 적대적 입력 fixture. **실제 Trojan Source 패턴을 담는다.**
///
/// 각 줄이 하나씩 맡는다 — BiDi override(주석이 코드처럼 보이게 하는 수단), 폭 0 문자(식별자를
/// 같아 보이게), C0 제어 문자(파일에 든 ESC), 비표준 공백(문법 오류가 안 보임). 가시화가 없으면
/// 이 줄들이 **평범해 보이는 것**이 요점이라, 캡처를 눈으로 봐도 "정상"으로 읽힌다.
const editor_hazard_lines = [_][]const u8{
    "// 아래는 겉보기와 다르다",
    "if (level == \u{202E}admin) {",
    "const user\u{200B}Name = 1;",
    "const esc = \"\x1b[31m\";",
    "const a\u{00A0}= 1;",
    "const ad\u{200D}min = 2;",
    "const ok = \"\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\";",
    "",
    "// 위에 숨은 문자가 있다(가족 이모지 줄은 정상)",
    "",
    // **§3.8 표기가 오른쪽 경계에 걸치는 줄.** 본문이 50열이고 표기가 8칸이므로, BiDi 문자를
    // 열 46에 두면 표기가 46~53을 요구해 **네 칸이 화면 밖**이다(폭이 바뀌면 함께 옮긴다).
    //
    // 표기를 통째로 빼면 앞뒤가 붙어 위험 문자의 존재가 사라진다 — 적대적 검증이 실제로 그 상태를
    // 만들었다(`ab<U+202E>cd` → `abcd`). 잘려서라도 남아야 §3.8의 불변식이 선다. 그것을 **캡처로**
    // 고정하는 것이 이 줄의 몫이다(단위 테스트는 문자열만 보고 화면을 보지 않는다).
    ("x" ** 46) ++ "\u{202E}end",
    // 한 cluster에 hazard cp와 정상 cp가 함께 있는 경우(ZWJ가 앞 글자에 흡수된다). 이 모양이
    // **정수 언더플로 패닉**을 만들었다 — 캡처가 만들어진다는 것 자체가 그 회귀의 가드다.
    ("y" ** 42) ++ "a\u{200D}\u{200D}b\u{200D}c",
};

/// §4.2 표시 폭 fixture. **라벨은 모두 8칸, 내용은 4칸 또는 6칸, `|`는 20열**이 되도록 짰다 —
/// 폭 규칙이 하나라도 틀리면 그 줄의 막대만 어긋나므로 **어느 규칙이 깨졌는지까지** 캡처가 말한다.
///
/// 내용 칸 수 근거(§4.2): 이모지·가족·스킨톤·국기·VS16은 각 2칸이라 둘이면 4칸, 한글과 동그란
/// 번호는 각 2칸이라 셋이면 6칸이다. `MMMM`은 ASCII 4칸.
/// §4 랩 fixture. **길이를 본문 폭(약 55열) 기준으로 잡았다** — 넘지 않으면 랩이 안 일어나고
/// 캡처가 랩 없는 상태와 같아진다.
///
/// 줄 2는 ASCII라 근사와 실제가 일치하고, 줄 3은 한글이라 **행마다 한 칸이 남아 근사가 틀리는**
/// 경우다. 둘을 나란히 두면 어느 쪽이 깨졌는지 캡처에서 갈린다. 줄 4의 빈 줄은 **빈 줄이 행 하나를
/// 지키는지**(caret 자리) 보고, 줄 5는 그 뒤 번호가 밀리지 않았는지 보여준다.
const editor_wrap_lines = [_][]const u8{
    // **자.** 랩이 몇 열에서 접히는지 캡처에서 **읽을 수 있게** 한다 — 글자가 화면 오른쪽에 닿아
    // 끝나면 "폭에 맞게 접혔는지"와 "넘쳐서 잘렸는지"가 그림상 같아 보인다. 이어지는 행의 첫 숫자가
    // 앞 행 마지막 숫자 다음이면 조각이 정확히 맞물린 것이다.
    //
    // **주기가 7인 이유**: 본문 폭(50)과 서로소여야 행마다 시작 숫자가 달라진다. 10주기를 쓰다가
    // 스크롤바가 자리를 먹어 폭이 50이 되자 주기와 정확히 맞아떨어져 **모든 행이 `0`으로 시작**했고,
    // 그러면 랩이 통째로 깨져도 그림이 같아 자가 아무것도 판정하지 못한다(실제로 그 상태가 됐다).
    "0123456" ** 18,
    "fn wrap(text: []const u8) void {",
    "    // This ASCII comment is deliberately longer than the content width so it folds onto the next visual row.",
    "    // 한글 주석도 본문 폭을 넘도록 길게 씁니다. 두 칸짜리 글자는 행 끝에 한 칸을 남기므로 나눗셈 근사와 어긋납니다.",
    "",
    "    return;",
    "}",
    // **2칸 글자가 행 경계에 정확히 걸치는 줄.** 본문이 50열이므로 49칸을 ASCII로 채우면 다음
    // 한글이 49~50을 요구하는데 50이 마지막 칸이라 **들어갈 수 없다** — 그 칸을 비우고 넘겨야 한다.
    //
    // **스크롤바가 자리를 먹으면서 본문이 52 → 50열이 됐다**(§4.1a). 이 상수는 폭에 매여 있으므로
    // 폭이 바뀌면 함께 옮겨야 한다 — 안 맞추면 경계에 안 걸려 가드가 조용히 무력해진다.
    //
    // 이 줄이 없으면 "2칸 글자를 쪼개지 않는다"는 계약에 **가드가 없다.** 자연스러운 한글 문장은
    // `col`이 짝수로만 늘어 52에서 정확히 떨어지므로, 경계 판정을 `col + w > 폭`에서 `col >= 폭`으로
    // 바꿔도 그림이 같다(적대적 검증이 실제로 그 상태를 통과시켰다).
    ("x" ** 49) ++ "가나다",
    // **왼쪽 경계에 2칸 글자가 걸치는 줄.** `editor-hscroll`이 20열을 밀므로, 19칸 뒤의 한글이
    // 열 19~20을 요구해 **첫 칸이 화면 밖**이 된다 — 반쪽을 그릴 수 없으니 통째로 빼야 한다.
    //
    // 위 `x*51` 줄로는 이것을 못 본다. 그 줄의 한글은 열 51부터라 경계와 무관하고, **1칸 글자에서는
    // `col >= start`와 `col + w > start`가 같은 결과를 내기** 때문이다(적대적 검증이 그 반증을
    // 통과시켰다). 오른쪽 경계(랩)와 정확히 대칭인 상황이다.
    ("y" ** 19) ++ "가나다",
    // **랩 + 초장문.** 적대적 검증이 잡은 결함의 회귀 가드다 — 랩은 한 줄에 `남은 행 × 뷰 열수`만큼
    // 저장소를 쓸 수 있어서, 이 줄이 저장소를 다 삼키면 `expandTabs`가 `OutOfSpace`를 올리고
    // **캡처가 통째로 안 만들어졌다**(#2086이 고친 결함이 랩에서 되살아났던 것이다).
    //
    // **맨 끝에 둔다.** 앞에 두면 화면 대부분을 먹어 위쪽 검증(자·한글)의 골든 rect가 전부 밀린다.
    long_line,
};

const editor_width_lines = [_][]const u8{
    "// | 가 한 열에 서야 한다",
    "ascii   MMMM        |",
    "hangul  가나다      |",
    "emoji   \u{1F600}\u{1F600}        |",
    "family  \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}        |",
    "skin    \u{1F44D}\u{1F3FD}\u{1F44D}\u{1F3FD}        |",
    "flag    \u{1F1F0}\u{1F1F7}\u{1F1F0}\u{1F1F7}        |",
    "vs16    \u{2764}\u{FE0F}\u{26A0}\u{FE0F}        |",
    "circle  \u{2460}\u{2461}\u{2462}      |",
};

/// N1 §4.1 — 편집기 gutter와 본문을 실제 draw op으로 내려 픽셀까지 보낸다.
///
/// 이 시나리오가 증명하려는 것은 문서 내용이 아니라 **기하**다 — 줄 번호가 우측 정렬로 같은 오른쪽
/// 끝에 서는가, 자릿수가 9에서 10으로 넘어가도 본문 시작 열이 그대로인가, 본문이 gutter 오른쪽에서
/// 시작하며 줄 번호와 **같은 baseline**에 서는가. 마지막 항목이 셀↔픽셀 변환 회귀가 드러나는 자리다.
fn buildEditorGutterFrame(scenario: Scenario, buffers: FrameBuffers) !Frame {
    const editor_view = chrome.components.editor_view;

    const cell_w_px = scenario.cell_w_px;
    const cell_h_px = scenario.cell_h_px;
    const viewport_w: u32 = @intFromFloat(scenario.viewport_px.width);
    const viewport_h: u32 = @intFromFloat(scenario.viewport_px.height);
    // **스크롤바가 자리를 먹는다**(§4.1a) — 본문 위에 겹치면 오른쪽 끝 글자가 막대에 가려지고,
    // §3.8이 "보이는 것과 파일 내용이 달라지면 안 된다"를 요구하는 편집기에서 그것은 특히 나쁘다.
    const scrollbar_metrics = chrome.ui.scroll_area.ScrollbarMetrics{
        .width_px = 8,
        .inset_x_px = 4,
        .min_thumb_px = 24,
    };
    const total_cols: u16 = @intCast((viewport_w -| scrollbar_metrics.gutterPx()) / cell_w_px);
    // **남은 공간 전부가 스크롤바 gutter다.** `total_cols`가 버림이라 본문이 셀 경계에서 끝나고,
    // 요구한 gutter(12px)보다 넓은 자투리가 생긴다 — 그것을 gutter에 포함하지 않으면 막대가 화면
    // 오른쪽 끝에서 어중간하게 떠 있다(실측 6px). 남은 폭을 그대로 주면 막대가 그 안에 가운데로 선다.
    const scrollbar_gutter_px: u32 = viewport_w -| (@as(u32, total_cols) * cell_w_px);
    // **호출자가 준 줄이 있으면 그것을 그린다**(`editor_real_file`) — 디스크에서 읽어 온 것이라
    // Lab이 픽스처로 흉내낼 수 없다.
    const lines: []const []const u8 = scenario.lines orelse switch (scenario.id) {
        .editor_hazard => &editor_hazard_lines,
        .editor_wide_glyph => &editor_width_lines,
        .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll => &editor_wrap_lines,
        else => &editor_fixture_lines,
    };
    const line_count: usize = lines.len;

    // 스크롤 시나리오는 **화면을 일부러 좁힌다.** fixture를 화면보다 길게 늘리는 것보다 이쪽이
    // 낫다 — 줄을 60개 손으로 쓰면 골든이 무엇을 보는지 흐려지고, 좁은 화면은 실제 분할 pane에서
    // 늘 일어나는 상태다.
    const vp: editor_view.viewport.Viewport = switch (scenario.id) {
        .editor_scrolled => .{ .first_row = 5, .rows = 6 },
        // **20열 밀어 둔다.** 0이면 안 민 것과 그림이 같아 시나리오가 아무것도 증명하지 못하고,
        // 너무 크면 fixture의 짧은 줄들이 전부 비어 gutter만 남는다.
        .editor_hscroll => .{ .first_row = 0, .first_col = 20, .rows = @intCast(viewport_h / cell_h_px) },
        // **화면을 6행으로 좁힌다.** 전체 높이면 전개 예산이 늘 넉넉해서, `first_piece`가 예산을
        // 갉아먹어 **화면 아래가 비는** 결함(코드 리뷰 #1)이 캡처에 나타나지 않는다 — 실제로 그
        // 상태로 골든이 전부 통과했다. 좁은 화면은 분할 pane에서 늘 일어나는 상태이기도 하다.
        .editor_wrap_scrolled, .editor_wrap_stale_scroll => .{ .first_row = 0, .rows = 6 },
        else => .{ .first_row = 0, .rows = @intCast(viewport_h / cell_h_px) },
    };

    const layout = editor_view.geometry.compute(total_cols, line_count, .{});
    // 행 저장소가 고정이므로 **거기에 맞춰 자른다.** 지금 fixture로는 넘지 않지만, 줄을 늘리거나
    // 뷰포트를 키우면 `while (n < visible)` 루프가 배열 밖을 쓴다. 잘린 캡처가 나오는 편이
    // 메모리를 밟는 것보다 낫고, 그 상태는 골든이 즉시 잡는다.
    const row_capacity: u16 = 64;
    const visible = @min(vp.visibleRows(line_count), row_capacity);

    // gutter와 본문이 같은 저장소를 나눠 쓴다. **쓴 양은 각 build가 돌려준 값으로만** 넘긴다 —
    // 호출자가 다시 계산하면 그쪽 내부 규칙을 복제하게 된다.
    // **본문을 먼저 그린다.** 랩이 켜지면 어느 논리 줄이 몇 행으로 접히는지는 전개해서 나눠 본
    // 쪽만 알기 때문에(§4 세로 축), 본문이 시각 배치를 정하고 gutter가 그것을 따른다. 둘이 각자
    // 세면 랩된 줄에서 번호가 본문과 어긋난다.
    // **세로 스크롤이 시각 행 단위인 시나리오**는 여기서 갈린다. 랩된 줄 하나가 화면보다 길면
    // 논리 줄 단위로는 그 줄 머리에서만 멈출 수 있어 **아래를 볼 방법이 없다** — `RowIndex`가
    // 시각 행을 논리 줄+조각으로 풀고, 그 조각부터 그린다.
    const wrap_on = scenario.id == .editor_wrap or scenario.id == .editor_wrap_scrolled or
        scenario.id == .editor_wrap_stale_scroll;
    var first_line: usize = vp.first_row;
    var first_piece: u32 = 0;
    if (scenario.id == .editor_wrap_stale_scroll) {
        // **낡은 위치를 흉내낸다.** 첫 줄(자, 세 조각)에 조각 99를 요구하는 상태 — 인덱스가 무효가
        // 된 뒤에도 스크롤 위치가 살아남으면 이렇게 된다. 첫 줄이 사라지지 않고 **처음부터** 나와야
        // 한다(캡처의 첫 행에 번호 `1`이 있는 것이 그 증거다).
        first_line = 0;
        first_piece = 99;
    }
    if (scenario.id == .editor_wrap_scrolled) {
        var counts: [row_capacity]u32 = undefined;
        // **인덱스와 렌더러가 서로 다른 저장소 한도를 본다** — 인덱스는 줄마다 재사용하는 이
        // 버퍼를, 렌더러는 모든 줄이 나눠 쓰는 `text_bytes`(2048)를 쓴다. 그래서 렌더러가 절단한
        // 줄을 인덱스는 온전히 세고, `totalRows`가 화면이 실제로 닿을 수 있는 것보다 커질 수 있다
        // (코드 리뷰가 지적했다).
        //
        // **Lab의 한계다.** 제품에서는 문서 전체를 인덱싱하고 렌더는 화면 몫만 그리므로 두 저장소가
        // 애초에 다른 것이 정상이며, 어긋남은 `rowCount`가 `truncated`를 돌려주는 것으로 드러난다.
        // 여기서 맞추려면 Lab이 렌더 저장소를 미리 나눠야 하는데, 그러면 픽스처가 제품에 없는
        // 제약을 흉내내게 된다.
        var index_scratch: [4096]u8 = undefined;
        const counted = @min(line_count, row_capacity);
        for (lines[0..counted], 0..) |line, i| {
            counts[i] = editor_view.content.rowCount(line, 4, layout.content.width, true, &index_scratch).rows;
        }
        var starts: [row_capacity + 1]u32 = undefined;
        const index = editor_view.visual_map.buildIndex(counts[0..counted], &starts);
        // **초장문 줄(`long_line`, fixture 마지막)의 10번째 조각부터.** 자리를 손으로 박지 않고
        // 인덱스에서 유도하므로, 앞 줄이 바뀌어도 가리키는 곳이 흔들리지 않는다.
        //
        // **왜 하필 긴 줄 안쪽인가**: 짧은 줄이면 전개 예산이 늘 넉넉해서 `first_piece`가 예산을
        // 갉아먹는 결함(코드 리뷰 #1)이 **캡처에 나타나지 않는다** — 실제로 그 결함이 살아 있는
        // 상태로 골든이 전부 통과했다. 조각 10은 열 500 언저리라, 건너뛸 몫을 예산에 더하지
        // 않으면 전개가 거기까지 닿지 못하고 화면이 통째로 달라진다.
        const long_line_index = editor_wrap_lines.len - 1;
        const target: u32 = if (index.firstRowOf(long_line_index)) |start| start + 10 else 6;
        if (index.resolve(target)) |pos| {
            first_line = pos.line;
            first_piece = pos.piece;
        }
    }

    // **배경이 맨 먼저다**(§4.1b, painter) — 나중에 오면 글자를 덮는다.
    //
    // **이 픽스처에서는 경계가 눈에 보이지 않는다.** Lab 토큰의 `surface_bg`가 오프스크린 렌더의
    // clear color와 우연히 같은 값(20,20,20)이라 뷰 안팎이 같은 색으로 나온다. 제품에서는 pane이
    // 자기 배경을 그리므로 두 색이 갈리고, 그때 이 사각이 편집기 경계가 된다.
    //
    // **스크롤 시나리오에서 화면 아래가 비는 이유**도 여기 적어 둔다: `vp.rows`를 6으로 좁혀 놓았고
    // (아래 주석 참고) 화면은 45행분이라, 편집기는 위 6행만 그리고 스크롤바도 그 안에 선다. 캡처만
    // 보면 "꽉 안 찼는데 스크롤바가 있다"로 읽히는데, 좁힌 뷰포트 안에서는 정확한 동작이다.
    const view_h_px: u32 = @as(u32, @min(vp.rows, row_capacity)) * cell_h_px;
    const bgw = editor_view.surface.build(.{
        .rect = .{ .x = 0, .y = 0, .w = viewport_w, .h = view_h_px },
    }, buffers.ops);

    var content_rows: [row_capacity]editor_view.content.Row = undefined;
    var n: u16 = 0;
    while (n < visible and first_line + n < line_count) : (n += 1) {
        content_rows[n] = .{ .bytes = lines[first_line + n] };
    }

    var visual_rows: [row_capacity]editor_view.visual_map.VisualRow = undefined;
    // 랩이 켜지면 논리 줄 하나가 화면 여럿을 덮으므로 **그릴 수 있는 행 수**로 상한을 준다.
    const visual_budget = @min(vp.rows, row_capacity);

    // **gutter 몫을 먼저 떼어 둔다.** 본문이 먼저 도는 순서로 바꾼 대가다 — 랩이 켜지면 긴 줄 하나가
    // 저장소를 다 써서 뒤에 도는 gutter가 `OutOfSpace`로 죽는다(적대적 검증이 실제로 잡았다).
    //
    // **줄 번호가 본문보다 먼저 확보돼야 한다.** 본문이 덜 그려지면 그 줄만 짧게 보이지만, 번호가
    // 없으면 화면 전체가 어느 위치인지 알 수 없다. 그리고 gutter 소요는 예측 가능하다(행 × 자릿수).
    //
    // **이 fixture로는 그 상태가 재현되지 않는다** — 여기 줄들은 대부분 탭이 없어 `expandTabs`가
    // 원본을 빌려주고(scratch 0), 긴 줄이 맨 끝이라 앞 줄들이 이미 행을 소비해 전개 예산이 작다.
    // 그래서 이 방어를 지워도 캡처가 나온다. 계약은 `content.zig`의 단위 테스트가 고정한다
    // ("긴 줄은 본문이 저장소를 끝까지 쓴다").
    const gutter_reserve = @min(
        buffers.text_bytes.len / 2,
        // **실제 자릿수로 잡는다.** `max_digits`(usize 최대 20자리)로 잡으면 실제의 스무 배를
        // 예약해 본문이 근거 없이 줄어든다 — 저장소를 나눠 쓰므로 한쪽의 과잉이 다른 쪽의 손실이다.
        // **`line_count`는 이미 문서 전체 줄 수다.** 여기에 스크롤 오프셋을 더하면 gutter가
        // 그릴 수 있는 어떤 번호보다 큰 값이 되어 자릿수가 하나 늘고, 그만큼 본문 저장소가
        // 근거 없이 줄어든다(바로 위 주석이 경고하는 그 실패다 — 코드 리뷰가 잡았다).
        editor_view.gutter.scratchNeeded(visual_budget, line_count),
    );
    const content_scratch = buffers.text_bytes[0 .. buffers.text_bytes.len - gutter_reserve];

    const cw = editor_view.content.build(.{
        .layout = layout,
        .rows = content_rows[0..n],
        .wrap = wrap_on,
        .first_col = vp.first_col,
        .first_piece = first_piece,

        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .origin_px = .{ .x = 0, .y = 0 },
        .font_px = scenario.font_px,
    }, buffers.ops[bgw.ops..], content_scratch, buffers.text_runs, visual_rows[0..visual_budget]);

    var gutter_rows: [row_capacity]editor_view.gutter.Row = undefined;
    const grows = editor_view.gutter.rowsForVisual(
        visual_rows[0..cw.visual_rows],
        first_line,
        &gutter_rows,
    );
    const gw = editor_view.gutter.build(.{
        .layout = layout,
        .rows = grows,
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .origin_px = .{ .x = 0, .y = 0 },
        .font_px = scenario.font_px,
    }, buffers.ops[bgw.ops + cw.ops ..], buffers.text_bytes[cw.bytes..], buffers.text_runs[cw.runs..]);

    // **문서 전체의 시각 행 수**가 있어야 막대 길이가 나온다(§4.1a) — 논리 줄로 세면 랩된 문서에서
    // 실제보다 길어 보인다. 화면에 그린 행이 아니라 **문서 전체**를 세는 것이 요점이다.
    var sb_counts: [row_capacity]u32 = undefined;
    var sb_scratch: [4096]u8 = undefined;
    const sb_counted = @min(line_count, row_capacity);
    for (lines[0..sb_counted], 0..) |line, i| {
        sb_counts[i] = editor_view.content.rowCount(line, 4, layout.content.width, wrap_on, &sb_scratch).rows;
    }
    var sb_total: u32 = 0;
    for (sb_counts[0..sb_counted]) |rows| sb_total +|= rows;

    const sw = editor_view.scrollbar.build(.{
        .content = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(total_cols * cell_w_px),
            // **실제로 보이는 높이**여야 한다. 창 전체 높이를 주면 문서가 늘 다 들어간다고 판정돼
            // 막대가 안 그려진다(스크롤 시나리오는 화면을 일부러 좁힌다).
            .h = @floatFromInt(@as(u32, visual_budget) * cell_h_px),
            .gutter_w = @floatFromInt(scrollbar_gutter_px),
        },
        .total_visual_rows = sb_total,
        .first_visual_row = @intCast(@min(first_line, std.math.maxInt(u32))),
        .cell_h_px = cell_h_px,
        .metrics = scrollbar_metrics,
    }, buffers.ops[bgw.ops + cw.ops + gw.ops ..]);

    return .{
        // 아직 hit-test 대상이 없다(줄 번호 클릭은 N2의 줄 선택, 본문 클릭은 캐럿 배치다). 빈 트리를 낸다.
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = .sidebar, .ops = buffers.ops[0 .. bgw.ops + gw.ops + cw.ops + sw.ops] },
    };
}

fn buildDockFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    const retained = [_]session_dock.types.Item{
        // fixture 문자열은 synthetic이어야 한다(project-rules "fixture는 synthetic·redacted만"). 실제 조직·
        // 저장소 이름을 쓰면 그것이 골든 이미지에 **픽셀로 고정**돼 저장소에 영구히 남는다. 워크스페이스
        // 이름은 그룹 행의 레이아웃만 증명하면 되므로 명백히 가짜인 값을 쓴다.
        .{ .group = .{ .identity = 1, .label = "sample-workspace", .count = 3 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = "94 messages · 3m ago · claude-opus-5", .selected = scenario.id == .retained_list } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = "140 messages · 22h ago · gpt-5.6-sol" } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = "356 messages · 1d ago · claude-opus-5" } },
    };
    // 그룹 **둘**이 있어야 sticky의 세 번째 상태(다음 헤더가 밀어냄)를 만들 수 있다. 하나짜리
    // fixture로는 "상단 고정"까지만 보이고 두 헤더가 겹치는 회귀를 못 본다.
    const two_groups = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "sample-workspace", .count = 2 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = "94 messages · 3m ago · claude-opus-5" } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = "140 messages · 22h ago · gpt-5.6-sol" } },
        .{ .group = .{ .identity = 4, .label = "second-workspace", .count = 2 } },
        .{ .card = .{ .identity = 5, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = "356 messages · 1d ago · claude-opus-5" } },
        .{ .card = .{ .identity = 6, .provider = .codex, .title = "Publish scrollbar inside preorder", .summary = "Keep the tree invariants while the gutter stays reserved", .metadata = "12 messages · 2d ago · gpt-5.6-sol" } },
    };
    // This is deliberately a real Session Dock card, not an out-of-band font test canvas. The
    // retained-list fixture proves list behavior; this specimen instead makes font selection
    // reviewable at PR scale. ASCII differentiators expose the selected primary face, while the
    // Korean line makes a missing primary glyph visibly exercise CoreText's fallback face.
    const font_specimen = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "font specimen", .count = 3 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Il1 O0 MWmw @# [] {} <>", .summary = "ASCII primary-face specimen", .metadata = "한글 가나다라마바사 · primary or fallback", .selected = true } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "rn m w |! `.,:; /\\", .summary = "narrow and wide glyph contours", .metadata = "가각간 한글 폰트 비교" } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "S5 2Z 8B 0O 1l I|", .summary = "same fixed grid, distinct ink", .metadata = "fallback face is reported in JSON" } },
    };
    // sticky 세 상태의 스크롤 위치. clamp가 한 줄이라 offset 하나로 상태가 정해지므로, 그 offset을
    // 기하에서 유도한다 — 상수를 박으면 metric이 바뀔 때 시나리오가 조용히 다른 상태를 찍는다.
    const m = session_dock.types.DockMetrics.resolve(1000);
    const second_group_top: u32 = (m.group_h + m.item_gap) + 2 * (m.card_h + m.item_gap);
    const sticky_offset: u32 = switch (scenario.id) {
        // 아직 안 지남 — 헤더가 흐름 그대로다.
        .sticky_at_rest => 0,
        // 지나침 — 첫 카드가 헤더 **밑으로** 지나간다.
        .sticky_pinned => m.group_h + m.item_gap + m.card_h / 2,
        // 다음 헤더가 올라와 밀어내는 중. 반쯤 밀려난 자리라야 두 헤더가 겹치는 회귀가 픽셀에 남는다.
        .sticky_pushed => second_group_top - m.item_gap - m.group_h / 2,
        else => 0,
    };
    const sticky_head: ?session_dock.types.StickyGroup = if (isSticky(scenario.id))
        .{ .group = two_groups[0].group, .top_px = 0, .next_top_px = second_group_top }
    else
        null;

    const dock_props = session_dock.types.Props{
        .viewport_px = scenario.viewport_px,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .displayed_count = if (scenario.id == .empty or scenario.id == .loading) 0 else 3,
        .loading = scenario.id == .loading,
        .refreshing = false,
        .spinner_phase = @intCast(scenario.now_ns % 8),
        .search = if (scenario.id == .empty) "" else "",
        // The partial fixture starts at the first card with an integer negative origin. It is the
        // same component geometry used by the host virtualization path, not a screenshot-only crop.
        // 스크롤바는 목록이 실제로 넘칠 때만 발행된다. 그 입력은 **보이는 item 수가 아니라** 전체
        // content 높이와 현재 offset이다(가상화 때문에 component는 보이는 창만 받는다). 그래서 이 둘을
        // 채우지 않으면 item이 몇 개든 스크롤바가 나오지 않는다 — 기존 골든 네 장에 스크롤바 픽셀이
        // 하나도 없던 이유가 이것이고, 그 상태에서는 스크롤바를 통째로 지워도 게이트가 통과한다.
        .scroll_content_height_px = if (scenario.id == .scrollbar)
            4000
        else if (isSticky(scenario.id))
            2 * m.group_h + 4 * m.card_h + 5 * m.item_gap
        else
            0,
        // 양 끝이 아닌 중간 위치라야 track과 thumb이 **둘 다** 픽셀로 남는다. 끝에 붙이면 한쪽 여백이
        // 사라져 thumb 높이·위치 회귀를 골든이 못 본다.
        .scroll_offset_px = if (scenario.id == .scrollbar) 1500 else sticky_offset,
        .sticky_group = sticky_head,
        .content_first_item_origin_y_px = switch (scenario.id) {
            .partial_scroll => -28,
            // 그룹 행을 절반쯤 스크롤 영역 위로 밀어, **radius를 가진** count pill이 잘리는 상태를 만든다.
            // 카드 배경(radius 0)으로는 못 보는 계약이 여기 걸린다: 잘린 변에 곡률이나 border stroke가
            // 생기면 안 된다(CPU가 rect를 미리 자르면 shader가 줄어든 rect를 원본으로 착각해 그렇게 된다).
            .partial_group_scroll => -22,
            // 목록 전체를 넘기므로 첫 항목 원점이 곧 -offset이다(가상화 창을 자르지 않는다).
            .sticky_at_rest, .sticky_pinned, .sticky_pushed => -@as(i32, @intCast(sticky_offset)),
            else => 0,
        },
        .items = switch (scenario.id) {
            .retained_list => &retained,
            .font_specimen => &font_specimen,
            .partial_scroll => retained[1..],
            .partial_group_scroll, .scrollbar => &retained,
            .sticky_at_rest, .sticky_pinned, .sticky_pushed => &two_groups,
            .empty, .loading, .sidebar_status_strip => &.{}, // strip 시나리오는 목록이 비어야 경계만 남는다
            // editor_gutter는 buildEditorGutterFrame이 처리한다 — 도크 목록을 타지 않는다.
            .detail_loading, .detail_ready, .detail_stale, .detail_unavailable, .editor_gutter, .editor_scrolled, .editor_font_large, .editor_hazard, .editor_wide_glyph, .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll, .editor_real_file => unreachable,
        },
    };
    const session_frame = try session_dock.build.build(dock_props, .{
        .nodes = buffers.dock_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.dock_actions,
    });
    const draws = try session_dock.view.view(dock_props, session_frame, .{}, tokens, .{ .ops = buffers.ops, .runs = buffers.text_runs, .text_bytes = buffers.text_bytes });
    return .{ .tree = session_frame.tree, .draws = draws };
}

fn buildDetailFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    const state: archive_detail.types.State = switch (scenario.id) {
        .detail_loading => .loading,
        .detail_ready => .ready,
        .detail_stale => .stale,
        .detail_unavailable => .unavailable,
        else => unreachable,
    };
    const turns = [_]archive_detail.types.Turn{
        .{ .role = .user, .text = "Show the current document work" },
        .{ .role = .assistant, .text = "This is a synthetic redacted recent-turn summary." },
    };
    const props = archive_detail.types.Props{
        .viewport_px = scenario.viewport_px,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .state = state,
        .provider = .claude,
        .title = "Document implementation review",
        .metadata = "3 messages · 3m ago · claude-opus-5",
        .turns = if (state == .ready) &turns else &.{},
        .action_record_count = if (state == .ready) 2 else 0,
        .spinner_phase = @intCast(scenario.now_ns % 8),
        .resume_enabled = state == .ready,
        .reveal_enabled = state == .ready,
        // A Lab fixture deliberately never claims a live provider mapping.
        .focus_live_enabled = false,
    };
    const detail_frame = try archive_detail.build.build(props, .{
        .nodes = buffers.detail_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.detail_actions,
    });
    const draws = try archive_detail.view.view(props, detail_frame, .{}, tokens, .{ .ops = buffers.ops, .runs = buffers.text_runs, .text_bytes = buffers.text_bytes });
    return .{ .tree = detail_frame.tree, .draws = draws };
}

pub fn dispatchRecordedAction(
    state: *chrome.ui.interaction.InteractionState,
    frame: Frame,
    event: chrome.ui.interaction.UiPointerEvent,
) !?chrome.ui.tree.UiActionId {
    return (try chrome.ui.interaction.dispatch(state, frame.tree, event)).action;
}

/// Lowers one already-built synthetic draw frame through the production lowerer. The caller owns
/// scenario construction and raster deinit; this leaf cannot create an OS surface or dispatch an
/// external effect.
pub fn lowerDraws(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tokens: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
) !Result {
    return .{ .raster = try lowering.lower(allocator, draws, tokens, cell_width_px, cell_height_px, true) };
}

test "Chrome Lab has no implicit surface and fails closed for an empty synthetic frame" {
    // The lowerer returns before reading tokens when there is no drawable box. This proves the Lab
    // seam cannot manufacture a fallback AppSession/window/terminal merely to make a fixture pass.
    const undefined_tokens: chrome.Tokens = undefined;
    try std.testing.expectError(error.NoBox, lowerDraws(std.testing.allocator, &.{}, &undefined_tokens, 8, 16));
}

test "Chrome Lab builds a deterministic font specimen card and records only its action" {
    const tokens = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var entries: [16]chrome.ui.tree.RectEntry = undefined;
    var items: [16]chrome.ui.layout.Item = undefined;
    var flex_scratch: [16]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [16]chrome.ui.layout.UiRect = undefined;
    // A specimen has three real cards. Each card now owns title, summary, provider,
    // metadata, and its disclosure affordance, in addition to generic paint. Keep this
    // fixture's explicit bounded scratch above that complete component contract rather
    // than relying on the old pre-disclosure 32-op estimate.
    var ops: [frame_op_capacity]chrome.draw.Op = undefined;
    var dock_nodes: [16]chrome.ui.tree.UiNode = undefined;
    var dock_actions: [12]session_dock.ids.Entry = undefined;
    var text_runs: [frame_run_capacity]chrome.draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const frame = try buildFrame(.{
        .id = .font_specimen,
        .viewport_px = .{ .width = 720, .height = 960 },
        .now_ns = 77,
    }, &tokens, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .ops = &ops,
        .dock_nodes = &dock_nodes,
        .dock_actions = &dock_actions,
        .text_runs = &text_runs,
        .text_bytes = &text_bytes,
    });

    try std.testing.expect(frame.tree.entries.len > 7);
    try std.testing.expect(frame.draws.ops.len > 8);
    try std.testing.expect(frame.draws.ops[0] == .quad);
    var saw_primary_ascii_probe = false;
    var saw_korean_fallback_probe = false;
    for (frame.draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            saw_primary_ascii_probe = saw_primary_ascii_probe or std.mem.indexOf(u8, run.text, "Il1 O0 MWmw") != null;
            saw_korean_fallback_probe = saw_korean_fallback_probe or std.mem.indexOf(u8, run.text, "가각간") != null;
        },
        else => {},
    };
    try std.testing.expect(saw_primary_ascii_probe);
    try std.testing.expect(saw_korean_fallback_probe);

    const card_index = frame.tree.find(session_dock.build.NodeIds.item(1)).?;
    const card_rect = frame.tree.entries[card_index].rect;
    try std.testing.expect(card_rect.width > 0);
    try std.testing.expect(card_rect.height > 0);
    try std.testing.expect(frame.tree.entries[card_index].effective_clip != null);
    const card_clip = frame.tree.entries[card_index].effective_clip.?;
    try std.testing.expect(card_clip.width > 0);
    try std.testing.expect(card_clip.height > 0);
    const card_x = card_rect.x + card_rect.width / 2;
    const card_y = card_rect.y + card_rect.height / 2;

    var state = chrome.ui.interaction.InteractionState{};
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, null), try dispatchRecordedAction(&state, frame, .{
        .phase = .down,
        .x_px = card_x,
        .y_px = card_y,
        .timestamp_ns = 1,
    }));
    // 8은 첫 카드의 select_card다. header가 정렬 토글 action을 하나 더 발급하면서 item action의 시작이
    // 한 칸 밀렸다(refresh 1 · scope 2~4 · search 5 · 정렬 6 · 첫 item 7~).
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, 8), try dispatchRecordedAction(&state, frame, .{
        .phase = .up,
        .x_px = 1000,
        .y_px = 1000,
        .timestamp_ns = 2,
    }));
}
