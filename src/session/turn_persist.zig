//! 턴 링과 봉인 턴의 **디스크 모양**(AT7 — 계약 [§6.2~6.4](../../docs/agent-turn-changes.md)).
//!
//! **무엇을 답하나**: 「세션 하나의 링(`turn_snapshot.RingMap.Entry`)과 그 링이 가리키는 봉인 턴들(`turn_capture.Turn`)을
//! 텍스트 한 장 + blob 묶음으로 어떻게 적고, 어떻게 되읽나」. 파일은 **안 건드린다** — 이 층은 바이트 ↔ 구조만 안다.
//! 디렉터리·권한·rename·blob 읽기·tree 존재 확인은 L4(`app_session/turn_store.zig`)의 몫이다.
//!
//! **모양은 `workspace.v1` 과 같다** — `<kind> key=val key="quoted"` 줄, 인용은 `text_escape` 공유(계약 L: 새 인용 규칙을
//! 만들지 않는다). 사본 본문은 줄에 싣지 않고 **blob 해시**(`Wyhash(0)` — `capture_file` 이 `folded` 에 쓰는 것과 같은
//! 함수)로 가리킨다. 그래서 텍스트는 작고, 같은 내용(턴 n 의 after = 턴 n+1 의 before)은 절로 접힌다.
//!
//! **손상은 세션 통째로**(사용자 결정 2026-09-22). 줄 하나·해시 하나가 어긋나면 그 파일 전체를 거절한다 — 일부만 살리면
//! 링의 순서와 `↩` 판정이 거짓이 된다.
const std = @import("std");
const turn_snapshot = @import("turn_snapshot.zig");
const turn_capture = @import("turn_capture.zig");
const text_escape = @import("../text_escape.zig");

pub const header = "maru.turn-ring.v1";

/// 사본 본문의 이름. `capture_file.readSide` 가 `folded.hash` 에 쓰는 함수와 **같다** — 두 곳이 다른 해시를 쓰면
/// «같은 내용인가» 에 답이 둘이 된다.
pub fn blobHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// 한 side 의 디스크 표현. `Side.text` 만 blob 참조로 바뀐다 — 나머지는 값 그대로.
pub const SideRef = union(enum) {
    absent,
    empty,
    blob: struct { hash: u64, len: u64 },
    folded: struct { hash: u64, size: u64, why: turn_capture.Fold },
    unknown: turn_capture.Unknown,
};

pub const EntryRef = struct {
    path: []const u8,
    trigger: turn_capture.Trigger,
    before: SideRef,
    after: ?SideRef,
    shell_diff: bool,
    before_trusted: bool,
};

/// 쓰는 쪽이 넘기는 «봉인 턴 하나» — 링의 `capture_id` 와 스토어의 턴.
pub const SealedRef = struct { id: u64, turn: *const turn_capture.Turn };

pub const TurnRef = struct {
    /// 쓸 때: 링의 `capture_id`. 읽을 때: 파일에 적힌 옛 id — 되살릴 때 새 id 로 바뀌고 링의 `capture_id` 도 그것을 따른다.
    capture_id: u64,
    shell_calls: u32,
    remote: bool,
    entries: []EntryRef,
};

/// 텍스트 한 장의 내용. 쓸 때는 링에서 만들고(`fromRing`), 읽을 때는 `parse` 가 만든다.
pub const Manifest = struct {
    entry: turn_snapshot.RingMap.Entry,
    turns: []TurnRef,

    pub fn deinit(self: *Manifest, gpa: std.mem.Allocator) void {
        for (self.turns) |t| {
            for (t.entries) |e| gpa.free(e.path);
            gpa.free(t.entries);
        }
        gpa.free(self.turns);
        self.* = undefined;
    }

    /// 이 manifest 가 가리키는 blob 들(중복 제거 없이 — L4 가 «있으면 건너뜀» 으로 접는다).
    pub fn eachBlob(self: *const Manifest, ctx: anytype, comptime f: fn (@TypeOf(ctx), u64, u64) void) void {
        for (self.turns) |t| for (t.entries) |e| {
            if (e.before == .blob) f(ctx, e.before.blob.hash, e.before.blob.len);
            if (e.after) |a| if (a == .blob) f(ctx, a.blob.hash, a.blob.len);
        };
    }
};

fn sideRef(side: turn_capture.Side) SideRef {
    return switch (side) {
        .absent => .absent,
        .empty => .empty,
        // 길이 0 의 `text` 는 제품이 만들지 않지만(`capture_file.readSide` 는 0 바이트를 `.empty` 로 준다) 혹시 오면 `empty` 로 —
        // 되읽으면 `.text ""` 가 아니라 `.empty` 가 되어 `Side.sameAs` 의 답이 달라지기 때문이다(적대적 6회차).
        .text => |t| if (t.len == 0) .empty else .{ .blob = .{ .hash = blobHash(t), .len = t.len } },
        .folded => |f| .{ .folded = .{ .hash = f.hash, .size = f.size, .why = f.why } },
        .unknown => |u| .{ .unknown = u },
    };
}

/// 링 + 봉인 턴 → manifest. `turns` 는 링의 `capture_id` 순서와 무관하게 받는다(가리켜지지 않는 것은 안 담는다 —
/// 도달성 sweep 과 같은 규율). 경로는 **빌린다**(쓰는 동안만 산다) — `deinit` 하지 말 것.
pub fn fromRing(
    gpa: std.mem.Allocator,
    entry: *const turn_snapshot.RingMap.Entry,
    turns: []const SealedRef,
) !Manifest {
    var out: std.ArrayList(TurnRef) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t.entries);
        out.deinit(gpa);
    }
    for (turns) |t| {
        if (t.id == 0) continue;
        var referenced = false;
        var back: usize = 0;
        while (entry.ring.nth(back)) |s| : (back += 1) {
            if (s.capture_id == t.id) referenced = true;
        }
        if (!referenced) continue;
        const entries = try gpa.alloc(EntryRef, t.turn.entries.items.len);
        for (t.turn.entries.items, 0..) |e, i| {
            entries[i] = .{
                .path = e.path,
                .trigger = e.trigger,
                .before = sideRef(e.before),
                .after = if (e.after) |a| sideRef(a) else null,
                .shell_diff = e.shell_diff,
                .before_trusted = e.before_trusted,
            };
        }
        try out.append(gpa, .{ .capture_id = t.id, .shell_calls = t.turn.shell_calls, .remote = t.turn.remote, .entries = entries });
    }
    return .{ .entry = entry.*, .turns = try out.toOwnedSlice(gpa) };
}

/// `fromRing` 이 만든 manifest 의 회수(경로는 빌린 것이라 안 놓는다).
pub fn releaseBorrowed(gpa: std.mem.Allocator, m: *Manifest) void {
    for (m.turns) |t| gpa.free(t.entries);
    gpa.free(m.turns);
    m.* = undefined;
}

fn writeSide(w: *std.Io.Writer, s: SideRef) !void {
    switch (s) {
        .absent => try w.writeAll("absent"),
        .empty => try w.writeAll("empty"),
        .blob => |b| try w.print("blob:{x}:{d}", .{ b.hash, b.len }),
        .folded => |f| try w.print("folded:{x}:{d}:{s}", .{ f.hash, f.size, @tagName(f.why) }),
        .unknown => |u| try w.print("unknown:{s}", .{@tagName(u)}),
    }
}

pub fn write(w: *std.Io.Writer, m: *const Manifest) !void {
    const e = &m.entry;
    try w.writeAll(header);
    try w.writeByte('\n');
    try w.writeAll("session id=\"");
    try text_escape.writeEscaped(w, e.sessionId());
    try w.writeAll("\" repo=\"");
    try text_escape.writeEscaped(w, e.repoPath());
    try w.print("\" missed={d} history-evicted={d}\n", .{ e.ring.missed, @intFromBool(e.ring.history_evicted) });
    // 오래된 것부터 — 되읽을 때 같은 순서로 밀어 넣으면 `next`·`len` 이 저절로 맞는다.
    var back: usize = e.ring.len;
    while (back > 0) {
        back -= 1;
        const s = e.ring.nth(back).?;
        try w.print("snapshot tree=\"{s}\" surface={d} captured={d} kind={d} files={d} files-known={d} edited={d} edited-known={d} capture={d} turn=\"", .{
            s.oid(), s.surface_id, s.captured_s, s.agent_kind, s.changed_files, @intFromBool(s.files_known), s.edited_joined, @intFromBool(s.edited_joined_known), s.capture_id,
        });
        try text_escape.writeEscaped(w, s.turnKey());
        try w.writeAll("\" title=\"");
        try text_escape.writeEscaped(w, s.titleText());
        try w.writeAll("\"\n");
    }
    for (m.turns) |t| {
        try w.print("turn capture={d} shell-calls={d} remote={d} entries={d}\n", .{ t.capture_id, t.shell_calls, @intFromBool(t.remote), t.entries.len });
        for (t.entries) |en| {
            try w.writeAll("entry path=\"");
            try text_escape.writeEscaped(w, en.path);
            try w.print("\" trigger={s} before=", .{@tagName(en.trigger)});
            try writeSide(w, en.before);
            try w.writeAll(" after=");
            if (en.after) |a| try writeSide(w, a) else try w.writeAll("none");
            try w.print(" shell-diff={d} before-trusted={d}\n", .{ @intFromBool(en.shell_diff), @intFromBool(en.before_trusted) });
        }
    }
}

pub const ParseError = error{ BadHeader, BadLine, BadValue, TooMany } || std.mem.Allocator.Error;

/// `key=val` / `key="…"` 토큰 하나를 순서대로 읽는 최소 리더. `workspace.v1` 의 `LineFields` 처럼 키로 찾지 않고
/// **적힌 순서를 요구한다** — 쓰는 쪽이 같은 파일에 있고(위 `write`), 미지 키는 없다(버전이 다르면 헤더가 가른다).
const Fields = struct {
    rest: []const u8,

    fn next(self: *Fields, key: []const u8) ParseError![]const u8 {
        var r = std.mem.trimStart(u8, self.rest, " ");
        if (!std.mem.startsWith(u8, r, key) or r.len <= key.len or r[key.len] != '=') return error.BadLine;
        r = r[key.len + 1 ..];
        if (r.len > 0 and r[0] == '"') {
            // 닫는 따옴표까지(escape 된 `\"` 는 건너뛴다).
            var i: usize = 1;
            while (i < r.len) : (i += 1) {
                if (r[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (r[i] == '"') break;
            }
            if (i >= r.len) return error.BadLine;
            const raw = r[1..i];
            self.rest = r[i + 1 ..];
            return raw;
        }
        const end = std.mem.indexOfScalar(u8, r, ' ') orelse r.len;
        self.rest = r[end..];
        return r[0..end];
    }

    fn uint(self: *Fields, key: []const u8, comptime T: type) ParseError!T {
        return std.fmt.parseInt(T, try self.next(key), 10) catch error.BadValue;
    }

    fn int(self: *Fields, key: []const u8, comptime T: type) ParseError!T {
        return std.fmt.parseInt(T, try self.next(key), 10) catch error.BadValue;
    }

    fn flag(self: *Fields, key: []const u8) ParseError!bool {
        const v = try self.next(key);
        if (std.mem.eql(u8, v, "0")) return false;
        if (std.mem.eql(u8, v, "1")) return true;
        return error.BadValue;
    }

    fn done(self: *Fields) ParseError!void {
        if (std.mem.trim(u8, self.rest, " ").len != 0) return error.BadLine;
    }
};

fn parseEnum(comptime E: type, s: []const u8) ParseError!E {
    return std.meta.stringToEnum(E, s) orelse error.BadValue;
}

fn parseSide(s: []const u8) ParseError!SideRef {
    if (std.mem.eql(u8, s, "absent")) return .absent;
    if (std.mem.eql(u8, s, "empty")) return .empty;
    var it = std.mem.splitScalar(u8, s, ':');
    const kind = it.next() orelse return error.BadValue;
    if (std.mem.eql(u8, kind, "blob")) {
        const hash = std.fmt.parseInt(u64, it.next() orelse return error.BadValue, 16) catch return error.BadValue;
        const len = std.fmt.parseInt(u64, it.next() orelse return error.BadValue, 10) catch return error.BadValue;
        if (it.next() != null) return error.BadValue;
        return .{ .blob = .{ .hash = hash, .len = len } };
    }
    if (std.mem.eql(u8, kind, "folded")) {
        const hash = std.fmt.parseInt(u64, it.next() orelse return error.BadValue, 16) catch return error.BadValue;
        const size = std.fmt.parseInt(u64, it.next() orelse return error.BadValue, 10) catch return error.BadValue;
        const why = try parseEnum(turn_capture.Fold, it.next() orelse return error.BadValue);
        if (it.next() != null) return error.BadValue;
        return .{ .folded = .{ .hash = hash, .size = size, .why = why } };
    }
    if (std.mem.eql(u8, kind, "unknown")) {
        const why = try parseEnum(turn_capture.Unknown, it.next() orelse return error.BadValue);
        if (it.next() != null) return error.BadValue;
        return .{ .unknown = why };
    }
    return error.BadValue;
}

fn copyBounded(dst: []u8, raw: []const u8, gpa: std.mem.Allocator) ParseError!usize {
    const un = try text_escape.unescapeAlloc(gpa, raw);
    defer gpa.free(un);
    if (un.len > dst.len) return error.BadValue;
    @memcpy(dst[0..un.len], un);
    return un.len;
}

/// 텍스트 → manifest. 어느 줄이든 어긋나면 **전체를 거절한다**(부분 복원 없음). 경로는 소유(`Manifest.deinit`).
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Manifest {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadHeader;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), header)) return error.BadHeader;

    var entry: turn_snapshot.RingMap.Entry = .{};
    var turns: std.ArrayList(TurnRef) = .empty;
    errdefer {
        for (turns.items) |t| {
            for (t.entries) |e| gpa.free(e.path);
            gpa.free(t.entries);
        }
        turns.deinit(gpa);
    }
    var saw_session = false;
    var pending: ?struct { ref: TurnRef, filled: usize } = null;
    // 아직 `turns` 에 안 들어간 turn 의 entries 는 위 errdefer 가 못 본다 — 여기서 따로 놓는다(채운 만큼의 path 까지).
    errdefer if (pending) |p| {
        for (p.ref.entries[0..p.filled]) |e| gpa.free(e.path);
        gpa.free(p.ref.entries);
    };

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const kind = line[0..sp];
        var f: Fields = .{ .rest = line[sp..] };
        if (std.mem.eql(u8, kind, "session")) {
            if (saw_session) return error.BadLine;
            saw_session = true;
            entry.id_len = try copyBounded(&entry.id, try f.next("id"), gpa);
            if (entry.id_len == 0) return error.BadValue;
            entry.repo_len = try copyBounded(&entry.repo, try f.next("repo"), gpa);
            entry.ring.missed = try f.uint("missed", u32);
            entry.ring.history_evicted = try f.flag("history-evicted");
            try f.done();
        } else if (std.mem.eql(u8, kind, "snapshot")) {
            if (!saw_session or pending != null) return error.BadLine;
            if (entry.ring.len >= turn_snapshot.capacity) return error.TooMany;
            var s: turn_snapshot.Snapshot = .{};
            s.tree_len = try copyBounded(&s.tree, try f.next("tree"), gpa);
            if (s.tree_len == 0) return error.BadValue;
            s.surface_id = try f.uint("surface", u64);
            s.captured_s = try f.int("captured", i64);
            s.agent_kind = try f.uint("kind", u8);
            s.changed_files = try f.uint("files", u32);
            s.files_known = try f.flag("files-known");
            s.edited_joined = try f.uint("edited", u32);
            s.edited_joined_known = try f.flag("edited-known");
            s.capture_id = try f.uint("capture", u64);
            s.turn_len = try copyBounded(&s.turn, try f.next("turn"), gpa);
            s.title_len = try copyBounded(&s.title, try f.next("title"), gpa);
            try f.done();
            // `push` 를 안 쓴다 — dedup 이 «같은 tree 연속» 을 거절하는데 파일은 이미 그 규칙을 지나온 것이다.
            entry.ring.items[entry.ring.next] = s;
            entry.ring.next = (entry.ring.next + 1) % turn_snapshot.capacity;
            entry.ring.len += 1;
        } else if (std.mem.eql(u8, kind, "turn")) {
            if (!saw_session) return error.BadLine;
            if (pending) |p| {
                if (p.filled != p.ref.entries.len) return error.BadLine;
                try turns.append(gpa, p.ref);
                pending = null;
            }
            const id = try f.uint("capture", u64);
            if (id == 0) return error.BadValue;
            const shell_calls = try f.uint("shell-calls", u32);
            const remote = try f.flag("remote");
            const n = try f.uint("entries", usize);
            try f.done();
            if (n > turn_capture.max_turn_paths) return error.TooMany;
            const entries = try gpa.alloc(EntryRef, n);
            errdefer gpa.free(entries);
            for (entries) |*e| e.* = .{ .path = "", .trigger = .read, .before = .absent, .after = null, .shell_diff = false, .before_trusted = false };
            pending = .{ .ref = .{ .capture_id = id, .shell_calls = shell_calls, .remote = remote, .entries = entries }, .filled = 0 };
        } else if (std.mem.eql(u8, kind, "entry")) {
            const p: *@TypeOf(pending.?) = if (pending) |*pp| pp else return error.BadLine;
            if (p.filled >= p.ref.entries.len) return error.TooMany;
            const path = try text_escape.unescapeAlloc(gpa, try f.next("path"));
            errdefer gpa.free(path);
            if (path.len == 0) return error.BadValue;
            const trigger = try parseEnum(turn_capture.Trigger, try f.next("trigger"));
            const before = try parseSide(try f.next("before"));
            const after_raw = try f.next("after");
            const after: ?SideRef = if (std.mem.eql(u8, after_raw, "none")) null else try parseSide(after_raw);
            const shell_diff = try f.flag("shell-diff");
            const before_trusted = try f.flag("before-trusted");
            try f.done();
            p.ref.entries[p.filled] = .{ .path = path, .trigger = trigger, .before = before, .after = after, .shell_diff = shell_diff, .before_trusted = before_trusted };
            p.filled += 1;
        } else return error.BadLine;
    }
    if (!saw_session) return error.BadLine;
    if (pending) |p| {
        if (p.filled != p.ref.entries.len) return error.BadLine;
        try turns.append(gpa, p.ref);
    }
    // 링이 가리키는 capture 는 전부 있어야 한다(0 은 «없음»). 없으면 손상 — 통째로 거절.
    var back: usize = 0;
    while (entry.ring.nth(back)) |s| : (back += 1) {
        if (s.capture_id == 0) continue;
        var found = false;
        for (turns.items) |t| if (t.capture_id == s.capture_id) {
            found = true;
        };
        if (!found) return error.BadValue;
    }
    return .{ .entry = entry, .turns = try turns.toOwnedSlice(gpa) };
}

/// blob 을 내주는 쪽(L4). `null` 은 «없거나 해시가 안 맞는다» — 그러면 되살리기 전체가 실패한다.
pub const BlobLookup = struct {
    ctx: *anyopaque,
    /// 소유 바이트를 돌려준다(호출자가 `gpa.free`). 길이·해시 검증은 **여기서** 한다 — 이 층은 결과만 믿는다.
    fetch: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, hash: u64, len: u64) ?[]u8,
};

fn sideFrom(gpa: std.mem.Allocator, ref: SideRef, blobs: BlobLookup) error{ BlobMissing, OutOfMemory }!turn_capture.Side {
    return switch (ref) {
        .absent => .absent,
        .empty => .empty,
        .blob => |b| .{ .text = blobs.fetch(blobs.ctx, gpa, b.hash, b.len) orelse return error.BlobMissing },
        .folded => |f| .{ .folded = .{ .hash = f.hash, .size = f.size, .why = f.why } },
        .unknown => |u| .{ .unknown = u },
    };
}

/// manifest → 링 항목 + 스토어의 봉인 턴. 턴은 **새 id** 로 들어가고 링의 `capture_id` 가 그것을 따른다.
/// blob 하나라도 없으면 **아무것도 들이지 않는다**(세션 통째로 — 이미 들인 턴은 없다: 먼저 다 만들고 나서 들인다).
pub fn restore(
    gpa: std.mem.Allocator,
    m: *const Manifest,
    store: *turn_capture.Store,
    blobs: BlobLookup,
) error{ BlobMissing, OutOfMemory }!turn_snapshot.RingMap.Entry {
    var built: std.ArrayList(turn_capture.Turn) = .empty;
    errdefer {
        for (built.items) |*t| t.deinit(gpa);
        built.deinit(gpa);
    }
    for (m.turns) |t| {
        var turn: turn_capture.Turn = .{ .shell_calls = t.shell_calls, .remote = t.remote };
        errdefer turn.deinit(gpa);
        for (t.entries) |e| {
            const path = try gpa.dupe(u8, e.path);
            errdefer gpa.free(path);
            const before = try sideFrom(gpa, e.before, blobs);
            errdefer freeSide(gpa, before);
            const after: ?turn_capture.Side = if (e.after) |a| try sideFrom(gpa, a, blobs) else null;
            errdefer if (after) |a| freeSide(gpa, a);
            try turn.entries.append(gpa, .{ .path = path, .trigger = e.trigger, .before = before, .after = after, .shell_diff = e.shell_diff, .before_trusted = e.before_trusted });
            turn.held += before.heldBytes() + (if (after) |a| a.heldBytes() else 0);
        }
        try built.append(gpa, turn);
    }
    // 여기부터는 실패가 없다 — 들이면서 id 를 바꿔 단다.
    var entry = m.entry;
    for (m.turns, 0..) |t, i| {
        const new_id = store.adoptSealed(gpa, built.items[i]);
        var k: usize = 0;
        while (k < entry.ring.len) : (k += 1) {
            const idx = (entry.ring.next + turn_snapshot.capacity - 1 - k) % turn_snapshot.capacity;
            if (entry.ring.items[idx].capture_id == t.capture_id) entry.ring.items[idx].capture_id = new_id;
        }
    }
    built.deinit(gpa);
    return entry;
}

fn freeSide(gpa: std.mem.Allocator, side: turn_capture.Side) void {
    switch (side) {
        .text => |t| gpa.free(t),
        else => {},
    }
}

// ───────────────────────── 판정자 ─────────────────────────

const testing = std.testing;

fn sampleTurn(gpa: std.mem.Allocator) !turn_capture.Turn {
    var t: turn_capture.Turn = .{ .shell_calls = 2 };
    // 경로에 따옴표·백슬래시(끝에!)·개행·`=`·공백 — 인용 규칙이 하나라도 새면 여기서 깨진다(적대적 4회차).
    try t.entries.append(gpa, .{ .path = try gpa.dupe(u8, "src/a \"q\"=x\n\\"), .trigger = .edit, .before = .{ .text = try gpa.dupe(u8, "old\n") }, .after = .{ .text = try gpa.dupe(u8, "new \"q\"\n") }, .before_trusted = true });
    try t.entries.append(gpa, .{ .path = try gpa.dupe(u8, "big.bin"), .trigger = .read, .before = .{ .folded = .{ .hash = 0xabc, .size = 5_000_000, .why = .too_large } }, .after = .{ .unknown = .budget } });
    try t.entries.append(gpa, .{ .path = try gpa.dupe(u8, "new file.md"), .trigger = .edit, .before = .absent, .after = .{ .text = try gpa.dupe(u8, "old\n") }, .shell_diff = true });
    return t;
}

const MemBlobs = struct {
    map: std.AutoHashMap(u64, []const u8),
    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, hash: u64, len: u64) ?[]u8 {
        const self: *MemBlobs = @ptrCast(@alignCast(ctx));
        const b = self.map.get(hash) orelse return null;
        if (b.len != len) return null;
        return gpa.dupe(u8, b) catch null;
    }
};

test "turn_persist: 링 + 봉인 턴이 텍스트를 지나 같은 모양으로 돌아온다 — 새 id, 같은 순서, 같은 side (AT7)" {
    const a = testing.allocator;
    // `Store` 는 112 KB 라 스택에 두지 않는다(적대적 6회차 — 두 개를 스택에 두니 test 함수 진입에서 guard page 를 밟았다).
    const store = try a.create(turn_capture.Store);
    store.* = .{};
    defer {
        store.deinit(a);
        a.destroy(store);
    }
    // `adoptSealed` 가 소유권을 가져간다 — 여기에 `errdefer turn.deinit` 을 두면 판정자가 중간에 실패할 때 **이중 해제**로 segfault 가
    // 나 실패 이유가 가려진다(적대적 6회차 뮤턴트 M6a 가 그 길로 죽었다).
    const id = store.adoptSealed(a, try sampleTurn(a));
    try testing.expect(id != 0);

    var entry: turn_snapshot.RingMap.Entry = .{ .id_len = 4, .repo_len = 12, .used = 1 };
    @memcpy(entry.id[0..4], "S-01");
    @memcpy(entry.repo[0..12], "mac:/r/ep o/");
    entry.ring.push(.{ .tree = "aaaa", .captured_s = 100, .agent_kind = 1 });
    entry.ring.push(.{ .tree = "bbbb", .captured_s = 200, .agent_kind = 1, .turn_key = "t-2", .title = "제목 \"인용\"\n둘째 줄", .capture_id = id });
    entry.ring.markFiles("bbbb", 3, 2);
    entry.ring.missed = 4;
    entry.ring.history_evicted = true;

    var m = try fromRing(a, &entry, &.{.{ .id = id, .turn = store.sealedTurn(id).? }});
    defer releaseBorrowed(a, &m);
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try write(&buf.writer, &m);
    const text = buf.written();
    try testing.expect(std.mem.startsWith(u8, text, header ++ "\nsession id=\"S-01\" repo=\"mac:/r/ep o/\" missed=4 history-evicted=1\n"));
    try testing.expect(std.mem.indexOf(u8, text, "snapshot tree=\"aaaa\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "title=\"제목 \\\"인용\\\"\\n둘째 줄\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "entry path=\"new file.md\" trigger=edit before=absent after=blob:") != null);
    // 사본 본문은 텍스트에 없다.
    try testing.expect(std.mem.indexOf(u8, text, "new \"q\"") == null);

    var parsed = try parse(a, text);
    defer parsed.deinit(a);
    try testing.expectEqualStrings("S-01", parsed.entry.sessionId());
    try testing.expectEqualStrings("mac:/r/ep o/", parsed.entry.repoPath());
    try testing.expectEqual(@as(usize, 2), parsed.entry.ring.len);
    try testing.expectEqualStrings("bbbb", parsed.entry.ring.latest().?.oid());
    try testing.expectEqualStrings("aaaa", parsed.entry.ring.nth(1).?.oid());
    try testing.expectEqual(@as(u32, 3), parsed.entry.ring.latest().?.changed_files);
    try testing.expect(parsed.entry.ring.latest().?.files_known);
    try testing.expectEqual(@as(u32, 2), parsed.entry.ring.latest().?.edited_joined);
    try testing.expectEqualStrings("제목 \"인용\"\n둘째 줄", parsed.entry.ring.latest().?.titleText());
    try testing.expectEqual(@as(u32, 4), parsed.entry.ring.missed);
    try testing.expect(parsed.entry.ring.history_evicted);
    try testing.expectEqual(@as(usize, 1), parsed.turns.len);
    try testing.expectEqual(@as(usize, 3), parsed.turns[0].entries.len);

    // 되살리기 — blob 은 메모리에서.
    var blobs: MemBlobs = .{ .map = .init(a) };
    defer blobs.map.deinit();
    try blobs.map.put(blobHash("old\n"), "old\n");
    try blobs.map.put(blobHash("new \"q\"\n"), "new \"q\"\n");
    const store2 = try a.create(turn_capture.Store);
    store2.* = .{};
    defer {
        store2.deinit(a);
        a.destroy(store2);
    }
    const restored = try restore(a, &parsed, store2, .{ .ctx = &blobs, .fetch = MemBlobs.fetch });
    const new_id = restored.ring.latest().?.capture_id;
    try testing.expect(new_id != 0);
    const rt = store2.sealedTurn(new_id).?;
    try testing.expectEqual(@as(u32, 2), rt.shell_calls);
    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("src/a \"q\"=x\n\\", rt.entries.items[0].path);
    try testing.expectEqualStrings("old\n", rt.entries.items[0].before.text);
    try testing.expectEqualStrings("new \"q\"\n", rt.entries.items[0].after.?.text);
    try testing.expect(rt.entries.items[0].before_trusted);
    try testing.expect(rt.entries.items[1].before.folded.why == .too_large);
    try testing.expect(rt.entries.items[1].after.?.unknown == .budget);
    try testing.expect(rt.entries.items[2].before == .absent);
    try testing.expect(rt.entries.items[2].shell_diff);
    try testing.expectEqual(@as(u32, 2), rt.edited_count); // a.zig(다름) + 새 파일(absent→text)
    try testing.expectEqual(@as(usize, 2 * 4 + 8), rt.held); // "old\n" ×2 + "new \"q\"\n"
}

test "turn_persist: 손상은 통째로 거절한다 — 헤더·잘린 줄·모르는 side·링이 가리키는 turn 없음·blob 없음" {
    const a = testing.allocator;
    try testing.expectError(error.BadHeader, parse(a, "maru.turn-ring.v2\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\n"));
    try testing.expectError(error.BadLine, parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0\n")); // 필드 하나 빠짐
    try testing.expectError(error.BadLine, parse(a, header ++ "\nsnapshot tree=\"a\"\n")); // session 줄 없이
    try testing.expectError(error.BadValue, parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\nturn capture=1 shell-calls=0 remote=0 entries=1\nentry path=\"p\" trigger=edit before=weird after=none shell-diff=0 before-trusted=0\n"));
    // turn 이 entries=2 라 했는데 하나만
    try testing.expectError(error.BadLine, parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\nturn capture=1 shell-calls=0 remote=0 entries=2\nentry path=\"p\" trigger=edit before=absent after=none shell-diff=0 before-trusted=0\n"));
    // 링이 capture=7 을 가리키는데 turn 줄이 없다
    try testing.expectError(error.BadValue, parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\nsnapshot tree=\"a\" surface=0 captured=0 kind=0 files=0 files-known=0 edited=0 edited-known=0 capture=7 turn=\"\" title=\"\"\n"));
    // turn 뒤에 snapshot 이 오면 순서 위반(쓰는 쪽은 절대 그렇게 안 쓴다) — 통째로.
    try testing.expectError(error.BadLine, parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\nturn capture=1 shell-calls=0 remote=0 entries=0\nsnapshot tree=\"a\" surface=0 captured=0 kind=0 files=0 files-known=0 edited=0 edited-known=0 capture=0 turn=\"\" title=\"\"\n"));
    // 파싱은 되지만 blob 이 없다 → restore 가 아무것도 안 들인다
    var parsed = try parse(a, header ++ "\nsession id=\"x\" repo=\"\" missed=0 history-evicted=0\nsnapshot tree=\"a\" surface=0 captured=0 kind=0 files=0 files-known=0 edited=0 edited-known=0 capture=7 turn=\"\" title=\"\"\nturn capture=7 shell-calls=0 remote=0 entries=1\nentry path=\"p\" trigger=edit before=blob:1:3 after=none shell-diff=0 before-trusted=0\n");
    defer parsed.deinit(a);
    var blobs: MemBlobs = .{ .map = .init(a) };
    defer blobs.map.deinit();
    // `Store` 는 112 KB 라 스택에 두지 않는다(적대적 6회차 — 두 개를 스택에 두니 test 함수 진입에서 guard page 를 밟았다).
    const store = try a.create(turn_capture.Store);
    store.* = .{};
    defer {
        store.deinit(a);
        a.destroy(store);
    }
    try testing.expectError(error.BlobMissing, restore(a, &parsed, store, .{ .ctx = &blobs, .fetch = MemBlobs.fetch }));
    try testing.expectEqual(@as(turn_capture.Id, 1), store.next_id); // 아무것도 안 들였다
}

test "turn_persist: 링이 안 가리키는 턴은 안 적고, 상한을 넘는 snapshot 줄은 거절한다" {
    const a = testing.allocator;
    // `Store` 는 112 KB 라 스택에 두지 않는다(적대적 6회차 — 두 개를 스택에 두니 test 함수 진입에서 guard page 를 밟았다).
    const store = try a.create(turn_capture.Store);
    store.* = .{};
    defer {
        store.deinit(a);
        a.destroy(store);
    }
    const orphan = store.adoptSealed(a, try sampleTurn(a));
    var entry: turn_snapshot.RingMap.Entry = .{ .id_len = 1 };
    entry.id[0] = 's';
    entry.ring.push(.{ .tree = "t1" });
    var m = try fromRing(a, &entry, &.{.{ .id = orphan, .turn = store.sealedTurn(orphan).? }});
    defer releaseBorrowed(a, &m);
    try testing.expectEqual(@as(usize, 0), m.turns.len);

    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeAll(header ++ "\nsession id=\"s\" repo=\"\" missed=0 history-evicted=0\n");
    var i: usize = 0;
    while (i < turn_snapshot.capacity + 1) : (i += 1) {
        try text.writer.print("snapshot tree=\"t{d}\" surface=0 captured=0 kind=0 files=0 files-known=0 edited=0 edited-known=0 capture=0 turn=\"\" title=\"\"\n", .{i});
    }
    try testing.expectError(error.TooMany, parse(a, text.written()));
}
