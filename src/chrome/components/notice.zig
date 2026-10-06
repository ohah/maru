//! Notice — 손상/오류 알림 모달(키보드 전용, hit-test 없음). chrome 컴포넌트 **계약의 exemplar**:
//!   State(순수 데이터+전이) + view(state, props, tokens → ChromeDraw, 순수) + handle(event, *state → ?Action).
//! 규칙(기존 palette/find 패턴 승계): State는 렌더를 모르고, view는 State를 읽기만, handle은 State를
//! mutate + intent(Action) 반환. 라이프사이클(언제 열고)은 host가 소유. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

/// 순수 상태 — message 슬롯 + open 플래그. host(또는 복원 손상 감지)가 show를 부른다.
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",

    pub fn show(self: *State, message: []const u8) void {
        self.message = message;
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리(여기선 닫기 외 부수효과 없음).
pub const Action = enum { dismissed };

/// 키 이벤트 처리. 열려 있을 때만 동작 — notice는 **비-인터랙티브 정보 토스트**(자동 닫힘 타이머 없음)라 **아무 키로나
/// 닫고** `dismissed`를 돌려준다(Enter/Esc 전용이던 것을 넓힘 — 그 외 키는 소비만 하고 안 닫혀, 토스트가 떠 있는 동안
/// 키 입력이 막힌 것처럼 보이던 회귀를 푼다). 닫는 키는 host가 소비한다(셸로 안 흘림 — 토스트 확인 제스처). 닫혀 있으면
/// null(라우팅 안 가로챔). host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 mouse().
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    _ = k; // 키 종류 무관 — 모든 키가 동일하게 토스트를 닫는다(입력 대상이 아닌 정보 토스트)
    if (!state.open) return null;
    state.dismiss();
    return .dismissed;
}

/// 메시지를 중앙 모달 박스로 그린다(상자 안쪽 폭에서 줄을 나눈다 — `modal_box.wrapLine`) — 박스 기하·폭 clamp·soft-lock 가드·배경 quad+테두리는 modal_box.view
/// 단일 출처에 위임한다(notice/confirm 공유). 안 열렸으면 무동작. 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    try modal_box.view(&.{.{ .text = state.message, .role = .surface_fg }}, p, tk, arena, out);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// Notice는 chrome 컴포넌트 계약의 첫 구현이라, 헤드리스로 (1) 상태 전이 (2) 입력→intent (3) view가
// 기대 ops를 내는지를 증명한다 — macOS·렌더 없이.

test "notice state: show/dismiss" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("손상됨");
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("손상됨", s.message);
    s.dismiss();
    try std.testing.expect(!s.open);
}

test "notice handle: 아무 키로나 닫고 dismissed, 닫힘이면 null" {
    var s = State{};
    try std.testing.expect(handle(.{ .key = .enter }, &s) == null); // 닫혀 있으면 무동작
    s.show("x");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .escape }, &s).?); // Esc로 닫힘
    try std.testing.expect(!s.open);
    s.show("y");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .enter }, &s).?); // Enter로 닫힘
    try std.testing.expect(!s.open);
    // 평문 글자도 토스트를 닫는다(비-인터랙티브 토스트 — Enter/Esc 전용이 아니다, 회귀 수정).
    s.show("z");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .char, .codepoint = 'a' }, &s).?);
    try std.testing.expect(!s.open);
}

test "notice view: 닫힘이면 ops 0, 열림이면 quad+text(modal)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show("file corrupt");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("file corrupt", out.items[1].text.runs[0].text);
    // 모달 박스는 전체 작업영역(사이드바·titlebar 제외, dock 포함) 안, 화면 중앙쯤. 박스 기하 엣지케이스(soft-lock 가드·폭 clamp·
    // rich 패딩 침범)는 modal_box.zig 테스트가 단일 출처로 커버한다(notice/confirm 공유 — 여기선 위임만 확인).
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
    try std.testing.expect(out.items[0].quad.rect.w > 0);
}

// 긴 notice 는 상자 안쪽 폭에서 줄을 나눈다 — 안 나누면 작업영역보다 긴 줄(host 연결 실패 안내처럼 원인 코드가 끼는 것)이
// 상자 밖으로 넘쳐 창 가장자리에서 잘렸다(2026-10-06 실제 앱 캡처). 창 폭·사이드바·rich 패딩을 바꿔 가며 본다:
// 모든 조각이 상자 안쪽 **왼쪽 끝에서 시작해** 안쪽에서 끝나고, 한 줄씩 아래로 서며, 상자 높이가 조각 수에 정확히 맞고,
// 색 역할이 그대로이며, 공백을 뺀 내용이 하나도 안 빠지고, 줄은 **채울 만큼 채운다**(다음 낱말을 붙이면 넘친다),
// 줄 상한을 넘으면 마지막 줄이 「…」로 끝난다.
test "notice view: 긴 메시지는 상자 안쪽 폭에서 줄을 나눠 내용이 안 잘리고, 상한을 넘으면 「…」로 끝난다" {
    const overlay_input = @import("overlay_input.zig");
    const i18n = @import("../../i18n.zig");
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const cw: i32 = 8;
    const ch: i32 = 16;
    const margin: i32 = @intCast(tk.space.modal_margin_cells);
    var en_buf: [512]u8 = undefined;
    var ko_buf: [512]u8 = undefined;
    const detail = "stage=connect reason=endpoint_denied";
    const messages = [_][]const u8{
        // 제품 문구 그대로(i18n 키 + 실제 원인 형식) — 한국어·영어.
        i18n.format(&ko_buf, i18n.tIn(.ko, .app_host_connect_failed), &.{.{ .s = detail }}),
        i18n.format(&en_buf, i18n.tIn(.en, .app_host_connect_failed), &.{.{ .s = detail }}),
        // 공백 없는 긴 토큰은 글자 경계에서 자른다.
        "https://example.com/a/very/long/path/without/any/spaces/that/must/still/be/broken/at/glyph/boundaries/index.html",
        // LSP 오류 메시지가 그대로 끼는 notice(줄바꿈·CRLF 가 섞인다) — `\n` 에서 나누고 `\r` 은 칸을 안 차지한다.
        "rename failed: the server responded with an error\r\nunknown symbol at line 12\r\n",
    };
    var wrapped_cases: usize = 0;
    var truncated_cases: usize = 0;
    var backing_w: u32 = 160;
    while (backing_w <= 1200) : (backing_w += 40) for ([_]u32{ 0, 180 }) |sidebar| for ([_]u16{ 0, 12 }) |pad| {
        if (sidebar + 40 >= backing_w) continue;
        const p = props.ChromeProps{
            .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = sidebar, .backing_width_px = backing_w, .backing_height_px = 600 },
            .shape = .{ .modal_padding_px = pad },
        };
        for (messages) |msg| {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var out: std.ArrayList(draw.Op) = .empty;
            var s = State{};
            s.show(msg);
            try view(&s, p, &tk, arena, &out);
            if (out.items.len == 0) continue; // 상자를 못 세우는 폭(soft-lock 가드) — modal_box 테스트가 본다
            const rect = out.items[0].quad.rect;
            const inner_left = rect.x + margin * cw;
            const inner_right = rect.x + @as(i32, @intCast(rect.w)) - margin * cw;
            const inner_cols: u32 = @intCast(@divTrunc(inner_right - inner_left, cw));
            // 안쪽이 2칸(넓은 글자 하나)도 안 되는 상자는 나눌 수 없다 — `wrapLine` 이 통째로 돌려주는 갈래(작업영역 약
            // 6칸 이하, 실제 창 크기에선 닿지 않는다). 그 아래는 「상자를 세우되 글자는 넘친다」는 soft-lock 가드의 몫이다.
            if (inner_cols < 2) continue;
            // 상자는 작업영역(사이드바 오른쪽) 안이고, rich 패딩까지 넣어도 그 안이다.
            try std.testing.expect(rect.x - @as(i32, pad) >= @as(i32, @intCast(sidebar)));
            try std.testing.expect(rect.x + @as(i32, @intCast(rect.w)) + @as(i32, pad) <= @as(i32, @intCast(backing_w)));
            const pieces = out.items[1..];
            try std.testing.expectEqual(@as(u32, @intCast((pieces.len + 2) * @as(usize, @intCast(ch)))), rect.h); // 높이 = 조각 수 + 위아래 여백
            var joined: std.ArrayList(u8) = .empty;
            for (pieces, 0..) |op, i| {
                const t = op.text;
                const piece = t.runs[0].text;
                const cols: i32 = @intCast(overlay_input.displayCols(piece));
                try std.testing.expectEqual(inner_left, t.origin.x); // 왼쪽 정렬
                try std.testing.expect(t.origin.x + cols * cw <= inner_right); // 상자 안쪽에서 끝난다
                try std.testing.expectEqual(rect.y + ch * @as(i32, @intCast(i + 1)), t.origin.y); // 한 줄씩 아래로
                try std.testing.expectEqual(tokens.ColorRole.surface_fg, t.role); // 이어진 조각도 같은 역할
                try std.testing.expect(std.mem.indexOfScalar(u8, piece, '\r') == null and std.mem.indexOfScalar(u8, piece, '\n') == null);
                // 채울 만큼 채운다 — 다음 조각의 첫 낱말(공백 앞까지, 없으면 첫 글자)을 붙이면 넘친다. 원문 줄바꿈 자리는 예외.
                if (i + 1 < pieces.len) {
                    const next = pieces[i + 1].text.runs[0].text;
                    const word_end = std.mem.indexOfScalar(u8, next, ' ') orelse next.len;
                    const first_cp = std.unicode.utf8ByteSequenceLength(next[0]) catch 1;
                    const glued = std.mem.indexOf(u8, msg, piece) != null and std.mem.indexOf(u8, msg, next) != null and blk: {
                        // 두 조각이 원문에서 `\r\n`/`\n` 으로 갈렸으면 채움을 묻지 않는다.
                        const at = std.mem.indexOf(u8, msg, piece).? + piece.len;
                        break :blk !(at < msg.len and (msg[at] == '\n' or msg[at] == '\r'));
                    };
                    if (glued) {
                        const with_word = overlay_input.displayCols(piece) + 1 + overlay_input.displayCols(next[0..word_end]);
                        const with_glyph = overlay_input.displayCols(piece) + overlay_input.displayCols(next[0..@min(first_cp, next.len)]);
                        try std.testing.expect(with_word > inner_cols or with_glyph > inner_cols);
                    }
                }
                for (piece) |b| if (b != ' ') try joined.append(arena, b);
            }
            var expect: std.ArrayList(u8) = .empty;
            for (msg) |b| if (b != ' ' and b != '\r' and b != '\n') try expect.append(arena, b);
            const last = pieces[pieces.len - 1].text.runs[0].text;
            if (std.mem.endsWith(u8, last, "…")) {
                // 상한에 걸렸다 — 줄 수는 상한, 보인 것은 원문의 앞부분이다.
                try std.testing.expectEqual(@as(usize, 6), pieces.len);
                const shown = joined.items[0 .. joined.items.len - "…".len];
                try std.testing.expect(std.mem.startsWith(u8, expect.items, shown));
                truncated_cases += 1;
            } else {
                try std.testing.expectEqualStrings(expect.items, joined.items); // 하나도 안 빠졌다
            }
            if (pieces.len > 1) wrapped_cases += 1;
        }
    };
    try std.testing.expect(wrapped_cases > 50); // 실제로 나뉜 경우를 많이 봤다(공허한 통과 방지)
    try std.testing.expect(truncated_cases > 0); // 아주 좁은 창에선 상한에 걸린다

    // 대조: 들어가는 메시지는 예전 그대로 한 줄 한 조각이다.
    const wide = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(draw.Op) = .empty;
    var s = State{};
    s.show("file corrupt");
    try view(&s, wide, &tk, arena_state.allocator(), &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("file corrupt", out.items[1].text.runs[0].text);
    // `\n` 이 섞이면 상자 폭은 **가장 긴 줄**로 잰다 — 전체 길이로 재면 줄은 짧아도 상자가 작업영역 폭까지 넓어졌다.
    out.clearRetainingCapacity();
    s.show("short line\nanother short line");
    try view(&s, wide, &tk, arena_state.allocator(), &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, @intCast(("another short line".len + 2 * @as(usize, @intCast(margin))) * 8)), out.items[0].quad.rect.w);
}

// 깨진 UTF-8 은 렌더러(`text_layout.decodeCodepoint`)와 같은 단위로 걷는다 — lead 바이트 길이로 묶으면 깨진 바이트
// 뒤의 온전한 글자가 그 덩어리에 먹혀 줄이 그 글자 **중간**에서 끊겼다. 모든 조각이 온전한 UTF-8 경계에서 시작·끝난다.
test "notice view: 깨진 바이트가 섞여도 줄을 온전한 글자 경계에서 나눈다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const msg = "경로 /tmp/\xE0가나다라마바사아자차카타파하/\xFF한글파일이름이아주길다.txt 를 열 수 없습니다";
    var backing_w: u32 = 120;
    var checked: usize = 0;
    while (backing_w <= 400) : (backing_w += 8) {
        const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = backing_w, .backing_height_px = 600 } };
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var out: std.ArrayList(draw.Op) = .empty;
        var s = State{};
        s.show(msg);
        try view(&s, p, &tk, arena_state.allocator(), &out);
        for (out.items[1..]) |op| {
            const piece = op.text.runs[0].text;
            if (std.mem.endsWith(u8, piece, "…")) continue;
            // 조각 시작·끝이 원문에서 온전한 글자 경계다 — 「가」(EA B0 80) 같은 글자를 반으로 가르지 않는다.
            const start = @intFromPtr(piece.ptr) - @intFromPtr(s.message.ptr);
            const end = start + piece.len;
            for ([_]usize{ start, end }) |at| if (at < msg.len) {
                try std.testing.expect(msg[at] & 0xC0 != 0x80); // 이어짐 바이트가 아니다
            };
            checked += 1;
        }
    }
    try std.testing.expect(checked > 30);
}
