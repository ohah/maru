//! Test-only Chrome Lab fixture seam.
//!
//! This module owns synthetic UI inputs and recorded actions only. It deliberately does not
//! import AppSession, session, PTY, provider, filesystem, or a platform window host.

const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const editor_syntax = @import("../app_session/editor_syntax.zig");
const lowering = @import("metal_lowering.zig");

/// **Lab 안의 탭 폭 단일 출처.** 제품은 `Term.rt.editor_tab_width`를 쓰는데 Lab에는 Term이 없다.
/// 소비처가 각자 상수를 읽으면 한 캡처 안에서 갈리므로(가장 긴 줄 계수 ↔ `diff_frame.build`) 여기서
/// 한 번 정한다 — 설정이 배선되면 이 한 줄만 고치면 된다(12차 적대적 검증).
const lab_tab_width: u8 = chrome.components.editor_view.frame.default_tab_width;

const chrome = maru.chrome;
const session_dock = chrome.components.session_dock;
const scm_dock = chrome.components.scm_dock;
const archive_detail = chrome.components.archive_detail;
const file_tree = chrome.components.file_tree;

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
    /// 소스 컨트롤 도크의 목록. **이 도크에는 Lab 시나리오가 없었다** — 그래서 시각 회귀가 CI에 안
    /// 잡혔고, 실제로 도크가 통째로 비는 결함(#2196 draw 예산)이 골든 없이 나갔다가 손 확인으로만
    /// 드러났다. 그룹 헤더·개수 배지·상태 문자·증감 색이 한 캡처에 든다.
    scm_rows,
    /// 같은 목록에서 **행 하나에 호버**한 상태. 행 동작(`+`)은 호버할 때만 그려지는 계약이라 이 시나리오가
    /// 없으면 그 버튼의 자리를 아무도 못 본다 — 실제로 `+`가 상태 문자와 겹치고(#2209), 색 없는 테두리가
    /// 배경을 뚫고, 버튼이 개수 배지 위로 올라온 결함 셋이 전부 이 상태에서만 보였다.
    scm_row_hover,
    /// 같은 목록에서 **저장소 머리 줄에 호버**한 상태. 그 줄은 동작 아이콘 자리를 평소에 비워 두지
    /// 않으므로(빈 띠 52px 을 안 남기려고) 호버하는 순간 아이콘과 브랜치·개수 배지가 **같은 자리**를
    /// 다툰다. 옛 답("배경색 quad 로 덮는다")은 chrome quad 가 chrome 글자보다 먼저 그리는 층이라
    /// 원리적으로 통하지 않았고, 그래서 새로고침 아이콘이 브랜치 이름 위에 그대로 겹쳐 보였다
    /// (사용자 캡처 2026-08-21). 파일 행 호버(`scm_row_hover`)로는 그 자리가 안 보인다 — 머리 줄에만
    /// 브랜치·배지가 선다.
    scm_repo_hover,
    /// 같은 목록을 **스크롤한** 상태. 가상화는 창의 첫 항목을 음수 origin 으로 올려 두므로 그 행의
    /// rect 는 목록 뷰포트 **밖까지** 이어진다. 그 rect 를 clip 으로 실으면 clip 이 뷰포트보다 커져
    /// 아무것도 자르지 않고, 행의 칠과 글자가 위쪽 고정 chrome(탭 줄·요약 줄) 위에 그려진다
    /// (사용자 캡처 2026-08-21). 스크롤이 없는 `scm_rows` 로는 그 상태를 만들 수 없다.
    scm_scrolled,
    /// 같은 목록을 **작은 터미널 폰트**(`font.size` 12 상당)로 그린 상태.
    ///
    /// 이 축에는 골든이 하나도 없었고, 그 사이 결함이 두 번 지나갔다. chrome 텍스트는 role 이 정한
    /// **고정 크기**(`list_row` 14pt)로 그려지는데 자리 계산은 터미널 셀에서 나온다 — 둘은 의도적으로
    /// 독립이라 사용자가 폰트를 줄이면 벌어진다. 셀 8 하나만 보던 골든은 그 상태를 **전혀 못 봤고**,
    /// 실측으로 셀 7 에서 이름과 경로 꼬리가 붙었다(`staged.zigsrc/session/`).
    ///
    /// 셀 폭과 높이를 **함께** 줄인다 — 폭만 줄이면 제품에 없는 조합이 되어(셀은 폰트 크기에서 나온다)
    /// 판정이 거짓이 된다. 실제로 그 잘못된 픽스처로 한 번 오판했다.
    scm_small_font,
    /// 도크 **아래에 상태바가 있는** 화면. 지금까지 Lab 은 컴포넌트를 프레임 원점에 **단독으로** 그려서
    /// pane 합성(이웃과의 경계·레이어 순서)을 하나도 보지 못했다 — 그 간극은 이 파일의 헤더가 적어 두고
    /// 있었고, 실제로 그 축의 결함은 **사용자 캡처로만** 드러났다(SCM 목록이 위쪽 고정 chrome 을 덮은
    /// 2026-08-21 건).
    ///
    /// 이 시나리오는 그 축의 첫 조각이다: 도크 뷰포트를 상태바 높이만큼 **줄여** 세우고 그 아래에 띠를
    /// 심는다. 목록이 자기 뷰포트에서 멈추지 않으면 띠를 덮어 골든이 빨개진다.
    dock_over_status_bar,
    /// 파일 탐색기 **행 목록**. 이 도크에는 Lab 시나리오도 시각 골든도 없었다 — FT1 이 행을 셀 격자에서
    /// typed component 로 옮기면서 밀도·아이콘·들여쓰기 안내선·상태 점을 전부 새로 그렸는데, 그 픽셀을
    /// 보는 자동 판정자는 하나도 없었다(계획 문서 §6 이 그 한계를 적어 두고 있다). 실제로 그 단계에서
    /// **draw 예산이 모자라 트리가 통째로 비는** 결함이 났고(밴드·포커스 막대를 세지 않은
    /// `max_ops_per_row`), 한 행 픽스처는 통과하는데 다섯 행이 빈 화면이었다 — SCM 도크가 #2196 에서
    /// 겪은 것과 같은 종류다. 한 캡처에 종류 아이콘·안내선·선택 밴드·dirty 점·무시된 행의 흐림이 든다.
    file_tree_rows,
    /// 같은 목록에서 **행 하나에 호버**한 상태. 호버 밴드는 포인터가 있을 때만 그려지는 계약이라
    /// (`bandRole` — 선택보다 약한 색) 이 시나리오가 없으면 그 색과 자리를 아무도 못 본다. 선택 밴드와
    /// **구별되는지**가 이 캡처의 관심사다 — 둘이 같은 색이면 사용자는 무엇을 고른 상태인지 알 수 없다.
    file_tree_row_hover,
    /// 같은 목록을 **스크롤한** 상태. 가상화는 창의 첫 항목을 음수 origin 으로 올려 두므로 그 행의
    /// rect 는 목록 뷰포트 **위쪽까지** 이어진다. 그 rect 를 clip 으로 그대로 실으면 clip 이 뷰포트보다
    /// 커져 아무것도 자르지 않고, 반쯤 걸친 행의 밴드·글자가 위쪽 고정 chrome 위에 그려진다 — SCM
    /// 도크에서 정확히 그 결함이 사용자 캡처로 드러났고(`scm_scrolled` 가 그때 생겼다), 트리도 같은
    /// 창 산술을 쓴다. 스크롤이 없는 `file_tree_rows` 로는 이 상태를 만들 수 없다.
    file_tree_scrolled,
    /// 세션 기록 헤더의 **정렬 토글에 호버**한 상태. 이 토글은 `.ghost`라 평소에는 label만 보이고 면·테두리가
    /// 없다 — 즉 **호버·pressed 때만 존재하는 그림**이고, 그 그림을 보던 골든이 하나도 없었다. 실제로
    /// 목록 행용 hover 토큰(활성보다 밝게 잡은 색)이 그대로 깔려 작은 pill 하나만 튀는 상태가 사용자
    /// 제보로만 드러났다(2026-08-17). 이 시나리오가 그 자리를 픽셀로 고정한다.
    sort_toggle_hover,
    /// 같은 토글을 **누르고 있는** 상태. 사용자가 실제로 지적한 그림이 이것이다("최신순 누를 때") — pressed는
    /// hover보다 진해야 하지만 활성 밴드와 같은 세기로 칠하면 헤더에서 그 상자만 튄다. hover 캡처와 나란히
    /// 놓아 **두 상태의 세기 차이**가 유지되는지도 함께 본다.
    sort_toggle_pressed,
    /// 커밋 메시지 상자가 **편집 중**인 상태(P3c). caret·선택 밴드·여러 줄·랩은 전부 이 상태에서만
    /// 그려지고, 그 중 무엇도 단위 테스트가 "자리"까지 보지는 못한다 — 열을 셀 폭으로 환산해 놓는
    /// 일이라 한 칸 어긋나도 테스트는 통과하고 화면만 틀린다.
    scm_commit_edit,
    /// **막힌 이유의 자리와 색**(2026-08-31 사용자 제보). 커밋이 거절되면 그 이유가 **그 저장소의
    /// 버튼 바로 아래**에 붉게 서는지 픽셀로 본다 — 예전에는 목록 맨 위에 중립 톤으로 떠서, 아래쪽
    /// 워크트리에서 커밋하면 어느 저장소 얘기인지도 왜 안 됐는지도 화면에서 안 이어졌다.
    ///
    /// **중립 안내를 같은 캡처에 둔다.** 색을 가른다는 것은 둘을 나란히 놓아야 보인다 — 하나만 찍으면
    /// "붉다" 는 알아도 "구별된다" 는 모른다.
    scm_blocker,
    /// **히스토리 탭**(P4·P4b) — 커밋 줄과 **펼친 커밋의 파일 줄**이 한 캡처에 든다. 이 탭에는 Lab
    /// 시나리오가 하나도 없었고(`scm_rows` 는 전부 변경 사항 탭이다), 그래서 커밋 줄의 두 단 배치·ref
    /// 칩·펼친 파일 행의 증감은 **사용자 캡처로만** 보였다. 실제로 그 목록은 파일마다 증감이 빈 채로
    /// 나갔다(사용자 지적 2026-08-27 — 「라인 몇 개 바뀐지 나왔으면」).
    scm_history,
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
    /// N1 §4.1f — **접힌 편집기**. gutter 접힘 칸에 화살표가 서고(펼침 ▾ · 접힘 ▸), 접힌 만큼 줄
    /// 번호가 **건너뛴다**. 화면에 보이는 변경이라 캡처로 고정한다 — 화살표가 번호나 본문을 덮으면
    /// 여기서 드러난다.
    ///
    /// **접힘 계산은 여기서 안 한다.** 줄·번호·표식을 손으로 적어 넘긴다(다른 편집기 시나리오와 같다)
    /// — 계산을 Lab에 복제하면 제품과 갈릴 자리가 하나 더 생기고, 그 계산은 단위·제품 테스트가 이미
    /// 판정한다. 여기서 고정하는 것은 **그리기**다.
    editor_folded,
    /// 체크 열이 있는 컨텍스트 메뉴(사이드바 ⚙ — 보기 옵션). **이 컴포넌트에도 Lab 시나리오가 없었다** —
    /// 그래서 재는 쪽(`menuRect`)과 그리는 쪽(`view`)이 갈려 가장 긴 줄이 테두리에 닿는 결함이 골든 없이
    /// 나갔다. 켜짐 하나·꺼짐 하나를 한 캡처에 담아 마크 폭과 상자 폭이 함께 보이게 한다.
    context_menu_checked,
    /// **보내기 구획이 붙은 편집기 우클릭 메뉴**(NS4~NS6 — send-selection-to-agent.md §5.1).
    /// 머리글 한 줄 + 대상 줄들 + 편집 항목이고, **대상 라벨이 이 메뉴에서 가장 긴 줄**이다 —
    /// 위 두 시나리오가 잡으려던 "가장 긴 줄이 테두리에 닿는가" 가 여기서 되살아난다.
    ///
    /// **선택 강조는 이 캡처가 답하지 못한다.** 그것은 `.fill` op 인데 Lab 의 lowering
    /// (`appendBackgroundQuads`)은 `.quad` 만 내린다 — 제품은 `metal_lowering` 이 `.fill` 을 셀
    /// 배경으로 칠하지만 Lab 에는 그 경로가 없다. **랩의 한계이지 제품 결함이 아니다**(토큰을 확인했다 —
    /// `tab_active_bg` 는 `surface_bg` 와 다른 색이다). 선택 자리는 제품 테스트가 잰다.
    context_menu_send,
    /// 같은 메뉴에서 **둘 다 꺼진** 상태. 예전에는 `checked_mask == 0` 이 "체크 열 없음"과 같은 뜻이라
    /// 이 상태에서 라벨이 두 칸 왼쪽으로 튀었다 — 위 캡처와 **같은 폭**이어야 한다는 것이 계약이다.
    context_menu_unchecked,
    /// N1 §3.5 — **디스크에서 읽은 파일이 화면에 뜬다.** 앞의 편집기 시나리오들은 전부 소스에 박은
    /// 배열을 그리므로, `openPath`가 실제로 무엇을 돌려주는지는 증명하지 않는다. 여기서는 호출자가
    /// 파일을 써서 `openPath`로 읽고 그 줄들을 그대로 넘긴다(`Scenario.lines`).
    ///
    /// **읽은 문자열 자체는 단위 테스트가 판정한다**(`session/editor/open.zig`). 이 시나리오가 더하는
    /// 것은 그 다음 구간이다 — 읽은 줄이 셀 격자에 놓이기까지 경로가 이어져 있는가. BOM을 안 떼면
    /// §3.8 가시화가 `<U+FEFF>`를 첫 줄에 그리고, 탭 전개가 틀리면 들여쓴 행의 열이 어긋난다.
    editor_real_file,
    /// **여러 언어의 색이 실제로 다르게 붙는가**(N4 §5.3 · 번들 grammar 표). zig 하나만 캡처하면
    /// 나머지 열일곱은 골든이 안 지킨다 — TypeScript 는 `; inherits: javascript` 구조라 상속을
    /// 안 이으면 문자열·주석이 통째로 빠지는데, 그 회귀가 정확히 여기서 보인다.
    editor_typescript,
    /// N1 §4.1g — **본문 텍스트 선택**을 픽셀로 본다. 띠가 글자 위가 아니라 **뒤**에 서고(알파로
    /// 얹으므로 글자가 읽혀야 한다), 줄을 걸친 선택이 첫 줄은 중간부터·끝 줄은 머리부터 칠해지고,
    /// gutter를 침범하지 않는지가 단위 테스트로 안 보이는 부분이다 — 열을 셀 폭으로 환산해 놓는
    /// 일이라 한 칸 어긋나도 테스트는 통과하고 화면만 틀린다(강조가 7칸 밀린 §4.1c 전례).
    editor_selection,
    /// **caret 모양**(`editor.cursor-shape`). 세 값이 각각 어떤 사각을 그리는지 픽셀로 본다 —
    /// 헤드리스 단언은 사각의 `w`·`h`·`y`까지만 답하고, **그 사각이 글자와 맞는 자리에 서는지**와
    /// **`block` 아래 글자가 읽히는지**는 픽셀만이 답한다. 후자가 이 시나리오의 요점이다: quad는
    /// 글자를 덮지 못하므로(`draw.zig`) 반전이 없으면 커서색 위에 원래 글자색이 남아 **그 한
    /// 글자만 안 읽힌다** — 그 상태는 단위 테스트에서 초록이고 화면에서만 보인다.
    ///
    /// **한글 줄이 fixture에 있어야 한다.** `block`·`underline`은 글자 폭을 덮으므로 2칸 글자에서
    /// 한 칸만 칠하면 절반에 걸치는데, ASCII만이면 그 차이가 캡처에 안 나온다.
    editor_caret_bar,
    editor_caret_block,
    editor_caret_underline,
    /// N2 §5.1 — **문서 내 검색 결과.** 한 줄에 매치가 **여럿** 서고, 그 중 하나만 다른 색인지를
    /// 픽셀로 본다. 단위 테스트가 못 보는 것이 그 둘이다: 마크 저장소가 줄당 하나였다면 둘째
    /// 매치가 조용히 사라지고(리스트는 여전히 넷이라 카운터는 맞다), 현재 매치를 가르는 코드가
    /// 어긋나면 색이 둘인 매치나 색이 없는 매치가 난다 — 둘 다 화면에서만 드러난다.
    editor_find,
    /// N1 §4.1g "비교 뷰" — **좌우 두 열 중 한 쪽만** 선택 띠가 서는지 픽셀로 본다. 계약이
    /// *"좌우를 걸치는 선택은 만들지 않는다"*로 정한 것이 화면에서 어떻게 보이는가이고, 짝맞춤
    /// 빈 행(왼쪽 3행)에 띠가 어떻게 서는지도 여기서만 드러난다 — 그 행은 그 자리에 줄이 **없다**.
    editor_diff_selection,
    /// N1.5 §7 — **나란한 비교.** 좌우 두 열이 같은 행을 같은 높이에 세우는지, 짝을 맞추려 넣은 빈
    /// 행이 반대쪽 줄을 밀지 않는지, 두 gutter가 **각자 문서의 번호**를 다는지를 픽셀로 본다.
    /// 세로 어긋남은 단위 테스트로도 잡히지만(같은 y), **한 칸 어긋난 gutter 폭이나 가운데 틈이
    /// 사라진 것**은 캡처로만 드러난다. 색 띠는 다음 슬라이스라 여기서는 배치만 본다.
    editor_diff,
    /// N1.5 §7 — **긴 비교를 스크롤한 상태.** 짧은 fixture의 첫 화면만 보면 세 가지가 무판정으로
    /// 남는다: 스크롤한 뒤 밴드가 **그 줄**에 붙는지(표를 뷰포트 기준으로 읽으면 어긋난다), 두 열이
    /// 같은 행에서 시작하는지, 그리고 막대가 문서 중간 자리에 서는지.
    editor_diff_scrolled,
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
    /// face 의 **포인트당 advance**(× 1000). 하네스가 native 메트릭에서 재서 넣는다 — Lab 이 자기
    /// 합성 셀에서 비율을 만들면 제품과 다른 산술이 되고, 실제로 작은 셀 조합에서 2px 이 모자랐다
    /// (예약 82px 대 실제 84px). 제품은 `advance_milli_px` 로 정확한 값을 쓰므로 Lab 도 같은 출처를 쓴다.
    advance_milli_per_point: u32 = 0,
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
    scm_nodes: []chrome.ui.tree.UiNode = &.{},
    scm_actions: []scm_dock.ids.Entry = &.{},
    file_tree_nodes: []chrome.ui.tree.UiNode = &.{},
    file_tree_actions: []file_tree.ids.Entry = &.{},
    text_runs: []chrome.draw.Run,
    text_bytes: []u8,
    /// 오버레이 컴포넌트(`context_menu`)는 op 를 **arena 에 append** 한다 — 도크처럼 고정 슬라이스에
    /// 채우지 않는다. 그 시나리오에서만 쓰이므로 기본값을 두어 기존 호출부를 건드리지 않는다.
    /// 없이 그 시나리오를 부르면 빈 프레임이 나오고, 캡처가 비어 골든이 그것을 잡는다.
    arena: ?std.mem.Allocator = null,
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
        .scm_rows, .scm_row_hover, .scm_repo_hover, .scm_scrolled, .scm_commit_edit, .scm_blocker, .scm_small_font, .dock_over_status_bar => buildScmFrame(scenario, tokens, buffers),
        .scm_history => buildScmHistoryFrame(scenario, tokens, buffers),
        .file_tree_rows, .file_tree_row_hover, .file_tree_scrolled => buildFileTreeFrame(scenario, tokens, buffers),
        .context_menu_checked, .context_menu_unchecked, .context_menu_send => buildContextMenuFrame(scenario, tokens, buffers),
        .editor_gutter, .editor_scrolled, .editor_font_large, .editor_hazard, .editor_wide_glyph, .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll, .editor_folded, .editor_real_file, .editor_typescript, .editor_selection, .editor_find, .editor_caret_bar, .editor_caret_block, .editor_caret_underline => buildEditorGutterFrame(scenario, buffers),
        .editor_diff, .editor_diff_scrolled, .editor_diff_selection => buildEditorDiffFrame(scenario, buffers),
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
        .sort_toggle_hover,
        .sort_toggle_pressed,
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

/// `editor_selection` 픽스처. **줄을 걸친 선택**을 보여야 하므로 짧고 뚜렷한 줄로 짠다 —
/// 첫 줄은 중간부터, 가운데 줄은 통째로, 끝 줄은 머리부터 칠해지는 세 모양이 한 화면에 든다.
const editor_selection_lines = [_][]const u8{
    "fn render(self: *View) void {",
    "    const rows = self.visibleRows();",
    "    for (rows) |row| self.paint(row);",
    "}",
    "",
    "// 선택 밖 — 띠가 여기까지 오면 안 된다",
};

/// 줄별 선택 범위. `render(self` 뒤부터 셋째 줄 `for (rows)`까지 — 세 줄에 걸친다.
const editor_selection_marks_row0 = [_]chrome.components.editor_view.frame.Mark{.{ .start = 10, .len = 18 }}; // "self: *View) void"
const editor_selection_marks_row1 = [_]chrome.components.editor_view.frame.Mark{.{ .start = 0, .len = 34 }}; // 줄 전체
const editor_selection_marks_row2 = [_]chrome.components.editor_view.frame.Mark{.{ .start = 0, .len = 14 }}; // "    for (rows)"
const editor_selection_marks_none = [_]chrome.components.editor_view.frame.Mark{};
const editor_selection_marks = [_][]const chrome.components.editor_view.frame.Mark{
    &editor_selection_marks_row0,
    &editor_selection_marks_row1,
    &editor_selection_marks_row2,
    &editor_selection_marks_none,
    &editor_selection_marks_none,
    &editor_selection_marks_none,
};

/// `editor_find` 픽스처. 검색어는 `row`이고, **둘째 줄에 넷**이 든다 — 한 줄 여러 매치가 이
/// 슬라이스의 이유라 그것이 화면 가운데 있어야 한다.
const editor_find_lines = [_][]const u8{
    "fn paint(self: *View) void {",
    "    for (row) |row| self.row(row);",
    "    // 위 줄에 매치가 넷이다 — 현재는 그 중 하나뿐",
    "}",
    "",
    "// 여기 row 하나 더 — 다른 줄에도 선다",
};

/// 줄별 검색 결과. `editor_selection`과 같은 축이고 **줄당 개수만 다르다**.
const editor_find_marks_row1 = [_]chrome.components.editor_view.frame.Mark{
    .{ .start = 9, .len = 3 }, // for (row)
    .{ .start = 15, .len = 3 }, // |row|
    .{ .start = 25, .len = 3 }, // self.row(
    .{ .start = 29, .len = 3 }, // (row)
};
const editor_find_marks_row5 = [_]chrome.components.editor_view.frame.Mark{.{ .start = 10, .len = 3 }}; // `여기`가 3 byte씩이다
const editor_find_marks_none = [_]chrome.components.editor_view.frame.Mark{};
const editor_find_marks = [_][]const chrome.components.editor_view.frame.Mark{
    &editor_find_marks_none,
    &editor_find_marks_row1,
    &editor_find_marks_none,
    &editor_find_marks_none,
    &editor_find_marks_none,
    &editor_find_marks_row5,
};
/// 현재 매치는 **둘째 줄의 둘째 것**이다. 첫 것을 고르면 "앞에서 자른 것"과 구분이 안 되고,
/// 마지막을 고르면 "뒤에서 자른 것"과 구분이 안 된다 — 가운데여야 셋으로 가르는 코드가 판정된다.
const editor_find_current: chrome.components.editor_view.frame.CurrentMatch = .{ .line = 1, .start = 15 };

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
/// 접힌 화면이 그리는 줄들 — 접은 블록은 몸통이 숨어 **머리 줄만** 남았다.
const editor_folded_lines = [_][]const u8{
    "pub fn main() !void {",
    "fn helper(a: u32) u32 {",
    "const config = .{",
    "    .verbose = true,",
};

/// 위 줄들의 **원래 문서 번호**. 접힌 만큼 건너뛴다 — 이것이 접힘의 눈에 보이는 증거다.
///
/// **표식과 앞뒤가 맞아야 한다.** 초판은 `{ 1, 8, 15, 24 }`에 마지막 표식을 `.open`으로 두었는데,
/// 그러면 *"15는 펼쳐져 있는데 다음 보이는 줄이 24"*가 되어 **제품에서 나올 수 없는 화면**을 골든이
/// 굳힌다(펼쳐졌으면 16이 와야 한다). 캡처는 리뷰어가 눈으로 읽는 계약이므로, 손으로 적는 픽스처도
/// 제품이 만들 수 있는 조합이어야 한다(적대적 검증 2026-08-17).
const editor_folded_numbers = [_]?u32{ 1, 8, 15, 16 };

/// 줄마다의 접힘 표식. 앞의 둘은 접혀 있고(▸ — 번호가 1→8→15로 건너뛴다), 셋째는 **펼쳐진 머리**
/// (▾ — 그래서 바로 다음 줄 16이 이어진다), 넷째는 접을 자리가 아니다.
const editor_folded_marks = [_]chrome.components.editor_view.gutter.Fold{ .collapsed, .collapsed, .open, .none };

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

/// caret 모양 fixture. **세 자리에 커서를 세운다** — 글자 위(ASCII)·한글 위(2칸)·줄 끝(덮을
/// 글자가 없다). 마지막 자리가 있어야 "줄 끝의 블록 커서" 가 캡처에 남는다.
const editor_caret_lines = [_][]const u8{
    "const a = 1;",
    "가나다 라마바",
    "end",
};

/// 줄마다의 커서 자리(줄 안 byte offset). `editor_caret_lines`와 같은 축이다.
/// 줄 0: `t`(6) 위 · 줄 1: `가`(0) 위 — 2칸 글자다 · 줄 2: 줄 끝(3) — 덮을 글자가 없다.
const editor_caret_row0 = [_]u32{6};
const editor_caret_row1 = [_]u32{0};
const editor_caret_row2 = [_]u32{3};
const editor_caret_rows = [_][]const u32{ &editor_caret_row0, &editor_caret_row1, &editor_caret_row2 };

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
/// Lab 편집기 장면의 구문 색. 줄 배열을 문서 하나로 이어 붙여 제품의 변환 층에 물린다.
///
/// **Lab은 결정적이어야 하므로** 여는 언어를 `.zig`로 고정한다 — 픽스처가 전부 Zig 코드다.
/// 색이 안 나오면(`grammar` 없음 등) 빈 것을 돌려주고 화면은 무색이 된다(§5).
const LabSyntax = struct {
    allocator: std.mem.Allocator,
    doc: []u8 = &.{},
    file: ?maru.session.editor.edit_doc.EditableFile = null,
    state: editor_syntax.State = .{},
    colors: []const []const chrome.components.editor_view.content.ColorSpan = &.{},

    fn deinit(self: *LabSyntax) void {
        self.state.deinit(self.allocator);
        if (self.file) |*f| f.deinit();
        if (self.doc.len > 0) self.allocator.free(self.doc);
        self.* = .{ .allocator = self.allocator };
    }
};

fn editorSyntaxColors(lines: []const []const u8, tab_width: u16, grammar: maru.session.editor.language.Grammar) LabSyntax {
    const a = std.heap.page_allocator;
    var out: LabSyntax = .{ .allocator = a };

    var total: usize = 0;
    for (lines) |l| total += l.len + 1;
    if (total == 0) return out;

    const doc = a.alloc(u8, total) catch return out;
    var n: usize = 0;
    for (lines) |l| {
        @memcpy(doc[n..][0..l.len], l);
        n += l.len;
        doc[n] = '\n';
        n += 1;
    }
    out.doc = doc;

    out.file = maru.session.editor.edit_doc.EditableFile.init(a, doc, true) catch {
        return out;
    };
    out.state = editor_syntax.open(out.file.?.content, grammar);
    out.colors = editor_syntax.lineColors(
        &out.state,
        a,
        out.file.?.content,
        out.file.?.lines,
        0,
        lines.len,
        tab_width,
        &.{}, // Lab 은 접힘이 없다 — 두 축이 같다
    );
    return out;
}

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
    // **제품과 같은 내용 여백을 쓴다**(`frame.content_inset_px`) — Lab이 안 쓰면 캡처가 제품보다
    // 넓은 본문을 보여 주고, 포커스 테두리에 덮이는 경계를 예고하지 못한다.
    const view_rect_full = editor_view.frame.contentRect(.{ .x = 0, .y = 0, .w = viewport_w, .h = viewport_h });
    const content_w = view_rect_full.w;
    const total_cols: u16 = @intCast((content_w -| scrollbar_metrics.gutterPx()) / cell_w_px);
    // **남은 공간 전부가 스크롤바 gutter다.** `total_cols`가 버림이라 본문이 셀 경계에서 끝나고,
    // 요구한 gutter(12px)보다 넓은 자투리가 생긴다 — 그것을 gutter에 포함하지 않으면 막대가 화면
    // 오른쪽 끝에서 어중간하게 떠 있다(실측 6px). 남은 폭을 그대로 주면 막대가 그 안에 가운데로 선다.
    const scrollbar_gutter_px: u32 = content_w -| (@as(u32, total_cols) * cell_w_px);
    // **호출자가 준 줄이 있으면 그것을 그린다**(`editor_real_file`) — 디스크에서 읽어 온 것이라
    // Lab이 픽스처로 흉내낼 수 없다.
    const lines: []const []const u8 = scenario.lines orelse switch (scenario.id) {
        .editor_hazard => &editor_hazard_lines,
        .editor_wide_glyph => &editor_width_lines,
        .editor_caret_bar, .editor_caret_block, .editor_caret_underline => &editor_caret_lines,
        .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll => &editor_wrap_lines,
        .editor_folded => &editor_folded_lines,
        .editor_selection => &editor_selection_lines,
        .editor_find => &editor_find_lines,
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
    // **가로 막대가 서는 시나리오만 값을 낸다.** 손으로 적지 않고 fixture를 세는 이유는 제품이
    // 여는 경로에서 세는 그 계산과 같아야 캡처가 제품을 예고하기 때문이다(§4.1a).
    const hscroll_max_cols: ?u32 = if (scenario.id == .editor_hscroll) blk: {
        var widest: u32 = 0;
        for (lines) |line| widest = @max(widest, editor_view.content.lineColumnsUpTo(line, lab_tab_width, editor_view.frame.max_cols_count_limit));
        break :blk widest;
    } else null;
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
            counts[i] = editor_view.content.rowCount(line, lab_tab_width, layout.content.width, true, &index_scratch).rows;
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

    // **조립은 `editor_view.frame`이 한다.** 순서(배경 → 본문 → gutter → 스크롤바)와 저장소 분배가
    // 계약이라 Lab이 자기 판으로 짜면 제품과 갈리고, 그러면 이 캡처가 제품을 예고하지 못한다.
    //
    // **이 픽스처에서는 뷰 경계가 눈에 보이지 않는다.** Lab 토큰의 `surface_bg`가 오프스크린 렌더의
    // clear color와 우연히 같은 값(20,20,20)이라 뷰 안팎이 같은 색으로 나온다. 제품에서는 pane이
    // 자기 배경을 그리므로 두 색이 갈리고, 그때 그 사각이 편집기 경계가 된다.
    //
    // **스크롤 시나리오에서 화면 아래가 비는 이유**도 여기 적어 둔다: `vp.rows`를 6으로 좁혀 놓았고
    // 화면은 45행분이라, 편집기는 위 6행만 그리고 스크롤바도 그 안에 선다. 캡처만 보면 "꽉 안 찼는데
    // 스크롤바가 있다"로 읽히는데, 좁힌 뷰포트 안에서는 정확한 동작이다.
    const view_h_px: u32 = @as(u32, @min(vp.rows, row_capacity)) * cell_h_px;

    var content_rows: [row_capacity]editor_view.content.Row = undefined;
    var visual_rows: [row_capacity]editor_view.visual_map.VisualRow = undefined;
    var gutter_rows: [row_capacity]editor_view.gutter.Row = undefined;
    var row_counts: [row_capacity]u32 = undefined;
    // **크기를 손으로 적지 않는다.** 세는 쪽과 그리는 쪽이 갈리면 같은 줄의 행 수가 달라지고
    // (visual-mapping §4.1 "행 수를 세는 저장소는 한 곳에서 정한다"), Lab이 제품과 다른 화면을
    // 골든으로 굳힌다 — 캡처가 지켜야 할 것이 바로 제품 화면이다(적대적 검증 2026-08-17).
    var count_scratch: [editor_view.content.count_scratch_bytes]u8 = undefined;
    // 블록 caret 이 선 칸의 글자를 배경색으로 낼 자리(`frame.Scratch.caret_cols`).
    var caret_cols: [64]u32 = undefined;

    // **구문 강조 색**(§5.3). **제품과 같은 층을 지난다** — Lab이 자기 나름대로 색을 만들면
    // 캡처가 제품을 예고하지 못한다(이 파일이 크기 계산에서 이미 같은 판단을 적어 두었다).
    //
    // **이 배선 전에는 캡처가 무색이었다** — Lab이 `frame.build`를 직접 부르며 색을 안 넘겼고,
    // 그래서 **골든 게이트가 색 회귀를 원리상 못 잡았다**. 기능이 화면에 뜨는데 캡처 하네스가
    // 그것을 한 번도 안 밟는 상태였다.
    // **표시 폭 장면은 색을 안 입힌다.** `a390f8b8`이 세운 규율을 잇는다 — 그 커밋은 *"그림은
    // Apple Color Emoji가 소유하고 우리가 계약하는 것은 몇 칸을 차지하는가뿐"*이라며 이모지
    // 그림을 크롭에서 잘라 냈다. 그런데 **색이 붙으면 그 회피가 무력화된다**: 잘라 낸 것은
    // 이모지였지만 남긴 `|` 막대 자체가 색을 갖게 되고, 색 있는 글리프는 안티에일리어싱이
    // macOS 버전마다 달라 CI에서만 깨진다(실측: 채널 차이 139, 허용치 2 — 같은 사고가 그
    // 커밋에서 200으로 한 번 났다).
    //
    // **색 계약은 다른 골든이 지킨다**(`editor-real-file`·`editor-content-text` 등). 여기서
    // 재는 것은 폭이지 색이 아니다.
    const paints_syntax = scenario.id != .editor_wide_glyph;
    // **장면이 언어를 정한다.** 예전엔 `.zig`가 박혀 있었는데, grammar가 열여덟이 된 뒤로는 그러면
    // 다른 언어의 색이 **캡처에 영원히 안 나타난다** — 골든이 지키는 것이 zig 하나뿐이 된다.
    const scenario_grammar: maru.session.editor.language.Grammar = switch (scenario.id) {
        .editor_typescript => .typescript,
        else => .zig,
    };
    var syn = if (paints_syntax) editorSyntaxColors(lines, lab_tab_width, scenario_grammar) else LabSyntax{ .allocator = std.heap.page_allocator };
    defer syn.deinit();

    const fw = chrome.components.editor_view.frame.build(.{
        .lines = lines,
        .line_colors = syn.colors,
        .tab_width = lab_tab_width,
        .first_line = first_line,
        .first_piece = first_piece,
        .first_col = vp.first_col,
        // **gutter 자릿수는 문서 줄 수로 잡는다** — 접히면 그리는 줄보다 번호가 크다.
        .total_lines = if (scenario.id == .editor_folded) 24 else line_count,
        .line_numbers = if (scenario.id == .editor_folded) &editor_folded_numbers else null,
        .folds = if (scenario.id == .editor_folded) &editor_folded_marks else null,
        .selection_marks = if (scenario.id == .editor_selection) &editor_selection_marks else null,
        .search_marks = if (scenario.id == .editor_find) &editor_find_marks else null,
        .search_current = if (scenario.id == .editor_find) editor_find_current else null,
        // **caret 시나리오만 커서를 세운다.** 다른 골든까지 커서를 켜면 그 캡처들이 깜빡임 축을
        // 함께 떠안는다(커밋 상자 골든이 같은 이유로 한 시나리오에만 caret을 켠다).
        .carets = switch (scenario.id) {
            .editor_caret_bar, .editor_caret_block, .editor_caret_underline => &editor_caret_rows,
            else => null,
        },
        .caret_shape = switch (scenario.id) {
            .editor_caret_block => .block,
            .editor_caret_underline => .underline,
            else => .bar,
        },
        // **가로 스크롤 시나리오만 막대를 세운다.** 값은 손으로 적지 않고 fixture에서 센다 —
        // 제품이 여는 경로에서 세는 그 값과 같은 계산이어야 캡처가 제품을 예고한다(§4.1a).
        .content_max_cols = hscroll_max_cols,
        // **가로 막대가 자리를 먹는다**(§4.1a) — 제품은 `diff_frame.sideMetricsWith`가 같은 일을
        // 한다. Lab이 이 몫을 안 빼면 막대가 뷰 밖에 그려져 캡처에 안 나오고, 그러면 이 시나리오가
        // 예고해야 할 화면을 예고하지 못한다.
        .visible_rows = editor_view.diff_frame.sideMetricsWith(
            content_w,
            view_h_px,
            cell_w_px,
            cell_h_px,
            editor_view.frame.showsHorizontalBar(wrap_on, hscroll_max_cols, layout.content.width),
        ).visible_rows,
        .wrap = wrap_on,

        .rect = editor_view.frame.contentRect(.{ .x = 0, .y = 0, .w = viewport_w, .h = view_h_px }),
        .background_rect = .{ .x = 0, .y = 0, .w = viewport_w, .h = view_h_px }, // 배경은 뷰 전체(§4.1b)
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .font_px = scenario.font_px,
        .total_cols = total_cols,
        .scrollbar_gutter_px = scrollbar_gutter_px,
        .metrics = scrollbar_metrics,
    }, .{
        .ops = buffers.ops,
        .text_bytes = buffers.text_bytes,
        .runs = buffers.text_runs,
        .content_rows = content_rows[0..@min(visible, row_capacity)],
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &row_counts,
        .count_scratch = &count_scratch,
        .caret_cols = &caret_cols,
    });

    return .{
        // 아직 hit-test 대상이 없다(줄 번호 클릭은 N2의 줄 선택, 본문 클릭은 캐럿 배치다). 빈 트리를 낸다.
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = .sidebar, .ops = buffers.ops[0..fw.ops] },
    };
}

/// N1.5 c — 나란한 비교 한 프레임. **제품과 같은 함수를 부른다**(`diff_frame.build`) — 조합을 Lab이
/// 따로 들면 캡처가 제품을 예고하지 못한다(편집기 배경 층에서 실제로 그 상태가 됐었다).
fn buildEditorDiffFrame(scenario: Scenario, buffers: FrameBuffers) !Frame {
    const editor_view = chrome.components.editor_view;
    const viewport_w: u32 = @intFromFloat(scenario.viewport_px.width);
    const viewport_h: u32 = @intFromFloat(scenario.viewport_px.height);

    // **행이 좌우로 나란한 fixture다.** 셋을 한 화면에 담는다:
    //   ① 양쪽에 있는 줄(context), ② 왼쪽에만 있는 줄(삭제) + 오른쪽 빈 행,
    //   ③ 오른쪽에만 있는 줄(추가) + 왼쪽 빈 행, ④ 자리에서 바뀐 줄(짝).
    // 번호가 **각자 문서**의 것이라, 빈 행을 지나면 반대쪽 번호가 한 칸 앞서 나간다 — 순차 번호로
    // 그리면 그 어긋남이 캡처에 그대로 보인다.
    // 줄을 **열 폭 안에** 둔다. 넘치면 골든이 우연한 잘림을 고정하고, 배치가 틀렸는지 폭이 좁았는지
    // 캡처만 보고는 갈리지 않는다(첫 렌더에서 오른쪽 `;` 하나가 그렇게 잘렸다).
    const left_texts = [_][]const u8{ "fn main() {", "  var a = 1;", "", "  log(a);", "}" };
    const right_texts = [_][]const u8{ "fn main() {", "  var b = 2;", "  var c = 3;", "  log(b);", "}" };
    const left_numbers = [_]?u32{ 1, 2, null, 3, 4 };
    const right_numbers = [_]?u32{ 1, 2, 3, 4, 5 };

    // **스크롤 시나리오는 뷰포트보다 긴 비교를 만든다.** 화면에 다 들어가면 막대가 아예 안 그려져
    // (그것이 옳은 동작이다) 스크롤 관련 계약이 무판정으로 남는다. 90행이면 45행 뷰포트의 두 배라,
    // 문서 중간에서 막대가 트랙 가운데 자리에 선다 — 그 자리가 논리 줄이 아니라 **시각 행** 기준임을
    // 이 캡처가 픽셀로 고정한다.
    const long_rows = 90;
    // **줄 문자열은 프레임보다 오래 살아야 한다.** op은 줄 슬라이스를 **빌린다**(복사하지 않는다) —
    // 스택 버퍼에 만들어 넣으면 이 함수가 반환하는 순간 죽고, 캡처에는 번호만 남고 본문이 사라진다
    // (실제로 그렇게 한 번 뽑혔다). comptime 문자열은 정적이라 그 문제가 없다.
    const long_labels = comptime blk: {
        @setEvalBranchQuota(200_000);
        var out: [long_rows][]const u8 = undefined;
        for (0..long_rows) |i| out[i] = std.fmt.comptimePrint("row {d:0>2}", .{i});
        break :blk out;
    };
    var long_left: [long_rows][]const u8 = undefined;
    var long_right: [long_rows][]const u8 = undefined;
    var long_left_nums: [long_rows]?u32 = undefined;
    var long_right_nums: [long_rows]?u32 = undefined;
    var long_left_bands: [long_rows]editor_view.frame.RowBand = undefined;
    var long_right_bands: [long_rows]editor_view.frame.RowBand = undefined;
    for (0..long_rows) |i| {
        // 다섯 줄마다 한 줄이 바뀐다 — 스크롤한 화면 안에 밴드가 반드시 들어온다.
        const changed = i % 5 == 3;
        long_left[i] = long_labels[i];
        long_right[i] = if (changed) "changed" else long_labels[i];
        long_left_nums[i] = @intCast(i + 1);
        long_right_nums[i] = @intCast(i + 1);
        long_left_bands[i] = if (changed) .removed else .none;
        long_right_bands[i] = if (changed) .added else .none;
    }
    const scrolled = scenario.id == .editor_diff_scrolled;
    // **왼쪽은 삭제만, 오른쪽은 추가만.** 2행은 자리에서 바뀐 줄(양쪽에 색), 3행은 오른쪽에만 있는 줄
    // (왼쪽은 빈 행이라 색이 없다) — 좌우를 나눈 이유가 이 두 모양에서 보인다.
    const left_bands = [_]editor_view.frame.RowBand{ .none, .removed, .none, .none, .none };
    const right_bands = [_]editor_view.frame.RowBand{ .none, .added, .added, .none, .none };
    // **바뀐 글자만 진하게**(§3.5 — 슬라이스 e). 2행이 `var a = 1;` → `var b = 2;`라 두 글자가
    // 떨어져 바뀐다. 줄 전체 밴드 위에 그 두 자리만 한 겹 더 얹히는 것이 이 캡처의 판정 대상이다.
    const left_marks_row = [_]editor_view.frame.Mark{ .{ .start = 6, .len = 1 }, .{ .start = 10, .len = 1 } };
    const right_marks_row = [_]editor_view.frame.Mark{ .{ .start = 6, .len = 1 }, .{ .start = 10, .len = 1 } };
    const left_marks = [_][]const editor_view.frame.Mark{ &.{}, &left_marks_row, &.{}, &.{}, &.{} };
    const right_marks = [_][]const editor_view.frame.Mark{ &.{}, &right_marks_row, &.{}, &.{}, &.{} };

    // **두 열로 갈리므로 열당 절반이다**(`splitScratch`). 64면 열당 32행인데 뷰포트는 45행이라,
    // 캡처에 **제품에는 없을 스크롤바**가 뜬다(막대는 "보이는 높이"를 그린 행 수로 잡는다).
    // 골든이 제품을 예고하려면 이 저장소가 뷰포트를 덮어야 한다.
    var content_rows: [128]editor_view.content.Row = undefined;
    var visual_rows: [128]editor_view.visual_map.VisualRow = undefined;
    var gutter_rows: [128]editor_view.gutter.Row = undefined;
    var row_counts: [128]u32 = undefined;
    // 위와 같은 단일 출처. **비교는 좌우가 이것을 반씩 나눠 쓴다**(`diff_frame.splitScratch`).
    var count_scratch: [editor_view.content.count_scratch_bytes]u8 = undefined;
    // 블록 caret 이 선 칸의 글자를 배경색으로 낼 자리(`frame.Scratch.caret_cols`).
    var caret_cols: [64]u32 = undefined;

    // **오른쪽 열만 고른 상태.** 계약이 *"좌우를 걸치는 선택은 만들지 않는다"*로 정했으므로 한쪽만
    // 띠가 선다 — 2행 중간부터 4행 앞부분까지, 짝맞춤 빈 행이 있는 왼쪽과 나란히 놓여 대비된다.
    const sel_r1 = [_]editor_view.frame.Mark{.{ .start = 2, .len = 9 }}; // "var b = 2;"의 일부
    const sel_r2 = [_]editor_view.frame.Mark{.{ .start = 0, .len = 12 }}; // 행 전체
    const sel_r3 = [_]editor_view.frame.Mark{.{ .start = 0, .len = 6 }}; // "  log("
    const sel_none = [_]editor_view.frame.Mark{};
    const right_selection = [_][]const editor_view.frame.Mark{ &sel_none, &sel_r1, &sel_r2, &sel_r3, &sel_none };
    const selecting = scenario.id == .editor_diff_selection;

    const w = editor_view.diff_frame.build(.{
        .left = if (scrolled)
            .{ .lines = &long_left, .numbers = &long_left_nums, .total_lines = long_rows, .bands = &long_left_bands }
        else
            .{ .lines = &left_texts, .numbers = &left_numbers, .total_lines = 4, .bands = &left_bands, .marks = &left_marks },
        .right = if (scrolled)
            .{ .lines = &long_right, .numbers = &long_right_nums, .total_lines = long_rows, .bands = &long_right_bands }
        else
            .{ .lines = &right_texts, .numbers = &right_numbers, .total_lines = 5, .bands = &right_bands, .marks = &right_marks, .selection_marks = if (selecting) &right_selection else null },
        // **문서 중간부터 그린다** — 막대가 트랙 가운데에 서고, 맨 위 줄 번호가 41이다.
        .first_line = if (scrolled) 40 else 0,
        .tab_width = lab_tab_width,
        .rect = editor_view.frame.contentRect(.{ .x = 0, .y = 0, .w = viewport_w, .h = viewport_h }),
        .background_rect = .{ .x = 0, .y = 0, .w = viewport_w, .h = viewport_h }, // 배경은 뷰 전체(§4.1b)
        .cell_w_px = scenario.cell_w_px,
        .cell_h_px = scenario.cell_h_px,
        .font_px = scenario.font_px,
    }, .{
        .ops = buffers.ops,
        .text_bytes = buffers.text_bytes,
        .runs = buffers.text_runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &row_counts,
        .count_scratch = &count_scratch,
        .caret_cols = &caret_cols,
    });

    return .{
        // 아직 hit-test 대상이 없다(읽기 전용 비교다). 빈 트리를 낸다.
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = .sidebar, .ops = buffers.ops[0..w.ops] },
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
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = .{ .messages = "94 messages", .age = "3m ago", .model = "claude-opus-5" }, .selected = scenario.id == .retained_list } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = .{ .messages = "140 messages", .age = "22h ago", .model = "gpt-5.6-sol" } } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = .{ .messages = "356 messages", .age = "1d ago", .model = "claude-opus-5" } } },
    };
    // 그룹 **둘**이 있어야 sticky의 세 번째 상태(다음 헤더가 밀어냄)를 만들 수 있다. 하나짜리
    // fixture로는 "상단 고정"까지만 보이고 두 헤더가 겹치는 회귀를 못 본다.
    const two_groups = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "sample-workspace", .count = 2 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = .{ .messages = "94 messages", .age = "3m ago", .model = "claude-opus-5" } } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = .{ .messages = "140 messages", .age = "22h ago", .model = "gpt-5.6-sol" } } },
        .{ .group = .{ .identity = 4, .label = "second-workspace", .count = 2 } },
        .{ .card = .{ .identity = 5, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = .{ .messages = "356 messages", .age = "1d ago", .model = "claude-opus-5" } } },
        .{ .card = .{ .identity = 6, .provider = .codex, .title = "Publish scrollbar inside preorder", .summary = "Keep the tree invariants while the gutter stays reserved", .metadata = .{ .messages = "12 messages", .age = "2d ago", .model = "gpt-5.6-sol" } } },
    };
    // This is deliberately a real Session Dock card, not an out-of-band font test canvas. The
    // retained-list fixture proves list behavior; this specimen instead makes font selection
    // reviewable at PR scale. ASCII differentiators expose the selected primary face, while the
    // Korean line makes a missing primary glyph visibly exercise CoreText's fallback face.
    const font_specimen = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "font specimen", .count = 3 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Il1 O0 MWmw @# [] {} <>", .summary = "ASCII primary-face specimen", .metadata = .{ .messages = "한글 가나다라마바사", .age = "primary or fallback" }, .selected = true } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "rn m w |! `.,:; /\\", .summary = "narrow and wide glyph contours", .metadata = .{ .messages = "가각간 한글 폰트 비교" } } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "S5 2Z 8B 0O 1l I|", .summary = "same fixed grid, distinct ink", .metadata = .{ .messages = "fallback face is reported in JSON" } } },
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
            // 호버 시나리오는 헤더만 보지만 목록이 비면 헤더 폭·개수 표기가 실제 사용과 달라진다.
            .retained_list, .sort_toggle_hover, .sort_toggle_pressed => &retained,
            .font_specimen => &font_specimen,
            .partial_scroll => retained[1..],
            .partial_group_scroll, .scrollbar => &retained,
            .sticky_at_rest, .sticky_pinned, .sticky_pushed => &two_groups,
            .empty, .loading, .sidebar_status_strip => &.{}, // strip 시나리오는 목록이 비어야 경계만 남는다
            // editor_gutter는 buildEditorGutterFrame이 처리한다 — 도크 목록을 타지 않는다.
            .context_menu_checked, .context_menu_unchecked, .context_menu_send, .scm_rows, .scm_history, .scm_row_hover, .scm_repo_hover, .scm_scrolled, .scm_commit_edit, .scm_blocker, .scm_small_font, .dock_over_status_bar, .file_tree_rows, .file_tree_row_hover, .file_tree_scrolled, .detail_loading, .detail_ready, .detail_stale, .detail_unavailable, .editor_gutter, .editor_scrolled, .editor_font_large, .editor_hazard, .editor_wide_glyph, .editor_wrap, .editor_hscroll, .editor_wrap_scrolled, .editor_wrap_stale_scroll, .editor_folded, .editor_real_file, .editor_typescript, .editor_selection, .editor_find, .editor_caret_bar, .editor_caret_block, .editor_caret_underline, .editor_diff, .editor_diff_scrolled, .editor_diff_selection => unreachable,
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
    // `.ghost` 토글의 면·테두리는 **호버할 때만** 존재한다. 포인터가 없는 캡처에서 그 그림을 보려면
    // 상태를 직접 세워야 한다(scm 행 호버와 같은 근거).
    const dock_state: chrome.ui.interaction.InteractionState = switch (scenario.id) {
        .sort_toggle_hover => .{ .hovered = session_dock.build.NodeIds.sort_toggle },
        // capture는 **action까지** 지목한다(제품에서도 press가 action에 붙는다). action id는 build가
        // 발급하므로 발행된 표에서 그 intent를 찾아 쓴다 — 상수를 적으면 발급 순서가 바뀔 때 조용히 어긋난다.
        .sort_toggle_pressed => .{ .capture = .{
            .id = session_dock.build.NodeIds.sort_toggle,
            .action_id = sortActionId(session_frame.actions),
        } },
        else => .{},
    };
    const draws = try session_dock.view.view(dock_props, session_frame, dock_state, tokens, .{ .ops = buffers.ops, .runs = buffers.text_runs, .text_bytes = buffers.text_bytes });
    return .{ .tree = session_frame.tree, .draws = draws };
}

/// 발행된 action 표에서 정렬 토글의 action id를 찾는다. pressed 시나리오가 그 짝(`node id`, `action id`)을
/// 둘 다 맞춰야 `resolveButton`이 press로 해석한다 — 하나만 맞으면 캡처가 평소 그림으로 돌아가 골든이
/// "pressed를 본다"고 거짓말한다.
fn sortActionId(actions: []const session_dock.ids.Entry) chrome.ui.tree.UiActionId {
    for (actions) |entry| if (entry.intent == .toggle_sort) return entry.action_id;
    return 0;
}

/// 소스 컨트롤 도크 한 프레임. **픽스처는 합성이다** — Lab은 deterministic·effect-free라 저장소를 읽지
/// 않는다(읽으면 캡처가 디스크 상태에 딸린다).
///
/// 행 구성은 이 도크가 실제로 내는 형태를 덮도록 골랐다: 두 그룹 · 스테이지된 파일 · 추적되지 않은 파일 ·
/// **충돌 파일**(동작이 없는 행) · 증감이 있는 파일. 그래야 상태 문자 색 축과 "동작 없는 행은 자리를
/// 비우지 않는다"가 한 캡처에 든다.
/// 커밋 상자 fixture. 제목 줄 + 빈 줄 + **도크 폭에서 접히는 긴 본문**을 함께 담는다 — 셋이 아니면
/// 랩·빈 줄·caret 중 하나가 무판정으로 남는다.
const commit_fixture_message = "fix: 커밋 상자를 그린다\n\n랩이 켜져 있어 이 줄은 도크 폭에서 접힌다.";
/// caret 오프셋 — 둘째(빈) 줄 다음 본문 안이다.
const commit_fixture_caret: usize = 40;

/// 체크 열이 있는 컨텍스트 메뉴 한 프레임. **제품과 같은 `context_menu.view` 를 부른다** — 조합을 Lab 이
/// 따로 들면 캡처가 제품을 예고하지 못한다(재는 쪽과 그리는 쪽이 갈렸던 것이 바로 이 컴포넌트다).
///
/// 라벨은 제품과 **같은 키**에서 온다. Lab 이 `.ko` 를 고정하므로 한글 라벨이 나오고, **한글이 EAW Wide 라
/// 마크 2칸이 상자 폭에 들어갔는지가 눈으로 보인다** — 영어 라벨이면 그 차이가 덜 드러난다.
fn buildContextMenuFrame(scenario: Scenario, tokens: *const chrome.Tokens, buffers: FrameBuffers) !Frame {
    const arena = buffers.arena orelse return .{
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = .sidebar, .ops = buffers.ops[0..0] },
    };

    // 사이드바 ⚙ 의 보기 옵션 메뉴와 같은 두 줄. 길이가 다른 두 라벨이라 **가장 긴 줄**이 상자 폭을
    // 정하고, 그 줄이 테두리에 닿는지가 이 캡처의 판정 대상이다.
    // **제품이 쓰는 그 키를 읽는다** — Lab 이 자기 리터럴을 들면 문구가 바뀔 때 캡처만 옛 폭에 머문다.
    // Lab 은 `.ko` 를 고정하므로(`chrome_lab_smoke.zig`) 제품의 한국어 화면과 같은 폭이 나온다.
    const view_items = [_][]const u8{ maru.i18n.t(.set_show_branch), maru.i18n.t(.set_show_folder) };

    // **보내기 메뉴는 줄 구성이 다르다**(§5.1) — 머리글 한 줄 + 대상 줄들 + 편집 항목. 대상 라벨은
    // 제품이 `agent_selection.writeLabel` 로 만드는 그 모양(`이름 — 폴더 (브랜치)`)을 그대로 쓴다 —
    // 여기서 리터럴을 새로 지으면 제품 폭과 캡처 폭이 갈린다.
    // **arena 에 잡는다 — 스택이면 안 된다.** `view` 는 라벨을 **빌리는** draw op 을 만들고 그것이
    // 이 함수가 돌아간 **뒤에** 렌더된다. 처음에 스택 배열로 썼더니 캡처에서 두 대상 줄이 `(` 하나와
    // 빈 줄로 나왔다(죽은 스택 바이트). **시각 확인이 그것을 잡았다** — 헤드리스로는 안 보였다.
    const send_bufs = try arena.alloc([128]u8, 2);
    const send_items = [_][]const u8{
        maru.i18n.t(.ctx_send_selection),
        maru.session.agent_selection.writeLabel(&send_bufs[0], .{
            .surface_id = 1,
            .kind = .claude,
            .where = "~/Documents/workspace/maru",
            .branch = "feat/send-selection",
        }) orelse "",
        maru.session.agent_selection.writeLabel(&send_bufs[1], .{
            .surface_id = 2,
            .kind = .shell,
            .shell_name = maru.i18n.t(.ctx_target_shell),
            .where = "~/work",
        }) orelse "",
        maru.i18n.t(.ctx_cut),
        maru.i18n.t(.ctx_copy),
        maru.i18n.t(.ctx_paste),
        maru.i18n.t(.ctx_select_all),
    };
    const items: []const []const u8 = if (scenario.id == .context_menu_send) &send_items else &view_items;

    var state: chrome.components.context_menu.State = .{};
    if (scenario.id == .context_menu_send) {
        // 머리글 한 줄만 고를 수 없다. 선택은 **둘째 대상**에 둔다 — "마지막으로 보낸 대상이
        // 기본 선택" 을 그림으로 보이려면 첫 줄이 아니어야 하고(첫 줄은 기본값과 구별이 안 된다),
        // 머리글에 강조가 안 붙는 것도 같은 캡처에서 보인다.
        state.showWithHeaders(context_menu_fixture_anchor_x, context_menu_fixture_anchor_y, items.len, 1);
        state.selected = 2;
    } else {
        state.show(context_menu_fixture_anchor_x, context_menu_fixture_anchor_y, items.len);
        // 켜짐 하나·꺼짐 하나 → 마크 두 종류가 한 캡처에 든다. 둘 다 꺼짐 시나리오는 **같은 폭**이어야 한다.
        state.checked_mask = if (scenario.id == .context_menu_checked) 0b01 else 0b00;
    }

    const p: chrome.props.ChromeProps = .{ .metrics = .{
        .cell_width_px = scenario.cell_w_px,
        .cell_height_px = scenario.cell_h_px,
        .sidebar_width_px = 0,
        .backing_width_px = @intFromFloat(scenario.viewport_px.width),
        .backing_height_px = @intFromFloat(scenario.viewport_px.height),
    } };

    var ops: std.ArrayList(chrome.draw.Op) = .empty;
    try chrome.components.context_menu.view(&state, items, p, tokens, arena, &ops);

    return .{
        // 메뉴는 자기 hit-test 를 `itemAt` 으로 한다(트리를 안 쓴다) — 빈 트리를 낸다.
        .tree = .{ .entries = buffers.entries[0..0], .generation = 0 },
        .draws = .{ .layer = chrome.components.context_menu.layer, .ops = ops.items },
    };
}

/// 앵커. 화면 왼쪽 위에서 조금 떨어뜨려 상자 테두리 네 변이 다 보이게 한다.
/// 스크롤 픽스처가 목록을 밀어 올리는 양. 행 높이보다 **작아야** 첫 행이 반쯤 걸친 채 남는다(위 설명).
const scm_scroll_fixture_offset_px: u32 = 12;
/// 그 픽스처의 전체 콘텐츠 높이. 뷰포트보다 크기만 하면 되고(스크롤바가 서는 조건), 정확한 값은
/// 이 캡처가 증언하는 것과 무관하다.
const scm_scroll_fixture_content_h_px: u32 = 900;

const context_menu_fixture_anchor_x: i32 = 24;
const context_menu_fixture_anchor_y: i32 = 24;

/// 파일 탐색기 행 목록 하나를 **제품과 같은 build → view** 로 낸다.
///
/// 픽스처가 노리는 상태는 골든이 실제로 회귀를 잡을 수 있는 것들이다: 깊이가 다른 행(안내선 개수),
/// 종류가 다른 아이콘(색), 선택된 행과 호버한 행(밴드 두 색), dirty 점, 무시된 행의 흐림, 그리고
/// 접힌 폴더와 펼친 폴더의 chevron 방향. 한 화면에 다 담아야 crop 하나로 여러 계약을 보는 것이
/// 아니라 **crop 을 나눠** 각 계약을 따로 지목할 수 있다(`tests/golden/dock_visual.zig` 의 관례).
fn buildFileTreeFrame(scenario: Scenario, tokens: *const chrome.Tokens, buffers: FrameBuffers) !Frame {
    const K = chrome.file_tree_icon.IconKind;
    const rows = [_]file_tree.types.Row{
        // 루트 줄 — 깊이 0, 안내선이 없어야 한다.
        .{ .kind = .root, .label = "maru3", .depth = 0, .expandable = true, .expanded = true, .icon_kind = @intFromEnum(K.folder), .model_index = 0 },
        // 펼친 폴더와 접힌 폴더 — chevron 방향이 서로 달라야 한다.
        .{ .kind = .directory, .label = "src", .depth = 1, .expandable = true, .expanded = true, .icon_kind = @intFromEnum(K.folder), .model_index = 1 },
        .{ .kind = .file, .label = "main.zig", .depth = 2, .icon_kind = @intFromEnum(K.code), .model_index = 2 },
        // **선택된 행.** 밴드가 가장 진하고 글자가 surface 전경으로 올라온다.
        .{ .kind = .file, .label = "app_session.zig", .depth = 2, .icon_kind = @intFromEnum(K.code), .active = true, .selected = true, .model_index = 3 },
        // dirty 점이 오른쪽 슬롯에 선다(라벨과 겹치면 그 결함은 픽셀로만 보인다).
        .{ .kind = .file, .label = "renderer.zig", .depth = 2, .icon_kind = @intFromEnum(K.code), .dirty = true, .model_index = 4 },
        // 무시된 행 — 한 단 흐린 전경이다(색 위계가 뒤집히면 이 캡처가 잡는다).
        .{ .kind = .directory, .label = "zig-out", .depth = 1, .expandable = true, .ignored = true, .icon_kind = @intFromEnum(K.folder), .model_index = 5 },
        .{ .kind = .directory, .label = "docs", .depth = 1, .expandable = true, .icon_kind = @intFromEnum(K.folder), .model_index = 6 },
        .{ .kind = .file, .label = "README.md", .depth = 1, .icon_kind = @intFromEnum(K.document), .model_index = 7 },
    };
    const props = file_tree.types.Props{
        // **제품 도크 폭을 쓴다**(Lab 캡처 폭 480 이 아니라). 트리는 사이드바 도크 안에 살고 라벨은
        // 그 폭에서 말줄임된다 — 480 으로 그리면 말줄임이 한 번도 안 걸려 그 계약을 골든이 못 본다.
        .viewport_px = .{ .width = 260, .height = scenario.viewport_px.height },
        .scale_milli = 1000,
        .snapshot_generation = 1,
        .rows = &rows,
        .selection_focused = true,
        // **행 높이의 배수가 아닌 값**이다. 배수면 첫 행이 통째로 밀려 나가 "반쯤 걸친 행"이 없고,
        // 그러면 이 시나리오가 clip 을 증언하지 못한다(내 판정자가 같은 함정을 한 번 밟았다 —
        // 스크롤을 정확히 10 행만큼 줘서 단언이 아무것도 안 보던 적이 있다).
        .origin_shift_px = if (scenario.id == .file_tree_scrolled) 11 else 0,
    };
    const sizes = file_tree.build.bufferSizes(rows.len);
    if (sizes.nodes > buffers.file_tree_nodes.len or sizes.entries > buffers.entries.len or
        sizes.actions > buffers.file_tree_actions.len) return error.LabBufferTooSmall;
    const frame = try file_tree.build.build(props, .{
        .nodes = buffers.file_tree_nodes[0..sizes.nodes],
        .entries = buffers.entries[0..sizes.entries],
        .layout_items = buffers.items[0..sizes.entries],
        .flex_scratch = buffers.flex_scratch[0..sizes.entries],
        .child_rects = buffers.child_rects[0..sizes.entries],
        .actions = buffers.file_tree_actions[0..sizes.actions],
    });
    // 호버는 포인터가 있을 때만 나오는 그림이라 상태를 직접 세운다(SCM 도크와 같은 이유).
    // **선택된 행이 아닌 행**을 호버한다 — 두 밴드가 같은 행에 겹치면 색이 구별되는지 볼 수 없다.
    const state: chrome.ui.interaction.InteractionState = switch (scenario.id) {
        .file_tree_row_hover => .{ .hovered = file_tree.build.NodeIds.row(4) },
        else => .{},
    };
    // **host 와 같은 예산으로 그린다** — Lab 버퍼는 넉넉해서 통째로 넘기면 `bufferSizes` 가 낡아도
    // 캡처는 멀쩡하고 제품만 빈 트리가 된다. FT1 에서 실제로 그 조합이 났다(한 행은 통과, 다섯 행은
    // 빈 화면). 예산을 지나게 하면 그 어긋남이 스모크에서 먼저 걸린다.
    const budget = file_tree.view.bufferSizes(&rows);
    if (budget.ops > buffers.ops.len or budget.runs > buffers.text_runs.len or budget.text_bytes > buffers.text_bytes.len)
        return error.LabBufferTooSmall;
    const draws = try file_tree.view.view(props, frame, state, tokens, .{
        .ops = buffers.ops[0..budget.ops],
        .runs = buffers.text_runs[0..budget.runs],
        .text_bytes = buffers.text_bytes[0..budget.text_bytes],
    });
    return .{ .tree = frame.tree, .draws = draws };
}

fn buildScmFrame(scenario: Scenario, tokens: *const chrome.Tokens, buffers: FrameBuffers) !Frame {
    // **막힌 이유는 그 저장소의 버튼 아래에 선다**(2026-08-31). 목록을 짧게 두어 그 관계가 한눈에
    // 보이게 하고, 중립 안내를 **바로 아래** 놓아 색이 갈리는지 같은 캡처에서 견준다.
    const blocker_items = [_]scm_dock.types.Item{
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "feat/lab-fixture", .primary = true, .count = 1 } },
        .{ .commit_box = .{ .repo_index = 0 } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = true } },
        .{ .blocker = "커밋 메시지를 입력하세요" },
        .{ .notice = "변경 사항 없음" },
        // 두 번째 저장소 — **그 아래에는 안 선다**(사유는 한 저장소 것이다).
        .{ .repo = .{ .index = 1, .name = "wt-review", .branch = "review-wt", .primary = false, .collapsed = true, .count = 2 } },
    };
    const default_items = [_]scm_dock.types.Item{
        // 저장소·워크트리 머리 줄(P3d-②). 같은 이름의 두 줄을 사용자가 구별해야 하므로 **종류가
        // 글리프로** 보여야 하고, 접힌 줄도 개수를 갖는다 — 그 셋이 한 캡처에 든다.
        .{ .repo = .{ .index = 0, .name = "maru3", .branch = "feat/lab-fixture", .primary = true, .count = 4 } },
        // **커밋 줄은 그 그룹 안에 산다**(②b) — 저장소마다 하나씩이라 고정 chrome이 아니다.
        .{ .commit_box = .{
            .repo_index = 0,
            .rows = if (scenario.id == .scm_commit_edit) 3 else 1,
            .text = if (scenario.id == .scm_commit_edit) commit_fixture_message else "",
            .edit = if (scenario.id == .scm_commit_edit) .{
                .focused = true,
                .caret = commit_fixture_caret,
                .selection = .{ .anchor = 3, .focus = commit_fixture_caret },
            } else .{},
        } },
        .{ .commit_button = .{ .repo_index = 0, .enabled = true } },
        .{ .section = .{ .section = .staged, .count = 1, .collapsed = false, .action = .unstage } },
        .{ .file = .{ .model_index = 1, .name = "staged.zig", .dir = "src/session/", .status = .added, .letter = 'A', .added = 12, .removed = 0, .has_delta = true, .action = .unstage } },
        .{ .section = .{ .section = .changes, .count = 3, .collapsed = false, .action = .stage } },
        .{ .file = .{ .model_index = 3, .name = "changed.zig", .dir = "src/chrome/components/", .status = .modified, .letter = 'M', .added = 34, .removed = 7, .has_delta = true, .action = .stage } },
        // 충돌 행은 **동작이 없다**(`git add`가 "해결됨"으로 표시하므로). 그 사실이 화면에서 버튼의 부재로 보인다.
        .{ .file = .{ .model_index = 4, .name = "conflict.zig", .dir = "src/", .status = .conflicted, .letter = 'U', .action = .none } },
        .{ .file = .{ .model_index = 5, .name = "untracked.txt", .dir = "", .status = .added, .letter = 'U', .action = .stage } },
        // 접힌 워크트리 — 자기 줄과 개수만 있고 그 아래 행이 없다(host가 안 넣는다).
        .{ .repo = .{ .index = 1, .name = "wt-review", .branch = "review-wt", .primary = false, .collapsed = true, .count = 2 } },
    };
    const items: []const scm_dock.types.Item =
        if (scenario.id == .scm_blocker) &blocker_items else &default_items;
    const props = scm_dock.types.Props{
        // scm_dock은 `UiRect`(원점 포함)를 받는다 — Lab 시나리오는 크기만 들고 원점은 0,0이다.
        .viewport_px = .{ .x = 0, .y = 0, .width = scenario.viewport_px.width, .height = scenario.viewport_px.height },
        .cell_width_px = scenario.cell_w_px,
        // 제품과 같은 입력을 준다(`app_session/scm_dock.zig` 의 `advanceMilliPerPoint`). 하네스가
        // **native 메트릭에서 실제 face 를 재서** 넣는다 — 합성 셀에서 비율을 만들면 제품과 다른 산술이
        // 되고, 작은 셀 조합에서 실제로 2px 이 모자랐다(예약 82px 대 실제 84px).
        .advance_milli_per_point = scenario.advance_milli_per_point,
        .snapshot_generation = 1,
        .items = items,
        .branch = "feat/lab-fixture",
        .has_ab = true,
        .ahead = 2,
        .behind = 1,
        .summary = .{ .added = 46, .removed = 7 },
        // 스크롤 상태(가상화가 내는 그 형태): 창의 첫 항목을 음수 origin 으로 올려 **부분 가림**을 만든다.
        // 전부 밀어내면(offset 이 행 높이보다 크면) 그 행의 clip 면적이 0 이 되어 lowering 이 quad 를
        // 통째로 버리므로, "clip 이 위를 자르는가"를 증언하지 못한다 — 반쯤 걸친 행이 있어야 한다.
        .scroll_offset_px = if (scenario.id == .scm_scrolled or scenario.id == .dock_over_status_bar) scm_scroll_fixture_offset_px else 0,
        .content_first_item_origin_y_px = if (scenario.id == .scm_scrolled or scenario.id == .dock_over_status_bar) -@as(i32, scm_scroll_fixture_offset_px) else 0,
        .content_h_px = if (scenario.id == .scm_scrolled or scenario.id == .dock_over_status_bar) scm_scroll_fixture_content_h_px else 0,
        .list_overflows = scenario.id == .scm_scrolled or scenario.id == .dock_over_status_bar,
        .changed_file_count = 4,
        // 커밋 상자: 스테이지된 파일이 있으므로 버튼이 **켜진** 상태다(§7 — 실제 index 상태로만 정한다).
        // 두 상태(꺼짐/켜짐)를 한 캡처에 담을 수 없어, 켜진 쪽을 고른다 — 꺼짐은 단위 테스트가 본다.
        // 커밋 줄은 위 `items`에 있다(②b). 편집 상태는 **한 시나리오만** 싣는다 — 목록 시나리오까지
        // caret을 켜면 그 골든들이 깜빡임 축까지 떠안는다.
    };
    const frame = try scm_dock.build.build(props, .{
        .nodes = buffers.scm_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.scm_actions,
    });
    // 행 동작은 **호버할 때만** 그려진다. 포인터가 없는 캡처에서 그 자리를 보려면 상태를 직접 세워야 한다
    // (제품도 같은 이유로 `MARU_FORCE_SCM_HOVER`를 둔다).
    // **파일 행**을 호버한다(그룹 헤더가 아니다) — 이 시나리오가 증언하는 것은 "행 동작 `+`가 상태
    // 문자를 비켜 앉는가"이고 그건 파일 행에서만 보인다. ②b에서 커밋 줄 둘이 앞에 들어와 자리가 밀렸다.
    const state: chrome.ui.interaction.InteractionState = switch (scenario.id) {
        .scm_row_hover => .{ .hovered = scm_dock.build.NodeIds.item(6) },
        // 머리 줄은 목록의 **첫 항목**이다(②b 에서 커밋 줄 둘이 그 뒤에 온다). 이 시나리오가 증언하는
        // 것은 "동작 아이콘이 브랜치·개수 배지 위에 겹치지 않는가"이고, 그건 머리 줄에서만 보인다.
        .scm_repo_hover => .{ .hovered = scm_dock.build.NodeIds.item(0) },
        else => .{},
    };
    // **host와 같은 예산으로 그린다.** Lab 버퍼는 모든 시나리오를 덮도록 넉넉해서, 그냥 통째로 넘기면
    // `drawBufferSizes`가 낡아도 이 캡처는 멀쩡하고 제품만 빈 화면이 된다 — 2026-08-16에 실제로 그
    // 조합이었다(골든은 초록, 깨끗한 저장소의 도크는 통째로 사라짐). 예산을 지나게 하면 그 어긋남이
    // 스모크에서 먼저 걸린다.
    const budget = scm_dock.view.drawBufferSizes(props, frame.tree.entries.len);
    if (budget.ops > buffers.ops.len or budget.runs > buffers.text_runs.len or budget.text_bytes > buffers.text_bytes.len)
        return error.LabBufferTooSmall;
    const draws = try scm_dock.view.view(props, frame, state, tokens, .{
        .ops = buffers.ops[0..budget.ops],
        .runs = buffers.text_runs[0..budget.runs],
        .text_bytes = buffers.text_bytes[0..budget.text_bytes],
    });
    return .{ .tree = frame.tree, .draws = draws };
}

/// 히스토리 탭(P4·P4b). **변경 사항 탭과 다른 목록**이라 `buildScmFrame` 의 픽스처를 나눠 쓸 수 없다 —
/// 저장소 머리 줄·커밋 상자가 없고, 커밋 줄과 그 아래 파일 줄만 선다.
///
/// 픽스처는 사용자 캡처의 모양을 따른다(2026-08-27): 제목이 긴 커밋, ref 칩이 붙은 커밋, 한글 작성자,
/// 그리고 **펼친 커밋의 파일 줄들**. 그 줄들이 이 캡처의 관심사다 — 증감이 실제로 서는지, 좁은 도크에서
/// 이름을 밀어내지 않는지는 픽셀로만 보인다.
fn buildScmHistoryFrame(scenario: Scenario, tokens: *const chrome.Tokens, buffers: FrameBuffers) !Frame {
    const items = [_]scm_dock.types.Item{
        .{ .commit = .{
            .index = 0,
            .subject = "feat(pc-seller): 상품 카드 레이아웃을 격자로 바꾼다",
            .author = "윤형배 [Frontend]",
            .when = "15시간 전",
            .short_oid = "63b092b",
            .ref = "feat/pc-seller-grid",
            .ref_is_head = true,
            .ref_more = 1,
        } },
        // **펼친 커밋**. 아래 파일 줄들이 이 커밋의 것이다.
        .{ .commit = .{
            .index = 1,
            .subject = "fix(mobile-seller): 상품탭 카테고리 전환 지연 개선 (#8721)",
            .author = "윤형배 [Frontend]",
            .when = "20시간 전",
            .short_oid = "0556c10",
            .selected = true,
            .expanded = true,
        } },
        .{ .commit_file = .{ .index = 0, .name = "ProductArea.js", .dir = "src/pages/product/", .status = .modified, .letter = 'M', .added = 34, .removed = 12, .has_delta = true } },
        .{ .commit_file = .{ .index = 1, .name = "ProductGridItem.js", .dir = "src/pages/product/", .status = .added, .letter = 'A', .added = 128, .removed = 0, .has_delta = true } },
        .{ .commit_file = .{ .index = 2, .name = "ProductListItem.js", .dir = "src/pages/product/", .status = .deleted, .letter = 'D', .added = 0, .removed = 96, .has_delta = true } },
        // 지금 열어 둔 비교(강조). 목록이 **무엇을 보고 있는지** 말하는 자리다.
        .{ .commit_file = .{ .index = 3, .name = "ProductListRenderer.js", .dir = "src/pages/product/", .status = .modified, .letter = 'M', .added = 7, .removed = 3, .has_delta = true, .selected = true } },
        // 증감이 **없는** 파일(이진). `0/0` 으로 거짓말하지 않고 `bin` 이라고 적는 자리다.
        .{ .commit_file = .{ .index = 4, .name = "placeholder.png", .dir = "assets/", .status = .added, .letter = 'A', .binary = true, .has_delta = true } },
        .{ .commit = .{
            .index = 2,
            .subject = "[FE-1350] test(sales-analysis): vitest 러너 도입",
            .author = "사공 지은 [Frontend]",
            .when = "21시간 전",
            .short_oid = "da0d391",
        } },
        .{ .commit = .{
            .index = 3,
            .subject = "결제 수단별 적립률 저장에 확인 모달을 노출한다 (#8720)",
            .author = "이흥수",
            .when = "21시간 전",
            .short_oid = "54629ed",
        } },
    };
    const props = scm_dock.types.Props{
        .viewport_px = .{ .x = 0, .y = 0, .width = scenario.viewport_px.width, .height = scenario.viewport_px.height },
        .cell_width_px = scenario.cell_w_px,
        .advance_milli_per_point = scenario.advance_milli_per_point,
        .snapshot_generation = 1,
        .items = &items,
        // 히스토리 탭은 브랜치 줄·요약 줄이 **없다**(P4) — 그 숫자는 작업트리의 것이라 커밋 목록과
        // 관계가 없다. 여기서 켜면 제품에 없는 화면이 골든이 된다.
        .branch = "",
        .active_tab = .history,
        .show_summary = false,
        .changed_file_count = 4,
    };
    const frame = try scm_dock.build.build(props, .{
        .nodes = buffers.scm_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.scm_actions,
    });
    const budget = scm_dock.view.drawBufferSizes(props, frame.tree.entries.len);
    if (budget.ops > buffers.ops.len or budget.runs > buffers.text_runs.len or budget.text_bytes > buffers.text_bytes.len)
        return error.LabBufferTooSmall;
    const draws = try scm_dock.view.view(props, frame, .{}, tokens, .{
        .ops = buffers.ops[0..budget.ops],
        .runs = buffers.text_runs[0..budget.runs],
        .text_bytes = buffers.text_bytes[0..budget.text_bytes],
    });
    return .{ .tree = frame.tree, .draws = draws };
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
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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
