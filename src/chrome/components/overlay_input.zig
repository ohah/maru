//! 단일행 입력 오버레이(find·palette)의 **공유 기반** — 컴포넌트가 아니라 두 입력 오버레이가 같은 모델을 쓰게 하는
//! neutral 헬퍼다. (1) `OverlayInput`: IME 조합을 보존하는 검색어 입력(query+preedit) 상태·전이, (2) `displayCols`:
//! UTF-8 표시 폭(EAW), (3) `panelLayout`: palette의 창-중앙 패널 레이아웃, (4) `findLayout`: find의 활성 pane 우상단
//! 레이아웃(p.active_pane 경계). 이주 전엔 find.zig·palette.zig에 같은 코드가
//! 복붙돼 있었다(C1 리뷰 cleanup으로 단일 출처화). 의존은 std + sibling chrome(draw/props) + ../../width.zig뿐
//! (chrome neutral). 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5.

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const width = @import("../../width.zig"); // Unicode 셀 폭(EAW) — 한글/CJK=2칸.

/// UTF-8 바이트열의 **표시 폭**(셀 칸 수) = Σ max(1, cellWidth(cp)). 한글/CJK는 2칸, 결합 문자는 1칸으로 친다
/// (placeText·coretext_frame_builder의 `@max(1, cellWidth)`와 같은 규약). 코드포인트 수가 아니다 — 한글을 1칸으로
/// 세면 caret/우측정렬이 글자 중간에 박혀 잘려 보인다(회귀의 루트커즈). caret 위치·바인딩 우측정렬에 쓴다.
pub fn displayCols(bytes: []const u8) u32 {
    const utf8 = std.unicode.Utf8View.init(bytes) catch return @intCast(bytes.len); // 손상 UTF-8은 바이트 수로 폴백
    var it = utf8.iterator();
    var cols: u32 = 0;
    while (it.nextCodepoint()) |cp| cols += @max(1, width.cellWidth(cp));
    return cols;
}

/// `bytes`를 표시 폭 `max_cols`칸 이내로 자른다(EAW 기준 — displayCols의 짝). 넘치면 끝에 `…`(1칸)를 붙여
/// 잘렸음을 보인다(글자 예산=max_cols-1). 안 넘치면 원본을 그대로 돌려준다(복사 없음). 자를 때만 arena alloc.
/// 코드포인트 경계로만 자르므로 UTF-8이 깨지지 않는다. 세팅 폼의 긴 값(폰트 패밀리 등)을 control 폭 안에 가두는 데 쓴다.
pub fn truncateToCols(arena: std.mem.Allocator, bytes: []const u8, max_cols: u32) ![]const u8 {
    if (displayCols(bytes) <= max_cols) return bytes;
    if (max_cols == 0) return "";
    const budget = max_cols - 1; // "…" 1칸 자리를 남긴다
    const utf8 = std.unicode.Utf8View.init(bytes) catch return bytes; // 손상 UTF-8은 자르지 않음(원본)
    var it = utf8.iterator();
    var cols: u32 = 0;
    var end: usize = 0;
    while (it.nextCodepoint()) |cp| {
        const w = @max(1, width.cellWidth(cp));
        if (cols + w > budget) break;
        cols += w;
        end = it.i; // 이 코드포인트 끝(다음 시작) — 포함 경계
    }
    return std.fmt.allocPrint(arena, "{s}…", .{bytes[0..end]});
}

/// 검색어(query) + IME 조합(preedit) 입력 모델. **커밋과 조합은 독립** — `appendChar`는 preedit를 건드리지 않고,
/// preedit는 `setPreedit`가 단일 관리한다(터미널 core와 같은 모델). 이주 전 두 컴포넌트가 `appendChar`에서 preedit를
/// 비우다가 IME 멀티-문자 흐름(커밋 N + 조합 N+1)에서 다음 조합을 지워 "조합 안 보임" 버그를 냈다 — 그 모델을 여기
/// 단일 출처로 못 박는다. query·preedit는 ArrayList라 소유자(컴포넌트 State)가 deinit한다.
pub const OverlayInput = struct {
    query: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *OverlayInput, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.preedit.deinit(allocator);
    }

    /// 열기/리셋용 — 검색어·조합을 비운다(capacity 유지). 컴포넌트 show()가 고유 상태 리셋과 함께 부른다.
    pub fn clear(self: *OverlayInput) void {
        self.query.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
    }

    /// 검색어에 확정 글자 추가(UTF-8 인코딩). **preedit는 안 건드린다**(위 모델). 인코딩 불가/OOM은 무시.
    pub fn appendChar(self: *OverlayInput, allocator: std.mem.Allocator, cp: u21) !void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.query.appendSlice(allocator, utf8[0..n]);
    }

    /// IME 조합 중(marked) 텍스트를 교체한다(빈 bytes = 조합 해제). session.imeMarked가 해당 오버레이 열림일 때 부른다.
    pub fn setPreedit(self: *OverlayInput, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(allocator, bytes);
    }

    /// 조합 중(preedit) 텍스트를 검색어로 확정한다(query 뒤에 붙이고 preedit 비움) — 포커스 상실 등에서 조합을 잃지
    /// 않게. 확정한 게 있으면 true(호출자가 재검색/재필터). 빈 조합이면 false. OOM이면 조합을 버리고 false(반쪽 안 남김).
    pub fn commitPreedit(self: *OverlayInput, allocator: std.mem.Allocator) bool {
        if (self.preedit.items.len == 0) return false;
        self.query.appendSlice(allocator, self.preedit.items) catch {
            self.preedit.clearRetainingCapacity();
            return false;
        };
        self.preedit.clearRetainingCapacity();
        return true;
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중). 빈 쿼리면 무동작.
    pub fn backspace(self: *OverlayInput) void {
        if (self.query.items.len == 0) return;
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1; // continuation 바이트 건너뜀
        self.query.shrinkRetainingCapacity(cut);
    }

    /// 검색어의 표시 폭(EAW). caret 열 = prompt_cols + 이 값(조합중 preedit는 안 더한다 — 커서가 조합 글자를 덮음).
    pub fn queryCols(self: *const OverlayInput) u32 {
        return displayCols(self.query.items);
    }
};

pub const PanelLayout = struct { x: i32, y: i32, panel_cols: u32, cw: u32, ch: u32 };

/// 패널 **폭 산출 공유 코어** — panelLayout(palette 창-중앙)·findLayout(find pane 우상단)이 정렬만 달리하고 이걸
/// 함께 쓴다. 이 모듈의 존재 이유가 패널 레이아웃 복붙 제거(위 모듈 doc)이므로, 폭 규약(60·−4·2*pad)을 여기 한
/// 곳에만 둔다. region_w(가용 가로 px)/cw==0이면 null(영역 0칸 — 호출자 무동작). C4b 패딩: 폭 상한을 2*pad만큼
/// 줄인 가용 칸으로 panel_cols를 산출 — platform lowering이 배경 quad를 ±pad 확장한 뒤에도 박스가 영역에 들도록
/// 텍스트 폭을 양보한다(pad=0(tui)이면 무변화). 단 avail_cols==0(region_w < 2*pad, 1~3칸의 비정상적으로 좁은
/// 영역)이면 soft-lock 방지로 panel_cols=1을 강제하므로 ±pad 확장이 최대 pad만큼 경계를 침범할 수 있다 — bounded
/// 이고 '안 보이는 열린 모달'보다 작은 박스가 낫다는 절충(panelLayout·findLayout 양쪽 동일).
const PanelSize = struct { panel_cols: u32, panel_w: u32, cw: u32, ch: u32 };
fn panelSize(p: props.ChromeProps, region_w: u32) ?PanelSize {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    if (region_w / cw == 0) return null;
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (region_w -| 2 * pad) / cw;
    const panel_cols: u32 = @max(@min(@as(u32, 60), avail_cols -| 4), 1);
    return .{ .panel_cols = panel_cols, .panel_w = panel_cols * cw, .cw = cw, .ch = ch };
}

/// palette 패널 가로 레이아웃(사이드바 오른쪽, 상단-중앙) — **palette 전용**(find는 활성 pane 우상단 findLayout으로
/// 분리). 폭은 panelSize 공유. clamp로 panel_w ≤ term_w_px라 중앙배치 뺄셈이 안전. y는 상단에서 두 줄 아래.
pub fn panelLayout(p: props.ChromeProps) ?PanelLayout {
    const m = p.metrics;
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const sz = panelSize(p, term_w_px) orelse return null;
    const x = @as(i32, @intCast(m.sidebar_width_px)) + @as(i32, @intCast((term_w_px - sz.panel_w) / 2));
    const y = 2 * @as(i32, @intCast(sz.ch)); // 상단에서 두 줄 내려(기존 오버레이와 같은 위치)
    return .{ .x = x, .y = y, .panel_cols = sz.panel_cols, .cw = sz.cw, .ch = sz.ch };
}

/// find 오버레이 레이아웃 — **활성 pane 우상단**(브라우저/iTerm/VS Code 관례). palette의 창-중앙 panelLayout과
/// 분리: 검색·하이라이트가 활성 surface만 보므로(app_session.activeSurface) 바도 그 pane에 붙여 어느 분할을 검색
/// 중인지 시각적으로 맞춘다. 경계 = `p.active_pane`(platform active_pane_rect 미러); 미초기화(w==0)면 사이드바
/// 오른쪽 터미널 영역 전체로 폴백해 단일-pane·헤드리스 테스트에서도 안전. 폭은 panelSize 공유. 우측 정렬이라
/// 오른쪽 여백을 pad로 둬 **정상 폭에선** 우측 pane/divider를 안 침범한다 — 단 panelSize가 panel_cols=1을 강제하는
/// 비정상적으로 좁은 pane(panel_w+pad > 영역 폭)이면 우측 여백이 0으로 saturate돼 ±pad 확장이 최대 pad만큼 경계를
/// 넘을 수 있다(bounded, panelLayout과 동일 절충). y는 pane 상단 한 줄 아래 — 패널 높이는 한 칸이라 region.h는
/// 안 본다(2칸보다 낮은 극단적 pane이면 아래로 한 칸 넘칠 수 있으나 bounded).
pub fn findLayout(p: props.ChromeProps) ?PanelLayout {
    const m = p.metrics;
    // 활성 pane rect를 경계로. 미초기화(w==0)면 사이드바 오른쪽 터미널 영역 전체로 폴백(단일-pane/테스트 안전).
    const region: struct { x: u32, y: u32, w: u32 } = if (p.active_pane.w > 0)
        .{ .x = p.active_pane.x, .y = p.active_pane.y, .w = p.active_pane.w }
    else
        .{ .x = m.sidebar_width_px, .y = 0, .w = m.backing_width_px -| m.sidebar_width_px };
    const sz = panelSize(p, region.w) orelse return null; // 영역 0칸 — 무동작
    const pad: u32 = p.shape.modal_padding_px;
    // 우상단: 우측 정렬(오른쪽 여백 = pad라 정상 폭이면 lowering ±pad 확장 후에도 pane 안), 상단에서 한 줄 내려.
    const x = @as(i32, @intCast(region.x)) + @as(i32, @intCast(region.w -| sz.panel_w -| pad));
    const y = @as(i32, @intCast(region.y)) + @as(i32, @intCast(sz.ch));
    return .{ .x = x, .y = y, .panel_cols = sz.panel_cols, .cw = sz.cw, .ch = sz.ch };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "OverlayInput: appendChar(UTF-8)·backspace(코드포인트 경계)·preedit는 독립" {
    const allocator = std.testing.allocator;
    var in: OverlayInput = .{};
    defer in.deinit(allocator);

    try in.appendChar(allocator, 'a');
    try in.appendChar(allocator, 'b');
    try in.appendChar(allocator, '한'); // 3바이트
    try std.testing.expectEqual(@as(usize, 5), in.query.items.len);
    in.backspace(); // '한' 한 코드포인트(3바이트) 제거
    try std.testing.expectEqualStrings("ab", in.query.items);

    // appendChar는 조합(preedit)을 안 건드린다(커밋·조합 독립 — IME 멀티-문자 회귀 고정).
    try in.setPreedit(allocator, "\xea\xb0\x80"); // 조합 "가"
    try in.appendChar(allocator, 'c');
    try std.testing.expectEqualStrings("abc", in.query.items);
    try std.testing.expectEqualStrings("\xea\xb0\x80", in.preedit.items); // 조합 유지

    in.backspace();
    in.backspace();
    in.backspace();
    in.backspace(); // 빈 쿼리에서 추가 backspace 무동작
    try std.testing.expectEqual(@as(usize, 0), in.query.items.len);
    in.clear();
    try std.testing.expectEqual(@as(usize, 0), in.preedit.items.len);
}

test "OverlayInput: commitPreedit는 조합을 query로 확정·빈 조합이면 false" {
    const allocator = std.testing.allocator;
    var in: OverlayInput = .{};
    defer in.deinit(allocator);
    try in.appendChar(allocator, 'a');
    try in.setPreedit(allocator, "\xea\xb0\x80"); // 조합 "가"
    try std.testing.expect(in.commitPreedit(allocator)); // 확정 → "a가", preedit 비움
    try std.testing.expectEqualStrings("a\xea\xb0\x80", in.query.items);
    try std.testing.expectEqual(@as(usize, 0), in.preedit.items.len);
    try std.testing.expect(!in.commitPreedit(allocator)); // 빈 조합이면 무동작 false
}

test "OverlayInput: displayCols/queryCols는 EAW(한글=2칸)" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 8), displayCols("\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4\xeb\x9d\xbc")); // "가나다라" = 4×2
    try std.testing.expectEqual(@as(u32, 4), displayCols("abcd"));
    var in: OverlayInput = .{};
    defer in.deinit(allocator);
    for ([_]u21{ '가', '나' }) |c| try in.appendChar(allocator, c);
    try std.testing.expectEqual(@as(u32, 4), in.queryCols()); // 한글 2글자 = 4칸
}

test "panelLayout: term_cols 0이면 null, 아니면 사이드바 오른쪽 상단-중앙" {
    try std.testing.expectEqual(@as(?PanelLayout, null), panelLayout(.{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 800, // 사이드바가 backing 전부 — 터미널 0칸
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    }));
    const lay = panelLayout(.{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } }) orelse return error.NoLayout;
    try std.testing.expect(lay.x >= 40); // 사이드바 오른쪽
    try std.testing.expectEqual(@as(i32, 32), lay.y); // 2 줄(2×16)
    try std.testing.expectEqual(@as(u32, 8), lay.cw);
    try std.testing.expectEqual(@as(u32, 16), lay.ch);
    try std.testing.expect(lay.panel_cols >= 1 and lay.panel_cols <= 60);
}

test "panelLayout: rich 패딩이면 확장 박스(panel_w + 2*pad)가 터미널 영역 안 — 사이드바 침범·화면밖 방지" {
    const pad: u32 = 12;
    const sidebar: u32 = 40;
    const backing: u32 = 200; // 좁은 창 — clamp가 걸리는 경계
    const lay = panelLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = sidebar, .backing_width_px = backing, .backing_height_px = 600 },
        .shape = .{ .modal_padding_px = @intCast(pad) },
    }) orelse return error.NoLayout;
    const term_w_px = backing - sidebar;
    const panel_w = lay.panel_cols * lay.cw;
    // lowering이 ±pad 확장해도 박스가 [sidebar, sidebar+term_w_px] 안: 좌단 quad.x>=sidebar, 우단<=sidebar+term_w_px.
    try std.testing.expect(panel_w + 2 * pad <= term_w_px);
    try std.testing.expect(lay.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(lay.x + @as(i32, @intCast(panel_w + pad)) <= @as(i32, @intCast(sidebar + term_w_px)));
}

test "findLayout: 활성 pane 우상단 우측 정렬·미초기화면 창 전체로 폴백" {
    // 활성 pane = 창 오른쪽 절반(x=400..800, top=32 — 탭 바 아래). 바는 그 pane 우상단에 붙는다.
    const lay = findLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 32, .w = 400, .h = 568 },
    }) orelse return error.NoLayout;
    const panel_w = lay.panel_cols * lay.cw;
    try std.testing.expectEqual(@as(i32, 800), lay.x + @as(i32, @intCast(panel_w))); // 우단이 pane 우단(800)에 닿음(pad=0)
    try std.testing.expect(lay.x >= 400); // pane 안 — 왼쪽 pane 안 침범
    try std.testing.expectEqual(@as(i32, 48), lay.y); // pane top(32) + 한 줄(16)

    // 미초기화(active_pane.w==0) → 사이드바 오른쪽 터미널 영역 전체로 폴백, 그 영역 우상단.
    const fb = findLayout(.{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } }) orelse return error.NoLayout;
    const fb_w = fb.panel_cols * fb.cw;
    try std.testing.expectEqual(@as(i32, 800), fb.x + @as(i32, @intCast(fb_w))); // 우단이 창 우단
    try std.testing.expect(fb.x >= 40); // 사이드바 오른쪽
    try std.testing.expectEqual(@as(i32, 16), fb.y); // 폴백 영역 top(0) + 한 줄
}

test "findLayout: rich 패딩이면 우측 확장 박스가 pane 안 — 우측 pane/divider 침범 방지" {
    const pad: u32 = 12;
    const lay = findLayout(.{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 0, .w = 200, .h = 600 }, // 좁은 가운데 pane(우측에 divider/다른 pane)
        .shape = .{ .modal_padding_px = @intCast(pad) },
    }) orelse return error.NoLayout;
    const panel_w = lay.panel_cols * lay.cw;
    // lowering이 ±pad 확장해도 박스가 [pane.x, pane.x+pane.w](=[400,600]) 안.
    try std.testing.expect(lay.x + @as(i32, @intCast(panel_w + pad)) <= 600);
    try std.testing.expect(lay.x - @as(i32, @intCast(pad)) >= 400);
}
