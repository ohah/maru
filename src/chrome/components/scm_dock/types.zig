//! 소스 컨트롤 도크의 platform-neutral 입력 DTO다(docs/editor-surface-dock.md §3.5).
//!
//! 이 파일은 `AppSession`도 git 결과 버퍼도 보관하지 않는다. platform이 `session/scm_view.zig`의 행 모델을
//! **화면용 문자열로 이미 잘라** 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다
//! (Session Dock과 같은 규율 — component가 domain을 다시 해석하지 않는다).

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const ui_icon = @import("../../ui/icon.zig");
const typography = @import("../../ui/typography.zig");
const i18n = @import("../../../i18n.zig"); // 표시 문자열 단일 출처

/// 목록 그룹. `scm_view.Section`과 **같은 값 집합**이지만 component는 그쪽을 import하지 않는다 —
/// platform이 값을 옮기고, 값이 갈리면 그 변환 함수가 exhaustive switch에서 컴파일로 걸린다.
pub const Section = enum { staged, changes };

/// 도크 탭(§3.5.1). **축이 다르면 화면을 나눈다** — 세 탭은 서로 다른 질문에 답하고 항목 단위도 다르다
/// (변경 사항=파일, 히스토리=커밋, 에이전트=턴). 그래서 한 목록으로 합칠 수 없다.
pub const Tab = enum { changes, history, agent };

/// 행에 붙는 주 동작. 호버할 때만 보이는 컨트롤이다(§3.5.2).
pub const RowAction = enum { stage, unstage, none };

/// 상태 문자의 **의미**. 색을 고르는 것은 view이고, 여기서는 어떤 종류인지만 말한다 —
/// 색 결정이 platform으로 새면 테마마다 두 곳을 고쳐야 한다.
pub const StatusKind = enum {
    modified,
    /// 새로 생긴 것(`A`)과 추적되지 않은 것(`U`)은 같은 계열로 본다(VS Code 관례).
    added,
    deleted,
    /// 병합 충돌. 색은 위험 계열이지만 **동작이 없다**는 점이 더 중요하다(§3.5.2).
    conflicted,
};

/// 그 파일이 **왜** 이 턴의 목록에 있나(계약 §4.2 배지). 상태 문자(`A`·`M`·`D`)와 **다른 축**이다 —
/// 그쪽은 「무엇이 일어났나」이고 이쪽은 「누가 했나」다. 색·글리프를 고르는 것은 view 다.
///
/// ⚠️ **§4.2 의 셋 중 둘만 여기 온다.** 이 목록은 tree 비교에서 나오므로 **모든 행이 「tree 가 바뀌었다고
/// 말하는 파일」**이다 — 「캡처에만 있고 tree 에는 없음」(`↩ 순변경 없음`)은 이 목록에 뜰 자리가 아예
/// 없다. 그 배지는 목록의 권위가 캡처로 옮겨간 뒤(AT3b 이후) 설 수 있다.
pub const TurnFileOrigin = enum {
    /// 근거가 없다 — 그 턴에 캡처가 없다(훅 없는 세션·관측 모드·상한 초과). **`turn_change` 와 가른다**:
    /// 「셸이 고쳤다」와 「우리가 못 봤다」는 다른 사실이라 같은 표시를 주면 안 된다.
    unknown,
    /// 에이전트가 **편집 도구로** 고쳤다 — 캡처에 있고 before ≠ after(`Entry.editedByAgent`).
    ai_edit,
    /// 턴 구간에 바뀌었으나 편집 도구 소행이 **아니다** — 셸 편집이거나 사용자·다른 세션.
    turn_change,
};

pub const SectionItem = struct {
    /// 어느 저장소의 그룹인가(목록 기준 — 머리 줄과 같은 축). 목록에 저장소가 여럿이면 **같은 이름의
    /// 그룹이 여럿**이라, 이것이 없으면 일괄 스테이지가 남의 저장소로 간다(②d).
    repo_index: u32 = 0,
    section: Section,
    /// 그 그룹의 **전체** 파일 수(접혀 있어도 전체를 말한다).
    count: u32,
    collapsed: bool,
    /// 헤더 호버에 뜰 일괄 동작. `.none`이면 그 자리에 아무것도 그리지 않는다.
    action: RowAction,
};

pub const FileItem = struct {
    /// 어느 저장소의 행인가(목록 기준). 모델 인덱스는 **저장소마다 따로** 세므로, 이것 없이 인덱스만
    /// 실으면 아래 그룹의 파일을 눌렀는데 위 저장소의 같은 번호 파일이 열린다(②d).
    repo_index: u32 = 0,
    /// 이 행의 **모델 인덱스**. 화면 창(virtualized window) 안의 자리가 아니다 — host가 같은 스냅샷의
    /// 모델에서 이 행을 다시 찾는 열쇠이고, 창은 스크롤에 따라 움직인다. **창 자리를 쓰면 스크롤한 뒤
    /// 누른 행과 열리는 행이 어긋난다**(P1b가 그렇게 나갔다).
    model_index: u32 = 0,
    /// 파일 이름(굵게). 폭이 모자라도 **끝까지 남는다**.
    name: []const u8,
    /// 흐린 상대 경로. 폭이 좁아지면 **가장 먼저** 줄어든다.
    dir: []const u8,
    status: StatusKind,
    /// 화면에 그대로 그릴 한 글자(`M`·`A`·`D`·`U`·`R`…). 색은 `status`가 정한다.
    letter: u8,
    added: u32 = 0,
    removed: u32 = 0,
    /// 증감을 그릴 수 있나. 추적되지 않은 파일·충돌·하위 모듈은 숫자가 **존재하지 않는다**.
    has_delta: bool = false,
    /// numstat이 `-`를 준 파일 — 숫자 대신 그 사실을 적는다.
    binary: bool = false,
    action: RowAction,
    /// 지금 열려 있는 비교인가(강조).
    selected: bool = false,
};

pub const MoreItem = struct { repo_index: u32 = 0, section: Section, hidden: u32 };

/// 저장소 하나의 **커밋 입력 상자**. 목록 안에 산다(§3.5.1c) — 그룹마다 자기 상자를 갖는다.
///
/// **고정 chrome에서 목록으로 내려온 이유**: 상자가 하나면 "지금 어느 저장소로 커밋하는가"가 화면에
/// 없다. 사용자가 두 저장소를 열어 둔 채 아래 그룹의 파일을 보고 있어도, 위에 떠 있는 상자는 다른
/// 저장소의 것일 수 있다 — 그 어긋남은 **잘못된 저장소에 커밋**으로 끝난다.
pub const CommitBoxItem = struct {
    /// 어느 저장소의 상자인가(목록 기준 — 머리 줄과 같은 축).
    repo_index: u32,
    /// 보여 줄 **시각 행** 수(host가 랩해서 정한다).
    rows: u32 = 1,
    /// 상자에 그릴 글자(조합 중이면 그것이 끼워진 표시 텍스트).
    text: []const u8 = "",
    /// 편집 상태. **포커스는 상자마다 다르다** — 여럿이 동시에 caret을 갖지 않는다.
    edit: CommitEdit = .{},
};

/// 저장소 하나의 **커밋 버튼**. 상자 바로 아래 줄이다.
pub const CommitButtonItem = struct {
    repo_index: u32,
    /// 실제 index 상태로만 켠다(쓰기 문서 §7 — 낙관하지 않는다).
    enabled: bool = false,
    run: CommitRun = .idle,
};

/// 저장소·워크트리 하나의 **머리 줄**(§3.5.1c). 목록의 단위가 저장소가 아니라 워크트리이므로 이 행
/// 하나가 곧 한 워크트리다.
///
/// 화면에 세 가지가 함께 선다: 접힘 표시 · 이름 · 브랜치 칩. 동작 아이콘 줄(새로고침·스테이지·커밋…)은
/// 다음 조각이다 — **자리를 먼저 잡되 없는 버튼을 그리지 않는다**(P1 계약은 "누를 수 없는 컨트롤은
/// 비활성으로 표시한다"이지 "아직 없는 컨트롤을 그린다"가 아니다).
pub const RepoItem = struct {
    /// 목록 안에서 이 저장소의 자리. host가 같은 스냅샷에서 이 저장소를 다시 찾는 열쇠다 —
    /// **경로 문자열로 되찾지 않는다**(창이 스크롤되면 화면 자리와 어긋난다는 이유는 파일 행과 같다).
    index: u32,
    /// 화면에 그릴 이름. 보통 마지막 경로 조각이고, 같은 이름이 둘이면 host가 구별되는 데까지 늘린다.
    name: []const u8,
    /// 체크아웃된 브랜치. 분리 HEAD면 짧은 해시가 대신 온다(host가 정한다 — 컴포넌트는 문자열만 그린다).
    branch: []const u8 = "",
    /// 접혀 있나. 접히면 그 저장소의 커밋 상자·요약·파일 행이 목록에 아예 없다(host가 안 넣는다).
    collapsed: bool = false,
    /// 주 워크트리(저장소 루트 자신)인가. 아이콘이 갈린다 — 워크트리는 "딸린 것"이라는 사실이 보여야
    /// 사용자가 같은 이름의 두 줄을 구별한다.
    primary: bool = true,
    /// 그 저장소의 변경 파일 수. 접혀 있어도 보여야 "여기 뭔가 있다"를 안다(VS Code도 그렇다).
    count: u32 = 0,
    /// 아직 그 저장소를 **읽지 않았다**. 읽기는 하나씩 순차로 도므로(§3.5.1c) 목록에 있는데 아직
    /// 차례가 안 온 저장소가 생긴다.
    ///
    /// **0건과 구별해야 한다** — 배지가 없는 것을 사용자는 "변경 없음"으로 읽는다. 이 값이 참이면
    /// 배지 대신 `읽는 중…`을 적어 "아직 모른다"를 말한다.
    pending: bool = false,
    /// 그 저장소를 **읽지 못했다**(경로가 사라졌거나 git이 실패했다). `pending`과 다른 사실이라 문구도
    /// 다르다 — "읽는 중…"은 곧 온다는 약속이고, 이쪽은 오지 않는다는 말이다. 0건으로 그리면 **없는
    /// 사실을 단정한다**.
    failed: bool = false,
    /// **전체 스테이지**를 켤 수 있나(그 저장소를 읽었고 스테이지할 것이 있다). 새로고침은 읽기라 늘
    /// 켜져 있으므로 따로 두지 않는다.
    ///
    /// 꺼져 있어도 **감추지 않는다**(P1 계약) — 비활성으로 표시하고, 눌리면 host가 이유를 적는다.
    can_stage_all: bool = false,
};

/// 히스토리 탭의 커밋 한 줄(P4). 문자열은 전부 host가 든 원문을 빌린다(할당 없음).
pub const CommitItem = struct {
    /// 목록 안 자리. 클릭 intent가 이것을 싣고 host가 같은 스냅샷에서 다시 찾는다(파일 행과 같은 규율).
    index: u32 = 0,
    /// 제목 한 줄. 폭이 모자라면 **여기가 마지막으로** 줄어든다(무엇을 한 커밋인지가 가장 중요하다).
    subject: []const u8,
    author: []const u8 = "",
    /// 이미 사람이 읽을 꼴로 만든 상대 시각(`3시간 전`). **host가 만든다** — component에는 시간이 없다.
    when: []const u8 = "",
    /// 짧은 해시(7자).
    short_oid: []const u8 = "",
    /// 첫 ref 칩 하나만 그린다. 여럿이면 좁은 도크에서 제목을 다 밀어낸다.
    ref: []const u8 = "",
    /// 그리지 **않은** 나머지 ref 수(§3.5.3 "칩이 많으면 `+N`으로 접는다"). 0이면 접을 것이 없다.
    ///
    /// **개수만 싣는다.** 이름들을 실으면 화면에 못 그릴 문자열을 프레임마다 들고 다니게 되고, 접힌
    /// 이름을 보여 주는 길(툴팁·펼치기)이 아직 없다 — 그 길이 생기는 날 그때 싣는다.
    ref_more: u32 = 0,
    /// 그 칩이 **지금 체크아웃된 브랜치**인가(색이 갈린다).
    ref_is_head: bool = false,
    /// 지금 고른 커밋인가(강조).
    selected: bool = false,
    /// 펼쳐져 있나(P4b). 펼치면 그 커밋이 바꾼 파일 줄이 **바로 아래**에 온다.
    expanded: bool = false,
};

/// 에이전트 탭의 **턴 한 줄**(P5 — §3.5.4). 1급 항목은 파일이 아니라 턴이다.
pub const TurnItem = struct {
    /// 목록 안 자리(0 = 진행 중). 클릭 intent가 이것을 싣고 host가 같은 스냅샷에서 다시 찾는다.
    index: u32 = 0,
    /// 사람이 읽을 이름(`마지막 턴 이후`·`마지막 턴`·`3턴 전`). **host가 만든다** — 세는 규칙이 화면 문구다.
    title: []const u8,
    /// 그 턴을 돌린 에이전트(`claude`·`codex`). 모르면 빈 문자열이고 그 자리는 비운다.
    agent: []const u8 = "",
    /// 그 턴이 바꾼 파일 수를 사람이 읽을 꼴로(`3개 파일`). **모르거나 0이면 빈 문자열**이다 —
    /// 읽지 못한 턴도 0으로 오므로 «0개»를 그리면 거짓이 된다. 제목 줄 **오른쪽**에 선다.
    summary: []const u8 = "",
    /// 이미 사람이 읽을 꼴로 만든 상대 시각. **진행 중은 빈 문자열**이다(끝나지 않았다).
    when: []const u8 = "",
    /// 그 턴의 **마지막 응답 첫머리**(AT2). 없으면 빈 문자열이고 그 자리는 비운다.
    ///
    /// `title`(`마지막 턴`·`3턴 전`)이 **어느 턴인지**를 말한다면 이것은 **무엇을 했는지**를 말한다 —
    /// 목록을 훑는 사람이 실제로 찾는 것이 이쪽이다. 자리가 모자라면 **이것이 먼저 잘린다**(위치 이름이
    /// 없으면 그 줄이 어느 턴인지조차 알 수 없다).
    reply: []const u8 = "",
    selected: bool = false,
    expanded: bool = false,
    /// 아직 턴으로 굳지 않은 줄인가(맨 위 한 줄). 오른쪽이 **작업트리**라 계속 변한다.
    /// **에이전트 실행 상태가 아니다** — 링에 스냅샷이 있으면 늘 선다.
    live: bool = false,
};

/// 펼친 커밋 아래의 파일 한 줄(P4b). 변경 사항 탭의 `FileItem`과 **다른 항목**이다 — 그쪽은 작업트리
/// 상태이고 이쪽은 그 커밋이 바꾼 것이라, 클릭이 여는 비교 기준도 동작(스테이지)도 다르다.
pub const CommitFileItem = struct {
    /// 그 커밋 안에서 몇 번째 파일인가. 클릭 intent가 이것을 싣고 host가 같은 목록에서 다시 찾는다.
    index: u32 = 0,
    name: []const u8,
    dir: []const u8 = "",
    status: StatusKind,
    /// 화면에 그대로 그릴 한 글자(`M`·`A`·`D`·`R`).
    letter: u8,
    /// 그 커밋/턴이 이 파일에서 **더한·지운 줄 수**. 변경 사항 탭의 `FileItem` 과 **같은 세 필드**다 —
    /// 한 화면의 두 목록이 같은 사실을 다른 모양으로 말하면 그 자체가 두 화면처럼 읽힌다.
    ///
    /// **`has_delta` 가 없으면 자리를 비운다**: 0/0 으로 그리면 "안 바뀐 파일"이라는 거짓 진술이 되고,
    /// 읽지 못한 목록(짝이 안 맞는 numstat·잘린 출력)도 그 자리로 온다.
    added: u32 = 0,
    removed: u32 = 0,
    /// 이진 파일인가. git 이 `-\t-` 로 주는 그 사실이고, 숫자 대신 `bin` 을 그린다.
    binary: bool = false,
    has_delta: bool = false,
    /// 지금 열려 있는 비교인가(강조). 목록이 **무엇을 보고 있는지** 말해야 파일 여럿을 오갈 때 길을
    /// 잃지 않는다(변경 사항 탭의 파일 행과 같은 규율).
    selected: bool = false,
    /// **턴의 파일인가**(P5). 같은 줄 모양을 두 탭이 쓰지만 여는 비교가 다르다 — 커밋은 `커밋^ ↔ 커밋`,
    /// 턴은 `스냅샷 ↔ 스냅샷`이다. 이 값이 없으면 intent가 한쪽으로만 가서 다른 탭의 클릭이 죽는다.
    from_turn: bool = false,
    /// 누가 이 파일을 바꿨나(§4.2). **커밋 탭에서는 늘 `.unknown`** 이다 — 지난 커밋에는 「이번 턴의
    /// 에이전트」라는 것이 없다.
    origin: TurnFileOrigin = .unknown,
};

pub const Item = union(enum) {
    /// 저장소·워크트리 머리 줄. **목록의 첫 층**이고, 그 아래에 그 저장소의 줄들이 온다.
    repo: RepoItem,
    /// 그 저장소의 커밋 입력 상자(머리 줄 바로 아래).
    commit_box: CommitBoxItem,
    /// 그 저장소의 커밋 버튼(상자 바로 아래).
    commit_button: CommitButtonItem,
    section: SectionItem,
    file: FileItem,
    more: MoreItem,
    /// 목록이 불완전하다는 진술(누를 수 없다).
    /// 히스토리 탭의 커밋 줄(P4).
    commit: CommitItem,
    /// 에이전트 탭의 턴 줄(P5).
    turn: TurnItem,
    /// 펼친 커밋 아래의 파일 줄(P4b).
    commit_file: CommitFileItem,
    /// 히스토리 목록 끝의 **더 보기**(P4). 상한만큼 읽었을 때만 선다 — 끝까지 읽었으면 없다(있으면
    /// 눌러도 아무 일이 없어 "고장"으로 읽힌다).
    load_more,
    notice: []const u8,
    /// **동작이 멈춘 이유**(커밋 메시지가 비었다·스테이지된 것이 없다 …). `notice` 와 자리는 같지만
    /// **색이 다르다**(`danger_fg`) — 「변경 사항 없음」 같은 중립 진술과 한 톤이면 *무엇이 나를 막고
    /// 있는지*가 안 읽힌다(사용자 제보 2026-08-31).
    ///
    /// **왜 `notice` 에 bool 을 달지 않았나**: 그러면 모든 생성 자리가 그 값을 정해야 하고, 안 정하면
    /// 조용히 중립이 된다. 종류를 나누면 부르는 쪽이 고를 수밖에 없다.
    blocker: []const u8,
};

/// 목록 위의 요약 줄. 아직 커밋·필터가 없으므로 **숫자만** 싣는다.
pub const Summary = struct {
    added: u32 = 0,
    removed: u32 = 0,
};

pub const Props = struct {
    /// 도크 content rect(도크-로컬 좌표, 원점 0,0).
    viewport_px: layout.UiRect,
    /// 스크롤바 fade 의 최종 alpha(0xFF=선명). **`view` 만 읽는다 — `build` 는 쓰지 않는다**(계약 §7 —
    /// tree 에 실으면 발행 동등 비교가 매 프레임 실패한다). 산술은 host 가 소유한다.
    scrollbar_alpha: u8 = 0xFF,
    /// Dock UI zoom. Session Dock과 같은 축이라 두 뷰의 행 높이가 함께 움직인다.
    scale_milli: u32 = 1000,
    /// 등폭 셀 폭. **`build`와 `view`가 같은 값을 봐야 한다** — 개수 배지의 자리는 이 값에서 나오고,
    /// 그 배지를 피해 앉아야 하는 일괄 동작 버튼의 자리는 `build`가 정한다. 둘이 갈리면 버튼이 배지 위로
    /// 올라오고, 배지는 paint 전용이라 **숫자를 눌렀는데 그룹 전체가 스테이지된다**(실측으로 그랬다).
    cell_width_px: u32 = 8,
    /// **face 의 포인트당 advance**(device px × 1000 / 논리 pt). platform 이 채운다.
    ///
    /// 왜 필요한가: `cell_width_px` 는 **터미널 폰트 크기**의 글자 폭인데, chrome 텍스트는 role 이 정한
    /// **고정 point size**(`list_row` 14pt)로 그려진다. 둘은 의도적으로 독립이라(typography 헤더 계약)
    /// 사용자가 `font.size` 를 12 로 두면 셀은 7px 인데 14pt 글자는 8.4px 로 나간다 — 열마다 1.4px 씩
    /// 모자란다. 그 값으로 다음 런의 자리를 잡으면 앞 글자를 파고든다(실측: `font.size` 12 상당에서
    /// `staged.zigsrc/session/` 처럼 붙었다). 셀 반올림만 덮는 `cell + 1` 상한으로는 못 막는다.
    ///
    /// 등폭 face 에서 advance 는 point size 에 비례하므로 이 비율 하나면 어떤 role 이든 환산된다:
    /// `advance(role) = ceil(advance_milli_per_point * pointSize(role) / 1000)`.
    ///
    /// 0 이면 "모른다"는 뜻이고, 그때는 옛 셀 기반 추정으로 물러난다(단위 테스트·구형 호출부).
    advance_milli_per_point: u32 = 0,
    /// 이 tree를 만든 스냅샷 세대. action 표가 이 값으로 stale 클릭을 거부한다.
    snapshot_generation: u64 = 1,
    /// **가상화된 창**이다 — 화면에 보이는 만큼만 platform이 잘라 준다.
    items: []const Item = &.{},
    /// 스크롤 상태(전체 높이·현재 offset·첫 항목의 local y).
    scroll_offset_px: u32 = 0,
    content_h_px: u32 = 0,
    /// 목록이 창을 **넘치나**(스크롤바가 실제로 서나). 넘치지 않으면 오른쪽에 그 자리를 안 비운다 —
    /// 늘 비워 두면 스크롤바가 없는 화면에도 이유를 말하지 않는 12px 띠가 남는다(사용자 지적 2026-08-20,
    /// 머리 줄 동작 아이콘의 빈 띠와 같은 종류의 문제다).
    ///
    /// **판정은 host가 준다**: 창 높이를 아는 쪽이 그쪽이고(스크롤 투영을 이미 거기서 만든다),
    /// component가 다시 재면 같은 값의 출처가 둘이 된다.
    list_overflows: bool = false,
    content_first_item_origin_y_px: i32 = 0,
    /// 브랜치 줄. 없으면(저장소를 못 잡음) 빈 문자열이고 그 줄을 그리지 않는다.
    branch: []const u8 = "",
    /// 이 목록이 **원격 호스트의 것**이면 `user@host`, 로컬이면 빈 문자열(RS3b —
    /// docs/plans/remote-scm.md §2.3).
    ///
    /// **로컬과 원격을 눈으로 못 가르면 사고가 이름만 바꿔 돌아온다.** 경로만 보면 원격 `/srv/app` 과
    /// 로컬 `/srv/app` 이 같은 값이라, 화면에 호스트가 없으면 사용자는 지금 보는 목록이 어느 기계의
    /// 것인지 알 방법이 없다 — 그 상태에서 누른 스테이지가 어디에 걸리는지도 모른다.
    ///
    /// **로컬에서는 빈 문자열이라 화면이 한 픽셀도 안 바뀐다**(그리는 쪽이 길이 0을 건너뛴다).
    remote_host: []const u8 = "",
    ahead: u32 = 0,
    behind: u32 = 0,
    has_ab: bool = false,
    /// 이 브랜치에 **아직 push 안 한 커밋**이 있나(§3.5 — `@{u}`는 그걸 보여 주는 데만 쓴다).
    ///
    /// **개수가 아니라 사실 하나다**(2026-08-19 사용자 결정). 위 `ahead`/`behind`는 **기본 브랜치** 기준이라
    /// 기준이 다른 숫자 둘을 한 줄에 나란히 놓으면 어느 쪽이 무엇인지 읽을 수 없다 — 점 하나면 그 혼동이
    /// 아예 안 생긴다.
    unpushed: bool = false,
    /// 브랜치 줄의 **원격 갱신 버튼**(P6). 자리는 **늘 있다** — 원격이 없어도 감추지 않고 비활성으로
    /// 그린다(§3.5: 누를 수 없는 상황은 비활성으로 보여 주고 왜 안 되는지 말한다).
    fetch: FetchState = .{},
    /// 그 옆 `∨`가 **눌리는가**(P6b → §3.5). fetch와 **따로 판정한다**: 원격이 없는 저장소에서도
    /// 메뉴에는 고를 것이 있다(비교 기준 고르기). 하나로 묶어 두면 `origin/HEAD`가 없는 저장소 —
    /// 즉 이 기능이 가장 필요한 곳 — 에서 메뉴가 안 열린다.
    remote_menu_enabled: bool = false,
    summary: Summary = .{},
    /// 지금 열려 있는 탭. 모르는 값은 platform이 `.changes`로 clamp한다(§3.5.1) — component는 받은 값을
    /// 그대로 그린다.
    active_tab: Tab = .changes,
    /// 요약 줄(`+N -N`)을 그리나. **히스토리 탭에서는 끈다**(P4) — 그 숫자는 작업트리의 것이고 커밋
    /// 목록과 아무 관계가 없다. 0으로 두면 "바뀐 것이 없다"는 **틀린 진술**이 된다.
    show_summary: bool = true,
    /// `변경 사항` 탭 이름 옆에 붙는 **전체** 파일 수. **`items`로 셀 수 없다** — 그쪽은 가상화된 창이라
    /// 보이는 만큼만 오고, 스크롤 위치에 따라 숫자가 흔들린다.
    ///
    /// **활성 탭과 무관하게 채운다.** 작업트리 사실이라 히스토리·에이전트를 보는 동안에도 참이고, 그때
    /// 0으로 두면 탭 줄이 `변경 사항 (0)`이라고 **거짓말**한다(사용자는 그 탭을 눌러 보고서야 안다).
    changed_file_count: u32 = 0,
    /// 커밋 메시지 상자에 보일 글자. 비면 안내 문구를 대신 그린다.
    commit_message: []const u8 = "",
    /// 상자가 보여 줄 **시각 행** 수(랩 결과). host가 `text_area.visibleRows`로 정해 준다 — 컴포넌트는
    /// 랩을 다시 계산하지 않는다(같은 계산이 두 곳이면 상자 높이와 그려지는 줄 수가 갈린다).
    commit_rows: u32 = 1,
    /// 커밋 버튼을 켤 수 있나. **실제 index 상태로만 정한다**(쓰기 문서 §7 — 낙관하지 않는다).
    commit_enabled: bool = false,
    /// 커밋이 도는 중인가. **버튼이 그 사실을 말한다** — 눌렀는데 아무 표시가 없으면 사용자는 다시
    /// 누르고, 두 번째 누름은 조용히 거부된다(쓰기는 하나씩이다).
    commit_run: CommitRun = .idle,
    /// 커밋 상자의 **편집 상태 스냅샷**. component는 편집하지 않는다 — host가 `TextField`로 편집하고
    /// 그 결과만 여기 싣는다(props는 immutable이고, 편집 상태가 둘이면 caret이 갈린다).
    commit_edit: CommitEdit = .{},
};

/// 원격 갱신 버튼의 상태(P6 — §3.6 §4). **`push`/`pull`은 여기 없다**: 그 둘은 우리가 실행하지 않고
/// 활성 터미널에 명령을 넣어 주므로 이 버튼의 상태가 아니다.
pub const FetchState = struct {
    /// 누를 수 있나. **원격이 있는가**가 유일한 조건이다(도는 중인지는 `running`이 따로 말한다) —
    /// 원격이 없는 저장소에서 `fetch`는 무엇을 해도 실패한다.
    enabled: bool = false,
    /// 지금 도는 중인가. **버튼이 그 사실을 말한다**(커밋 버튼과 같은 규율) — 눌렀는데 표시가 없으면
    /// 사용자는 다시 누르고, 두 번째 누름은 조용히 거부된다.
    running: bool = false,
};

/// 그 버튼에 적을 말. **`build`와 `view`가 같은 함수를 본다** — 폭은 build가 정하고 글자는 view가
/// 그리므로, 문자열을 두 곳에서 고르면 "칩은 좁은데 글자는 긴" 프레임이 나온다.
/// 커밋 실행 상태. `slow`는 **문구일 뿐**이다 — 상한을 넘겨도 프로세스를 죽이지 않는다(쓰기 문서 §3:
/// hook은 테스트 전체를 돌 수도 있고, 중간에 죽이면 index·`.git`이 어중간해진다).
pub const CommitRun = enum { idle, running, slow };

/// 커밋 상자의 편집 상태(§12 — 세로 축만 갖는 얇은 층). 가로 축(caret 열·선택 span)은 여전히
/// `text_field.fieldLayout`이 소유하고, 여기 있는 것은 그 함수에 넘길 **오프셋**뿐이다.
pub const CommitEdit = struct {
    /// 키를 받고 있나. 꺼져 있으면 caret도 선택 밴드도 그리지 않는다 — 안 깜빡이는 caret은
    /// "여기 쓰면 된다"가 아니라 "여기 뭔가 잘못됐다"로 읽힌다.
    focused: bool = false,
    /// 삽입점(바이트 오프셋). 개행이 섞여도 그대로 성립한다(§12.1 — `TextField`를 고치지 않는 이유).
    caret: usize = 0,
    /// 선택 구간(바이트 오프셋, 정렬되지 않을 수 있어 `lo`/`hi`로 읽는다).
    selection: ?Selection = null,
    /// IME 조합 중인 글자. caret 자리에 **끼워서** 그린다.
    preedit: []const u8 = "",
    /// 세로 스크롤 — 상자가 보여 줄 **첫 시각 행**이다(제약 ⑥: 논리 줄이 아니다).
    first_row: u32 = 0,
    /// 지금 위상에서 caret을 그릴까(깜빡임). **host가 위상을 소유한다** — 이 층에는 시간이 없다.
    /// 기본이 `true`라 위상을 안 주는 소비자(테스트·Lab)는 늘 보이는 caret을 얻는다.
    caret_visible: bool = true,
};

/// 선택 구간. `text_field.TextField.Selection`과 같은 모양이지만 **이 DTO가 자기 것을 갖는다** —
/// props는 platform이 채우는 값 묶음이고, 여기서 편집기 타입을 재수출하면 component 소비자가
/// 편집 API 전체를 딸려 보게 된다.
pub const Selection = struct {
    anchor: usize,
    focus: usize,

    pub fn lo(self: Selection) usize {
        return @min(self.anchor, self.focus);
    }
    pub fn hi(self: Selection) usize {
        return @max(self.anchor, self.focus);
    }
    pub fn empty(self: Selection) bool {
        return self.anchor == self.focus;
    }
};

/// 도크 치수. Session Dock과 같은 방식으로 zoom을 곱해 만든다 — 두 뷰가 같은 축으로 커지고 줄어야
/// 같은 컬럼에서 뷰를 갈아 끼울 때 행 높이가 튀지 않는다.
pub const DockMetrics = struct {
    /// 탭 줄(`변경 사항 (N) │ 히스토리 │ 에이전트`).
    tab_h: u32,
    /// 요약 줄(`+N -N`).
    summary_h: u32,
    /// 그룹 헤더 높이.
    section_h: u32,
    /// 파일 행 높이.
    row_h: u32,
    /// 브랜치 줄 높이.
    branch_h: u32,
    /// 저장소·워크트리 머리 줄 높이.
    repo_h: u32,
    /// 커밋 메시지 상자의 **한 시각 행** 높이. 상자 전체 높이는 이것 × 보이는 행 수다 —
    /// 내용을 따라 자라고 상한에서 멈춘다(§12.2).
    commit_row_h: u32,
    /// 커밋 버튼 줄 높이.
    commit_button_h: u32,
    /// 커밋 상자의 **위아래 여백**. 글자가 테두리와 버튼 줄에 붙지 않게 한다 — 입력란은 글자가 상자
    /// 안에서 숨 쉬어야 눌러서 쓰는 자리로 읽힌다(사용자 지적 2026-08-16).
    commit_pad_y: u32,
    /// 히스토리 커밋 줄 높이(두 줄 + 위아래 여백 — §3.5.3).
    commit_row_two_line_h: u32,
    /// 목록 좌우 여백.
    inset_x: u32,
    /// 행 안에서 아이콘·글자·동작 사이의 간격.
    gap: u32,
    /// 상태 문자 slot 폭(오른쪽 끝 고정).
    status_extent: u32,
    /// 호버 동작 버튼 하나의 폭·높이.
    action_extent: u32,
    /// 글자가 든 칩의 좌우 여백(원격 갱신). 아이콘 버튼과 달리 폭이 글자에서 나오므로 여백만 상수다.
    chip_pad_x: u32,
    /// 커밋 줄에서 **제목이 지키는 최소 칸 수**. `+N`을 그릴지 여기서 갈린다 — 부가 정보가 제목을
    /// 밀어내면 "무엇을 한 커밋인가"가 사라진다(§3.5.3: 제목이 마지막까지 남는다).
    commit_subject_min_cols: u32,
    /// 그룹 헤더의 접힘 표시가 차지하는 가로 자리.
    disclosure_extent: u32,
    /// 고른 줄의 **좌측 강조 막대** 폭. 밴드 하나만으로는 히스토리처럼 두 줄짜리 행이 이어지는 목록에서
    /// 「고른 줄」이 「조금 밝은 줄」로만 읽힌다(사용자 지적 2026-08-27). 사이드바 활성 카드가 같은
    /// 이유로 막대를 갖는다 — 색 하나를 더 쓰지 않고 **자리**로 말하는 신호다.
    accent_bar_w: u32,
    /// 펼친 항목 아래 파일 줄들을 잇는 **세로 안내선** 폭. 파일 탐색기의 들여쓰기 안내선과 같은 값·같은
    /// 뜻이다 — 그 줄들이 바로 위 커밋/턴에 속한다는 사실을 들여쓰기만으로는 말하지 못한다.
    rail_w: u32,
    /// **아이콘 한 변(logical px)**. 셀 크기가 아니라 디자인 토큰(`ui/icon.Size`)에서 온다 — 셀로 그리면
    /// 행 높이와 무관하게 구워져 화살표가 글자보다 크고 세로도 어긋난다(사용자 지적 2026-08-14).
    icon_extent: u32,
    scrollbar_width: u32,
    scrollbar_inset_x: u32,
    scrollbar_min_thumb: u32,

    pub fn resolve(scale_milli: u32) DockMetrics {
        const s = struct {
            fn px(base: u32, milli: u32) u32 {
                return @max(1, base * @max(milli, 1) / 1000);
            }
        };
        return .{
            // 28px면 13pt 글자(줄 높이 17) 위아래로 5px씩밖에 안 남아 탭 이름이 줄에 낀 것처럼 보인다
            // (사용자 지적 2026-08-16). 34px는 위아래 8px 남겨 아래 커밋 줄의 여백(`commit_pad_y`)과
            // 같은 급이 된다 — 두 줄이 서로 다른 리듬으로 숨 쉬면 그 사이가 어긋나 보인다.
            .tab_h = s.px(34, scale_milli),
            .summary_h = s.px(24, scale_milli),
            .section_h = s.px(24, scale_milli),
            .row_h = s.px(24, scale_milli),
            .branch_h = s.px(26, scale_milli),
            // 그룹 헤더(24)보다 크고 탭 줄(34)보다 작다 — 목록 안에서 가장 굵은 층이되 고정 chrome보다는
            // 가볍다.
            .repo_h = s.px(30, scale_milli),
            // **글자 줄 높이 그대로다.** 여기서 따로 20px를 고르면 상자 높이는 20씩 세는데 `view`는
            // 17(=`.control` 줄 높이)씩 줄을 놓아, 줄이 늘수록 아래에 빈 띠가 남고 클릭 → 행 변환도
            // 그만큼 어긋난다(같은 값의 출처가 둘이면 늘 이렇게 갈린다).
            .commit_row_h = typography.lineHeightPx(.control, scale_milli),
            .commit_button_h = s.px(28, scale_milli),
            .commit_pad_y = s.px(8, scale_milli),
            // 제목(control 17px) + 보조 줄(supporting) + 위아래 여백. 파일 행보다 높지만 그만큼
            // 정보가 둘이다.
            .commit_row_two_line_h = typography.lineHeightPx(.control, scale_milli) +
                typography.lineHeightPx(.supporting, scale_milli) + s.px(8, scale_milli),
            .inset_x = s.px(8, scale_milli),
            .gap = s.px(6, scale_milli),
            .status_extent = s.px(14, scale_milli),
            .action_extent = s.px(20, scale_milli),
            .chip_pad_x = s.px(6, scale_milli),
            // 칸 수는 배율과 무관하다(셀 폭이 이미 배율을 든다).
            .commit_subject_min_cols = 8,
            .disclosure_extent = s.px(16, scale_milli),
            .accent_bar_w = s.px(2, scale_milli),
            .rail_w = s.px(1, scale_milli),
            // 행 높이 24px에 18pt 아이콘은 꽉 차 보인다 — 목록 행은 밀집한 자리라 `compact`가 맞다.
            .icon_extent = s.px(ui_icon.Size.compact.extentPt(), scale_milli),
            .scrollbar_width = s.px(8, scale_milli),
            .scrollbar_inset_x = s.px(2, scale_milli),
            .scrollbar_min_thumb = s.px(24, scale_milli),
        };
    }

    /// 항목 하나의 높이. 스크롤 상한·가상화 계산이 이 함수를 단일 출처로 쓴다 — platform이 자기
    /// 산술로 다시 재면 그린 자리와 스크롤 범위가 갈린다.
    /// 커밋 상자 전체 높이. **세 곳이 이 함수를 쓴다** — build(노드 높이)·view(글자 자리)·platform(목록
    /// 높이). 각자 계산하면 상자가 차지한 만큼 목록이 줄지 않아 스크롤 범위가 어긋난다(탭 줄에서 겪었다).
    pub fn commitBoxHeight(self: DockMetrics, rows: u32) u32 {
        return self.commit_row_h * @max(rows, 1) + self.commit_pad_y * 2;
    }

    /// 커밋 상자가 한 줄에 담는 **열 수**. **랩 계산의 단일 출처다** — host는 이 값으로 랩해 상자 높이를
    /// 정하고(`commit_rows`), view는 같은 값으로 랩해 글자를 놓는다. 둘이 갈리면 상자 높이와 실제 줄
    /// 수가 어긋나 마지막 줄이 잘리거나 빈 줄이 남는다.
    ///
    /// **13pt 역할 기준이다**(text-field-editor.md §12.3 ①) — chrome 글자가 사용자 등폭 폰트라 셀 =
    /// 실제 advance인 덕분에 셀 단위 랩이 성립한다. 12pt 역할로 낮추면 그 순간 랩이 깨진다.
    /// 상자 안 **스크롤바 거터**. 목록과 같은 규율로 **늘 비워 둔다** — 글이 8행을 넘는 순간 막대가
    /// 나타나는데, 그때 폭이 줄면 글이 통째로 다시 접혀 커서가 튄다(목록이 같은 이유로 gutter를 상시
    /// 소유한다).
    pub fn commitGutterPx(self: DockMetrics) u32 {
        return self.scrollbar_width + self.scrollbar_inset_x * 2;
    }

    pub fn commitViewCols(self: DockMetrics, box_width_px: f32, cell_width_px: u32) u16 {
        const cell: f32 = @floatFromInt(@max(cell_width_px, 1));
        const usable = box_width_px - @as(f32, @floatFromInt(self.inset_x * 2 + self.commitGutterPx()));
        if (usable < cell) return 1; // 한 열은 늘 있다 — 0열이면 랩이 무한 루프가 될 자리다
        const cols = @floor(usable / cell);
        return @intFromFloat(@min(cols, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    }

    pub fn itemHeight(self: DockMetrics, item: Item) u32 {
        return switch (item) {
            // 머리 줄은 그룹 헤더보다 한 급 크다 — 이름·브랜치 칩이 함께 서고, 목록의 첫 층이라
            // 눈이 여기서 끊겨야 저장소 경계가 보인다.
            .repo => self.repo_h,
            // 커밋 줄은 파일 행과 같은 높이다 — 목록 두 탭이 같은 격자를 쓰면 탭을 오가도 눈이 안 튄다.
            // **두 줄이다**(§3.5.3): 제목 / 작성자·시각·해시. 한 줄에 몰면 좁은 도크에서 제목이 거의
            // 남지 않는다 — 목록에서 가장 중요한 것이 "무엇을 한 커밋인가"다.
            // 턴 줄도 두 줄이다(제목 / 에이전트 · 시각) — 커밋 줄과 같은 격자를 쓴다.
            .commit, .turn => self.commit_row_two_line_h,
            // 커밋 안의 파일 줄은 **파일 행과 같은 높이**다 — 두 탭이 같은 격자를 쓴다.
            .commit_file => self.row_h,
            .load_more => self.row_h,
            .commit_box => |box| self.commitBoxHeight(box.rows),
            // 버튼 아래 여백까지 이 행이 갖는다 — 다음 줄(요약·그룹 헤더)과 붙지 않게.
            .commit_button => self.commit_button_h + self.commit_pad_y,
            .section => self.section_h,
            .file => self.row_h,
            // "모두 보기"와 안내는 파일 행과 같은 높이를 쓴다(줄이 하나이므로).
            .more, .notice, .blocker => self.row_h,
        };
    }

    /// 원격 갱신 칩의 폭(P6). 글자 + 좌우 여백이고, **글자가 길어지면 칩도 커진다**(`가져오는 중…`) —
    /// 고정 폭으로 두면 도는 동안 글자가 잘려 무슨 상태인지 못 읽는다.
    /// **아이콘 열의 x**(왼쪽 여백 + 접힘 화살표 칸 + 한 칸). 머리 줄의 종류 아이콘, 파일 행의 아이콘,
    /// 안내·`더 보기` 글자가 전부 이 열에 선다 — 값이 흩어져 있으면 한 줄만 고쳤을 때 열이 어긋난다.
    ///
    /// **화살표와 아이콘 사이에 `gap`을 둔다**(사용자 지적 2026-08-19). 그전에는 화살표 칸이 끝나는
    /// 자리에 아이콘이 바로 붙어(간격 0) 둘이 한 덩어리로 보였다 — 이름 앞에만 간격이 있었다.
    /// 이름에게 주려는 최소 폭 — **목표이지 보장이 아니다**(파일 탐색기의 `label_floor` 와 같은 값·성격).
    pub const name_floor_px: f32 = 80;

    /// 이 폭에서 **행 동작 버튼이 들어갈 자리가 있는가.**
    ///
    /// `build`(노드를 만드는 쪽)와 `view`(자리를 비우는 쪽)가 **같은 답**을 써야 한다. view 만 자리를
    /// 안 비우면 버튼 노드는 그대로 남아 호버할 때 **이름 위에 그려진다** — 사다리를 view 에만 넣었다가
    /// 적대적 검증에서 잡힌 구멍이다.
    ///
    /// 사다리에서 동작은 증감 **다음**이라, 이 판정 시점에는 증감이 이미 없다 — 그래서 측정값 없이
    /// 순수 기하만으로 답할 수 있다.
    pub fn rowActionFits(self: DockMetrics, row_w: f32) bool {
        const left: f32 = @floatFromInt(self.inset_x + self.icon_extent + self.gap);
        const right: f32 = @floatFromInt(self.inset_x + self.status_extent + self.gap + self.action_extent + self.gap);
        return row_w - left - right >= name_floor_px;
    }

    pub fn iconColumnX(self: DockMetrics) u32 {
        return self.inset_x + self.disclosure_extent + self.gap;
    }

    /// 개수 배지 **왼쪽**에 두는 여백. 보통 `gap`의 두 배다 — 배지는 칠해진 알약이라 같은 간격이면
    /// 글자보다 시각 무게가 커서 브랜치 이름에 달라붙어 보인다(사용자 지적 2026-08-19).
    pub fn badgeGapPx(self: DockMetrics) u32 {
        return self.gap * 2;
    }

    /// 원격 갱신 칩의 폭. **글자가 아니라 아이콘**이라 라벨 길이와 무관하다(사용자 결정 2026-08-20:
    /// `가져오기` 넉 자가 브랜치 줄 오른쪽을 계속 차지했다). 도는 중에도 폭이 안 변한다 — 라벨이었다면
    /// `가져오는 중…`으로 넓어져 그 옆 `↑`/`↓`가 밀린다.
    pub fn fetchChipWidthPx(self: DockMetrics) u32 {
        return self.action_extent + self.chip_pad_x * 2;
    }

    pub fn scrollbarMetrics(self: DockMetrics) scroll_area.ScrollbarMetrics {
        return .{
            .width_px = self.scrollbar_width,
            .inset_x_px = self.scrollbar_inset_x,
            .min_thumb_px = self.scrollbar_min_thumb,
        };
    }
};

const testing = std.testing;

test "DockMetrics: zoom이 커지면 행도 함께 커지고 0으로 접히지 않는다" {
    const base = DockMetrics.resolve(1000);
    const big = DockMetrics.resolve(2000);
    try testing.expect(big.row_h > base.row_h);
    try testing.expect(big.section_h > base.section_h);
    // 극단적으로 작은 zoom에서도 1px 아래로 접히면 행이 사라져 클릭할 것이 없어진다.
    const tiny = DockMetrics.resolve(1);
    try testing.expect(tiny.row_h >= 1 and tiny.status_extent >= 1);
}

test "itemHeight: 종류마다 높이가 정의된다(스크롤 상한의 단일 출처)" {
    const m = DockMetrics.resolve(1000);
    try testing.expectEqual(m.section_h, m.itemHeight(.{ .section = .{ .section = .staged, .count = 1, .collapsed = false, .action = .unstage } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .file = .{ .name = "a", .dir = "", .status = .modified, .letter = 'M', .action = .stage } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .more = .{ .section = .changes, .hidden = 3 } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .notice = "잘렸습니다" }));
}
