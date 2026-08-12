//! Session Dock 시각 골든 게이트.
//!
//! 무엇을 증명하는가: Chrome Lab이 **제품 lowering + Metal 오프스크린 렌더**로 남긴 캡처의 관심 영역이,
//! 커밋된 골든과 픽셀 단위로 같은지. chrome/renderer의 시각 계약(스크롤 클리핑, 액션 라벨,
//! 카드 밀도)은 지금까지 사람이 캡처를 눈으로 확인해 왔는데, 그 방식이 실제로 놓친 회귀가 있었다 —
//! 부분적으로 보이는 행이 "잘린" 것과 "세로로 눌린" 것을 구분하지 못해 클리핑이 죽은 상태를 정상으로
//! 보고했다(#1882 코드리뷰가 잡았다). 사람 눈이 놓치는 종류의 차이를 기계가 보게 하는 것이 목적이다.
//!
//! 왜 전체 프레임이 아니라 잘라서 보는가: 1920×960 PPM은 약 5.5 MB라 커밋할 수 없고, 무관한 UI 변경마다
//! 갱신해야 해서 결국 아무도 안 본다. 검증하려는 계약이 걸린 좁은 사각형 하나가 회귀를 더 정확히 지목한다.
//!
//! 골든 갱신: `MARU_UPDATE_GOLDEN=1 zig build test-dock-visual-golden` (기존 replay 골든과 같은 관례).
//! 갱신 후에는 **반드시 눈으로 확인**하고 커밋한다 — 자동 갱신은 회귀를 골든으로 굳힐 수 있다.
//!
//! **이 게이트가 신뢰할 수 있는 범위**: Lab은 제품 Session Dock과 **같은 두 텍스트 경로**를 탄다 —
//! 등록 SVG/PUA 아이콘은 셀 draw list(`buildIconTextDrawList`), 나머지 라벨은
//! `system_text.Artifact`(순수 픽셀 placement + 뷰포트 clip). 스크롤 뷰포트도 제품과 같은 출처
//! (published tree의 `content` 사각형)에서 가져와 넘긴다.
//!
//! 그래서 텍스트의 픽셀 정렬과 **텍스트 클리핑까지** 골든으로 고정할 수 있다. 예전에는 Lab이
//! `chrome_draw_lowering.RichTextArtifact`(셀 격자 + 오프셋, clip 파라미터 없음)를 써서 글자가 격자로
//! 스냅되고 잘리지도 않았고, 그 때문에 정렬·클리핑 case는 "고정하면 안 되는 것"으로 빼 뒀다
//! (`group-pill-clipped-edge`를 넣었다가 제거한 적이 있다). 이관 후 그 case가 돌아왔다.
//!
//! 남는 간극: Lab은 dock을 프레임 원점에 단독으로 그리므로 pane 합성(터미널과의 레이어 순서,
//! pane 오프셋)은 보지 않는다. 그건 실제 앱을 띄우는 archive 스모크의 몫이다.
//!
//! 왜 archive 스모크가 아니라 Lab인가: archive 스모크는 실제 앱을 띄우는 visible AppKit 픽스처라
//! `Maru.app` 번들(Swift host + web 번들 + 코드사인)을 통째로 요구한다. 시각 계약을 지키는 데 그 비용은
//! 불필요하다. Lab은 같은 제품 lowering과 Metal 렌더를 오프스크린으로 태우므로 번들 없이 결정적이고,
//! 창 생성 실패 같은 환경 변수도 없다. archive 스모크는 실제 사용자 플로우(포인터·키·provider 실행)
//! 검증에 그대로 남는다 — 두 게이트가 서로 다른 것을 본다.
//!
//! 캡처가 없으면 skip한다. 이 게이트는 Lab을 먼저 돌린 환경에서만 의미가 있고, 캡처 부재를 실패로
//! 만들면 Lab과 무관한 변경까지 막는다.
//!
//! 단 **CI처럼 스모크를 먼저 돌리도록 배선한 곳에서는 skip이 곧 무력화**다: 창 생성이나 캡처가 실패해도
//! 초록으로 지나가고, 로그를 아무도 안 보면 "게이트가 있다"는 착각만 남는다. `MARU_REQUIRE_GOLDEN=1`이면
//! 캡처 부재를 실패로 만든다 — `mise run macos-dock-visual-golden`이 그 값을 켠다.

const std = @import("std");
const ppm = @import("ppm");

const capture_root = "zig-out/maru-macos-chrome-lab";
const golden_root = "tests/fixtures/golden/dock";

/// GPU 렌더는 같은 기기·드라이버에서 결정적이지만, 러너가 바뀌면 rasterizer 미세 차이가 날 수 있다.
/// 채널당 2까지는 잡지 않는다 — 이번에 잡으려는 결함(클리핑 실패, 라벨 소실, 밀도 변화)은 그보다
/// 훨씬 큰 차이라 감도를 잃지 않는다.
const channel_tolerance: u8 = 2;

const Case = struct {
    name: []const u8,
    capture: []const u8,
    /// 이 사각형이 무엇을 지키는지 — 실패했을 때 사람이 바로 알 수 있게 계약을 적는다.
    contract: []const u8,
    rect: ppm.Rect,
};

const cases = [_]Case{
    // SB1 §5.2 — 이 항목이 그 절의 ⚠️(자동 가드 없음)를 닫는다. Zig가 값을 싣는 것까지는 테스트가 있었지만
    // **`.m`이 그 값으로 실제로 자르는지**는 아무도 안 봤다. 좌하단만 잘라 strip 바닥 경계 한 줄을 고정한다.
    .{
        .name = "sidebar-strip-stops-above-status-bar",
        .capture = "sidebar-status-strip.ppm",
        .contract = "사이드바 배경 strip이 창 바닥까지 가지 않고 상태바 높이만큼 위에서 끝난다(그 아래는 배경색)",
        .rect = .{ .x = 0, .y = 660, .w = 200, .h = 60 },
    },
    .{
        // 이 case가 생기기 전까지 **어떤 골든도 헤더를 보지 않았다.** crop이 전부 목록 영역(y≥200)에
        // 있어서, 헤더 utility를 통째로 지워도 골든 전부가 통과했다. 실제로 정렬 토글을 추가한 PR에서
        // 게이트가 아무 말도 하지 않았고, 사람이 캡처를 열어 보고서야 label이 상자 위쪽에 붙고 상자만
        // 옆 utility보다 크다는 것을 알았다.
        //
        // crop은 헤더 오른쪽 utility 띠를 잡는다. `로컬` provenance · 정렬 토글 · refresh가 한 줄에
        // 나란히 서고 서로 겹치지 않는지, 각자의 line box가 세로 중앙에 있는지가 한 사각형으로 판정된다.
        // 셋의 가로 배치는 `headerUtilityWidth`의 역산 하나에서 나오므로, 그 식이 틀어지면 여기서 바로
        // 드러난다.
        .name = "header-utility-row",
        .capture = "retained-list.ppm",
        .contract = "헤더 오른쪽에 `로컬`·정렬 토글·refresh가 겹치지 않고 한 줄로 서며 각자 세로 중앙에 있다",
        .rect = .{ .x = 240, .y = 20, .w = 240, .h = 60 },
    },
    .{
        .name = "partial-scroll-cards",
        .capture = "partial-scroll.ppm",
        .contract = "부분 스크롤된 카드 3행의 높이·간격이 DockMetrics대로다(축소되지 않는다)",
        .rect = .{ .x = 0, .y = 205, .w = 480, .h = 290 },
    },
    .{
        .name = "group-header-pill",
        .capture = "retained-list.ppm",
        .contract = "그룹 헤더의 이름·chevron·count pill이 행 안 제자리에 있다(pill이 아래로 새지 않는다)",
        .rect = .{ .x = 0, .y = 225, .w = 480, .h = 60 },
    },
    .{
        // GPU per-quad clip(#1885)의 핵심 계약: CPU가 rect를 미리 자르면 shader가 줄어든 rect를
        // 원본으로 착각해 **잘린 변에도 곡률과 border stroke**를 그린다. radius가 높이의 절반인
        // count pill이 스크롤 상단에 걸린 이 상태가 그 차이를 유일하게 드러낸다.
        .name = "group-pill-clipped-edge",
        .capture = "partial-group-scroll.ppm",
        .contract = "스크롤 상단에 걸린 그룹 count pill의 잘린 변이 직선이다(곡률·stroke가 생기지 않는다)",
        .rect = .{ .x = 396, .y = 220, .w = 84, .h = 32 },
    },
    .{
        .name = "expanded-actions",
        .capture = "detail-ready.ppm",
        .contract = "펼친 detail의 액션 버튼에 아이콘과 라벨이 있다(빈 상자가 아니다)",
        .rect = .{ .x = 0, .y = 660, .w = 480, .h = 60 },
    },
    .{
        // 이 case가 생기기 전까지 **어떤 골든도 스크롤바를 보지 않았다.** Lab이 스크롤 입력
        // (`scroll_content_height_px`·`scroll_offset_px`)을 채우지 않아 스크롤바가 아예 발행되지
        // 않았고, 그래서 스크롤바를 통째로 지워도 골든 네 장이 전부 통과했다. 게이트가 있다는 것과
        // 그 게이트가 이것을 본다는 것은 다르다.
        //
        // 이 case가 더하는 것은 geometry 계산이 아니라 **그 계산이 GPU 픽셀까지 도달한다**는 것이다.
        // `scrollbarGeometry`의 산술은 build.zig 단위 테스트가 이미 본다. 그 사이 구간 — entry 발행,
        // clip, layer 순서, Metal lowering — 은 픽셀로만 판정된다.
        //
        // crop은 도크 우측 gutter와 그 왼쪽 content 가장자리를 함께 잡는다. 세로로는 track 위쪽 빈
        // 구간·thumb·아래쪽 빈 구간이 모두 들어가므로, thumb의 위치와 높이, track의 범위, 그리고
        // 스크롤바가 content 위로 넘어오는 회귀까지 한 사각형이 판정한다.
        //
        // 시나리오는 스크롤 입력만 주입한다 — 이 두 필드는 `scrollbarFor`만 읽고 가상화에는 관여하지
        // 않으므로, 카드가 offset만큼 밀렸는지는 이 case의 계약이 아니다(그건 `project`의 몫이다).
        .name = "scrollbar-track-and-thumb",
        .capture = "scrollbar.ppm",
        .contract = "넘치는 목록에 track과 thumb이 gutter 안에 있다(발행되고, content를 침범하지 않는다)",
        .rect = .{ .x = 452, .y = 200, .w = 28, .h = 400 },
    },
    // sticky의 세 상태는 clamp **한 줄**에서 나온다. 하나만 캡처하면 나머지 둘이 무판정으로 남고,
    // 그 상태로는 `next_y - h` 항을 빼도(=두 헤더가 겹쳐도) 게이트가 통과한다.
    //
    // crop은 목록 상단 밴드를 잡는다. 여기가 헤더와 지나가는 카드가 만나는 유일한 자리이고,
    // quad·text가 서로 다른 레이어라 **글자가 헤더를 뚫고 나오는** 회귀가 픽셀로만 판정된다.
    .{
        .name = "sticky-head-at-rest",
        .capture = "sticky-at-rest.ppm",
        .contract = "첫 그룹에 닿은 상태의 헤더가 흐름 그대로 있다(고정 때문에 자리가 튀지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
    .{
        .name = "sticky-head-pinned",
        .capture = "sticky-pinned.ppm",
        .contract = "지나간 카드가 고정 헤더 **밑으로** 지나간다(헤더를 뚫고 글자가 보이지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
    .{
        .name = "sticky-head-pushed",
        .capture = "sticky-pushed.ppm",
        .contract = "다음 그룹 헤더가 앞 헤더를 밀어낸다(둘이 같은 자리에 겹치지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
    // N1 §4.1 — 편집기 gutter. crop이 1~12번 줄 번호를 전부 담아 **우측 정렬**을 한 사각형으로 본다.
    // 자릿수가 1에서 2로 넘어가는 경계(9→10)가 이 안에 있어, 정렬이 좌측으로 뒤집히거나 셀↔픽셀
    // 변환이 어긋나면 오른쪽 끝이 흐트러져 바로 드러난다.
    //
    // **폭은 정확히 gutter까지(8셀 = 64px)다.** 초판은 "여유 한 칸"이라며 80px를 잡았는데 본문이
    // 셀 8(x=64)에서 시작하므로 16px가 crop 안에 들어왔고, 그러면 fixture 본문을 한 글자만 고쳐도
    // "줄 번호가 우측 정렬로…"라는 계약을 내건 case가 실패해 리뷰어를 오도한다.
    .{
        .name = "editor-gutter-line-numbers",
        .capture = "editor-gutter.ppm",
        .contract = "줄 번호가 우측 정렬로 같은 오른쪽 끝에 서고, 9→10 자릿수 변화에도 정렬이 유지된다",
        .rect = .{ .x = 0, .y = 0, .w = 64, .h = 200 },
    },
    // 같은 캡처의 본문 영역. gutter crop과 나누는 이유는 **실패했을 때 어느 쪽이 깨졌는지 바로
    // 알기 위해서**다 — 한 사각형으로 합치면 "편집기가 달라졌다"까지만 나온다.
    //
    // 이 사각형이 지키는 것: ⑴ 본문이 gutter 오른쪽(x=64px)에서 시작한다, ⑵ 줄 번호와 **같은
    // baseline**에 선다(셀↔픽셀 변환이 어긋나면 세로로 반 칸 밀린다), ⑶ 탭이 탭스톱으로 전개돼
    // 들여쓰기 깊이가 줄마다 다르다, ⑷ 빈 줄이 자리를 유지해 다음 줄이 위로 당겨지지 않는다,
    // ⑸ 한글이 fallback 폰트로 그려진다.
    // N1 §4 — 뷰포트 컬링. 문서 중간(first_row=5)으로 스크롤한 상태를 본다. **줄 번호가 1이 아니라
    // 6에서 시작**하고 6행만 그려지는 것이 이 case의 계약이다. 컬링이 죽으면 1번부터 전부 그려져
    // 곧바로 드러나고, off-by-one이 생기면 시작 번호가 5나 7이 된다.
    .{
        .name = "editor-viewport-scrolled",
        .capture = "editor-scrolled.ppm",
        .contract = "스크롤된 뷰포트가 first_row+1부터 visibleRows만큼만 그린다(1번부터 그리지 않는다)",
        .rect = .{ .x = 0, .y = 0, .w = 340, .h = 120 },
    },
    // N1 §4.1 — **폰트 크기 연동**. 폰트를 1.5배로 주면 글리프(높이 10px → 14px)와 배치가 함께
    // 커진다. 본문 시작이 64px가 아니라 96px이고 gutter는 계속 8셀이다.
    //
    // 이것이 gutter를 measured가 아니라 셀 경로에 둔 근거다(§4.1). gutter가 상수 픽셀을 쓰거나
    // 폰트 크기가 chrome 토큰에 고정되면 둘 다 여기서 드러난다.
    .{
        .name = "editor-font-large",
        .capture = "editor-font-large.ppm",
        .contract = "폰트를 키우면 글리프와 배치가 함께 커진다(글리프 높이와 본문 시작 열이 비례한다)",
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 180 },
    },
    // N1 §3.8 — **적대적 입력 가시화**. 화면과 파일 내용이 달라지게 만드는 문자(BiDi override·폭 0·
    // C0 제어·비표준 공백)가 `<U+202E>` 같은 표기로 드러나는지 본다.
    //
    // **이 case가 유일한 자동 가드다.** 가시화가 꺼지면 그 줄들이 **평범해 보이고**(그것이 공격의
    // 목적이다) 헤드리스 단언도 통과한다 — 숨은 문자는 여전히 문자열에 있으니까. 픽셀만이 "화면에
    // 보이는가"를 답한다.
    .{
        .name = "editor-hazard-visible",
        .capture = "editor-hazard.ppm",
        .contract = "BiDi·폭 0·제어·비표준 공백 문자가 <U+XXXX> 표기로 화면에 드러난다(문서는 바뀌지 않는다)",
        .rect = .{ .x = 56, .y = 0, .w = 300, .h = 96 },
    },
    .{
        .name = "editor-content-text",
        .capture = "editor-gutter.ppm",
        .contract = "본문이 gutter 오른쪽에서 줄 번호와 같은 baseline에 서고, 탭 전개·빈 줄 자리·한글 fallback이 유지된다",
        .rect = .{ .x = 56, .y = 0, .w = 320, .h = 200 },
    },
    // N1 §4.2 — **표시 폭**. 이모지 ZWJ 시퀀스·스킨톤·국기·VS16·동그란 번호가 각각 2칸을 차지하는지 본다.
    //
    // fixture가 줄마다 같은 열에 `|`를 두었으므로 **폭이 틀리면 그 줄의 막대만 어긋난다**. 헤드리스
    // 단언으로는 "폭 계산 함수가 2를 돌려준다"까지만 확인되고, 그 값이 실제 배치에 반영됐는지는 픽셀만이
    // 답한다(폭과 배치가 갈리던 것이 바로 이 회귀였다).
    //
    // **막대만 본다 — 이모지 그림은 골든 대상이 아니다.** 처음엔 본문 전체(w=300)를 덮었는데 CI에서만
    // 깨졌다: 같은 이모지가 macOS 버전에 따라 다르게 그려져 최대 채널 차이 200이 났다(허용치 2). 그림은
    // Apple Color Emoji가 소유하고 우리가 계약하는 것은 **몇 칸을 차지하는가**뿐이라, 그 답이 드러나는
    // 막대 열만 잠근다. 폭이 한 칸이라도 틀리면 그 줄 막대가 8px 밀려 즉시 걸린다.
    // §3.8 "초장문 단일 줄" — fixture 마지막 줄이 2340자다. **상한이 없으면 이 캡처가 아예 만들어지지
    // 않는다**(그 줄 하나가 scratch를 삼켜 `build` 전체가 OutOfSpace로 죽고 스모크가 실패한다) —
    // `MARU_REQUIRE_GOLDEN=1`이 캡처 부재를 실패로 만들므로 rect와 무관하게 그 회귀는 잡힌다.
    //
    // 이 case가 더하는 것은 **상한이 있을 때 어디까지 그리는가**다. 화면 폭에서 정확히 끊기는지,
    // 그 너머로 새지 않는지를 고정한다.
    .{
        .name = "editor-long-line-clipped",
        .capture = "editor-gutter.ppm",
        .contract = "2340자 줄이 본문 폭에서 끊기고 그 너머로 새지 않는다(줄 전체를 만들지 않는다)",
        .rect = .{ .x = 0, .y = 250, .w = 480, .h = 22 },
    },
    // §4 세로 축 — **랩**. fixture 첫 줄이 `0123456789`를 12번 반복한 **자**라, 이어지는 행의 첫
    // 숫자가 앞 행 마지막 숫자 다음이면 조각이 정확히 맞물린 것이다(실측: 52열씩 세 행).
    //
    // 자가 필요한 이유는 **글자가 화면 오른쪽에 닿아 끝나면 "폭에 맞게 접혔다"와 "넘쳐서 잘렸다"가
    // 그림상 같아 보이기** 때문이다. 숫자는 그 둘을 가른다.
    .{
        .name = "editor-wrap-ruler",
        .capture = "editor-wrap.ppm",
        .contract = "본문 폭을 넘는 줄이 52열에서 접혀 다음 시각 행으로 빠짐없이 이어진다",
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 48 },
    },
    // 같은 캡처의 **번호 열만**. 랩된 두 번째 이후 행에 번호가 비고(§4), 그 아래 줄 번호가 밀리지
    // 않는지를 고정한다 — 본문과 gutter가 각자 행을 세면 숫자는 다 그려지지만 본문과 어긋나므로,
    // 번호가 있고 없고가 아니라 **어느 행에 있는가**가 판정이다.
    // 같은 캡처의 **한글 줄**(4번 줄, 3행). fixture에 한글을 넣은 이유가 *"`ceil` 근사가 틀리는
    // 경우를 드러낸다"*인데 위 두 rect가 모두 ASCII 영역(자·번호)이라 **그 줄을 아무도 안 봤다** —
    // 적대적 검증이 잡았다. 2칸 글자가 행 끝에 한 칸을 남기며 접히는 자리가 여기서 고정된다.
    //
    // 이모지와 달리 한글은 **번들 폰트(Jetendard)**로 그려져 OS 버전에 흔들리지 않는다
    // (`editor-wide-glyph-hangul`이 같은 근거로 CI를 통과해 왔다).
    .{
        .name = "editor-wrap-hangul",
        .capture = "editor-wrap.ppm",
        .contract = "2칸 글자가 쪼개지지 않고 접힌다 — 행 끝에 한 칸이 남아도 다음 행으로 넘긴다",
        .rect = .{ .x = 0, .y = 112, .w = 480, .h = 48 },
    },
    // **2칸 글자가 행 경계에 걸치는 자리.** 51칸 ASCII 뒤의 한글이 52번째 칸에 들어갈 수 없어
    // 그 칸을 비우고 다음 행으로 넘어간다.
    //
    // 위 `editor-wrap-hangul`만으로는 이 계약에 **가드가 없었다** — 자연스러운 한글 문장은 `col`이
    // 짝수로만 늘어 본문 폭 52에서 정확히 떨어지므로, 경계 판정을 `col + w > 폭`에서 `col >= 폭`으로
    // 바꿔도 그림이 같다(적대적 검증이 그 반증을 실제로 통과시켰다). 홀수 위치에서 걸치게 해야 갈린다.
    .{
        .name = "editor-wrap-wide-boundary",
        .capture = "editor-wrap.ppm",
        .contract = "행 끝 한 칸에 2칸 글자가 안 들어가면 그 칸을 비우고 넘긴다(쪼개지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 40 },
    },
    .{
        .name = "editor-wrap-line-numbers",
        .capture = "editor-wrap.ppm",
        .contract = "랩으로 이어진 행은 번호가 비고, 논리 줄 번호는 1..7로 밀리지 않는다",
        .rect = .{ .x = 0, .y = 0, .w = 60, .h = 215 },
    },
    // §4 — **세로 스크롤이 시각 행 단위다.** 화면이 랩된 줄의 *중간 행*(`row.`)에서 시작하고,
    // **그 행에는 줄 번호가 없다** — 이어지는 조각이기 때문이다.
    //
    // 논리 줄 단위 뷰포트로는 이 그림을 만들 수 없다: 줄 머리에서만 멈출 수 있어 랩된 줄 하나가
    // 화면보다 길면 그 아래를 볼 방법이 없다. `visual_map.RowIndex`가 시각 행을 논리 줄+조각으로
    // 풀고 `content.first_piece`가 그 조각부터 그린다.
    .{
        .name = "editor-wrap-scrolled-mid-line",
        .capture = "editor-wrap-scrolled.ppm",
        .contract = "랩된 긴 줄의 중간 조각부터 화면을 채우고 그 행들에는 번호가 없다",
        // **6행 전체를 본다.** 위 두 행만 보면 "화면 아래가 비는" 결함이 캡처에 나타나도 골든이
        // 통과한다 — 실제로 그 상태였고 코드 리뷰가 잡았다.
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 100 },
    },
    // §4 — **가로 스크롤**(`first_col = 20`). 같은 fixture를 랩 대신 밀어서 본다.
    //
    // **자 줄(y<16)은 일부러 뺐다.** `0123456789`가 10주기라 20열을 밀어도 그림이 같아서, 그 줄을
    // 넣으면 스크롤이 통째로 죽어도 통과하는 rect가 된다. 대신 `fn wrap(...)`·주석 줄들이 앞을
    // 잘라낸 채 시작하는 것을 본다.
    .{
        .name = "editor-hscroll-body",
        .capture = "editor-hscroll.ppm",
        .contract = "본문이 first_col만큼 밀려 그려진다(앞 20열이 화면에 없다)",
        .rect = .{ .x = 0, .y = 16, .w = 480, .h = 64 },
    },
    // **gutter가 제자리인 것은 위 rect가 함께 본다**(x가 0부터라 번호 열을 포함한다). 따로 case를
    // 두었다가 지웠다 — gutter는 `first_col`을 아예 받지 않아 밀릴 수가 없고, 그래서 그 case가
    // 잡을 회귀가 지금은 없다. gutter가 가로 위치를 알게 되면 그때 다시 넣는다.
    // 2칸 글자가 **왼쪽** 경계에 걸치는 자리(51칸 ASCII + 한글). 오른쪽 경계는 랩이 보고, 이쪽은
    // 가로 스크롤이 본다 — 반쪽을 그릴 수 없으므로 통째로 빼고 한 칸이 빈다.
    .{
        .name = "editor-hscroll-wide-boundary",
        .capture = "editor-hscroll.ppm",
        .contract = "밀린 뒤에도 2칸 글자가 쪼개지지 않는다(왼쪽 경계에 걸치면 통째로 뺀다)",
        .rect = .{ .x = 0, .y = 140, .w = 480, .h = 24 },
    },
    // **오른쪽 경계에 걸친 2칸 글자.** fixture 마지막 줄이 `z`×51 + 한글이라, 본문 52열에서 한글이
    // 열 51~52를 요구하는데 52가 없다 — 통째로 빼야 하고 마지막 칸이 빈다.
    //
    // 이것이 없을 때 **렌더러가 반쪽을 그렸다**(실측: 마지막 셀에 한글 왼쪽 절반, 밝은 픽셀 14개).
    // 원인은 `expandTabs`가 원본을 빌려주는 길에서 열 상한을 안 지킨 것이고, 랩이 켜졌을 때는
    // `visual_map`이 뒤에서 다시 잘라 가려져 있었다 — 랩이 꺼진 화면에서만 드러난다.
    // §3.8 — **표기가 오른쪽 경계에 걸쳐도 사라지지 않는다.** 위 `editor-hazard-visible`은 표기가
    // 화면 안에 온전히 들어가는 경우만 보므로, 걸쳤을 때 통째로 빠지는 회귀를 못 잡는다.
    //
    // 통째로 빠지면 앞뒤가 붙어 **위험 문자의 존재가 화면에서 사라진다** — §3.8이 막으려는 것이
    // 정확히 그것이다(적대적 검증이 `ab<U+202E>cd` → `abcd`를 실제로 만들었다). 잘린 `<U+2`는
    // 이상해 보여도 "여기 뭔가 있다"를 남긴다.
    //
    // 아랫줄은 **한 cluster에 hazard cp와 정상 cp가 섞인 모양**(ZWJ가 앞 글자에 흡수된다)이고,
    // 이것이 정수 언더플로 패닉을 만들었다 — **캡처가 만들어진다는 것 자체가 그 회귀의 가드다.**
    .{
        .name = "editor-hazard-right-edge",
        .capture = "editor-hazard.ppm",
        .contract = "경계에 걸친 §3.8 표기가 잘려서라도 남는다(통째로 빠져 앞뒤가 붙지 않는다)",
        .rect = .{ .x = 360, .y = 172, .w = 120, .h = 36 },
    },
    .{
        .name = "editor-right-edge-wide-glyph",
        .capture = "editor-gutter.ppm",
        .contract = "오른쪽 경계에 2칸 글자가 걸치면 통째로 뺀다(반쪽을 그리지 않는다)",
        .rect = .{ .x = 400, .y = 264, .w = 80, .h = 24 },
    },
    .{
        .name = "editor-wide-glyph-bars",
        .capture = "editor-wide-glyph.ppm",
        .contract = "이모지·가족·스킨톤·국기·VS16·동그란 번호가 각 2칸을 차지해 줄 끝 | 가 한 열에 선다",
        .rect = .{ .x = 220, .y = 0, .w = 16, .h = 160 },
    },
    // 같은 fixture의 **한글 줄**. 이모지가 없어 OS 렌더에 의존하지 않으므로 라벨과 글자를 함께 덮는다 —
    // 한글 폴백(`font.fallback` 기본값 Jetendard)이 바뀌면 여기서 드러난다(docs/font-strategy.md).
    .{
        .name = "editor-wide-glyph-hangul",
        .capture = "editor-wide-glyph.ppm",
        .contract = "한글이 2칸 격자에 맞아 라벨과 같은 줄에서 자간이 벌어지지 않는다",
        .rect = .{ .x = 40, .y = 32, .w = 150, .h = 16 },
    },
};

test "session dock visual golden" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const update = std.c.getenv("MARU_UPDATE_GOLDEN") != null;
    // 갱신 중에는 캡처가 아직 없을 수 있으므로 요구하지 않는다.
    const require_captures = !update and std.c.getenv("MARU_REQUIRE_GOLDEN") != null;

    var checked: usize = 0;
    for (cases) |case| {
        var capture_path_buf: [256]u8 = undefined;
        const capture_path = try std.fmt.bufPrint(&capture_path_buf, "{s}/{s}", .{ capture_root, case.capture });
        const capture_bytes = std.Io.Dir.cwd().readFileAlloc(io, capture_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            // 스모크를 안 돌린 환경에서는 이 게이트가 의미 없으므로 건너뛴다. 그러나 스모크를 먼저
            // 배선한 곳(CI)에서는 **한 장만 없는 것도 결함**이다 — 나머지 case가 통과하면 `checked > 0`이라
            // 아래 전체-부재 가드에 걸리지 않고, 그 시나리오의 렌더가 죽었다는 사실이 초록에 묻힌다.
            error.FileNotFound => {
                if (require_captures) {
                    std.debug.print("골든 캡처가 없다: {s} (시나리오 렌더가 실패했는가?)\n", .{capture_path});
                    return error.VisualGoldenCaptureMissing;
                }
                continue;
            },
            else => return err,
        };
        defer allocator.free(capture_bytes);

        var frame = try ppm.decodeP6(allocator, capture_bytes);
        defer frame.deinit(allocator);
        var window = ppm.crop(allocator, frame, case.rect) catch |err| {
            std.debug.print(
                "golden crop이 캡처 밖이다: {s} (캡처 {d}x{d}, 요청 {d},{d} {d}x{d}) — viewport가 바뀌었으면 rect를 갱신하라\n",
                .{ case.name, frame.width, frame.height, case.rect.x, case.rect.y, case.rect.w, case.rect.h },
            );
            return err;
        };
        defer window.deinit(allocator);

        var golden_path_buf: [256]u8 = undefined;
        const golden_path = try std.fmt.bufPrint(&golden_path_buf, "{s}/{s}.ppm", .{ golden_root, case.name });

        if (update) {
            const encoded = try ppm.encodeP6(allocator, window);
            defer allocator.free(encoded);
            try std.Io.Dir.cwd().createDirPath(io, golden_root);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = encoded });
            checked += 1;
            continue;
        }

        const golden_bytes = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("golden이 없다: {s} (MARU_UPDATE_GOLDEN=1로 만들고 눈으로 확인한 뒤 커밋하라)\n", .{golden_path});
                return err;
            },
            else => return err,
        };
        defer allocator.free(golden_bytes);
        var golden = try ppm.decodeP6(allocator, golden_bytes);
        defer golden.deinit(allocator);

        const diff = ppm.compare(golden, window, channel_tolerance) catch |err| {
            std.debug.print("golden 크기가 캡처와 다르다: {s} — {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        if (diff.differing_pixels != 0) {
            std.debug.print(
                "시각 회귀: {s}\n  계약: {s}\n  다른 픽셀 {d}개, 최대 채널 차이 {d}, 처음 어긋난 곳 ({d},{d})\n  갱신이 의도라면 MARU_UPDATE_GOLDEN=1로 다시 만들고 **눈으로 확인**하라\n",
                .{ case.name, case.contract, diff.differing_pixels, diff.max_channel_delta, diff.first_x, diff.first_y },
            );
            return error.VisualGoldenMismatch;
        }
        checked += 1;
    }

    if (checked == 0) {
        // 캡처가 하나도 없으면 조용히 통과하지 않는다 — "게이트가 돌았다"는 착각이 가장 위험하다.
        std.debug.print("dock 시각 골든: 캡처가 없어 건너뛴다(먼저 `zig build macos-chrome-lab-smoke`)\n", .{});
        // 스모크를 먼저 돌리도록 배선한 곳(CI)에서는 캡처 부재 자체가 결함이다. 창 생성이나 캡처가
        // 실패했는데 게이트가 초록이면 그 실패를 영원히 못 본다.
        if (require_captures) return error.VisualGoldenCapturesMissing;
    }
}
