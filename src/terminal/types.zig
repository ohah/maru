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
    dirty: ?DirtyRegion = null,
};
