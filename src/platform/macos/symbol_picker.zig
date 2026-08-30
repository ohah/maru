//! 심볼 피커 필터 — **platform 전용 순수 로직**(native-editor-ui.md §7.5 「피커는 팔레트를 다시 쓴다」).
//!
//! UI 상태(open/query/preedit/selected)는 chrome 컴포넌트(`chrome/components/palette.zig`)가 들고,
//! 여기엔 그것이 만질 수 없는 것만 남는다 — 심볼 목록을 쿼리로 좁혀 **행을 굳히는 것**.
//!
//! **행이 인덱스가 아니라 값인 이유**(§7.5). 심볼 목록은 `editor_syntax.State.symbols` 한 버퍼에 사는데
//! 그것은 breadcrumb 이 **프레임마다 비우고 다시 채운다**. 인덱스를 들면 다른 소비자의 수명에 매달리므로,
//! 여는 순간 `offset` 과 라벨을 굳히고 그 뒤로는 공유 버퍼를 안 본다.
//!
//! **필터의 근거가 명령 팔레트와 다르다.** 그쪽은 *"title 은 영문이라 ASCII fold 로 충분"* 인데 심볼
//! 이름은 영문이 아니다 — zig 의 `test "이름 있다"` 가 그대로 심볼이다. 부분일치는 **바이트**로 하고
//! 대소문자 접기는 ASCII 에만 적용한다(UTF-8 은 자기동기적이라 바이트 부분일치가 코드포인트 가운데를
//! 물지 않는다). 유니코드 접기는 안 넣는다 — 표를 들이는 비용이 얻는 것보다 크다.

const std = @import("std");
const syntax = @import("syntax");

/// 굳힌 행 하나. **문서 내용을 안 빌린다** — `label` 은 이 모듈이 할당한 사본이다.
pub const Row = struct {
    /// 화면에 보일 라벨(`바깥 › 안쪽`, 넘치면 앞을 버린 것).
    label: []u8,
    /// 이동 대상(문서 byte offset). §5.2 의 `navigateTo` 가 이것만 받는다.
    offset: u32,
    /// 우측 보조 텍스트로 그릴 줄 번호(1-based).
    line: u32,
};

/// 체인을 잇는 구분자 — breadcrumb 과 **같은 것**(§7.5). 두 표시가 같은 것을 다르게 부르지 않는다.
pub const separator = " \u{203A} ";

/// 최대 체인 깊이 — `Provider.chainAt` 의 상한과 같은 자리다.
const max_chain: usize = 8;

pub const List = struct {
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.rows.items) |r| allocator.free(r.label);
        self.rows.deinit(allocator);
    }

    pub fn clear(self: *List, allocator: std.mem.Allocator) void {
        for (self.rows.items) |r| allocator.free(r.label);
        self.rows.clearRetainingCapacity();
    }
};

/// ASCII 대소문자 무시 **바이트** 부분일치. needle 이 비면 true(전체 통과).
fn containsFoldAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

/// 라벨을 `max_cols` 표시 폭에 맞춘다. **넘치면 앞을 버리고 안쪽을 남긴다**(§7.5) —
/// `…parseSyntaxRole` 이지 `ThemeConfig ›…` 가 아니다. 가장 구체적인 것이 가장 오래 남아야 한다.
///
/// **cluster 가운데를 안 자른다** — UTF-8 선두 바이트까지 물러난다.
fn fitTail(allocator: std.mem.Allocator, text: []const u8, max_cols: usize) ![]u8 {
    if (max_cols == 0) return allocator.alloc(u8, 0);
    if (displayCols(text) <= max_cols) return allocator.dupe(u8, text);

    // 뒤에서부터 max_cols-1 칸을 담을 시작점을 찾는다(1칸은 "…" 몫).
    const budget = max_cols - 1;
    var start = text.len;
    var cols: usize = 0;
    while (start > 0) {
        var prev = start - 1;
        while (prev > 0 and (text[prev] & 0xC0) == 0x80) prev -= 1; // 선두 바이트까지
        const w = codepointCols(text[prev..start]);
        if (cols + w > budget) break;
        cols += w;
        start = prev;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\u{2026}");
    try out.appendSlice(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

/// 표시 폭(East Asian Wide = 2칸). chrome 의 `overlay_input.displayCols` 와 같은 셈법이되 이 모듈은
/// chrome 을 import 하지 않으므로(platform 전용) 최소한만 둔다.
fn displayCols(text: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        cols += codepointCols(text[i..end]);
        i = end;
    }
    return cols;
}

fn codepointCols(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (bytes.len == 1) return 1; // ASCII
    const cp = std.unicode.utf8Decode(bytes) catch return 1;
    return if (isWide(cp)) 2 else 1;
}

/// 넓은 글자(한중일·한글). 표시 폭 셈법의 최소 판정 — 여기서 필요한 것은 「한글이 두 칸」 하나다.
fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6);
}

/// 심볼 목록을 쿼리로 좁혀 **행을 굳힌다**. `label_cols` 는 라벨이 쓸 수 있는 표시 폭이며 호출자가
/// **줄 번호 자리를 뗀 뒤** 넘긴다(§7.5 — `palette.view` 는 제목과 우측 텍스트의 겹침을 안 본다).
///
/// **순서는 문서 순서다**(§7.5) — 일치 품질로 재정렬하지 않는다.
pub fn filter(
    allocator: std.mem.Allocator,
    symbols: []const syntax.Provider.Symbol,
    source: []const u8,
    query: []const u8,
    label_cols: usize,
    out: *List,
) !void {
    out.clear(allocator);
    var chain: [max_chain]usize = undefined;
    for (symbols, 0..) |sym, i| {
        if (sym.name_end > source.len or sym.name_start >= sym.name_end) continue;
        const name = source[sym.name_start..sym.name_end];
        if (!containsFoldAscii(name, query)) continue;

        // **체인은 `chainAt(sym.start)` 으로 구한다**(§7.5) — 심볼의 시작 offset 은 그 심볼과 모든
        // 조상 안에 있으므로 커서용 조회가 행 라벨에도 그대로 쓰인다. 두 번째 조회를 만들지 않는다.
        const n = syntax.Provider.chainAt(symbols[0 .. i + 1], sym.start, &chain);
        var full: std.ArrayList(u8) = .empty;
        defer full.deinit(allocator);
        for (chain[0..n]) |ci| {
            const s = symbols[ci];
            if (s.name_end > source.len or s.name_start >= s.name_end) continue;
            if (full.items.len > 0) try full.appendSlice(allocator, separator);
            try full.appendSlice(allocator, source[s.name_start..s.name_end]);
        }
        if (full.items.len == 0) try full.appendSlice(allocator, name);

        const label = try fitTail(allocator, full.items, label_cols);
        errdefer allocator.free(label);
        try out.rows.append(allocator, .{ .label = label, .offset = sym.start, .line = sym.start_row + 1 });
    }
}

// ── 판정자 ────────────────────────────────────────────────────────────────
//
// **이 모듈이 증명하는 것**: 심볼 목록이 「고를 수 있는 행」이 되는 규칙 — 문서 순서·체인 라벨·
// 넘칠 때 안쪽 남기기·ASCII 접기·문서 내용을 안 빌리는 사본. 편집기에서 「그 함수로 가자」가
// 성립하려면 이 넷이 동시에 맞아야 한다.

const testing = std.testing;

fn symbolsOf(allocator: std.mem.Allocator, src: []const u8, out: *std.ArrayList(syntax.Provider.Symbol)) !void {
    var prov = syntax.Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    prov.symbols(allocator, out);
}

test "SP1 쿼리가 심볼 이름만 좁힌다 — 주석·문자열 속 같은 글자는 안 걸린다 (§7.5)" {
    // 찾기(⌘F)와 갈리는 지점이다. 아래 문서에는 "draw" 가 주석과 문자열에도 있는데, 피커는
    // **이름 붙은 자리**만 낸다.
    const allocator = testing.allocator;
    const src =
        \\// draw 를 주석에도 적는다
        \\pub const s = "draw 는 문자열에도 있다";
        \\pub fn drawBox() void {}
        \\pub fn other() void {}
    ;
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src, &syms);

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src, "draw", 60, &list);

    try testing.expectEqual(@as(usize, 1), list.rows.items.len);
    try testing.expectEqualStrings("drawBox", list.rows.items[0].label);
}

test "SP2 중첩 심볼은 체인 전체로 보인다 — breadcrumb 과 같은 구분자·순서 (§7.5)" {
    const allocator = testing.allocator;
    const src =
        \\pub const Widget = struct {
        \\    pub fn draw(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src, &syms);

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src, "draw", 60, &list);

    try testing.expectEqual(@as(usize, 1), list.rows.items.len);
    try testing.expectEqualStrings("Widget \u{203A} draw", list.rows.items[0].label);
    // 줄 번호는 1-based다.
    try testing.expectEqual(@as(u32, 2), list.rows.items[0].line);
}

test "SP3 라벨이 넘치면 앞을 버리고 안쪽을 남긴다 — 가장 구체적인 것이 남는다 (§7.5)" {
    // `palette.view` 는 제목을 안 자른다. 안 자르고 넘기면 패널 밖으로 나가거나 줄 번호와 겹친다.
    const allocator = testing.allocator;
    const src =
        \\pub const AVeryLongContainerNameIndeed = struct {
        \\    pub fn andAnEquallyLongMethodName() void {}
        \\};
    ;
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src, &syms);

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src, "andAn", 20, &list);

    try testing.expectEqual(@as(usize, 1), list.rows.items.len);
    const label = list.rows.items[0].label;
    try testing.expect(displayCols(label) <= 20);
    // **안쪽이 남는다** — 바깥(컨테이너)이 아니라 메서드 이름의 꼬리다.
    try testing.expect(std.mem.endsWith(u8, label, "LongMethodName"));
    try testing.expect(std.mem.startsWith(u8, label, "\u{2026}"));
}

test "SP4 한글 심볼도 걸리고 폭도 두 칸으로 센다 — 명령 팔레트의 ASCII 전제가 여기선 거짓이다" {
    // zig 의 `test "이름"` 이 그대로 심볼이다. ASCII fold 전제로 짠 필터를 그대로 물려받으면
    // 이 경우가 조용히 빠진다.
    const allocator = testing.allocator;
    const src =
        \\test "한글 판정자" {
        \\    _ = 1;
        \\}
    ;
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src, &syms);
    if (syms.items.len == 0) return error.SkipZigTest;

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src, "판정", 60, &list);
    try testing.expectEqual(@as(usize, 1), list.rows.items.len);

    // 한글은 두 칸이다 — 「한글 판정자」는 한글 5자와 공백 하나라 5 × 2 + 1 = 11칸.
    try testing.expectEqual(@as(usize, 11), displayCols("한글 판정자"));
}

test "SP5 행은 문서 내용을 안 빌린다 — 사본이라 원본이 사라져도 산다 (§7.5)" {
    // 심볼 목록은 breadcrumb 이 프레임마다 다시 채우는 **공유 버퍼**에 산다. 인덱스를 들면 그
    // 수명에 매달리므로 여는 순간 값을 굳힌다 — 그 성질을 여기서 못박는다.
    const allocator = testing.allocator;
    const src_owned = try allocator.dupe(u8, "pub fn alpha() void {}\npub fn beta() void {}\n");
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src_owned, &syms);

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src_owned, "", 60, &list);
    try testing.expectEqual(@as(usize, 2), list.rows.items.len);

    // **원본을 지운다.** 라벨이 슬라이스였다면 여기서부터 해제된 메모리다.
    allocator.free(src_owned);
    try testing.expectEqualStrings("alpha", list.rows.items[0].label);
    try testing.expectEqualStrings("beta", list.rows.items[1].label);
}

test "SP6 순서는 문서 순서다 — 일치 품질로 재정렬하지 않는다 (§7.5)" {
    const allocator = testing.allocator;
    const src =
        \\pub fn zzzMatch() void {}
        \\pub fn aaaMatch() void {}
    ;
    var syms: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer syms.deinit(allocator);
    try symbolsOf(allocator, src, &syms);

    var list: List = .{};
    defer list.deinit(allocator);
    try filter(allocator, syms.items, src, "match", 60, &list);

    try testing.expectEqual(@as(usize, 2), list.rows.items.len);
    // 알파벳순이면 aaa 가 먼저다 — 문서 순서를 지키면 zzz 가 먼저다.
    try testing.expectEqualStrings("zzzMatch", list.rows.items[0].label);
    try testing.expect(list.rows.items[0].offset < list.rows.items[1].offset);
}
