//! 네이티브 편집기의 **platform 쪽 절반** — 파일을 읽고 권한을 보는 일
//! ([native-editor-document-model.md](../../../../docs/native-editor-document-model.md) §3.5).
//!
//! **L2가 파일을 읽지 않는다.** `session/editor/`는 OS를 모르므로(§2 레이어) bytes만 다루고, 여기서
//! 읽어 넘긴다. 그래서 이 파일에 있는 것은 딱 둘이다 — 읽기와 쓰기 권한 판정.
//!
//! **기존 `readFileAlloc`을 쓰지 않는다.** 그쪽은 "작은 사용자 파일"(에이전트 기록·config) 용도라
//! **빈 파일을 `null`로 돌려주고 1 MiB에서 끊는다**. 편집기는 둘 다 어긋난다: 빈 파일도 열려야 하고
//! (§3.5 — 여는 것을 막는 이유는 UTF-8 아님 하나뿐이다), 로그·생성 파일을 못 여는 편집기는 쓸 수 없다.

const std = @import("std");
const maru = @import("maru");

const editor = maru.session.editor;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const chrome = maru.chrome;
const chrome_draw = maru.chrome.draw;
const chrome_editor = maru.chrome.components.editor_view;
const chrome_scroll_area = maru.chrome.ui.scroll_area;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const renderer = app_session_mod.renderer;
const diag_gate = app_session_mod.diag_gate;

/// 편집기 pane 렌더 진단 logger. MARU_DEBUG일 때 프레임 한 번의 입력(사각·문서 줄 수)과 산출(op 수·
/// 시각 행 수·lowering이 만든 셀 수)을 한 줄로 찍는다. "본문이 비었다"의 원인이 ⑴ 사각이 0이라 op이
/// 안 나온 것인지 ⑵ op은 나왔는데 셀이 0이 된 것인지 ⑶ 셀까지 갔는데 합성이 덮은 것인지를 가른다 —
/// 셋은 고치는 자리가 전부 다르다. 게이트는 diag.zig 단일 출처.
const editor_diag = std.log.scoped(.editor);

/// 읽기 상한. **§3.5는 "열지 않음이 아니라 축소"를 요구하지만**, 축소 단계(①미니맵 ②랩 ③파싱
/// ④읽기 전용)는 그것을 실제로 만드는 슬라이스에서 붙는다. 그때까지 이 값은 **메모리를 지키는
/// 임시 방벽**이고, 넘으면 읽지 않고 그 사실을 호출자에게 알린다.
///
/// **숫자는 잠정이다.** §10이 "선행 측정 게이트는 없다"고 했으므로 여기서도 근거 없는 값을 계약처럼
/// 굳히지 않는다 — 축소를 만드는 슬라이스에서 실측으로 정한다.
pub const read_limit_bytes: u64 = 64 << 20;

pub const OpenFileError = error{
    /// 파일을 열거나 읽지 못했다(없음·권한·I/O). **읽기 전용과 다르다** — 쓸 수 없는 파일은 열린다.
    Unreadable,
    /// 위 상한을 넘었다.
    TooLarge,
    /// UTF-8이 아니다. 다른 인코딩을 추측하지 않는다(§3.5).
    NotUtf8,
    OutOfMemory,
};

pub const Opened = struct {
    /// 할당한 버퍼 **전체**. 문서는 그 앞부분(실제로 읽은 만큼)을 빌려 쓰므로 문서보다 오래 살아야
    /// 한다. 파일이 `stat`과 read 사이에 줄어들면 뒤에 안 쓰는 꼬리가 남는데, `free`가 원래 크기를
    /// 요구하므로 잘라 들 수 없다 — **파일 내용으로 쓰지 말 것**(문서를 통해 읽어야 한다).
    bytes: []u8,
    file: editor.open.OpenFile,

    pub fn deinit(self: *Opened, allocator: std.mem.Allocator) void {
        self.file.deinit();
        allocator.free(self.bytes);
    }
};

/// 경로를 읽어 편집기 문서로 연다.
///
/// **쓸 수 없는 파일도 연다** — 읽기 전용으로 표시할 뿐이다(§3.5: "보는 것은 되어야 한다").
pub fn openPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) OpenFileError!Opened {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.Unreadable;
    defer file.close(io);

    const size = (file.stat(io) catch return error.Unreadable).size;
    if (size > read_limit_bytes) return error.TooLarge;

    // **빈 파일도 연다.** `alloc(0)`은 빈 슬라이스를 주고, `document.open`이 그것을 한 줄짜리
    // 문서로 해석한다 — 새 파일을 만들자마자 여는 흐름이 그렇게 생긴다.
    const buf = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    // **짧게 읽히면 그만큼만 문서가 된다.** `readPositionalAll`은 EOF에서 조용히 멈추므로(`amt == 0`
    // 이면 break) 파일이 `stat`과 여기 사이에 줄어들면 `n < size`가 되고, 우리는 그 시점의 실제
    // 내용을 여는 셈이라 화면은 거짓을 보이지 않는다.
    //
    // **저장이 붙으면 달라진다(N2).** 잘린 버퍼를 원문으로 알고 되쓰면 파일이 그만큼 잘린다 —
    // 그때는 `n != size`를 에러로 올리거나 다시 읽어야 한다. 읽기 전용인 지금은 그 판정을 만들지
    // 않는다(없는 계약을 여기서 지어내지 않는다).
    const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;

    const opened = editor.open.open(allocator, buf[0..n], !isWritable(path)) catch |e| switch (e) {
        error.NotUtf8 => return error.NotUtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .bytes = buf, .file = opened };
}

/// 이 경로에 쓸 수 있는가. **여는 것을 막는 판정이 아니라 표시할 값**이다.
fn isWritable(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0].ptr, std.posix.W_OK) == 0;
}

/// 편집기 프레임 한 번의 산출물.
pub const PaneFrame = struct {
    /// 배경·스크롤바 quad와 텍스트 op. 호출자가 lowering으로 내린다.
    ops: []const chrome_draw.Op,
    ops_len: usize,
    /// 그린 시각 행 수(스크롤 clamp용).
    visual_rows: usize,
};

/// 편집기 프레임에 필요한 호출자 소유 저장소. 한 프레임 안에서만 유효하다.
pub const FrameScratch = struct {
    ops: []chrome_draw.Op,
    text_bytes: []u8,
    runs: []chrome_draw.Run,
    content_rows: []chrome_editor.content.Row,
    visual_rows: []chrome_editor.visual_map.VisualRow,
    gutter_rows: []chrome_editor.gutter.Row,
    row_counts: []u32,
    count_scratch: []u8,
};

/// pane 사각과 셀 크기로 편집기 op을 만든다. 반환값은 `scratch.ops[0..ops_len]`이 유효하다는 뜻이다.
pub fn buildPaneOps(
    lines: []const []const u8,
    first_line: usize,
    wrap: bool,
    rect: chrome_draw.Rect,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    scratch: FrameScratch,
) PaneFrame {
    // **스크롤바가 자리를 먹는다**(§4.1a) — 본문 위에 겹치면 오른쪽 끝 글자가 막대에 가려지고,
    // §3.8이 "보이는 것과 파일 내용이 달라지면 안 된다"를 요구하는 편집기에서 그것은 특히 나쁘다.
    const metrics = chrome_scroll_area.ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const cw: u32 = @max(cell_w_px, 1);
    const ch: u32 = @max(cell_h_px, 1);
    const total_cols: u16 = @intCast(@min(
        (rect.w -| metrics.gutterPx()) / cw,
        @as(u32, std.math.maxInt(u16)),
    ));
    // **남은 폭 전부가 스크롤바 gutter다.** `total_cols`가 버림이라 본문이 셀 경계에서 끝나고,
    // 요구한 폭보다 넓은 자투리가 생긴다 — 그것을 포함하지 않으면 막대가 오른쪽 끝에서 뜬다.
    const scrollbar_gutter_px: u32 = rect.w -| (@as(u32, total_cols) * cw);
    const visible_rows: u16 = @intCast(@min(rect.h / ch, @as(u32, std.math.maxInt(u16))));

    const w = chrome_editor.frame.build(.{
        .lines = lines,
        .first_line = first_line,
        .total_lines = lines.len,
        .visible_rows = visible_rows,
        .wrap = wrap,
        .rect = rect,
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .font_px = font_px,
        .total_cols = total_cols,
        .scrollbar_gutter_px = scrollbar_gutter_px,
        .metrics = metrics,
    }, .{
        .ops = scratch.ops,
        .text_bytes = scratch.text_bytes,
        .runs = scratch.runs,
        .content_rows = scratch.content_rows,
        .visual_rows = scratch.visual_rows,
        .gutter_rows = scratch.gutter_rows,
        .row_counts = scratch.row_counts,
        .count_scratch = scratch.count_scratch,
    });

    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows };
}

/// 한 leaf에 편집기 프레임을 그린 결과. 배경·스크롤바 quad는 이미 `gpu_quads`에 실렸고, 글자는
/// 호출자가 셀로 내리도록 DrawList로 돌려준다.
pub const PaneDraw = struct {
    /// 그린 사각(pane grid). 호출자가 셀 origin으로 쓴다 — quad와 셀이 같은 자리에 서야 한다.
    rect: maru.session.SplitRect,
    /// 본문·gutter 글자. **호출자가 소유한다**(`collectShaped`가 가져가거나 직접 해제).
    dl: renderer.DrawList,
};

/// leaf 하나에 편집기 프레임을 그린다. 편집기 Term이 아니거나 그릴 것이 없으면 `null`.
///
/// **왜 tick에서 뽑아 왔나.** 이 함수가 정하는 셋(사각·quad layer·lowering 격자)은 전부 조용히
/// 틀릴 수 있는 판정이고, tick 안에 있으면 프레임 전체를 돌리지 않고는 검사할 수 없다. 실제로
/// 배경 layer 하나가 뒤집혀 본문이 통째로 안 보이는 동안 테스트는 전부 초록이었다 — 아래 테스트가
/// 그 두 뮤턴트(layer 3·leaf 사각)를 잡는다.
///
/// 조립 자체는 `editor_view.frame`이 한다 — Chrome Lab과 **같은 함수**라 캡처가 제품을 예고한다.
pub fn appendPaneFrame(self: *AppSession, leaf_rect: maru.session.SplitRect, term: *Term) ?PaneDraw {
    if (term.kind != .editor) return null;
    if (term.rt.editor_lines.len == 0) return null;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return null;

    // **본문 사각은 grid다**(`paneGeometry` 단일 출처) — leaf 사각 전체를 쓰면 탭 바와 창 padding까지
    // 편집기가 덮는다. 터미널 셀·hit-test·IME가 모두 이 grid를 쓰므로, 편집기만 다른 사각을 쓰면
    // "보이는 자리"와 "누르는 자리"가 갈린다.
    const rect = pane_ops.paneGeometry(self, leaf_rect).grid;
    if (rect.w == 0 or rect.h == 0) return null;

    var ops: [1024]chrome_draw.Op = undefined;
    var text: [16384]u8 = undefined;
    var runs: [1024]chrome_draw.Run = undefined;
    var content_rows: [256]chrome_editor.content.Row = undefined;
    var visual_rows: [256]chrome_editor.visual_map.VisualRow = undefined;
    var gutter_rows: [256]chrome_editor.gutter.Row = undefined;
    var counts: [4096]u32 = undefined;
    var count_scratch: [8192]u8 = undefined;

    // **원점은 0,0이다.** 컴포넌트가 내는 좌표는 pane **상대**여야 한다 — 창 절대 좌표를 주면
    // `buildTextDrawList`가 셀 인덱스로 바꿀 때 pane 폭을 넘어 글자가 잘린다. 화면상의 자리는
    // 호출자의 `PanePlacement.origin_*`(= `PaneDraw.rect`)이 정한다.
    const pf = buildPaneOps(
        term.rt.editor_lines,
        term.rt.editor_first_line,
        self.loaded_config.config.editor.wrap,
        .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h },
        @intCast(self.cell_width_px),
        @intCast(self.cell_height_px),
        @intCast(self.cell_height_px),
        .{
            .ops = &ops,
            .text_bytes = &text,
            .runs = &runs,
            .content_rows = &content_rows,
            .visual_rows = &visual_rows,
            .gutter_rows = &gutter_rows,
            .row_counts = &counts,
            .count_scratch = &count_scratch,
        },
    );
    if (pf.ops_len == 0) return null;

    const tokens = self.buildChromeTokens();
    const draws: chrome.ChromeDraw = .{ .layer = .sidebar, .ops = pf.ops };
    // **bottom(2)** — 셀 패스 **앞**에 그리는 유일한 quad 층이다. 0/1/3/4는 셀 뒤라 배경이 자기
    // 글자를 덮는다(`maru_metal_renderer.m`의 네 패스 배치). 실제로 3으로 두어 편집기 본문이
    // 통째로 안 보였다 — 배경만 칠해진 빈 pane. §4.1b의 "op 순서상 맨 처음"은 op 배열 안에서만
    // 참이고, quad와 셀은 파이프라인이 갈리므로 합성 층을 여기서 따로 맞춘다.
    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, rect.x, rect.y, &self.gpu_quads, 2);

    const cols: u16 = @intCast(@min(rect.w / @max(self.cell_width_px, 1), @as(u32, std.math.maxInt(u16))));
    const rows: u16 = @intCast(@min(rect.h / @max(self.cell_height_px, 1), @as(u32, std.math.maxInt(u16))));
    const dl = chrome_draw_lowering.buildTextDrawList(
        self.allocator,
        pf.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
    ) catch |e| {
        if (diag_gate.maruDebugEnabled()) editor_diag.debug("pane lowering failed: {s}", .{@errorName(e)});
        return null;
    };
    if (diag_gate.maruDebugEnabled()) editor_diag.debug(
        "pane rect=({d},{d} {d}x{d}) lines={d} ops={d} visual_rows={d} grid={d}x{d} cells={d}",
        .{ rect.x, rect.y, rect.w, rect.h, term.rt.editor_lines.len, pf.ops_len, pf.visual_rows, cols, rows, dl.cells.len },
    );
    return .{ .rect = rect, .dl = dl };
}

/// N1: **편집기 Term** 하나를 만든다 — `createWebTerm`과 대칭이다(web-panel.md §6의 그 구조).
/// registry가 `LiveSurface` **editor arm** 슬롯을 소유하고, 그 arm의 sentinel `Surface`(빈 core)를
/// 제자리 init한다. **PTY spawn·attachSurface·pump가 없다** — 편집기는 셸이 아니다.
///
/// **sentinel surface가 왜 필요한가.** `Term.surface.id`가 유효해야 `surface_ptrs`·`activeSurface`
/// 계약이 깨지지 않는다(web이 같은 이유로 sentinel을 든다). 화면에 그리는 것은 그 core가 아니라
/// 편집기 프레임이다(§4).
///
/// 문서를 붙이는 것은 호출자다 — 이 함수는 Term과 슬롯만 만든다. Pane에 거는 것도 호출자 몫이다.
pub fn createEditorTerm(self: *AppSession) !*Term {
    const term = try self.allocator.create(Term);
    errdefer self.allocator.destroy(term);
    term.* = .{ .kind = .editor };

    const id = self.surface_ids.next(); // 앱 전역 발급(비재사용) — terminal·web과 같은 네임스페이스
    const slot = try self.live_registry.create(id, 0);
    // editor arm 확정 후 sentinel surface를 제자리 init. init 실패 시 슬롯은 아직 uninit이라
    // removeUninitialized로 deinit 없이 슬롯만 해제한다(web과 같은 규칙).
    slot.* = .{ .editor = .{ .internal_allocator = self.allocator } };
    term.surface = &slot.editor.surface;
    errdefer self.live_registry.removeUninitialized(id) catch {};
    term.surface.* = try maru.session.Surface.init(self.allocator, id, .{ .cols = 1, .rows = 1 });
    return term;
}

/// 경로를 열어 **활성 pane에 편집기 Term으로 붙인다**. N1의 "화면에 파일이 뜬다"가 여기서 닫힌다.
///
/// 실패는 호출자가 사용자에게 알린다 — §3.5가 "여는 것을 막는 이유는 UTF-8 아님 하나"라고 정했으므로
/// 나머지 이유를 같은 메시지로 뭉개면 그 계약을 확인할 수 없다.
pub fn openPathInActivePane(self: *AppSession, path: []const u8) OpenFileError!*Term {
    var opened = try openPath(self.io, self.allocator, path);
    errdefer opened.deinit(self.allocator);

    // **줄 슬라이스를 미리 만든다.** `frame.build`는 문서 전체를 받아야 스크롤바 길이가 맞는데(§4.1a),
    // 매 프레임 다시 만들면 프레임마다 할당이 생긴다. 줄들은 문서 버퍼를 빌리므로 문서보다 오래 살면 안 된다.
    const n = opened.file.lineCount();
    const lines = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
    errdefer self.allocator.free(lines);
    for (0..n) |i| lines[i] = opened.file.lineText(i) orelse "";

    const term = createEditorTerm(self) catch return error.OutOfMemory;
    errdefer term_ops.destroyTerm(self, term);

    term.rt.editor_doc = opened;
    term.rt.editor_lines = lines;
    term.rt.editor_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;

    const pane = pane_ops.activePane(self);
    pane.terms.append(self.allocator, term) catch return error.OutOfMemory;
    self.focusTerm(pane.terms.items.len - 1);
    self.metal_dirty = true;
    return term;
}

/// 편집기 Term이 소유한 것을 놓는다. `destroyTerm`이 kind로 분기해 부른다.
pub fn releaseEditorTerm(self: *AppSession, term: *Term) void {
    if (term.rt.editor_doc) |*d| d.deinit(self.allocator);
    term.rt.editor_doc = null;
    if (term.rt.editor_lines.len > 0) self.allocator.free(term.rt.editor_lines);
    term.rt.editor_lines = &.{};
    if (term.rt.editor_path) |p| self.allocator.free(p);
    term.rt.editor_path = null;
}

const testing = std.testing;
const builtin = @import("builtin");

// ── `appendPaneFrame` — 편집기 pane 한 프레임의 기하·합성 계약 ────────────────────────────────
//
// **이 테스트들이 증명하는 것**: 편집기가 그린 배경이 자기 본문을 덮지 않고, 본문이 pane의 grid에
// 선다는 것. 왜 중요한가 — 둘 다 **조용히** 틀린다. 배경 layer가 뒤집혀도 op·셀은 정상으로 나오고
// 좌표도 맞아, 실패는 오직 화면에서만 보인다(실제로 그 상태로 커밋됐고 캡처 픽셀을 재고서야 잡혔다).
// 사각도 같다 — leaf 전체를 쓰면 탭 바를 덮고 hit-test와 갈리지만 어떤 단위 테스트도 안 깨진다.

/// 헤드리스 세션 + 실제 파일을 연 편집기 Term. 렌더 상태(셀 크기·padding)는 init이 안 세우므로 준다.
const PaneFixture = struct {
    session: *AppSession,
    term: *Term,
    dir: testing.TmpDir,
    /// `paneGeometry`가 실제로 줄여야 할 leaf 사각. 아래 테스트가 grid와 이것을 대조한다.
    leaf_rect: maru.session.SplitRect = .{ .x = 100, .y = 50, .w = 800, .h = 600 },

    fn init(allocator: std.mem.Allocator) !PaneFixture {
        const io = std.testing.io;
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(io, .{ .sub_path = "doc.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try dir.dir.realPath(io, &root_buf)];
        const path = try std.fs.path.join(allocator, &.{ root, "doc.zig" });
        defer allocator.free(path);

        const session = try allocator.create(AppSession);
        errdefer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = app_session_mod.abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
        });
        errdefer session.deinit();
        session.cell_width_px = 8;
        session.cell_height_px = 16;
        // **padding을 0이 아닌 값으로 둔다.** 0이면 grid가 leaf 사각과 (탭 바 높이를 빼면) 같아져,
        // 사각을 잘못 골라도 테스트가 통과한다 — 판정이 성립하려면 둘이 실제로 달라야 한다.
        session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };

        const term = try openPathInActivePane(session, path);
        return .{ .session = session, .term = term, .dir = dir };
    }

    fn deinit(self: *PaneFixture, allocator: std.mem.Allocator) void {
        self.session.deinit();
        allocator.destroy(self.session);
        self.dir.cleanup();
    }
};

test "편집기 배경 quad는 셀 패스 앞 층(2)이다 — 뒤 층이면 자기 본문을 덮는다" {
    // `maru_metal_renderer.m`은 quad를 네 패스로 그리고 그중 layer 2(bottom)만 셀 패스 **앞**에 온다.
    // 0/1/3/4는 셀 뒤라 배경이 글자를 덮는다 — 그 파일 주석이 이미 그렇게 적어 두었는데도 3으로
    // 실려 편집기 본문이 통째로 안 보였다. 이 테스트가 그 뮤턴트를 잡는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // ⑴ 배경이 실제로 나왔다. quad가 0이면 아래 for가 공허하게 통과한다.
    try testing.expect(fx.session.gpu_quads.items.len > 0);
    for (fx.session.gpu_quads.items) |q| try testing.expectEqual(@as(u32, 2), q.layer);

    // ⑵ **그리고 글자도 나왔다.** 이것이 없으면 배경만 칠하고 본문을 안 그리는 상태(=우리가 고친
    //    바로 그 화면)도 초록이 된다 — 두 축을 함께 봐야 판정이 된다.
    try testing.expect(drawn.dl.cells.len > 0);
}

test "편집기 본문 사각은 pane grid다 — leaf 사각 전체가 아니다" {
    // leaf 전체를 쓰면 탭 바와 창 padding까지 배경이 덮고, 터미널 셀·hit-test·IME가 쓰는 사각과
    // 갈려 "보이는 자리"와 "누르는 자리"가 어긋난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const grid = pane_ops.paneGeometry(fx.session, fx.leaf_rect).grid;
    // **대조군 먼저.** grid와 leaf가 같은 픽스처에서는 이 테스트가 아무것도 판정하지 못한다.
    try testing.expect(grid.x != fx.leaf_rect.x or grid.y != fx.leaf_rect.y);
    try testing.expect(grid.w != fx.leaf_rect.w or grid.h != fx.leaf_rect.h);

    try testing.expectEqual(grid.x, drawn.rect.x);
    try testing.expectEqual(grid.y, drawn.rect.y);
    try testing.expectEqual(grid.w, drawn.rect.w);
    try testing.expectEqual(grid.h, drawn.rect.h);
}

test "편집기 배경 quad와 글자 셀은 같은 자리에 선다 — origin이 갈리면 배경만 옮겨간다" {
    // 배경은 GpuQuad(절대 px), 글자는 셀(origin + col×cw)이라 **서로 다른 경로로** 화면에 간다.
    // 두 origin이 갈리면 배경이 엉뚱한 데 칠해지는데, 각자만 보는 테스트로는 안 잡힌다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 배경 quad(첫 op = surface.build)는 pane 사각을 그대로 덮는다(§4.1b "뷰포트 전체를 덮는다").
    const bg = fx.session.gpu_quads.items[0];
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.x)), bg.x);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.y)), bg.y);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.w)), bg.w);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.h)), bg.h);
}

test "편집기가 아닌 Term은 이 경로를 타지 않는다 — 터미널 pane을 덮어쓰지 않는다" {
    // `appendPaneFrame`은 모든 leaf에 대해 불린다. kind 가드가 없으면 터미널 pane 위에 편집기
    // 배경을 칠하게 되고, 그 pane의 셀은 그대로라 "터미널이 흐려졌다"로만 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const shell = pane_ops.activePane(fx.session).terms.items[0];
    try testing.expect(shell.kind != .editor); // 픽스처 전제: 첫 Term은 편집기가 아니다
    fx.session.gpu_quads.clearRetainingCapacity();
    try testing.expect(appendPaneFrame(fx.session, fx.leaf_rect, shell) == null);
    try testing.expectEqual(@as(usize, 0), fx.session.gpu_quads.items.len); // quad도 안 남긴다
}

test "사각이 0으로 접히면 그리지 않는다 — 빈 DrawList를 흘리지 않는다" {
    // padding이 pane보다 크거나 창이 접히는 순간이 실재한다. 그때 op을 내면 셀 격자가 0열/0행이라
    // lowering이 실패하거나 빈 프레임이 합성에 들어간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    try testing.expect(appendPaneFrame(fx.session, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, fx.term) == null);
    try testing.expectEqual(@as(usize, 0), fx.session.gpu_quads.items.len);
}

test "빈 파일도 열린다 — 기존 readFileAlloc은 null을 준다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "empty.txt" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opened.file.lineCount());
    try testing.expectEqualStrings("", opened.file.lineText(0).?);
}

test "UTF-8이 아니면 열지 않는다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = "\xff\xfe\x00binary" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "bad.bin" });
    defer testing.allocator.free(path);

    try testing.expectError(error.NotUtf8, openPath(io, testing.allocator, path));
}

test "없는 경로는 Unreadable — 읽기 전용과 구분된다" {
    try testing.expectError(
        error.Unreadable,
        openPath(std.testing.io, testing.allocator, "/nonexistent/maru-editor-test"),
    );
}

test "디렉터리를 가리켜도 죽지 않고 Unreadable이다" {
    // 파일 패널이 폴더 행을 잘못 넘기는 경로가 실재한다. `openFile`이 디렉터리에 성공하는 플랫폼이
    // 있으므로(그러면 read가 EISDIR로 실패한다) 어느 단계에서 걸리든 **같은 에러 하나로** 나와야 한다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "sub" });
    defer testing.allocator.free(path);

    try testing.expectError(error.Unreadable, openPath(io, testing.allocator, path));
}

test "쓸 수 없는 파일도 열리고 읽기 전용으로 표시된다" {
    // §3.5: "쓸 수 없는 파일은 읽기 전용으로 연다 — 보는 것은 되어야 한다." **두 가지를 함께 본다**:
    // ⑴ 열리는가(권한이 여는 것을 막지 않는다) ⑵ 그 사실이 문서에 실리는가. `isWritable`이 늘
    // true를 줘도 ⑴은 통과하므로, ⑵이 없으면 읽기 전용 표시가 통째로 사라져도 아무도 모른다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ro.txt", .data = "locked\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "ro.txt" });
    defer testing.allocator.free(path);

    const pathz = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(pathz);
    if (std.c.chmod(pathz.ptr, 0o444) != 0) return error.SkipZigTest;
    // **root는 W_OK를 통과한다.** 그 환경에서는 이 테스트가 증명할 것이 없으므로 비켜난다.
    //
    // **판정을 `isWritable`로 하지 않는다.** 그러면 검사 대상 함수가 자기 검사 여부를 정하게 되어,
    // 그 함수가 늘 `true`를 돌려주도록 망가진 순간 테스트가 실패 대신 skip이 된다 — 적대적 검증에서
    // 실제로 그 뮤턴트가 초록으로 빠져나갔다. 환경만 보는 축(euid)으로 가른다.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expect(opened.file.doc.read_only); // ⑵ 표시된다
    try testing.expectEqualStrings("locked", opened.file.lineText(0).?); // ⑴ 그래도 열린다
}

test "쓸 수 있는 파일은 읽기 전용이 아니다 — 대조군" {
    // 위 테스트만 있으면 `read_only`를 **항상 true로** 두어도 통과한다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "rw.txt", .data = "open\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "rw.txt" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expect(!opened.file.doc.read_only);
}

test "여러 줄 파일의 줄 내용이 줄바꿈 없이 나온다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.zig", .data = "const a = 1;\nconst 한글 = 2;\r\n\tconst c = 3;" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "src.zig" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), opened.file.lineCount());
    try testing.expectEqualStrings("const a = 1;", opened.file.lineText(0).?);
    try testing.expectEqualStrings("const 한글 = 2;", opened.file.lineText(1).?);
    try testing.expectEqualStrings("\tconst c = 3;", opened.file.lineText(2).?); // 탭은 전개 전이다
    try testing.expect(opened.file.doc.format.mixed_endings);
}
