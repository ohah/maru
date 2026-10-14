//! Chromium 탭 콘솔을 maru 가 쥐는 자리(W9c① — docs/plans/web-osr-backend.md W9c C2'') — L2 순수.
//!
//! 시험이 증명하는 것: 탭마다 줄을 오래된 것부터 버리며(500 줄·512 KiB) 쥐고, 버린 수는 `maru` 수준 표지로 남기며, 읽는 쪽이
//! 바뀌면 지금 문서의 줄만 보인다. 브라우저 패널에서 중요한 이유 — 콘솔은 늘 켜 둔다(첫 읽기가 `[]` 를 「오류 없음」 으로 읽지
//! 않게). 그래서 에이전트가 처음 읽을 때 버퍼에는 그 탭이 **허락 전에** 지나온 사이트의 줄(로그인 토큰을 찍는 페이지 등)이
//! 남아 있을 수 있다 — grant 가 앞 사이트의 기록을 열면 안 된다.
//!
//! 읽는 쪽(`Authorizer`)은 app 이 정한다 — 확인 grant 면 그 grant 의 번호(철회 뒤 다시 허락하면 새 번호), cap 이면 nonce 의 해시.
//! 마지막으로 읽은 쪽(묶인 쪽)은 모든 줄을 보고(WebKit 의 서버 버퍼처럼 이동을 넘어 남는다), 다른 쪽은 지금 문서의 줄 중 앞 문서가
//! 남긴 것(`old_document` — sidecar 가 출처로 가른 unload 줄)이 아닌 것만 본다. 다른 쪽이 읽으면 그쪽이 묶이고 그에게 보이지
//! 않던 줄은 버린다 — 남기면 묶인 뒤 다음 읽기에서 허락 전 기록이 보였다.

const std = @import("std");

/// 줄 수준. `maru` 는 maru 가 넣는 표지(버린 수)뿐이다 — 페이지는 이 수준을 만들 수 없다(sidecar 의 수준은 닫힌 enum 이다).
pub const Level = enum {
    log,
    info,
    warn,
    @"error",
    debug,
    maru,
};

/// 탭 하나가 쥐는 줄 수·글 바이트 상한(넘치면 오래된 것부터 버린다). sidecar 는 브라우저 32 개까지라(`registry.capacity`) 앱
/// 전체로도 16 MiB 안이다. 결과 상한(`control_browser.console_max_result_bytes`)보다 한참 작다 — 512 KiB 를 넘는 결과는
/// `browser.consoleChunk` 조각으로 간다.
pub const max_entries: usize = 500;
pub const max_bytes: usize = 512 * 1024;

/// 읽는 쪽 — 0 은 「모름」(늘 지금 문서만 보이고 묶이지 않는다).
pub const Authorizer = u64;

pub const Entry = struct {
    level: Level,
    /// 소유한 글(UTF-8 — sidecar 가 제어 문자를 지웠고 wire 가 다시 봤다).
    text: []u8,
    /// 그 줄이 온 때의 문서 번호(`newDocument` 가 올린다).
    doc: u32,
    /// 앞 문서가 새 문서의 시작 뒤에 남긴 줄(sidecar 의 출처 판정).
    old_document: bool,
    /// `maru` 표지가 센 버린 수(오류·경고, 그 밖) — 잇단 표지는 하나로 합친다.
    dropped: [2]u32 = .{ 0, 0 },
};

pub const Ring = struct {
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    doc: u32 = 0,
    latched: Authorizer = 0,

    pub fn deinit(self: *Ring, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
    }

    /// 주 프레임에 새 문서가 들어섰다(`page_started`, 오류 페이지 — `error_page`).
    pub fn newDocument(self: *Ring) void {
        self.doc +%= 1;
    }

    /// 페이지의 줄 하나. 넘치면 오래된 줄부터 버린다.
    pub fn add(self: *Ring, gpa: std.mem.Allocator, level: Level, text: []const u8, old_document: bool) std.mem.Allocator.Error!void {
        const owned = try gpa.dupe(u8, text[0..@min(text.len, max_bytes)]);
        errdefer gpa.free(owned);
        try self.push(gpa, .{ .level = level, .text = owned, .doc = self.doc, .old_document = old_document });
    }

    fn push(self: *Ring, gpa: std.mem.Allocator, entry: Entry) std.mem.Allocator.Error!void {
        try self.entries.ensureUnusedCapacity(gpa, 1);
        while (self.entries.items.len > 0 and (self.entries.items.len >= max_entries or self.bytes + entry.text.len > max_bytes)) {
            const oldest = self.entries.orderedRemove(0);
            self.bytes -= oldest.text.len;
            gpa.free(oldest.text);
        }
        self.entries.appendAssumeCapacity(entry);
        self.bytes += entry.text.len;
    }

    /// sidecar 가 버린 줄 수(양동이를 넘었다) — `maru` 표지 하나로. 바로 앞 줄이 같은 문서의 표지면 거기에 더한다(쏟아질 때 표지가
    /// 줄을 밀어내지 않게).
    pub fn addDropped(self: *Ring, gpa: std.mem.Allocator, errors: u32, other: u32) std.mem.Allocator.Error!void {
        if (errors == 0 and other == 0) return;
        var counts: [2]u32 = .{ errors, other };
        const last: ?*Entry = if (self.entries.items.len > 0) &self.entries.items[self.entries.items.len - 1] else null;
        if (last) |e| if (e.level == .maru and e.doc == self.doc) {
            counts = .{ e.dropped[0] +| errors, e.dropped[1] +| other };
            const text = try markerText(gpa, counts);
            self.bytes = self.bytes - e.text.len + text.len;
            gpa.free(e.text);
            e.text = text;
            e.dropped = counts;
            return;
        };
        const text = try markerText(gpa, counts);
        errdefer gpa.free(text);
        try self.push(gpa, .{ .level = .maru, .text = text, .doc = self.doc, .old_document = false, .dropped = counts });
    }

    fn markerText(gpa: std.mem.Allocator, counts: [2]u32) std.mem.Allocator.Error![]u8 {
        const total = @as(u64, counts[0]) + counts[1];
        return std.fmt.allocPrint(gpa, "{d} console messages were dropped ({d} error/warn, {d} other): the page logged faster than maru keeps", .{ total, counts[0], counts[1] });
    }

    /// `who` 가 볼 수 있는 줄을 `[{level,text}]` JSON 으로(`out` 이 소유). `clear` 면 읽은 뒤 모두 비운다(WebKit 과 같다).
    pub fn read(self: *Ring, gpa: std.mem.Allocator, out: std.mem.Allocator, who: Authorizer, clear_after: bool) std.mem.Allocator.Error![]u8 {
        const latched = who != 0 and who == self.latched;
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        (blk: {
            s.beginArray() catch |e| break :blk e;
            for (self.entries.items) |e| {
                if (!latched and !self.current(e)) continue;
                s.beginObject() catch |err| break :blk err;
                s.objectField("level") catch |err| break :blk err;
                s.write(@tagName(e.level)) catch |err| break :blk err;
                s.objectField("text") catch |err| break :blk err;
                s.write(e.text) catch |err| break :blk err;
                s.endObject() catch |err| break :blk err;
            }
            s.endArray() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        const json = try aw.toOwnedSlice();
        if (clear_after) {
            self.clear(gpa);
        } else if (!latched and who != 0) {
            // 새로 묶인다 — 이 쪽에게 보이지 않던 줄은 버린다(묶인 뒤의 읽기에서 허락 전 기록이 보이지 않게).
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (self.current(self.entries.items[i])) {
                    i += 1;
                    continue;
                }
                const gone = self.entries.orderedRemove(i);
                self.bytes -= gone.text.len;
                gpa.free(gone.text);
            }
        }
        if (who != 0) self.latched = who;
        return json;
    }

    /// 묶이지 않은 쪽에게 보이는 줄 — 지금 문서의 제 줄.
    fn current(self: *const Ring, e: Entry) bool {
        return e.doc == self.doc and !e.old_document;
    }

    pub fn clear(self: *Ring, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.text);
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Got = struct { level: []const u8, text: []const u8 };

fn readAll(r: *Ring, who: Authorizer, clear_after: bool) !std.json.Parsed([]Got) {
    const json = try r.read(testing.allocator, testing.allocator, who, clear_after);
    defer testing.allocator.free(json);
    return std.json.parseFromSlice([]Got, testing.allocator, json, .{ .allocate = .alloc_always });
}

fn expectTexts(r: *Ring, who: Authorizer, want: []const []const u8) !void {
    const got = try readAll(r, who, false);
    defer got.deinit();
    try testing.expectEqual(want.len, got.value.len);
    for (want, got.value) |w, g| try testing.expectEqualStrings(w, g.text);
}

test "W9c①: lines come back in order with their level, and clear empties after reading" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    try r.add(testing.allocator, .log, "one", false);
    try r.add(testing.allocator, .@"error", "two \"quoted\"\n두 줄", false);
    try r.add(testing.allocator, .debug, "three", false);
    {
        const got = try readAll(&r, 7, true);
        defer got.deinit();
        try testing.expectEqual(@as(usize, 3), got.value.len);
        try testing.expectEqualStrings("log", got.value[0].level);
        try testing.expectEqualStrings("error", got.value[1].level);
        try testing.expectEqualStrings("two \"quoted\"\n두 줄", got.value[1].text);
        try testing.expectEqualStrings("debug", got.value[2].level);
    }
    try expectTexts(&r, 7, &.{});
    try testing.expectEqual(@as(usize, 0), r.bytes);
}

test "W9c①: the ring drops the oldest lines past 500 lines or 512 KiB of text" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    for (0..max_entries + 3) |i| try r.add(testing.allocator, .log, try std.fmt.bufPrint(&buf, "{d}", .{i}), false);
    try testing.expectEqual(max_entries, r.entries.items.len);
    try testing.expectEqualStrings("3", r.entries.items[0].text);
    try testing.expectEqualStrings("502", r.entries.items[max_entries - 1].text);

    var b: Ring = .{};
    defer b.deinit(testing.allocator);
    const big = "x" ** 8192;
    for (0..max_bytes / big.len) |_| try b.add(testing.allocator, .log, big, false);
    try testing.expectEqual(max_bytes, b.bytes);
    try b.add(testing.allocator, .warn, "tail", false);
    try testing.expect(b.bytes <= max_bytes);
    try testing.expectEqual(max_bytes / big.len, b.entries.items.len); // 맨 앞 하나가 나가고 「tail」 이 들어왔다
    try testing.expectEqualStrings("tail", b.entries.items[b.entries.items.len - 1].text);
}

test "W9c①: dropped counts become one maru marker per run, placed where the drops happened" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    try r.add(testing.allocator, .log, "before", false);
    try r.addDropped(testing.allocator, 2, 5);
    try r.addDropped(testing.allocator, 1, 0); // 잇단 표지는 합친다
    try r.add(testing.allocator, .log, "after", false);
    try r.addDropped(testing.allocator, 0, 9);
    const got = try readAll(&r, 1, false);
    defer got.deinit();
    try testing.expectEqual(@as(usize, 4), got.value.len);
    try testing.expectEqualStrings("maru", got.value[1].level);
    try testing.expectEqualStrings("8 console messages were dropped (3 error/warn, 5 other): the page logged faster than maru keeps", got.value[1].text);
    try testing.expectEqualStrings("after", got.value[2].text);
    try testing.expectEqualStrings("9 console messages were dropped (0 error/warn, 9 other): the page logged faster than maru keeps", got.value[3].text);
    // 다른 문서의 표지에는 더하지 않는다.
    r.newDocument();
    try r.addDropped(testing.allocator, 1, 1);
    try testing.expectEqual(@as(usize, 5), r.entries.items.len);
}

test "W9c①: a reader other than the last one sees only the current document's own lines, then is latched and keeps them across navigation" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    try r.add(testing.allocator, .log, "site-a secret", false);
    r.newDocument(); // 사용자가 다른 사이트로 갔다
    try r.add(testing.allocator, .log, "site-a unload", true); // 앞 문서가 새 문서의 시작 뒤에 남긴 줄
    try r.add(testing.allocator, .log, "site-b head", false);
    // 처음 읽는 에이전트(grant 7) — 지금 문서의 제 줄만.
    try expectTexts(&r, 7, &.{"site-b head"});
    // 묶였다 — 보이지 않던 줄은 버렸으니 다음 읽기에도 앞 사이트의 줄은 없다. 이동을 넘어서는 남는다.
    r.newDocument();
    try r.add(testing.allocator, .warn, "site-c", false);
    try r.add(testing.allocator, .log, "site-b unload", true);
    try expectTexts(&r, 7, &.{ "site-b head", "site-c", "site-b unload" });
    // 다른 읽는 쪽(철회 뒤 다시 허락한 grant 8) — 다시 지금 문서의 제 줄만, 그리고 그쪽이 묶인다.
    try expectTexts(&r, 8, &.{"site-c"});
    try expectTexts(&r, 8, &.{"site-c"});
    // 앞에 묶였던 7 은 이제 묶이지 않았다 — 지금 문서의 것만.
    r.newDocument();
    try r.add(testing.allocator, .log, "site-d", false);
    try expectTexts(&r, 7, &.{"site-d"});
}

test "W9c①: an unknown reader (0) sees only the current document and never latches or drops" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    try r.add(testing.allocator, .log, "old", false);
    r.newDocument();
    try r.add(testing.allocator, .log, "new", false);
    try expectTexts(&r, 0, &.{"new"});
    try testing.expectEqual(@as(Authorizer, 0), r.latched);
    try testing.expectEqual(@as(usize, 2), r.entries.items.len);
    try expectTexts(&r, 3, &.{"new"});
    try testing.expectEqual(@as(Authorizer, 3), r.latched);
}
