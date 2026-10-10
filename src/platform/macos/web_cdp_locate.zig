//! `browser.*` 의 로케이터(W9b② — 역할·이름으로 요소를 가리킨다) 중 Chromium 이 푸는 부분. 순수 — CEF·control-plane 을 모른다.
//!
//! - **role**: ARIA 1.2 의 구체 역할 이름(대소문자 무시)을 Chromium 접근성 역할로 바꾼다 — 실측으로 거의 같은 문자열이고(약 100 개),
//!   다른 것은 별칭으로(`img` → `image`, `directory` → `list`, snapshot 표기 `disclosuretriangle`). `generic`·`none`·`presentation`·`text` 는
//!   찾을 수 없는 역할이라 거절한다(이름 없는 div·span 이 모두 generic 이다).
//! - 이름 일치: 양쪽을 정규화(공백 접기 — nbsp 포함, 보이지 않는 글자 `U+00AD U+200B-200D U+2060 U+FEFF` 지우기 — AX 이름에 그대로
//!   온다, 실측)한 뒤 exact 면 전체 일치(대소문자 구분), 아니면 대소문자 무시 부분 일치(ASCII 만 접는다).
//! - `Accessibility.queryAXTree` 결과에서 무시된 노드(`ignored` — aria-hidden 등)를 빼고 이름·level 로 거른 뒤 하나를 고른다. 여럿이면 실패
//!   메시지에 후보 다섯(ref·이름 — 에이전트가 ref 로 다시 부를 수 있게).

const std = @import("std");

/// 이름·라벨·글의 바이트 상한(L2 도 같은 상한으로 거절한다).
pub const max_text_bytes = 1024;
/// role 로케이터를 쓸 수 있는 페이지의 요소 수 상한 — 접근성 질의는 DOM 크기의 제곱으로 느려지고 그동안 페이지가 멈춘다(실측: 4 만 요소
/// 3.7 초 — 페이지 타이머가 3.6 초 멈췄다, 8 만 요소 14 초).
pub const max_role_page_elements = 30000;

/// 접근성 트리를 만드는 비용을 크게 키우는 페이지 구성의 상한 — **어떤 역할을 찾든** 질의마다 트리를 새로 만들고(캐시 없음) 그 비용은 이
/// 구성에 따라 제곱(또는 그 이상)으로 커졌다(실측, W9b②-1 적대 리뷰 3 회차 — 2 회차의 「link 가 느리다」 는 원인을 잘못 짚었다):
/// - 대상이 없는 같은 문서 fragment 링크(`href="#N"` 에 그 id 가 없음): 1 만 개면 role=link 2.5 초·role=button 1.2 초(정상 링크 1 만은 0.38 초).
/// - 네이티브 radio(같은 그룹·name 없음): 5 천 1.8 초·1 만 6.9 초.
/// - `role=radiogroup` 안의 `role=radio`: 1 천 0.36 초·2 천 2.5 초·1 만은 37 초에도 답이 없었다(앱의 DevTools 시한 30 초를 넘는다).
/// - 라벨이 붙은 폼 컨트롤(`<label for>`·감싼 label): 1 만 쌍 3.75 초·1.4 만 7.9 초(4 회차).
/// - 한 글 노드 안의 줄 수(로그 파일 탭 — Chromium 이 `<pre>` 로 감싼다): 2 만 줄 1.6 초, 5 만 줄은 10 초 넘게(4 회차).
/// 상한들은 더해진다(각자 상한이면 0.3–0.9 초, 셋이 함께면 1.7 초 — 4 회차) — 상한 대비 비율의 합이 1 을 넘으면 거절한다.
/// closed shadow root 안의 구성은 셀 수 없다(문서).
pub const max_dangling_fragment_links = 3000;
pub const max_native_radios = 3000;
pub const max_aria_radios = 800;
pub const max_labeled_controls = 3000;
pub const max_text_node_lines = 10000;

/// 세는 것들 — 세기 JS 의 결과 순서와 같다(첫째는 요소 수).
pub const Costly = struct { what: []const u8, limit: i64 };
pub const costly = [_]Costly{
    .{ .what = "same-page #links without a target", .limit = max_dangling_fragment_links },
    .{ .what = "radio inputs", .limit = max_native_radios },
    .{ .what = "role=radio elements", .limit = max_aria_radios },
    .{ .what = "labeled form controls", .limit = max_labeled_controls },
    .{ .what = "lines in one text node", .limit = max_text_node_lines },
};

/// ARIA 1.2 구체 역할(접근성 트리가 같은 문자열로 쓰는 것 — 실측) — 정렬 안 됨, 선형 탐색(작다).
const aria_roles = [_][]const u8{
    "alert",         "alertdialog", "application", "article",      "banner",    "blockquote",    "button",      "caption",
    "cell",          "checkbox",    "code",        "columnheader", "combobox",  "complementary", "contentinfo", "definition",
    "deletion",      "dialog",      "document",    "emphasis",     "feed",      "figure",        "form",        "grid",
    "gridcell",      "group",       "heading",     "insertion",    "link",      "list",          "listbox",     "listitem",
    "log",           "main",        "marquee",     "math",         "menu",      "menubar",       "menuitem",    "menuitemcheckbox",
    "menuitemradio", "meter",       "navigation",  "note",         "option",    "paragraph",     "progressbar", "radio",
    "radiogroup",    "region",      "row",         "rowgroup",     "rowheader", "scrollbar",     "search",      "searchbox",
    "separator",     "slider",      "spinbutton",  "status",       "strong",    "subscript",     "superscript", "switch",
    "tab",           "table",       "tablist",     "tabpanel",     "term",      "textbox",       "time",        "timer",
    "toolbar",       "tooltip",     "tree",        "treegrid",     "treeitem",
};

/// 별칭 — ARIA 이름이나 snapshot 표기가 Chromium 역할과 다른 것.
const role_aliases = [_]struct { []const u8, []const u8 }{
    .{ "img", "image" },
    .{ "image", "image" },
    .{ "directory", "list" },
    .{ "disclosuretriangle", "DisclosureTriangle" },
};

/// 흔한 역할(모르는 역할 메시지에 싣는다 — 전체 목록은 문서).
pub const common_roles = "button link textbox checkbox radio combobox heading tab menuitem option row cell img";

/// 입력한 역할 이름 → Chromium 접근성 역할(정적 글). 모르는 역할·찾을 수 없는 역할이면 null.
pub fn chromiumRole(input: []const u8) ?[]const u8 {
    for (role_aliases) |a| if (std.ascii.eqlIgnoreCase(a[0], input)) return a[1];
    for (aria_roles) |r| if (std.ascii.eqlIgnoreCase(r, input)) return r;
    return null;
}

/// 모르는 역할에 가장 가까운 것(편집 거리 2 이하) — 「did you mean」.
pub fn suggestRole(input: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (aria_roles) |r| {
        const d = editDistance(r, input);
        if (d < best_d) {
            best_d = d;
            best = r;
        }
    }
    for (role_aliases) |a| {
        const d = editDistance(a[0], input);
        if (d < best_d) {
            best_d = d;
            best = a[0];
        }
    }
    return best;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return 99;
    var row: [33]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var prev = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const cur = row[j];
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), prev + cost);
            prev = cur;
        }
    }
    return row[b.len];
}

/// 공백을 접고(앞뒤는 자르고) 보이지 않는 글자를 지운 글(소유).
pub fn normalize(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + len > s.len) break;
        const cp: u21 = if (len == 1) s[i] else std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += 1;
            continue;
        };
        const chunk = s[i .. i + len];
        i += len;
        switch (cp) {
            0xAD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF => continue, // 보이지 않는 글자
            ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => {
                pending_space = out.items.len > 0;
                continue;
            },
            else => {},
        }
        if (pending_space) try out.append(gpa, ' ');
        pending_space = false;
        try out.appendSlice(gpa, chunk);
    }
    return out.toOwnedSlice(gpa);
}

/// 정규화한 두 글의 일치 — exact 면 전체(대소문자 구분), 아니면 대소문자 무시(ASCII) 부분.
pub fn nameMatches(have: []const u8, want: []const u8, exact: bool) bool {
    if (exact) return std.mem.eql(u8, have, want);
    if (want.len > have.len) return false;
    var i: usize = 0;
    while (i + want.len <= have.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(have[i .. i + want.len], want)) return true;
    }
    return false;
}

pub const RoleQuery = struct {
    /// Chromium 역할(정적).
    role: []const u8,
    /// 정규화한 이름(빌린다) — null 이면 이름을 보지 않는다.
    name: ?[]const u8 = null,
    level: ?i64 = null,
    exact: bool = false,
    nth: ?u32 = null,
};

pub const Pick = union(enum) {
    /// 맞는 것이 없다(또는 nth 가 개수 이상) — `{ok:false}`.
    none,
    /// 하나 — backendNodeId 와 그 이름(소유).
    one: struct { backend: i64, name: []u8 },
    /// 여럿(nth 없음) — 실패 메시지(소유).
    ambiguous: []u8,
};

/// `Accessibility.queryAXTree` 결과(JSON 글)에서 고른다. 모양이 틀리면 error.Malformed.
pub fn pickFromAx(gpa: std.mem.Allocator, json: []const u8, q: RoleQuery, input_role: []const u8) !Pick {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    const nodes_v = parsed.value.object.get("nodes") orelse return error.Malformed;
    if (nodes_v != .array) return error.Malformed;

    const Match = struct { backend: i64, name: []u8, exact: bool };
    var matches: std.ArrayList(Match) = .empty;
    defer {
        for (matches.items) |m| gpa.free(m.name);
        matches.deinit(gpa);
    }
    var total: usize = 0;
    for (nodes_v.array.items) |n| {
        if (n != .object) continue;
        const o = n.object;
        if (o.get("ignored")) |ig| if (ig == .bool and ig.bool) continue;
        const backend = switch (o.get("backendDOMNodeId") orelse continue) {
            .integer => |b| b,
            else => continue,
        };
        if (q.level) |want_level| if (levelOf(o) != want_level) continue;
        const raw_name: []const u8 = blk: {
            const nv = o.get("name") orelse break :blk "";
            if (nv != .object) break :blk "";
            const vv = nv.object.get("value") orelse break :blk "";
            break :blk if (vv == .string) vv.string else "";
        };
        const name = try normalize(gpa, raw_name);
        var keep = false;
        defer if (!keep) gpa.free(name);
        if (q.name) |want| if (!nameMatches(name, want, q.exact)) continue;
        total += 1;
        if (q.nth) |k| {
            if (total - 1 != k) continue;
        } else if (matches.items.len >= 6) continue; // 후보는 다섯까지(여섯째로 「여럿」 만 안다)
        try matches.append(gpa, .{ .backend = backend, .name = name, .exact = if (q.name) |want| std.mem.eql(u8, name, want) else false });
        keep = true;
    }
    if (matches.items.len == 0) return .none;
    if (q.nth != null or total == 1) {
        const m = matches.items[0];
        matches.items[0].name = try gpa.alloc(u8, 0); // 소유를 넘긴다(빈 것은 defer 가 놓는다)
        return .{ .one = .{ .backend = m.backend, .name = m.name } };
    }
    // 여럿 — 「ambiguous: 3 elements match role=button name~"save" — n11 "Save" (exact), n12 "Save changes"; retry with ref (preferred), exact:true, or nth」
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("ambiguous: {d} elements match role={s}", .{ total, input_role }) catch return error.OutOfMemory;
    if (q.name) |want| {
        w.print(" name{s}", .{if (q.exact) "=" else "~"}) catch return error.OutOfMemory;
        writeQuoted(w, want) catch return error.OutOfMemory;
    }
    if (q.level) |l| w.print(" level={d}", .{l}) catch return error.OutOfMemory;
    w.writeAll(" — ") catch return error.OutOfMemory;
    for (matches.items[0..@min(matches.items.len, 5)], 0..) |m, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("n{d} ", .{m.backend}) catch return error.OutOfMemory;
        writeQuoted(w, m.name) catch return error.OutOfMemory;
        if (m.exact) w.writeAll(" (exact)") catch return error.OutOfMemory;
    }
    if (total > 5) w.writeAll(", …") catch return error.OutOfMemory;
    w.writeAll("; retry with ref (preferred), exact:true, or nth") catch return error.OutOfMemory;
    return .{ .ambiguous = try aw.toOwnedSlice() };
}

fn levelOf(o: std.json.ObjectMap) ?i64 {
    const props = o.get("properties") orelse return null;
    if (props != .array) return null;
    for (props.array.items) |p| {
        if (p != .object) continue;
        const name = p.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, "level")) continue;
        const v = p.object.get("value") orelse return null;
        if (v != .object) return null;
        const inner = v.object.get("value") orelse return null;
        return if (inner == .integer) inner.integer else null;
    }
    return null;
}

/// 페이지가 정한 글을 메시지에 — JSON 인용, 60 바이트(UTF-8 경계)까지, 제어 문자(C0·DEL·C1)와 양방향 제어 글자는 뺀다(CLI 가
/// 메시지를 그대로 찍는다 — 표시 속이기, 1 회차).
fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    var end: usize = @min(s.len, 60);
    while (end < s.len and end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    var clean: [60]u8 = undefined;
    const n = displaySafe(s[0..end], &clean);
    try std.json.Stringify.value(clean[0..n], .{}, w);
    if (end < s.len) try w.writeAll("…");
}

/// 표시해도 안전한 글만 `out` 에 — C0·DEL·C1 제어 문자, 양방향 제어 글자(U+061C·200E·200F·202A–202E·2066–2069), 줄·문단 구분
/// (U+2028·2029), interlinear(U+FFF9–FFFB), tag 글자(U+E0000–E007F)를 뺀다. 쓴 바이트 수. CLI(`src/cli/browser.zig`)에 같은 함수가 있다
/// (플랫폼 모듈과 CLI 는 서로 가져오지 않는다 — 둘을 함께 고친다).
pub fn displaySafe(s: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += len;
            continue;
        };
        const unsafe = cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x061C or cp == 0x200E or cp == 0x200F or
            (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0x2028 or cp == 0x2029 or
            (cp >= 0xFFF9 and cp <= 0xFFFB) or (cp >= 0xE0000 and cp <= 0xE007F); // 줄·문단 구분·interlinear·tag 글자도(2 회차)
        if (!unsafe and n + len <= out.len) {
            @memcpy(out[n .. n + len], s[i .. i + len]);
            n += len;
        }
        i += len;
    }
    return n;
}

const testing = std.testing;

test "역할 이름: ARIA 이름 그대로(대소문자 무시)·별칭, 찾을 수 없는 역할은 null, 가까운 것을 권한다" {
    try testing.expectEqualStrings("button", chromiumRole("Button").?);
    try testing.expectEqualStrings("image", chromiumRole("img").?);
    try testing.expectEqualStrings("list", chromiumRole("directory").?);
    try testing.expectEqualStrings("DisclosureTriangle", chromiumRole("disclosureTriangle").?);
    for ([_][]const u8{ "generic", "none", "presentation", "text", "", "StaticText" }) |bad| try testing.expect(chromiumRole(bad) == null);
    try testing.expectEqualStrings("button", suggestRole("buton").?);
    try testing.expectEqualStrings("checkbox", suggestRole("chekbox").?);
    try testing.expect(suggestRole("zzzzzzzz") == null);
}

test "정규화: 공백 접기(nbsp·줄바꿈)·앞뒤 자르기·보이지 않는 글자 지우기, 부분·정확 일치" {
    const n = try normalize(testing.allocator, "  Save\u{A0}\u{A0}\n changes\u{AD}\u{200B} ");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("Save changes", n);
    try testing.expect(nameMatches("Save changes", "save", false));
    try testing.expect(!nameMatches("Save changes", "save", true));
    try testing.expect(nameMatches("Save changes", "Save changes", true));
    try testing.expect(!nameMatches("Sa", "Save", false));
}

// 실측(W9b② 착수 전 — lv.html)의 queryAXTree 결과 모양: 무시된 노드는 이름이 비고 ignored, heading 은 properties 에 level.
const buttons_ax =
    \\{"nodes":[
    \\{"nodeId":"11","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Save"},"backendDOMNodeId":11},
    \\{"nodeId":"12","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Save changes"},"backendDOMNodeId":12},
    \\{"nodeId":"13","ignored":true,"ignoredReasons":[{"name":"ariaHiddenElement"}],"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":""},"backendDOMNodeId":13},
    \\{"nodeId":"14","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"SAVE \"all\"\u0007"},"backendDOMNodeId":14}
    \\]}
;
const headings_ax =
    \\{"nodes":[
    \\{"ignored":false,"role":{"value":"heading"},"name":{"value":"Top"},"properties":[{"name":"level","value":{"type":"integer","value":1}}],"backendDOMNodeId":7},
    \\{"ignored":false,"role":{"value":"heading"},"name":{"value":"Sub Save"},"properties":[{"name":"level","value":{"type":"integer","value":2}}],"backendDOMNodeId":8}
    \\]}
;

fn expectOne(p: Pick, backend: i64, name: []const u8) !void {
    switch (p) {
        .one => |o| {
            defer testing.allocator.free(o.name);
            try testing.expectEqual(backend, o.backend);
            try testing.expectEqualStrings(name, o.name);
        },
        else => return error.TestExpectedOne,
    }
}

test "queryAXTree 거르기: 무시된 노드는 빼고, 이름 부분·정확 일치, level, nth, 여럿이면 후보 ref 와 (exact) 표시" {
    const g = testing.allocator;
    try expectOne(try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "Save", .exact = true }, "button"), 11, "Save");
    try expectOne(try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "changes" }, "button"), 12, "Save changes");
    try expectOne(try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "save", .nth = 2 }, "button"), 14, "SAVE \"all\"\x07");
    try testing.expect(try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "save", .nth = 3 }, "button") == .none);
    try testing.expect(try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "nothing" }, "button") == .none);
    try expectOne(try pickFromAx(g, headings_ax, .{ .role = "heading", .level = 2 }, "heading"), 8, "Sub Save");
    const amb = try pickFromAx(g, buttons_ax, .{ .role = "button", .name = "save" }, "button");
    defer g.free(amb.ambiguous);
    try testing.expectEqualStrings("ambiguous: 3 elements match role=button name~\"save\" — n11 \"Save\", n12 \"Save changes\", n14 \"SAVE \\\"all\\\"\"; retry with ref (preferred), exact:true, or nth", amb.ambiguous);
    const amb2 = try pickFromAx(g, buttons_ax, .{ .role = "button" }, "button");
    defer g.free(amb2.ambiguous);
    try testing.expect(std.mem.startsWith(u8, amb2.ambiguous, "ambiguous: 3 elements match role=button — n11"));
    try testing.expectError(error.Malformed, pickFromAx(g, "[]", .{ .role = "button" }, "button"));
}

test "표시 안전: C1·양방향 제어·줄 구분·tag 글자는 메시지에서 빠진다" {
    var out: [64]u8 = undefined;
    const n = displaySafe("a\x1b[31mb\u{9b}c\u{202e}d\u{2066}e\u{85}f\u{2028}g\u{E0041}h\u{FFF9}i", &out);
    try testing.expectEqualStrings("a[31mbcdefghi", out[0..n]);
}

test "정규화한 이름끼리 비교한다 — nbsp·soft hyphen 이 섞인 이름도 exact 로 찾고, exact 는 대소문자를 가린다, 메시지에 양방향 제어 글자가 남지 않는다" {
    const g = testing.allocator;
    const ax =
        \\{"nodes":[
        \\{"ignored":false,"name":{"value":"Save\u00a0 all\u00ad"},"backendDOMNodeId":21},
        \\{"ignored":false,"name":{"value":"save ALL"},"backendDOMNodeId":22},
        \\{"ignored":false,"name":{"value":"\u202eevil"},"backendDOMNodeId":23}
        \\]}
    ;
    try expectOne(try pickFromAx(g, ax, .{ .role = "button", .name = "Save all", .exact = true }, "button"), 21, "Save all");
    try expectOne(try pickFromAx(g, ax, .{ .role = "button", .name = "save ALL", .exact = true }, "button"), 22, "save ALL");
    const amb = try pickFromAx(g, ax, .{ .role = "button" }, "button");
    defer g.free(amb.ambiguous);
    try testing.expect(std.mem.indexOf(u8, amb.ambiguous, "n23 \"evil\"") != null);
    try testing.expect(std.mem.indexOf(u8, amb.ambiguous, "\u{202e}") == null);
}

test "여럿 메시지: 긴 이름은 60 바이트(UTF-8 경계)에서 자르고, 다섯 넘으면 …, exact 로도 맞는 후보에 표시" {
    const g = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g);
    try buf.appendSlice(g, "{\"nodes\":[");
    for (0..7) |i| {
        if (i > 0) try buf.append(g, ',');
        try buf.print(g, "{{\"ignored\":false,\"name\":{{\"value\":\"{s}\"}},\"backendDOMNodeId\":{d}}}", .{ if (i == 0) "가나다라마바사아자차카타파하가나다라마바사아자차카타파하" else "Go", 100 + i });
    }
    try buf.appendSlice(g, "]}");
    const p = try pickFromAx(g, buf.items, .{ .role = "link", .name = "Go" }, "link");
    defer g.free(p.ambiguous);
    try testing.expect(std.mem.indexOf(u8, p.ambiguous, "ambiguous: 6 elements") != null);
    try testing.expect(std.mem.indexOf(u8, p.ambiguous, "n101 \"Go\" (exact)") != null);
    try testing.expect(std.mem.indexOf(u8, p.ambiguous, ", …;") != null);
    try testing.expect(std.mem.indexOf(u8, p.ambiguous, "n106") == null); // 다섯까지만
    try testing.expect(std.unicode.utf8ValidateSlice(p.ambiguous));
}
