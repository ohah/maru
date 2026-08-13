//! 셰이핑 run 분포 측정 도구.
//!
//! 지금 native CoreText 셰이퍼는 **셀 하나마다** `CTLineCreateWithAttributedString`을 만든다
//! (`coretext_smoke.m`의 cell 루프). 이걸 연속 run 하나당 한 번으로 묶으면 호출 수가 얼마나 줄어드는지를
//! 실제 터미널 출력으로 재는 것이 이 도구의 목적이다. 묶기 작업에 들어가기 전에 기대 이득을 숫자로
//! 확정하려는 것이며, 추정("20~45배")을 실측으로 대체한다.
//!
//! run 경계는 **native가 face를 고르는 기준**과 같아야 의미가 있다: 같은 행에서 열이 연속이고
//! bold/italic이 같으면 한 번의 셰이핑으로 묶을 수 있다. 색은 face 선택에 관여하지 않으므로 경계가 아니다.
//!
//! 사용: `zig build shape-run-probe -- <ansi-file> [ansi-file ...]`
//! 인자가 없으면 내장 합성 화면만 잰다.

const std = @import("std");
const maru = @import("maru");

/// 사용자 실환경에 맞춘 기본 격자(제보 환경의 workspace.v1이 cols=135 rows=72였다).
const default_cols: u16 = 135;
const default_rows: u16 = 72;

const RunStats = struct {
    cells: usize = 0,
    /// 지금 구조에서 실제로 CTLine을 만드는 셀 수(공백·width 0은 native가 건너뛴다).
    shaped_cells: usize = 0,
    runs: usize = 0,

    fn ratio(self: RunStats) f64 {
        if (self.runs == 0) return 0;
        return @as(f64, @floatFromInt(self.shaped_cells)) / @as(f64, @floatFromInt(self.runs));
    }
};

/// native의 셀 루프가 건너뛰는 셀인지. `maru_category_for_codepoint`가 space로 분류하거나 width==0이면
/// 셰이핑 없이 continue한다 — 여기서도 같은 기준으로 세야 "줄어드는 호출 수"가 실제와 맞는다.
fn isSkipped(cell: maru.renderer.DrawCell) bool {
    return cell.width == 0 or cell.codepoint == ' ' or cell.codepoint == 0;
}

/// 이어붙일 수 있는 셀인지 — 같은 행, 열이 바로 다음, face가 같음.
fn continuesRun(prev: maru.renderer.DrawCell, cur: maru.renderer.DrawCell) bool {
    if (prev.row != cur.row) return false;
    if (@as(usize, prev.col) + @as(usize, prev.width) != @as(usize, cur.col)) return false;
    return prev.style.bold == cur.style.bold and prev.style.italic == cur.style.italic;
}

/// 공백을 어떻게 볼지에 따라 묶이는 정도가 크게 달라진다.
///  - `.break_on_blank`: 공백이 run을 끊는다. 지금 native가 공백 셀에서 `continue`하는 것을 그대로 옮긴,
///    가장 보수적인 추정(단어마다 run이 갈린다).
///  - `.span_blanks`: 공백도 문자열에 넣어 한 번에 셰이핑한다. 실제 line-level shaper(및 Ghostty)가 하는
///    방식이며, 공백 glyph가 결과에 늘지만 CTLine 호출은 훨씬 줄어든다.
const BlankPolicy = enum { break_on_blank, span_blanks };

fn countRuns(cells: []const maru.renderer.DrawCell, policy: BlankPolicy) RunStats {
    var stats: RunStats = .{ .cells = cells.len };
    var have_prev = false;
    var prev: maru.renderer.DrawCell = undefined;
    for (cells) |cell| {
        const skipped = isSkipped(cell);
        if (skipped and policy == .break_on_blank) {
            have_prev = false;
            continue;
        }
        if (!skipped) stats.shaped_cells += 1;
        if (have_prev and continuesRun(prev, cell)) {
            prev = cell;
            continue;
        }
        // span_blanks에서 run이 공백으로 시작하는 것은 세지 않는다 — 앞의 문자 run에 이어 붙는 경우만
        // 이미 위에서 처리됐고, 순수 공백 구간은 셰이핑할 것이 없어 호출을 만들지 않는다.
        if (!(skipped and !have_prev)) stats.runs += 1;
        prev = cell;
        have_prev = true;
    }
    return stats;
}

fn measure(
    allocator: std.mem.Allocator,
    label: []const u8,
    bytes: []const u8,
    out: *std.Io.Writer,
) !void {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = default_cols, .rows = default_rows });
    defer core.deinit();
    try core.write(bytes);

    var list = try maru.renderer.buildDrawList(allocator, core.renderSnapshot());
    defer list.deinit(allocator);

    const broken = countRuns(list.cells, .break_on_blank);
    const spanned = countRuns(list.cells, .span_blanks);
    try out.print("{s:<22} shaped={d:<6} | 공백끊김 runs={d:<5} {d:>5.1}배 | 공백포함 runs={d:<5} {d:>5.1}배\n", .{
        label,
        broken.shaped_cells,
        broken.runs,
        broken.ratio(),
        spanned.runs,
        spanned.ratio(),
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    try out.print("shape run 분포 (격자 {d}x{d})\n", .{ default_cols, default_rows });
    try out.print("{s}\n", .{"-" ** 78});

    // 합성 기준선: 장식 없는 가득 찬 화면. run 묶기의 상한(행 하나가 통째로 한 run)을 보여준다.
    {
        const cell_count = @as(usize, default_cols) * @as(usize, default_rows);
        const fill = try allocator.alloc(u8, cell_count);
        defer allocator.free(fill);
        @memset(fill, 'M');
        try measure(allocator, "합성: 가득 찬 화면", fill, out);
    }

    // 합성 최악: 셀마다 bold를 토글해 run이 절대 이어지지 않는 화면. 묶기가 이득을 못 내는 하한.
    {
        var worst: std.ArrayList(u8) = .empty;
        defer worst.deinit(allocator);
        for (0..@as(usize, default_cols) * @as(usize, default_rows)) |i| {
            try worst.appendSlice(allocator, if (i % 2 == 0) "\x1b[1m" else "\x1b[22m");
            try worst.append(allocator, 'M');
        }
        try measure(allocator, "합성: 셀마다 bold 토글", worst.items, out);
    }

    // 인자 순회는 `main.zig`와 같은 방식(std.process.Init의 minimal.args)을 쓴다 — 0.16에는 argsAlloc이 없다.
    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next(); // argv[0]
    while (args.next()) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |e| {
            try out.print("{s:<24} 읽기 실패: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        defer allocator.free(bytes);
        try measure(allocator, std.fs.path.basename(path), bytes, out);
    }

    try out.flush();
}
