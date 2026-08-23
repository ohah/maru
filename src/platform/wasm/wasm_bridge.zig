//! L4 **wasm 어댑터**. 브라우저가 `TerminalCore` 를 쓰는 유일한 경계다.
//!
//! 여기 있는 export 가 곧 `@maru-term/core` 의 저수준 표면이다 — TS 쪽 바인딩과
//! **시그니처를 함께** 바꿔야 한다(한쪽만 고치면 링크는 되고 값만 어긋난다).
//! 계약은 [maru-term 라이브러리](../../../docs/maru-term-library.md) 가 소유하고,
//! wasm 으로 만들 수 있는 조건은 [wasm 이식성](../../../docs/wasm-portability.md) 이 소유한다.
//!
//! **OS 호출이 없다.** 링크 자동 감지(`openableLinkAt`)는 파일 존재 판정에서 libc 에
//! 도달하므로 노출하지 않는다 — OSC 8 명시 링크만 `link_uri` 로 준다(wasm-portability §2).
//!
//! **메모리 교환 규약**: 큰 값은 반환하지 않고 모듈 스코프 버퍼에 쓴 뒤 길이만 돌려준다.
//! 호출자는 `*_ptr()` 로 시작 주소를 받아 `memory.buffer` 를 직접 읽는다 — 복사가 0 이고
//! wasm ABI 에 구조체를 실을 필요도 없다.
const std = @import("std");
// **모듈 루트는 `maru.zig` 하나다.** terminal·renderer 를 따로 주면 둘 다 `draw_list.zig`
// 를 상대 경로로 끌어와 "file exists in two modules" 로 깨진다(실측 — build.zig 의 mobile
// 타깃이 같은 이유로 배럴 하나를 쓴다).
const maru = @import("maru");
const terminal = maru.terminal;
const renderer = maru.renderer;

/// 기본 panic 핸들러는 스택 트레이스를 찍으려고 dyld 심볼을 부르는데 freestanding 에는
/// 그 경로가 없다. `simple_panic` 은 메시지만 내고 트레이스 수집을 안 들여온다 —
/// **안전 검사(overflow·bounds)는 그대로 산다**(mobile_bridge 와 같은 선택).
pub const panic = std.debug.simple_panic;

const alloc = std.heap.wasm_allocator;

/// 호출자가 여기에 바이트를 쓰고 길이를 넘긴다. **1 MB** — 붙여넣기는 청킹할 수 없어서다
/// (`vt_paste` 가 bracketed 마커를 한 번 감싸므로 나누면 마커가 여러 번 붙는다).
var input_buf: [1 << 20]u8 = undefined;
/// 스냅샷 셀 버퍼. **512×128 = 65,536 셀** — 4K 디스플레이를 전체 화면으로 채워도(457×127 ≈
/// 58,000 셀) 담긴다. 이전 256×96(24,576 셀)은 1440p 최대화(≈304×84 = 25,536)에서 이미 넘쳐
/// 아래쪽 행이 영영 빈 채로 그려졌다.
var cell_buf: [512 * 128 * 20]u8 = undefined;
var glyph_buf: [64 * 64 * 4]u8 = undefined;
/// 검색 매치. 한 건이 `[startRow, startCol, endRow, endCol]` u32 넷이다. **4096 건** —
/// 그 이상은 사람이 훑을 수 있는 양이 아니고, 총 개수는 따로 돌려주므로 UI 는 "N+ 건"을
/// 표시할 수 있다.
var match_buf: [max_matches * 4]u32 = undefined;
const max_matches = 4096;

export fn input_ptr() [*]u8 {
    return &input_buf;
}
/// 입력 버퍼 용량. **호출자가 이걸 넘겨서는 안 된다** — JS 쪽 `Uint8Array(memory, ptr, len)`
/// 는 선형 메모리가 크면 예외 없이 인접 정적 버퍼(`cell_buf` 등)를 덮어쓴다. ReleaseSmall 이라
/// 트랩도 없다. 아래 export 들도 방어적으로 클램프하지만, 넘치기 전에 여기서 막아야 한다.
export fn input_cap() u32 {
    return input_buf.len;
}
export fn cells_ptr() [*]u8 {
    return &cell_buf;
}
/// 스냅샷이 담을 수 있는 최대 셀 수. 격자가 이걸 넘으면 아래쪽이 잘려 영영 안 그려지므로,
/// 호출자가 `fit()` 단계에서 clamp 해야 한다.
export fn cells_cap() u32 {
    return cell_buf.len / 20;
}
export fn glyph_ptr() [*]u8 {
    return &glyph_buf;
}
export fn match_ptr() [*]u8 {
    return @ptrCast(&match_buf);
}
/// 버퍼가 담을 수 있는 매치 수. `vt_find` 의 반환(총 개수)이 이걸 넘으면 앞의 이만큼만 있다.
export fn matches_cap() u32 {
    return max_matches;
}
export fn mem_bytes() u32 {
    return @intCast(@wasmMemorySize(0) * 65536);
}

export fn vt_new(cols: u32, rows: u32) ?*anyopaque {
    const core = alloc.create(terminal.TerminalCore) catch return null;
    core.* = terminal.TerminalCore.init(alloc, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
    }) catch {
        alloc.destroy(core);
        return null;
    };
    return @ptrCast(core);
}

export fn vt_write(h: *anyopaque, len: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.write(input_buf[0..@min(len, input_buf.len)]) catch return 1;
    return 0;
}

fn packColor(c: terminal.types.Color) u32 {
    return switch (c) {
        .default => 0,
        .indexed => |i| 0x0100_0000 | @as(u32, i),
        .rgb => |v| 0x0200_0000 | (@as(u32, v.r) << 16) | (@as(u32, v.g) << 8) | @as(u32, v.b),
    };
}

/// 셀을 16바이트 레코드로 평면화: [codepoint][fg][bg][flags|width]
export fn vt_snapshot(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const snap = core.renderSnapshot();
    var i: usize = 0;
    while (i < snap.cells.len and (i + 1) * 20 <= cell_buf.len) : (i += 1) {
        const cell = snap.cells[i];
        const cp: u32 = if (cell.codepoint == 0) ' ' else cell.codepoint;
        var flags: u32 = cell.width;
        if (cell.style.bold) flags |= 1 << 4;
        if (cell.style.italic) flags |= 1 << 5;
        if (cell.style.underline) flags |= 1 << 6;
        if (cell.style.reverse) flags |= 1 << 7;
        if (cell.continuation) flags |= 1 << 8;
        if (cell.link != 0) flags |= 1 << 9; // OSC 8 명시 링크가 걸린 셀
        const o = i * 20;
        std.mem.writeInt(u32, cell_buf[o..][0..4], cp, .little);
        std.mem.writeInt(u32, cell_buf[o + 4 ..][0..4], packColor(cell.style.foreground), .little);
        std.mem.writeInt(u32, cell_buf[o + 8 ..][0..4], packColor(cell.style.background), .little);
        std.mem.writeInt(u32, cell_buf[o + 12 ..][0..4], flags, .little);
        std.mem.writeInt(u32, cell_buf[o + 16 ..][0..4], cell.link, .little);
    }
    return @intCast(i);
}

export fn vt_cursor(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const snap = core.renderSnapshot();
    return (@as(u32, snap.cursor.row) << 16) | @as(u32, snap.cursor.col);
}

export fn cell_width(cp: u32) u32 {
    return terminal.cellWidth(@intCast(cp));
}

/// 프로시저럴 박스 글리프 — 폰트 없이 커버리지를 계산한다. RGBA 4바이트/픽셀.
/// 이 코드포인트를 코어가 직접 그리는가. 렌더러는 **폰트보다 먼저** 이걸 묻는다.
export fn glyph_covers(cp: u32) u32 {
    return if (renderer.isTerminalSynthesizedCodepoint(cp)) 1 else 0;
}

/// 합성 글리프의 RGBA 커버리지를 `glyph_ptr()`에 채우고 불투명 픽셀 수를 돌려준다.
///
/// `box_glyph`만 부르지 않고 **`renderer.synthesizeTerminalGlyph` 를 부른다** — 그게 합성 dispatch의
/// 단일 출처라서 블록·파워라인·브라유·모자이크까지 본체와 같은 집합을 덮는다(앱 chrome 아이콘만
/// 빠진다 — UI 자산이라 터미널에 안 나오고, 그 테이블이 wasm 을 91 KB 키운다). 박스만 부르면
/// 나머지는 조용히 폰트로 넘어가, Nerd Font 가 없는 브라우저에서 파워라인이 깨진다.
export fn glyph_box(cp: u32, w: u32, h: u32) u32 {
    if (w == 0 or h == 0 or w * h * 4 > glyph_buf.len) return 0;
    return renderer.synthesizeTerminalGlyph(cp, w, h, w * 4, glyph_buf[0 .. w * h * 4]) orelse 0;
}

/// 측정 probe 의 폭. **자동 줄바꿈 지점이 곧 측정 한계다** — 텍스트가 이보다 넓으면 wrap 해
/// 커서가 되감기고 작은 값이 나온다(오류 없이). 512 는 `fit()` 이 낼 수 있는 격자(4K 최대화
/// ≈457)보다 넓고, 데모의 줄 편집기가 재는 한 줄도 넉넉히 덮는다.
const probe_cols: u16 = 512;
/// probe 의 행 수. **wrap 을 이용해 누적한다** — 폭이 한 줄을 넘으면 다음 줄로 넘어가므로
/// `row * cols + col` 이 총 셀 수다. 1행이면 wrap 이 스크롤로 흡수돼 작은 값이 조용히 나온다.
/// 512×16 = 8,192 셀까지 정확하고, 그보다 긴 텍스트는 아래에서 overflow 로 알린다.
const probe_rows: u16 = 16;
/// `measure_cells` 가 폭을 셀 수 없을 때 돌려주는 값(probe 를 넘겨 wrap 했다).
const measure_overflow: u32 = 0xffff_ffff;

/// 측정이 실패했음을 나타내는 값. JS 가 이 값을 확인한다.
export fn measure_overflow_value() u32 {
    return measure_overflow;
}

/// 측정 전용 1행 코어(재사용). 텍스트를 쓴 뒤 커서 col이 곧 **셀 폭**이다 — grapheme cluster가
/// 합쳐지는지(ZWJ·VS16·국기), 동아시아 폭이 2인지가 전부 여기 반영된다.
var probe: ?*terminal.TerminalCore = null;
/// 측정 probe가 메인 코어와 **같은 폭 정책**을 쓰게 하는 미러. 이게 없으면 `vt_set_ambiguous_wide`가
/// 화면에는 반영되는데 `measure_cells`에는 안 반영돼, 렌더 폭과 측정 폭이 갈린다.
var probe_ambiguous: bool = false;

export fn measure_cells(len: u32) u32 {
    if (probe == null) {
        const core = alloc.create(terminal.TerminalCore) catch return 0;
        core.* = terminal.TerminalCore.init(alloc, .{ .cols = probe_cols, .rows = probe_rows }) catch {
            alloc.destroy(core);
            return 0;
        };
        probe = core;
    }
    const core = probe.?;
    core.ambiguous_wide = probe_ambiguous;
    core.write("\x1b[2J\x1b[H") catch return 0;
    core.write(input_buf[0..@min(len, input_buf.len)]) catch return 0;
    const snap = core.renderSnapshot();
    // 마지막 행까지 갔으면 스크롤로 앞부분이 사라졌을 수 있다 — 셀 수 없다고 알린다.
    if (snap.cursor.row + 1 >= probe_rows) return measure_overflow;
    return @as(u32, snap.cursor.row) * probe_cols + snap.cursor.col;
}

/// 그 텍스트가 만든 첫 셀의 base codepoint와 grapheme 여부(0=단일, 1=cluster).
export fn measure_first_cell(len: u32) u32 {
    const n = measure_cells(len);
    if (n == 0) return 0;
    const snap = probe.?.renderSnapshot();
    if (snap.cells.len == 0) return 0;
    const c = snap.cells[0];
    return (@as(u32, if (c.grapheme_id != 0) 1 else 0) << 24) | @as(u32, c.codepoint);
}

var link_buf: [2048]u8 = undefined;
export fn link_ptr() [*]u8 {
    return &link_buf;
}

/// OSC 8 명시 링크의 URI를 id로 조회한다. `link_store`를 직접 읽으므로 **경로 해석이 없다** —
/// `openableLinkAt`(자동 감지)는 file_path 판정에서 `std.c.access`에 도달해 wasm에서 libc를 요구한다.
export fn link_uri(h: *anyopaque, id: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    if (id == 0 or id > core.link_store.items.len) return 0;
    const uri = core.link_store.items[id - 1];
    const n = @min(uri.len, link_buf.len);
    @memcpy(link_buf[0..n], uri[0..n]);
    return @intCast(n);
}

// ── 스크롤 ────────────────────────────────────────────────
export fn vt_scroll(h: *anyopaque, delta_up: i32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.scrollViewport(@intCast(delta_up));
}
export fn vt_scroll_bottom(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.scrollToBottom();
}
/// 뷰포트가 바닥에서 위로 올라간 행 수. 0이면 활성 화면을 보고 있다.
///
/// 예전에는 `vt_scroll_state` 하나가 `(offset << 16) | len` 으로 둘을 실어 보냈는데, 각 필드가
/// 0xffff 로 잘려 **스크롤백이 65535 행을 넘으면 위치가 어긋났다**(`scrollback: 100000` 은
/// 실제로 쓰는 설정이다 — `docs/wasm-portability.md` §5.2 가 63.94MB 로 측정한 그 값이다).
/// 절대 행으로 스크롤하는 API(`scrollToLine`)가 이 값으로 델타를 계산하므로 정밀해야 한다.
export fn vt_view_offset(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    return @intCast(core.view_offset);
}
/// 스크롤백에 쌓인 행 수 = `view_offset` 의 최대값.
///
/// **지연된 재-wrap 을 먼저 끝낸다.** 폭이 바뀌면 스크롤백 행 수가 달라지는데 그 재-wrap 은
/// 지연된다(`screen.rewrap_pending`). `scrollbackLen()` 은 그걸 강제하지 않으므로 리사이즈
/// 직후에는 옛 폭 기준 행 수가 나온다 — 40→20 열에서 27 행이 57 행이 되는데 30 을 보고했다
/// (실측). 그 값으로 `scrollToTop` 이 델타를 잡으면 절반만 올라간다. `scrollViewport` 는
/// 이미 같은 이유로 진입할 때 재-wrap 을 끝낸다.
export fn vt_scrollback_len(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.scrollViewport(0); // 재-wrap 만 유발한다 — 델타 0 이라 위치도 dirty 도 안 바뀐다
    return @intCast(core.scrollbackLen());
}
/// 화면을 지운다(⌘K). 반환 1은 **셸에 form feed(^L)를 보내야 한다**는 뜻이다 —
/// OSC 133 프롬프트 상태에서만 전체를 비우고 커서를 홈으로 두므로, 셸이 프롬프트를 맨 위에
/// 다시 그려야 화면이 완성된다(`src/platform/macos/app_session.zig` 의 `.clear_screen` 과 같은 계약).
/// alt screen·비프롬프트에서는 0 — 커서를 안 옮기고 스크롤백과 커서 위 행만 비운다.
export fn vt_clear(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    return if (core.clearScreen()) 1 else 0;
}

// ── 검색 ──────────────────────────────────────────────────
/// `input_ptr()` 에 needle(UTF-8)을 쓰고 길이를 넘긴다. **반환은 총 매치 수**이고, 버퍼에는
/// 앞의 `matches_cap()` 건까지만 담긴다 — UI 가 "1/2371" 처럼 총량을 보여줄 수 있어야 한다.
///
/// 좌표는 **절대 행**이다(0 = 스크롤백 최상단). 뷰포트 좌표가 아니라서 스크롤해도 유효하고,
/// `vt_scroll` 로 해당 행에 가져다 놓으면 그대로 선택할 수 있다.
export fn vt_find(h: *anyopaque, needle_len: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const n = @min(needle_len, input_buf.len);
    var list: std.ArrayList(terminal.types.Match) = .empty;
    defer list.deinit(alloc);
    core.findMatches(alloc, input_buf[0..n], &list) catch return 0; // OOM 이면 매치 없음
    const kept = @min(list.items.len, max_matches);
    for (list.items[0..kept], 0..) |m, i| {
        match_buf[i * 4 + 0] = @intCast(m.start.row);
        match_buf[i * 4 + 1] = m.start.col;
        match_buf[i * 4 + 2] = @intCast(m.end.row);
        match_buf[i * 4 + 3] = m.end.col;
    }
    return @intCast(list.items.len);
}

// ── 키 인코딩 ─────────────────────────────────────────────
var key_buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
export fn key_ptr() [*]u8 {
    return &key_buf;
}

/// 브라우저 KeyboardEvent를 maru `KeyEvent`로 옮겨 **호스트로 보낼 바이트**를 인코딩한다.
/// DECCKM(application_cursor_keys)·DECKPAM을 코어에서 읽어 반영한다 — 같은 화살표가 모드에 따라
/// `CSI A`와 `SS3 A`로 갈린다. 인코딩 길이를 반환(0=보낼 것 없음).
export fn vt_key(h: *anyopaque, kind: u32, cp: u32, mods: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const key: terminal.input.Key = switch (kind) {
        0 => .{ .char = @intCast(cp) },
        1 => .enter,
        2 => .escape,
        3 => .tab,
        4 => .backspace,
        5 => .arrow_up,
        6 => .arrow_down,
        7 => .arrow_left,
        8 => .arrow_right,
        9 => .home,
        10 => .end,
        11 => .insert,
        12 => .delete,
        13 => .page_up,
        14 => .page_down,
        15 => .{ .function = @intCast(cp) },
        else => return 0,
    };
    const ev: terminal.input.KeyEvent = .{
        .key = key,
        .modifiers = .{
            .shift = (mods & 1) != 0,
            .control = (mods & 2) != 0,
            .option = (mods & 4) != 0,
            .command = (mods & 8) != 0,
        },
    };
    const out = terminal.input.encodeKey(ev, &key_buf, .{
        .application_cursor_keys = core.application_cursor_keys,
        .application_keypad = core.application_keypad,
    }) catch return 0;
    return @intCast(out.len);
}

// ── 선택(블록 포함) ───────────────────────────────────────
var sel_buf: [5]u32 = undefined;
export fn sel_ptr() [*]u32 {
    return &sel_buf;
}
export fn sel_start(h: *anyopaque, row: u32, col: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectionStart(@intCast(row), @intCast(col));
}
export fn sel_extend(h: *anyopaque, row: u32, col: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectionExtend(@intCast(row), @intCast(col));
}
export fn sel_word(h: *anyopaque, row: u32, col: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectWordAt(@intCast(row), @intCast(col), " \t\"'`()[]{}<>,;:");
}
export fn sel_line(h: *anyopaque, row: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectLineAt(@intCast(row));
}
export fn sel_all(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectAll();
}
export fn sel_clear(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.selectionClear();
}
/// Option 드래그 = 사각(블록) 선택. 코어가 span에 `block` 플래그로 실어 준다.
export fn sel_block(h: *anyopaque, on: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.setSelectionBlock(on != 0);
}
/// 선택 텍스트를 뽑는다(클립보드 복사용). **코어가 직접 만든다** — 셀에서 JS 가 재구성하면
/// grapheme cluster 를 base codepoint 로만 복원하고 soft-wrap 이음도 놓친다.
/// `paste_buf` 를 재사용한다(복사와 붙여넣기는 동시에 일어나지 않는다).
export fn sel_text(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const found = core.extractSelection(alloc) catch return 0;
    const text = found orelse return 0;
    defer alloc.free(text);
    const n = @min(text.len, paste_buf.len);
    @memcpy(paste_buf[0..n], text[0..n]);
    return @intCast(n);
}

/// 선택이 있으면 1을 주고 sel_buf에 [start_row, start_col, end_row, end_col, block]을 쓴다.
export fn sel_span(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const span = core.selectionViewportSpan() orelse return 0;
    sel_buf[0] = span.start.row;
    sel_buf[1] = span.start.col;
    sel_buf[2] = span.end.row;
    sel_buf[3] = span.end.col;
    sel_buf[4] = if (span.block) 1 else 0;
    return 1;
}

// ── 그리드/설정 (레이아웃을 바꾸는 것들) ──────────────────
export fn vt_resize(h: *anyopaque, cols: u32, rows: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.resize(@intCast(cols), @intCast(rows)) catch return 1;
    return 0;
}
/// EAW Ambiguous를 2셀로 볼지(`text.ambiguous-width`). **레이아웃을 통째로 바꾼다** — 동아시아
/// 로캘의 박스/기호가 1↔2셀로 갈린다. write 전에 설정해야 putCell이 읽는다.
export fn vt_set_ambiguous_wide(h: *anyopaque, on: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.ambiguous_wide = on != 0;
    probe_ambiguous = on != 0; // 측정 probe도 같은 정책으로 — 렌더 폭과 측정 폭이 갈리면 안 된다
    if (probe) |pc| pc.ambiguous_wide = probe_ambiguous;
}
export fn vt_set_max_scrollback(h: *anyopaque, lines: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.setMaxScrollback(lines);
}
export fn vt_set_cursor_shape(h: *anyopaque, shape: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.setDefaultCursorShape(switch (shape) {
        1 => .underline,
        2 => .bar,
        else => .block,
    });
}
export fn vt_set_default_colors(h: *anyopaque, fg: u32, bg: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.setDefaultColors(
        .{ .r = @intCast((fg >> 16) & 0xff), .g = @intCast((fg >> 8) & 0xff), .b = @intCast(fg & 0xff) },
        .{ .r = @intCast((bg >> 16) & 0xff), .g = @intCast((bg >> 8) & 0xff), .b = @intCast(bg & 0xff) },
    );
}
/// 16색 팔레트(테마). rgb는 0xRRGGBB, present=0이면 그 자리는 기본값.
var palette_slots: [16]?terminal.types.Rgb = .{null} ** 16;
export fn vt_palette_slot(idx: u32, rgb: u32, present: u32) void {
    if (idx >= 16) return;
    palette_slots[idx] = if (present != 0)
        .{ .r = @intCast((rgb >> 16) & 0xff), .g = @intCast((rgb >> 8) & 0xff), .b = @intCast(rgb & 0xff) }
    else
        null;
}
export fn vt_apply_palette(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.setConfigPalette(palette_slots);
}

// ── 호스트로 보낼 응답 (DA·CPR·OSC 질의) ──────────────────
/// **없으면 터미널이 질의에 답하지 못한다.** app은 매 write 후 이걸 PTY로 보내고 clear한다.
export fn vt_response(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const r = core.pendingResponse();
    const n = @min(r.len, resp_buf.len);
    @memcpy(resp_buf[0..n], r[0..n]);
    return @intCast(n);
}
export fn vt_clear_response(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.clearResponse();
}
var resp_buf: [4096]u8 = undefined;
export fn resp_ptr() [*]u8 {
    return &resp_buf;
}

// ── 입력: paste·마우스·포커스 ─────────────────────────────
var paste_buf: [1 << 18]u8 = undefined;
export fn paste_ptr() [*]u8 {
    return &paste_buf;
}
/// bracketed paste 래핑까지 코어가 한다(모드가 꺼져 있으면 원문 그대로).
export fn vt_paste(h: *anyopaque, len: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const out = core.encodePaste(alloc, input_buf[0..@min(len, input_buf.len)]) catch return 0;
    defer alloc.free(out);
    const n = @min(out.len, paste_buf.len);
    @memcpy(paste_buf[0..n], out[0..n]);
    return @intCast(n);
}
export fn vt_report_mouse(h: *anyopaque, button: u32, col: u32, row: u32, pressed: u32, motion: u32, mods: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.reportMouse(@intCast(button), @intCast(col), @intCast(row), 0, 0, pressed != 0, motion != 0, @intCast(mods));
}
export fn vt_report_focus(h: *anyopaque, gained: u32) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.reportFocus(gained != 0);
}

// ── 상태 읽기 ─────────────────────────────────────────────
export fn vt_title(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const t = core.windowTitle();
    const n = @min(t.len, link_buf.len);
    @memcpy(link_buf[0..n], t[0..n]);
    return @intCast(n);
}
export fn vt_take_bell(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    return if (core.takeBell()) 1 else 0;
}
/// 렌더·입력이 분기해야 하는 모드 비트: 1=bracketed paste, 2=application cursor,
/// 4=application keypad, 8=ambiguous wide, 마우스 트래킹은 상위 4비트(0=off).
export fn vt_modes(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    var m: u32 = 0;
    if (core.bracketedPasteEnabled()) m |= 1;
    if (core.application_cursor_keys) m |= 2;
    if (core.application_keypad) m |= 4;
    if (core.ambiguous_wide) m |= 8;
    m |= @as(u32, @intFromEnum(core.mouse_tracking)) << 8;
    return m;
}
/// 커서 표현: shape(0=block,1=underline,2=bar) | blink<<8 | visible<<9
export fn vt_cursor_style(h: *anyopaque) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    const snap = core.renderSnapshot();
    const shape: u32 = switch (snap.cursor_shape) {
        .block => 0,
        .underline => 1,
        .bar => 2,
    };
    return shape | (@as(u32, if (snap.cursor_blink) 1 else 0) << 8) |
        (@as(u32, if (snap.cursor.visible) 1 else 0) << 9);
}

export fn vt_free(h: *anyopaque) void {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.deinit();
    alloc.destroy(core);
}
