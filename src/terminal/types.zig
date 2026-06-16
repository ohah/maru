const color = @import("../color.zig");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub const default: Size = .{ .cols = 80, .rows = 24 };
};

// Rgb는 terminal 전용 타입이 아니라 config/renderer도 쓰는 공용 색 primitive다.
// 단일 출처를 src/color.zig에 두고 여기서는 재노출만 한다. `terminal.Rgb`와 아래
// `Color` union은 그대로 동작한다.
pub const Rgb = color.Rgb;

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    // SGR 7/27(reverse video): 렌더 시 전경/배경을 맞바꾼다(default 색은 theme 값으로 풀어 스왑).
    reverse: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
    width: u2 = 1,
    continuation: bool = false,
    combining: ?u21 = null,
    // OSC 8 하이퍼링크 id(0=없음). URI 자체는 TerminalCore.link_store에 한 번만 저장하고
    // 셀은 id만 든다 — 링크가 걸린 긴 출력에서도 셀 메모리가 URI 길이에 비례하지 않는다.
    link: u32 = 0,
};

/// OSC 133 semantic prompt — 셸이 알려주는 한 행의 의미 분류. 터미널은 raw 바이트만 봐선
/// 프롬프트/입력/출력을 구분 못 하므로, 셸 통합이 `OSC 133 ; A|B|C|D`로 경계를 마킹한다.
/// 행 단위로 보관(`wrapped`와 같은 병렬 배열 패턴)해, 이후 단계가 거터 마크(✓/✗)·프롬프트
/// 점프·출력 선택·reflow 정확화에 쓴다. 명세: freedesktop semantic-prompts.md(FinalTerm 발).
/// 주의: `wrapped`와 달리 glyph 쓰기(putCell)로 리셋되지 않는다 — 셸이 프롬프트를 다시 그려도
/// 그 행의 분류는 유지돼야 하기 때문이다.
pub const SemanticPrompt = enum(u8) {
    unknown, // OSC 133 분류 없음(모든 행 기본값)
    prompt, // A(또는 P)~B 사이 — 프롬프트 텍스트 자체
    input, // B~C 사이 — 사용자가 친 명령줄
    command, // C~D 사이 — 실행 중인 명령의 출력
};

/// 한 행의 OSC 133 정보(분류 + 그 프롬프트에서 실행된 명령의 종료코드). 종료코드는 프롬프트
/// 시작 행에만 `D;<code>`로 기록되고 나머지 행은 null이다. 분류와 한 묶음이라, 스크롤/reflow
/// carry가 둘을 함께 옮긴다(별도 배열을 안 들어도 됨). 거터 ✓/✗ 색(성공=초록/실패=빨강)에 쓴다.
pub const RowPrompt = struct {
    kind: SemanticPrompt = .unknown,
    exit: ?i16 = null, // 그 프롬프트의 명령 종료코드(프롬프트 시작 행에만; shell은 음수도 보냄)
};

/// 셸 통합(OSC 133/7)이 알린 의미 이벤트 — 명령 라이프사이클의 경계를 시간순으로 표시한다.
/// 같은 도메인 데이터를 디버그 로그·테스트·(후속) trace 직렬화/replay가 공유한다(관측 가능성
/// 원칙: 임시 포맷을 따로 두지 않는다). core가 OSC를 파싱하며 순서대로 기록하고 소비자가 drain한다.
///
/// 설계: POD다(소유 문자열 없음) — 행 인덱스는 이벤트 발생 시점의 활성 화면 커서 행이고, 종료코드는
/// OSC 133 D의 값이다. `cwd_changed`는 '경계만' 표시하고 cwd 값 자체는 `TerminalCore.currentCwd()`가
/// 권위다(trace는 순서가 정답이라 절대 좌표/문자열을 이벤트가 들 필요가 없고, 소유권도 단순해진다).
pub const ShellEvent = union(enum) {
    prompt_start: u16, // OSC 133 A — 프롬프트 시작(행)
    input_start: u16, // OSC 133 B — 입력 시작(행)
    command_start: u16, // OSC 133 C — 출력 시작(행)
    command_end: CommandEnd, // OSC 133 D — 명령 끝(행 + 종료코드, code 없으면 null)
    cwd_changed: void, // OSC 7 — cwd 변경(값은 currentCwd()가 권위)

    pub const CommandEnd = struct {
        row: u16,
        exit: ?i16,
    };
};

/// Iterates the visible codepoints of a single row: each non-continuation
/// cell yields its base codepoint, immediately followed by its combining mark
/// when present. Both the plain-text dump (`TerminalCore.dumpUtf8`) and the
/// snapshot row rendering consume this, so the rule for which cells actually
/// show on screen (skip continuations, append combining marks) lives in
/// exactly one place instead of being re-derived per consumer.
pub const RowCodepoints = struct {
    cells: []const Cell,
    col: usize = 0,
    pending_combining: ?u21 = null,

    pub fn next(self: *RowCodepoints) ?u21 {
        if (self.pending_combining) |combining| {
            self.pending_combining = null;
            return combining;
        }
        while (self.col < self.cells.len) {
            const cell = self.cells[self.col];
            self.col += 1;
            if (cell.continuation) continue;
            self.pending_combining = cell.combining;
            return cell.codepoint;
        }
        return null;
    }
};

/// 선택의 한 끝점. row는 "절대 행"(스크롤백 0..sb_count-1, 이어서 활성 화면 행) — 스크롤해도
/// 선택이 내용을 따라가게 하는 좌표계다.
pub const SelectionPoint = struct {
    row: usize,
    col: u16,
};

/// 뷰포트 좌표로 클립된 선택 범위(렌더용). [start, end]는 선형(행 단위 이어짐) 포함 범위다.
pub const SelectionSpan = struct {
    start: struct { row: u16, col: u16 },
    end: struct { row: u16, col: u16 },
};

/// 스크롤백 Find 매치 한 건의 절대-행 [start, end] 포함 범위. SelectionPoint와 같은 절대 좌표계라
/// 스크롤·eviction과 무관하게 내용을 가리키고, 렌더 시 clipAbsSpanToViewport로 뷰포트 span으로 클립한다.
/// 한 매치는 soft-wrap 경계를 넘어 여러 행에 걸칠 수 있다(논리 줄 단위 검색).
pub const Match = struct {
    start: SelectionPoint,
    end: SelectionPoint,
};

/// DECSCUSR(CSI Ps SP q)의 커서 모양. blink 여부는 별도 플래그로 추적한다.
pub const CursorShape = enum { block, underline, bar };

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16,
    end_row: u16,
};

/// kitty graphics placement — 화면에 표시 중인 이미지 인스턴스 하나(렌더용 뷰). 한 이미지(image_id)에
/// placement_id로 구분되는 여러 placement가 있을 수 있다. 좌표는 뷰포트 상대 — row는 placement가 앵커된
/// 셀의 뷰포트 행(top 기준 오프셋, i32라 위로 스크롤돼 화면 위로 벗어난 앵커는 음수). 셀 단위 크기(span)는
/// 코어가 셀 픽셀 크기를 모르므로 계산하지 않는다: source rect(픽셀)와 명시 columns/rows만 담고, 픽셀→셀
/// 환산·클립은 셀 메트릭을 가진 렌더러가 한다. 키 의미의 단일 출처는 core.zig의 KittyGraphicsCommand
/// 주석이다. 베이스: kitty graphics protocol(placement/display).
pub const KittyPlacement = struct {
    image_id: u32,
    placement_id: u32, // p: 0이면 default placement
    row: i32, // 앵커 셀의 뷰포트 행(top 기준 오프셋). 음수면 앵커가 화면 위로 벗어남.
    col: u16, // 앵커 셀의 열.
    cell_x_offset: u32 = 0, // X: 첫 셀 안에서 이미지를 그리기 시작할 픽셀 오프셋.
    cell_y_offset: u32 = 0, // Y
    src_x: u32 = 0, // x: 표시할 source 사각형의 좌상단(이미지 픽셀 좌표).
    src_y: u32 = 0, // y
    src_width: u32 = 0, // w: source 사각형 폭(픽셀, 0=전체).
    src_height: u32 = 0, // h: source 사각형 높이(픽셀, 0=전체).
    columns: u32 = 0, // c: 표시할 열 수(0=렌더러가 환산).
    rows: u32 = 0, // r: 표시할 행 수(0=렌더러가 환산).
    z: i32 = 0, // z-index(<0 텍스트 뒤, >=0 텍스트 앞).
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    // DECSCUSR가 정한 커서 모양/깜빡임. 렌더러가 block(반전)/underline(하단 바)/bar(좌측 바)로
    // 투영한다. blink는 추적만 하고 깜빡임 타이머는 아직 렌더하지 않는다.
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    cells: []const Cell = &.{},
    // 행별 OSC 133 정보(분류 + 종료코드, 길이=size.rows, cells와 같은 행 인덱싱). 스크롤된
    // 뷰포트에서도 보이는 행에 맞춰 합성된다. 마킹이 없으면 전부 {.unknown, null}이라 렌더러는
    // 무시해도 된다. 거터(✓/✗)는 prompt 시작 행의 exit로 색을 정한다.
    prompt_marks: []const RowPrompt = &.{},
    // 가장 최근에 끝난 명령의 종료코드(OSC 133 ; D ; <code>). 없으면 null. shell이 음수(-1 등)를
    // 보낼 수 있어 i32. **주의: 거터는 이 값이 아니라 `prompt_marks[행].exit`(행별)로 그린다** —
    // 이건 MARU_DEBUG 덤프 헤더용 편의 값이라 거터/UI를 여기에 연결하지 말 것.
    last_command_exit: ?i32 = null,
    // kitty graphics placement(표시 중인 이미지 인스턴스)의 뷰포트 뷰. 비어 있으면 표시할 이미지가
    // 없다(일반 경로 — 할당 없음). 렌더러가 image_id로 픽셀을 찾아 source rect/오프셋/span으로 그린다 —
    // 픽셀→셀 환산·클립은 렌더러 책임(코어는 셀 픽셀 크기를 모름). 좌표는 뷰포트 상대(row는 i32라 화면
    // 위로 벗어난 앵커도 노출 — 셀 span을 아는 렌더러가 가시성/클립을 정한다). 렌더는 후속 K-단계.
    placements: []const KittyPlacement = &.{},
    dirty: ?DirtyRegion = null,
};
