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
//! 남는 간극(줄어드는 중): Lab은 dock을 프레임 원점에 단독으로 그려 왔다. 2026-08-25에 그 축의 **첫
//! 조각**이 열렸다 — `dock-over-status-bar`는 도크 뷰포트를 상태바 높이만큼 줄여 세우고 그 아래에 띠를
//! 심어, 목록이 자기 뷰포트에서 멈추는지를 **이웃과의 경계로** 본다. 아직 못 보는 것은 **가로 이웃**
//! (터미널 pane이 도크 왼쪽에 있을 때의 레이어 순서·오프셋)이다. 그쪽은 Lab의 텍스트 경로에 pane 원점
//! 개념이 없어(제품은 `collectMeasuredTextFromCache`가 origin을 받는다) 파이프라인을 함께 손봐야 한다.
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

// **잡음 예산을 두지 않는다.** 2026-08-24 에 도크 face 를 제품과 맞추면서 CI 와 개발기의 캡처가 갈렸고
// (말줄임표 한 글자에서 20 픽셀·최대 채널 차이 31), 그것을 "러너 rasterizer 차이"로 보고 면적 비례
// 관용을 넣으려 했다. **그 진단이 틀렸다** — 원인은 Lab 이 번들 폰트의 Regular 만 등록해 굵은 글씨가
// 기기에 있는 face 로 흘러간 것이었고(`chrome_lab_smoke.zig` 의 `assetMembers`), 등록을 고치자 러너의
// 캡처가 **0 픽셀** 차이로 맞았다. 근거가 사라진 관용은 게이트만 약하게 하므로 넣지 않는다. 다시 차이가
// 나면 그때는 원인을 찾을 일이지 예산을 늘릴 일이 아니다.

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
        // crop이 **사이드바 오른쪽 절반부터** 시작하는 이유: 같은 캡처의 왼쪽 절반에는 §5.3 밴드가 있다.
        // 두 계약을 한 사각형에 섞으면 실패했을 때 strip이 샌 것인지 밴드가 샌 것인지 사람이 캡처를 열어
        // 봐야 하므로, 각 case가 한 표면만 보게 갈라 뒀다(밴드 폭은 `chrome_lab_smoke.zig`가 정한다).
        .name = "sidebar-strip-stops-above-status-bar",
        .capture = "sidebar-status-strip.ppm",
        .contract = "사이드바 배경 strip이 창 바닥까지 가지 않고 상태바 높이만큼 위에서 끝난다(그 아래는 배경색)",
        .rect = .{ .x = 96, .y = 660, .w = 104, .h = 60 },
    },
    .{
        // SB1 §5.3 — 이 항목이 그 절의 ⚠️를 닫는다. §5.2와 **같은 형태의 구멍**이었다: 자를 구간을 Zig가
        // 정하는 것까지는 순수 함수 테스트가 봤지만, `.m`이 그 값을 **under 버킷(layer 0) draw에 실제로
        // 거는지**는 아무도 안 봤다. 그래서 클립을 지워도 전 테스트가 green이었고, 결함은 사용자가 사이드바에
        // 마우스를 올렸을 때 상태바가 사라지는 것으로 드러났다.
        //
        // 시나리오가 뷰포트 바닥을 40px 가로지르는 layer 0 quad를 심는다(제품에서 그 자리에 오는 것은 카드
        // 호버 밴드다). crop은 그 경계 한 줄만 타이트하게 잡는다 — strip case와 같은 캡처지만 **보는 것이
        // 다르다**: 저쪽은 `.m`이 직접 그리는 strip, 이쪽은 호스트가 발행한 quad를 `.m`이 자르는가다.
        // 클립이 빠지면 이 사각형 아래쪽 절반이 밴드 색으로 채워져 즉시 어긋난다.
        .name = "sidebar-under-quad-stops-above-status-bar",
        .capture = "sidebar-status-strip.ppm",
        .contract = "사이드바 layer 0 quad(카드 호버 밴드 자리)가 상태바 띠를 덮지 않고 뷰포트 바닥에서 끊긴다",
        .rect = .{ .x = 0, .y = 684, .w = 84, .h = 20 },
    },
    .{
        // SB1 §5.3의 **나머지 절반**이다. 위 case가 "아래를 자른다"를 지키는 동안, 이쪽은 "**위는 안 자른다**"를
        // 지킨다 — under 버킷에는 스크롤을 타지 않는 헤더 고정 quad(검색 줄 밑줄·아이콘 호버·접힘 토글)가
        // 섞여 있어서, 셀과 통일한답시고 `scissor_top`을 걸면 그것들이 통째로 사라진다.
        //
        // 그 회귀는 **제품 캡처를 사람이 열어 봐야만** 보였다(스크롤한 사이드바에서 헤더 밑줄이 없어진다).
        // 시나리오가 `sidebar_scissor_top_px`에 0이 아닌 값을 싣고 그 위에 quad를 심어, 이제 골든이 본다.
        // crop은 헤더 밑줄 자리만 잡는다 — 같은 캡처의 다른 두 case(y≥660)와 세로로 갈려 서로를 안 가린다.
        .name = "sidebar-header-quad-survives-scissor",
        .capture = "sidebar-status-strip.ppm",
        .contract = "스크롤 클립 구간 위의 헤더 고정 quad(검색 줄 밑줄 자리)는 잘리지 않는다",
        .rect = .{ .x = 0, .y = 44, .w = 180, .h = 24 },
    },
    .{
        // 이 crop이 없으면 상자가 사라지거나 요약 줄과 자리가 바뀌어도 아무 검사가 말하지 않는다.
        .name = "scm-commit-box",
        .capture = "scm-rows.ppm",
        .contract = "탭 줄 바로 아래에 커밋 입력(빈 상자는 안내 문구)과 **채운** 커밋 버튼이 이 순서로 선다",
        // 3판에서 커밋 줄이 **위로** 올라왔다(§3.5) — 이 뷰의 주 동작이 목록에 밀려 스크롤 밖으로
        // 나가지 않게. 이 crop이 그 순서와 버튼의 채움을 함께 고정한다.
        // **y는 고정 chrome과 목록 구성이 함께 정한다.** 2026-08-16에 탭 줄이 28 → 34로 자랐고,
        // ②b에서 커밋 줄이 고정 chrome에서 **목록 안**으로 내려가며 그 아래가 전부 움직였다.
        // 숫자만 두고 눈으로 확인하지 않으면 crop이 엉뚱한 띠를 정답으로 굳힌다.
        .rect = .{ .x = 0, .y = 88, .w = 480, .h = 69 },
    },
    .{
        // 머리 줄은 동작 아이콘 자리를 평소에 **비워 두지 않는다**(빈 띠 52px 을 안 남기려고). 그래서
        // 호버하는 순간 아이콘과 브랜치·개수 배지가 같은 자리를 다투는데, 옛 답("배경색 quad 로 덮는다")은
        // chrome quad 가 chrome 글자보다 **먼저** 그리는 층이라 원리적으로 통하지 않았다 — 덮개는 색까지
        // 맞춰 놓고도 글자를 하나도 못 가렸고, 새로고침 아이콘이 브랜치 이름 위에 그대로 겹쳐 보였다
        // (사용자 캡처 2026-08-21). 이 crop 이 그 띠를 픽셀로 고정한다: 아이콘 둘만 있고 그 밑에 글자가
        // 남아 있지 않아야 한다. 실제 before/after 차이가 이 사각형 안(x 308..479, y 58..87)이었다.
        .name = "scm-repo-hover-actions-have-no-text-under-them",
        .capture = "scm-repo-hover.ppm",
        .contract = "머리 줄을 호버하면 동작 아이콘이 서고, 그 자리의 브랜치·개수 배지는 아예 그려지지 않는다(겹침 없음)",
        .rect = .{ .x = 300, .y = 56, .w = 180, .h = 34 },
    },
    .{
        // 가상화는 창의 첫 항목을 **음수 origin** 으로 올려 두므로 그 행의 rect 는 목록 뷰포트 밖까지
        // 이어진다. 그 rect 를 clip 으로 실으면 clip 이 뷰포트보다 커져 **아무것도 자르지 않고**, 행의
        // 칠과 글자가 위쪽 고정 chrome(탭 줄·요약 줄) 위에 그려진다(사용자 캡처 2026-08-21). 스크롤이
        // 없는 `scm-rows` 로는 이 상태를 만들 수 없다. crop 은 요약 줄 아래 경계에 걸친 개수 배지를
        // 잡는다 — 회귀하면 그 알약이 경계 위로 온전히 떠오른다(실제 차이가 y 51..57 이었다).
        // **2026-08-25 — 이 crop 은 오래 절반만 보고 있었다.** 계약문은 "행"이라 적었지만 crop 이 잡은
        // 것은 개수 알약, 즉 **quad** 하나였다. quad 는 tree 의 `effective_clip` 이 잘라 주므로 골든은
        // 초록이었고, 같은 행의 **글자**는 아무 데서도 안 잘리고 있었다(host 가 텍스트 뷰포트를 안
        // 넘겼다 — docs/scroll-area.md §5.1). 그 배선이 서면서 이 crop 이 71픽셀 달라졌다.
        .name = "scm-scrolled-row-stops-at-list-viewport",
        .capture = "scm-scrolled.ppm",
        .contract = "스크롤로 밀린 행은 칠도 글자도 목록 뷰포트 위(요약 줄·탭 줄)에 나오지 않고 그 경계에서 잘린다",
        .rect = .{ .x = 420, .y = 42, .w = 60, .h = 28 },
    },
    .{
        // caret·선택 밴드·랩은 **편집 중일 때만** 그려진다. 자리 계산이 열 → 셀 폭 환산이라 한 칸
        // 어긋나도 단위 테스트는 통과하고(열 숫자는 맞다) 화면만 틀린다 — 그 차이는 픽셀로만 보인다.
        .name = "scm-commit-edit",
        .capture = "scm-commit-edit.ppm",
        .contract = "편집 중인 상자는 제목·빈 줄·접힌 본문을 줄마다 그리고, 선택 밴드는 줄을 넘어 잘리며, caret은 그 줄 그 열에 선다",
        // **Lab에서는 밴드가 글자보다 넓게 보인다.** caret·밴드는 셀 열 산술인데(§12.3 ①) Lab의 셀 폭은
        // 시나리오 상수(8px)이고 그 폭으로 13pt 글자를 그리지 않기 때문이다 — 제품에서는 chrome 글자가
        // 사용자 등폭 폰트라 셀 = 실제 advance이고, 실측 캡처에서 밴드가 글자를 정확히 덮는 것을 확인했다.
        // 이 골든이 고정하는 것은 **자리와 존재**(어느 줄·몇 열·있는가)이지 글자와의 픽셀 정렬이 아니다.
        .rect = .{ .x = 0, .y = 88, .w = 480, .h = 104 },
    },
    .{
        // **이 컴포넌트에도 골든이 없었다.** 그래서 재는 쪽(`menuRect`)과 그리는 쪽(`view`)이 갈려 가장 긴
        // 줄이 상자 테두리에 닿는 결함이 나갔다 — 크래시하지 않고 픽셀로만 보이는 종류다. 이 crop 은 체크
        // 열이 상자 폭에 **들어갔는지**를 오른쪽 여백으로 본다.
        .name = "context-menu-checked-width",
        .capture = "context-menu-checked.ppm",
        .contract = "켜짐 표시(✓)가 라벨 앞 2칸을 차지하고, 가장 긴 줄 뒤에 우측 패딩이 남는다",
        // 앵커(24, 24)에서 두 줄짜리 상자 하나. 여백까지 담아야 "테두리에 닿는가"가 보인다.
        .rect = .{ .x = 16, .y = 16, .w = 160, .h = 48 },
    },
    .{
        // **보내기 구획**(NS4~NS6). 대상 라벨은 `이름 — 폴더 (브랜치)` 라 이 메뉴에서 **가장 긴 줄**이고,
        // 그래서 위 두 시나리오가 세운 "가장 긴 줄이 테두리에 닿는가" 축이 여기서 다시 걸린다.
        //
        // **이 캡처가 실제로 잡은 결함이 있다**: 처음에 라벨 버퍼를 스택에 두었더니 두 대상 줄이 `(` 하나와
        // 빈 줄로 그려졌다(죽은 스택 바이트). `view` 는 라벨을 **빌리는** op 을 만들고 그것이 함수가 돌아간
        // 뒤에 렌더되기 때문인데, 헤드리스 테스트로는 안 보였다.
        .name = "context-menu-send-longest-row",
        .capture = "context-menu-send.ppm",
        .contract = "머리글 아래 대상 줄이 온전히 그려지고, 가장 긴 대상 줄 뒤에 우측 패딩이 남는다",
        // **폭을 통째로 담는다.** 좌우 테두리가 둘 다 들어와야 "가장 긴 줄 뒤에 패딩이 남는가" 가
        // 보인다 — 처음에 x=16 으로 잘랐더니 왼쪽 테두리와 첫 글자가 함께 잘려 나갔다.
        .rect = .{ .x = 0, .y = 16, .w = 480, .h = 124 },
    },
    .{
        // 위와 **같은 폭**이어야 한다는 것이 계약이다. 예전에는 `checked_mask == 0` 이 "체크 열 없음"과
        // 같은 뜻이라 둘 다 끈 순간 라벨이 두 칸 왼쪽으로 튀었다 — 팝업이 토글 중에도 열려 있어 보인다.
        .name = "context-menu-unchecked-width",
        .capture = "context-menu-unchecked.ppm",
        .contract = "전부 꺼져도 체크 열은 남아 라벨 자리와 상자 폭이 켜진 상태와 같다",
        .rect = .{ .x = 16, .y = 16, .w = 160, .h = 48 },
    },
    .{
        // **이 도크에는 골든이 없었다.** 그래서 시각 회귀가 CI에 안 잡혔고, 실제로 draw 예산이 모자라
        // 도크가 **통째로 비는** 결함이 골든 없이 나갔다(#2196 — 파일 다섯 개만 바뀌어도 빈 화면).
        // 이 crop은 목록 상단을 잡아 그룹 헤더·개수 배지·파일 행이 실제로 그려지는지 본다.
        .name = "scm-list-rows",
        .capture = "scm-rows.ppm",
        .contract = "두 그룹 헤더와 개수 배지, 파일 행(이름·흐린 경로·증감 색·상태 문자)이 목록에 그려진다",
        // 목록은 요약 줄 아래에서 시작한다(3판 배치: 탭 → 커밋 입력·버튼 → 요약 → 목록).
        .rect = .{ .x = 0, .y = 157, .w = 480, .h = 130 },
    },
    .{
        // 행 동작(`+`)은 **호버할 때만** 그려지는 계약이라, 이 시나리오 전에는 그 버튼의 자리를 어떤
        // 자동 검사도 보지 못했다. 실제로 그 상태에서만 보이는 결함이 셋 있었다: `+`가 상태 문자와 같은
        // 픽셀에 겹침 · 색 없는 테두리가 배경을 뚫어 링이 생김 · 버튼이 개수 배지 위로 올라옴.
        // 셋 다 단위 테스트는 전부 통과하던 상태였다.
        .name = "scm-row-hover-action",
        .capture = "scm-row-hover.ppm",
        .contract = "호버한 행에만 `+`가 뜨고 상태 문자 왼쪽에 따로 앉으며(겹치지 않고 링도 없다) 그 자리의 증감은 비운다",
        .rect = .{ .x = 240, .y = 230, .w = 240, .h = 22 },
    },
    .{
        // 충돌 행은 **동작이 없다**(`git add`가 "해결됨"으로 표시하므로 `+`를 두면 사용자가 의도하지 않은
        // 해결이 일어난다). 그 사실은 화면에서 **버튼의 부재**로만 보이므로, 호버 캡처에서 그 행이 비어
        // 있는지가 유일한 시각 증거다.
        .name = "scm-conflict-no-action",
        .capture = "scm-row-hover.ppm",
        .contract = "충돌 행에는 동작 버튼이 없다(상태 문자 `U`만 오른쪽 끝에 선다)",
        .rect = .{ .x = 240, .y = 254, .w = 240, .h = 22 },
    },
    .{
        // **작은 터미널 폰트 축.** 이 축에는 골든이 하나도 없었고 그 사이 결함이 두 번 지나갔다:
        // chrome 텍스트는 role 이 정한 고정 크기(`list_row` 14pt)로 그려지는데 자리 계산은 터미널 셀에서
        // 나오고, 둘은 의도적으로 독립이라 폰트를 줄이면 벌어진다. 셀 8 하나만 보던 골든은 그 상태를
        // 전혀 못 봤고, 실측으로 셀 7(= `font.size` 12)에서 이름과 경로 꼬리가 붙었다.
        //
        // crop 은 파일 행 두 줄을 잡는다 — 이름이 끝나는 자리와 회색 꼬리가 시작하는 자리 **사이의 틈**이
        // 이 축의 계약이다.
        .name = "scm-small-font-name-dir-gap",
        .capture = "scm-small-font.ppm",
        .contract = "작은 폰트에서도 파일 이름과 경로 꼬리 사이에 틈이 남는다(붙어 한 낱말로 읽히지 않는다)",
        .rect = .{ .x = 0, .y = 182, .w = 300, .h = 18 },
    },
    .{
        // **pane 합성의 첫 축**(이 파일 헤더의 "남는 간극"). Lab 은 지금까지 컴포넌트를 프레임 원점에
        // **단독으로** 그려서 이웃과의 경계를 하나도 보지 못했고, 그 축의 결함은 **사용자 캡처로만**
        // 드러났다(SCM 목록이 위쪽 고정 chrome 을 덮은 2026-08-21 건).
        //
        // 이 시나리오는 도크 뷰포트를 상태바 높이만큼 줄여 세우고 그 아래에 띠를 심는다. 이 crop 이
        // 무는 것은 **도크가 줄어든 뷰포트 안에서 끝나는가**다 — 띠는 under 층이라 도크가 그 자리에
        // 무엇이든 그리면 그 위에 얹혀 **다른 그림**이 된다.
        //
        // **이 crop 은 목록의 clip 을 증언하지 못한다**(적대적 검증 2026-08-25). `ui/tree` 의
        // scroll_area clip 을 `.visible` 로 뒤집어도 이 자리는 한 픽셀도 안 변한다 — 목록이 가상화라
        // 뷰포트 아래로 넘치는 행을 **애초에 만들지 않기** 때문이다. 실제로 새는 쪽은 위쪽 경계이고,
        // 그것은 아래 `dock-list-clips-at-viewport-top` 이 본다. 이 둘을 한 문장으로 뭉뚱그리면
        // (처음 판이 그랬다) 잡지 못하는 회귀를 잡는다고 믿게 된다.
        .name = "dock-stops-above-status-bar",
        .capture = "dock-over-status-bar.ppm",
        .contract = "도크가 상태바 높이를 뺀 뷰포트 안에서 끝난다(띠 자리에 아무것도 그리지 않는다)",
        .rect = .{ .x = 0, .y = 686, .w = 300, .h = 34 },
    },
    .{
        // **목록이 자기 뷰포트를 넘지 않는다 — 위쪽 경계.** 스크롤된 첫 행은 뷰포트 위로 12px 걸쳐
        // 있고(rect y 46, 뷰포트 y 58), 그 경계가 풀리면 걸친 부분이 요약 줄 위에 그려진다.
        //
        // **두 경로를 함께 본다** — 이 자리에서 둘 다 실제로 새어 봤다:
        //   · quad — `ui/tree.zig` scroll_area `.overflow = .clip` → `.visible` 로 바꾸면 행의 칠이
        //     요약 줄의 아래 구분선을 지운다(전폭 979픽셀, 이 crop 안 195픽셀).
        //   · 글자 — `scm_dock.build.scrollTextViewport` 가 null 을 내면(= host 배선이 없던 상태)
        //     라벨 윗부분이 구분선 위로 나온다. 그 상태가 2026-08-25까지 제품의 실제 모습이었다.
        .name = "dock-list-clips-at-viewport-top",
        .capture = "dock-over-status-bar.ppm",
        .contract = "스크롤된 목록의 잘린 첫 행이 뷰포트 위 고정 chrome 을 침범하지 않는다",
        .rect = .{ .x = 0, .y = 44, .w = 300, .h = 16 },
    },
    // ── 파일 탐색기 트리 ────────────────────────────────────────────────────────────────────
    // **이 트리에는 시각 골든이 하나도 없었다.** FT1 이 행을 셀 격자에서 typed component 로 옮기며
    // 밀도·아이콘·안내선·밴드·상태 점을 전부 새로 그렸는데도(계획 문서 §6 이 그 한계를 적어 뒀다),
    // 픽셀을 보는 자동 판정자가 없었다. 시나리오를 만들고 **첫 캡처를 눈으로 본 자리에서** 스펙 위반이
    // 하나 나왔다: 호버 밴드가 선택 밴드보다 밝아 무엇을 고른 상태인지 화면에서 사라졌다(선택 rgb 80
    // 대 호버 rgb 140 — 계획 §3 은 "호버: 약한 배경"이다). 아래 crop 들이 그 종류를 다시 놓치지 않는다.
    //
    // 트리 폭은 260(제품 도크 폭)이고 행 높이는 26 이다 — crop 의 y 는 그 배수다.
    //
    // face 는 이제 제품과 같다(번들 등폭 — `chrome_lab_smoke.zig` 의 `faceFor`). 그 전에는 도크만 비례
    // UI face 였고, 그래서 이 골든들이 라벨의 advance·말줄임·겹침을 **하나도 증언하지 못했다**.
    .{
        .name = "file-tree-selection-band",
        .capture = "file-tree-rows.ppm",
        .contract = "선택 행: 왼쪽 끝 2px accent 막대 + 좌우로 들여 둥근 밴드 + 밝아진 라벨",
        .rect = .{ .x = 0, .y = 78, .w = 260, .h = 26 },
    },
    .{
        // 안내선은 밴드보다 **나중에** 그려야 보인다(`view` 의 행 루프 순서). 순서가 뒤집히면 선택된
        // 행에서만 안내선이 사라지는데, 그 상태는 op 개수만 세는 단위 테스트로는 통과한다.
        .name = "file-tree-indent-guides",
        .capture = "file-tree-rows.ppm",
        .contract = "depth 2 행의 안내선 두 단이 세로로 이어지고 선택 밴드가 그것을 덮지 않는다",
        .rect = .{ .x = 0, .y = 52, .w = 44, .h = 78 },
    },
    .{
        .name = "file-tree-kind-icons",
        .capture = "file-tree-rows.ppm",
        .contract = "아이콘 종류색(code 초록)이 살아 있고 선택된 행의 아이콘만 대비색으로 올라간다",
        .rect = .{ .x = 48, .y = 52, .w = 20, .h = 78 },
    },
    .{
        // 점이 라벨 위로 올라오면 긴 이름에서 글자를 가린다 — 그 겹침은 픽셀로만 보인다.
        .name = "file-tree-dirty-dot",
        .capture = "file-tree-rows.ppm",
        .contract = "저장 안 된 파일의 점은 우측 고정 슬롯에만 서고 라벨과 겹치지 않는다",
        .rect = .{ .x = 230, .y = 104, .w = 30, .h = 26 },
    },
    .{
        // 옛 셀 경로는 이 자리 색이 기본 행보다 **밝아** 신호가 거꾸로였다(`tokens.list_disabled_fg`
        // 주석의 실측). 값 위계는 단위 테스트가 보지만, 그 값이 실제로 화면에 나가는지는 여기서 본다.
        .name = "file-tree-ignored-row",
        .capture = "file-tree-rows.ppm",
        .contract = "git 이 무시하는 행은 라벨과 아이콘이 함께 한 단 물러나고 접힌 chevron 을 유지한다",
        .rect = .{ .x = 0, .y = 130, .w = 170, .h = 26 },
    },
    .{
        // 가상화된 창은 첫 항목을 **음수 origin** 으로 올린다. 그 값이 행 높이의 배수가 아니면 첫 행이
        // 반쯤 걸치는데, 그 상태에서 잘리는 대신 **눌리면**(높이가 줄면) 아래 행들의 자리가 전부 밀린다.
        // crop 은 위 두 행을 잡아 "첫 행은 잘리고 둘째 행은 온전한 26px" 을 고정한다.
        //
        // **이 캡처가 증언하지 못하는 것**: Lab 은 트리를 프레임 원점에 단독으로 그리므로 트리 위에
        // 고정 chrome 이 없다 — clip 이 뷰포트보다 커져 위쪽 chrome 을 덮는 결함(SCM 도크가 겪은 그것)은
        // 여기서 프레임 가장자리와 구별되지 않는다. 그 축은 제품 캡처의 몫이다.
        .name = "file-tree-scrolled-partial-row",
        .capture = "file-tree-scrolled.ppm",
        .contract = "스크롤 11px 에서 첫 행은 위가 잘린 채 나오고 아래 행들은 26px 간격을 유지한다",
        .rect = .{ .x = 0, .y = 0, .w = 260, .h = 40 },
    },
    .{
        // 두 밴드를 **한 crop 에** 담는다 — 이 계약은 "각각 무슨 색인가"가 아니라 "둘의 세기 순서"라서
        // 따로 자르면 판정이 안 된다.
        .name = "file-tree-hover-weaker-than-selection",
        .capture = "file-tree-row-hover.ppm",
        .contract = "호버 밴드는 바로 위 선택 밴드보다 배경에 가깝다(선택이 가장 진하다)",
        .rect = .{ .x = 0, .y = 78, .w = 260, .h = 52 },
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
        // 정렬 토글은 `.ghost`라 **호버·pressed 때만** 면과 테두리가 존재한다. 그 그림을 보는 골든이 없어서,
        // 목록 행용 hover 토큰(활성보다 밝은 색)이 헤더의 작은 pill에 그대로 깔린 상태가 자동 검사에는
        // 안 잡히고 사용자 제보로만 드러났다(2026-08-17). crop은 `로컬`·토글·refresh를 함께 잡아,
        // 호버한 토글이 **옆의 배경 없는 두 utility와 톤이 갈리지 않는지**까지 한 사각형에서 판정한다.
        .name = "sort-toggle-hover",
        .capture = "sort-toggle-hover.ppm",
        .contract = "호버한 정렬 토글은 한 단계 약한 면과 테두리만 얻고 옆 utility보다 튀지 않는다",
        .rect = .{ .x = 240, .y = 20, .w = 240, .h = 60 },
    },
    .{
        // 사용자가 실제로 지적한 그림("최신순 누를 때"). pressed는 hover보다 진해야 하지만 활성 밴드와
        // 같은 세기면 헤더에서 그 상자만 튄다. 두 캡처를 나란히 두면 **세기 순서**(hover < pressed)가
        // 그림으로 증명된다 — 단위 테스트는 role 이름만 보고 그 순서의 시각적 결과는 보지 못한다.
        .name = "sort-toggle-pressed",
        .capture = "sort-toggle-pressed.ppm",
        .contract = "누르는 중인 정렬 토글은 hover보다 진하되 활성 밴드 세기까지는 가지 않는다",
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
    .{
        // 위 case와 **같은 캡처의 다른 자리**다. sticky crop 셋이 전부 목록 밴드(y>=200)를 보는 동안
        // 이 캡처의 헤더는 아무도 보지 않았다. `header-utility-row`가 헤더를 보긴 하지만 그것은
        // `retained-list` 캡처이고, 스크롤·sticky 상태의 헤더는 여전히 사각지대였다.
        //
        // 그 사각지대에 실제로 결함이 있었다(#2110): 이 시나리오의 헤더 오른쪽 위에 정체불명의 밝은
        // 상자가 떠 있었는데 게이트가 침묵했고, 사람이 캡처를 열어 보고서야 알았다. 원인을 좁혀 보니
        // `header_sort_extent`(정렬 토글 slot 폭)를 72pt에서 되돌리면 그 상자가 그대로 재현된다 —
        // 즉 헤더 utility 배치가 이 자리의 그림을 정한다. 같은 축을 보는 `header-utility-row`가
        // `retained-list`에서는 통과하는 동안 이 캡처에서만 깨졌으므로, **캡처마다** 헤더를 봐야 한다.
        .name = "sticky-pushed-header-clean",
        .capture = "sticky-pushed.ppm",
        .contract = "스크롤·sticky 상태에서도 헤더 오른쪽 위가 깨끗하다(utility 밖에 잔여 quad가 없다)",
        .rect = .{ .x = 240, .y = 0, .w = 240, .h = 100 },
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
    // 숫자가 앞 행 마지막 숫자 다음이면 조각이 정확히 맞물린 것이다(실측: 50열씩 세 행).
    //
    // 자가 필요한 이유는 **글자가 화면 오른쪽에 닿아 끝나면 "폭에 맞게 접혔다"와 "넘쳐서 잘렸다"가
    // 그림상 같아 보이기** 때문이다. 숫자는 그 둘을 가른다.
    .{
        .name = "editor-wrap-ruler",
        .capture = "editor-wrap.ppm",
        .contract = "본문 폭을 넘는 줄이 50열에서 접혀 다음 시각 행으로 빠짐없이 이어진다",
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
    // §4.1b — **편집기 뷰가 자기 배경을 그린다.** 뷰포트(6행 = 96px)까지가 편집기 바탕이고 그
    // 아래는 아무도 그리지 않은 자리다. rect가 그 경계를 가로지르므로 배경을 빼면 위쪽이 바깥
    // 색으로 바뀌어 잡힌다.
    //
    // **이 가드는 Lab clear color를 편집기 배경과 다르게 둔 뒤에야 성립한다.** 둘이 같은 값
    // (20,20,20)이던 동안에는 배경을 빼도 캡처가 똑같아 아무것도 검증하지 못했다.
    .{
        .name = "editor-surface-view-bounds",
        .capture = "editor-scrolled.ppm",
        .contract = "편집기 뷰가 뷰포트까지 자기 배경을 그리고 그 밖은 바깥 색이다",
        .rect = .{ .x = 200, .y = 80, .w = 120, .h = 32 },
    },
    // §4.1a — **세로 스크롤바.** 문서 18행 중 6행을 보는 상태에서 5행 스크롤했으므로, thumb이
    // 위에서 1/3 지점에 track의 1/3 길이로 선다.
    //
    // **본문 오른쪽 gutter 안에 서고 본문 위에 겹치지 않는다** — 겹치면 오른쪽 끝 글자가 막대에
    // 가려지는데, §3.8이 "보이는 것과 파일 내용이 달라지면 안 된다"를 요구하는 편집기에서 그것은
    // 특히 나쁘다. rect가 본문 마지막 열까지 함께 덮으므로 막대가 왼쪽으로 침범하면 잡힌다.
    .{
        .name = "editor-scrollbar-thumb",
        .capture = "editor-scrolled.ppm",
        .contract = "세로 스크롤바가 본문 오른쪽 gutter에 서고 thumb 위치·길이가 시각 행 비율을 따른다",
        .rect = .{ .x = 440, .y = 0, .w = 40, .h = 112 },
    },
    // §4.1a — **범위가 시각 행 기준임을 랩된 문서에서 본다.** 여기서만 검증된다: 랩이 꺼진
    // `editor-scrolled`는 시각 행 = 논리 줄이라 둘을 바꿔도 그림이 같다(실제로 그 반증이
    // 통과했다). 이 문서는 논리 줄 10개가 랩으로 수백 시각 행이 되므로 thumb이 **최소 길이**로
    // 줄어드는데, 논리 줄로 세면 문서가 화면에 다 들어간다고 판정돼 **막대가 아예 사라진다.**
    .{
        .name = "editor-scrollbar-wrapped-range",
        .capture = "editor-wrap-scrolled.ppm",
        .contract = "랩된 문서에서 스크롤바 범위가 시각 행을 따른다(논리 줄로 세면 막대가 사라진다)",
        .rect = .{ .x = 460, .y = 0, .w = 20, .h = 96 },
    },
    // §4 — **낡은 스크롤 위치가 들어와도 첫 줄이 사라지지 않는다.** 뷰 폭·탭 폭·랩 토글이 바뀌면
    // 인덱스가 무효가 되는데(§2) 그 전에 만든 위치가 살아남으면 `first_piece`가 실제 조각 수를
    // 넘는다(여기서는 3조각 줄에 99를 요구한다).
    //
    // 그때 첫 논리 줄을 지우면 **다음 줄이 y=0에 자기 번호를 달고 올라와**, 사용자에게는 리사이즈
    // 한 번에 화면이 문서의 다른 곳으로 튄 것처럼 보인다. 첫 행의 번호가 `1`인 것이 증거다.
    // §3.5 — **디스크에서 읽은 파일이 화면에 뜬다.** 다른 편집기 골든은 전부 소스에 박은 배열을
    // 보므로, `openPath`가 실제로 무엇을 돌려주는지는 어느 것도 판정하지 않는다. 이 캡처만 파일을
    // 쓰고 읽어 그린다.
    //
    // 여덟 행을 잡는 이유는 **판정할 것들이 서로 다른 줄에 있기** 때문이다: 1행은 BOM이 유령 글자로
    // 서지 않는지(파일은 BOM으로 시작하고, 안 떼면 §3.8 가시화가 `<U+FEFF>`를 그린다), 5~6행은 탭이
    // 전개되어 들여쓰기가 맞는지, 3행은 2칸 글자가 열을 먹는지. 마지막 8행은 파일이 개행으로 끝나
    // 생긴 빈 줄이라, 줄 수를 하나 더 세거나 덜 세면 어긋난다.
    //
    // **CRLF는 이 골든이 판정하지 않는다.** `hazard.zig`가 `0x0D`를 가시화에서 빼므로 `\r`이 남아도
    // 줄 끝에 아무것도 안 그려진다 — 그쪽은 `session/editor/open.zig`의 문자열 비교가 판정한다.
    // N1.5 — **긴 비교를 스크롤한 상태.** 짧은 비교의 첫 화면만 보면 셋이 무판정으로 남는다:
    // 스크롤한 뒤 밴드가 그 줄에 붙는지(표를 뷰포트 기준으로 읽으면 어긋난다), 좌우가 같은 행에서
    // 시작하는지, 막대가 **시각 행** 기준 자리에 서는지(논리 줄로 세면 위에 붙는다).
    .{
        .name = "editor-diff-scrolled-bands",
        .capture = "editor-diff-scrolled.ppm",
        .contract = "문서 중간에서 좌우가 같은 행부터 서고, 밴드가 바뀐 줄에 붙고, 막대가 그 자리에 선다",
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 200 },
    },
    // N1.5 c·d §7 — 나란한 비교의 **배치와 색**. 좌우가 같은 행을 같은 높이에 세우고, 짝을 맞추려
    // 넣은 빈 행이 반대쪽을 밀지 않으며, 두 gutter가 각자 문서의 번호를 달고, 바뀐 줄에만 밴드와
    // 좌측 띠가 선다. 세로 어긋남은 단위 테스트도 잡지만 **gutter 폭·가운데 틈·띠 두께**는 여기서만 보인다.
    .{
        .name = "editor-diff-side-by-side",
        .capture = "editor-diff.ppm",
        .contract = "좌우 두 열이 같은 행을 같은 높이에 세우고 번호는 각자 문서의 것이다",
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 128 },
    },
    .{
        .name = "editor-real-file-from-disk",
        .capture = "editor-real-file.ppm",
        .contract = "openPath로 읽은 파일이 BOM·CRLF 없이, 탭이 전개된 채로 그려진다",
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 128 },
    },
    .{
        .name = "editor-typescript-colors",
        .capture = "editor-typescript.ppm",
        // **zig 말고 다른 grammar 가 실제로 색을 내는가.** 이것이 없으면 골든이 지키는 언어가
        // zig 하나뿐이고, 나머지 열일곱은 회귀해도 아무도 모른다 — 적대적 검증에서 Lab 의 언어를
        // 다시 `.zig` 로 박는 뮤턴트가 **살아남아** 그 사실이 드러났다.
        //
        // TypeScript 를 고른 이유는 그 쿼리가 javascript 를 **상속하는 구조**라서다(35줄 대 204줄).
        // 상속을 안 이으면 문자열·주석이 통째로 빠지는데, 값 판정자는 "색이 있다"만 보고 지나칠 수
        // 있고 여기서는 즉시 보인다.
        .contract = "TypeScript 파일이 keyword·string·type·function·number 로 갈려 칠해진다(상속한 js 쿼리 포함)",
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 128 },
    },
    .{
        .name = "editor-wrap-stale-scroll-keeps-line",
        .capture = "editor-wrap-stale-scroll.ppm",
        .contract = "first_piece가 범위를 넘어도 첫 논리 줄이 처음부터 그려진다(줄이 사라지지 않는다)",
        // **네 행(64px)이다.** 첫 줄의 세 조각과 그 **다음 줄(번호 2)**까지 봐야 "다음 줄이
        // 올라오지 않았다"가 판정된다. 52px로 잡았다가 네 번째 행이 중간에서 잘려 고쳤다.
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 64 },
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
    // §4.1f — **접힌 편집기**. gutter 접힘 칸의 화살표(▸·▾)와, 접힌 만큼 **건너뛰는 줄 번호**를 본다.
    //
    // **gutter만 본다**(x < 64 — 실측: 번호 45~50, 화살표 54~57, 본문 69부터). 본문을 넣으면
    // 접힘과 무관한 글자 변화에 이 case가 깨져 무엇이 회귀했는지 알려 주지 못한다. 실제로 이
    // fixture의 `//` 주석 줄이 폰트 합자로 한 칸 비는 상태인데(§4.2가 고쳤다고 적은 자리 — 별건),
    // 그것을 이 case가 지고 있을 이유가 없다.
    //
    // 화살표가 번호나 본문을 덮는 결함은 이 rect 안에서 드러난다 — 번호가 왼쪽, 화살표가 그 오른쪽
    // 한 칸이고, 넘치면 서로를 침범한다.
    .{
        .name = "editor-folded-gutter-arrows",
        .capture = "editor-folded.ppm",
        .contract = "접힘 칸에 화살표가 서고(▸ 접힘 · ▾ 펼침) 줄 번호가 접힌 만큼 건너뛴다",
        .rect = .{ .x = 0, .y = 0, .w = 64, .h = 72 },
    },
    // §4 — **가로 스크롤**(`first_col = 20`). 같은 fixture를 랩 대신 밀어서 본다.
    //
    // **자 줄(y<16)은 일부러 뺐다.** `0123456789`가 10주기라 20열을 밀어도 그림이 같아서, 그 줄을
    // 넣으면 스크롤이 통째로 죽어도 통과하는 rect가 된다. 대신 `fn wrap(...)`·주석 줄들이 앞을
    // 잘라낸 채 시작하는 것을 본다.
    // §4.1a — **가로 스크롤바**. 세로 막대가 오른쪽 여백에 서는 것과 짝이고, 본문 **아래** 여백에
    // 선다(자리를 먹는다 — 겹쳐 그리면 마지막 줄이 막대에 가린다).
    //
    // **하단 띠만 본다**(y 704~720 — 실측: 막대가 712~719). 본문을 넣으면 가로 스크롤과 무관한 글자
    // 변화에 이 case가 깨져 무엇이 회귀했는지 알려 주지 못한다(접힘 화살표 case와 같은 이유).
    .{
        .name = "editor-hscrollbar",
        .capture = "editor-hscroll.ppm",
        .contract = "본문 아래 여백에 가로 막대가 서고, 밀린 만큼 오른쪽으로 가 있다",
        .rect = .{ .x = 0, .y = 704, .w = 480, .h = 16 },
    },
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
