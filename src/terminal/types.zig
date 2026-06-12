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
    dirty: ?DirtyRegion = null,
};
