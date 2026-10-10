//! 워크스페이스 신뢰(docs/editor-surface-tooling.md §8.1·§8.2a 「신뢰」, 계획 docs/plans/workspace-trust.md WT2) — **앱 전체에 표 하나**.
//! 순수 계산: 표·세대 번호·묻는 자리·줄 형식·옛 형식 이관. 파일 읽기·쓰기와 키 정규화(실제 경로·볼륨)는 호출자.
//!
//! 파일은 줄마다 `allow\t‹볼륨 16진›\t‹실제 경로›` / `deny\t…` / `forget\t…`(결정을 지운다 — 계획 WT4a) 이고 마지막 줄이 이긴다 —
//! 결정을 바꾸거나 잊으면 뒤에 붙이기만 한다. 원격(SSH) 저장소는 네 칸 `allow\tssh\t‹목적지›\t‹원격 실제 경로›`(계획 WT7a) — 칸 수가
//! 달라 옛 빌드는 그 줄을 무시한다(로컬 키로 잘못 읽지 않는다).
//! **개행으로 끝나지 않은 줄은 읽지 않는다** — 덧붙이다 끊긴 줄(디스크가 찼다)은 경로가 잘려 있어 부모 폴더의 결정으로 읽힐 수 있다.
//! 옛 형식(`allow\t‹root›` — 창마다 따로 읽던 설정 옆 `lsp-trust`)은 이관할 때만 읽는다(`Store.mergeLegacy`).

const std = @import("std");

pub const Decision = enum { allow, deny };

/// 신뢰 키 — 로컬 저장소는 **(볼륨, 실제 경로)**. 작업 root(서버의 rootUri·표시)와 따로 둔다: `/tmp/x` 와 `/private/tmp/x`, 심링크,
/// 대소문자만 다른 경로가 한 키가 되고(그래야 거부가 먹는다), 같은 경로라도 볼륨이 다르면(같은 자리에 다른 디스크) 다른 키다.
///
/// 원격(SSH) 저장소는 **(목적지, 원격 실제 경로)**(계획 workspace-trust WT7 — 2026-10-11 사용자 결정: VS Code 와 같게, 연결 이름 + 경로).
/// `dest` 가 비면 로컬, 있으면 원격이고 그때 `volume` 은 0 이다. 목적지는 `maru ssh` 에 준 그 문자열을 `normalizeDest` 로 맞춘 것이다 —
/// 같은 기계라도 다른 이름(`dev`·`me@1.2.3.4`)으로 붙으면 다른 키다(VS Code 도 같다). 그 이름으로 붙는 기계가 진짜인지는 연결 때 ssh 의
/// `known_hosts` 검사가 지킨다.
pub const Key = struct {
    volume: u64,
    path: []const u8,
    dest: []const u8 = "",

    pub fn eql(a: Key, b: Key) bool {
        return a.volume == b.volume and std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.dest, b.dest);
    }

    pub fn isRemote(self: Key) bool {
        return self.dest.len > 0;
    }
};

/// 원격 목적지의 상한 — 앱이 원격 목적지를 들고 다니는 자리(`max_remote_dest_bytes`)와 같다.
pub const max_dest_bytes: usize = 256;

/// 원격 목적지를 키로 맞춘다(계획 WT7a): **호스트 부분만 소문자로** 둔다(ssh 도 호스트 이름의 대소문자를 가리지 않는다), `user@` 는 그대로
/// (계정 이름은 대소문자를 가린다). 빈 값·제어 문자·탭·상한 초과는 `null` — 그런 목적지는 기억할 수 없다(줄 형식이 깨지거나 표시가 깨진다).
pub fn normalizeDest(dest: []const u8, out: []u8) ?[]const u8 {
    if (dest.len == 0 or dest.len > max_dest_bytes or dest.len > out.len) return null;
    for (dest) |c| if (c < 0x20 or c == 0x7f) return null;
    const host_at = if (std.mem.lastIndexOfScalar(u8, dest, '@')) |at| at + 1 else 0;
    if (host_at >= dest.len) return null; // `user@` 만 — 호스트가 없다
    @memcpy(out[0..host_at], dest[0..host_at]);
    for (dest[host_at..], host_at..) |c, i| out[i] = std.ascii.toLower(c);
    return out[0..dest.len];
}

/// 한 줄. `decision == null` 은 `forget` 줄이다 — 그 키의 결정을 지운다(계획 WT4 「잊기」).
pub const Entry = struct { key: Key, decision: ?Decision };

/// 한 줄을 읽는다(빌린 경로). 모르는 동사·칸 수가 다른 줄·16진이 아닌 볼륨·상대 경로는 `null` — 무시한다. 네 칸이고 둘째 칸이 `ssh`
/// 면 원격 줄이다(목적지가 이미 맞춘 모양이 아니면 — 빈 값·제어 문자·대문자 호스트 — 무시한다: 파일을 손으로 고쳐 같은 기계가 두 키로
/// 갈리지 않게).
pub fn parseLine(raw: []const u8) ?Entry {
    const entry = std.mem.trimEnd(u8, raw, "\r");
    var it = std.mem.splitScalar(u8, entry, '\t');
    const verb = it.next() orelse return null;
    const second = it.next() orelse return null;
    const third = it.next() orelse return null;
    const fourth = it.next();
    if (it.next() != null) return null;
    const decision: ?Decision = if (std.mem.eql(u8, verb, "allow")) .allow else if (std.mem.eql(u8, verb, "deny")) .deny else if (std.mem.eql(u8, verb, "forget")) null else return null;
    if (fourth) |path| {
        if (!std.mem.eql(u8, second, "ssh")) return null;
        var dest_buf: [max_dest_bytes]u8 = undefined;
        const normalized = normalizeDest(third, &dest_buf) orelse return null;
        if (!std.mem.eql(u8, normalized, third)) return null;
        if (path.len == 0 or path[0] != '/') return null;
        return .{ .key = .{ .volume = 0, .path = path, .dest = third }, .decision = decision };
    }
    if (second.len == 0) return null;
    const volume = std.fmt.parseInt(u64, second, 16) catch return null;
    if (third.len == 0 or third[0] != '/') return null;
    return .{ .key = .{ .volume = volume, .path = third }, .decision = decision };
}

/// 붙일 한 줄(개행 포함). `decision == null` 이면 `forget` 줄. `out` 이 모자라면 `null`. 경로에 탭·개행이 있으면 `null` — 그런 경로는
/// 기억할 수 없다(줄 형식이 깨진다).
pub fn line(decision: ?Decision, key: Key, out: []u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, key.path, "\t\n\r") != null) return null;
    const verb = if (decision) |d| @tagName(d) else "forget";
    if (key.isRemote()) {
        var dest_buf: [max_dest_bytes]u8 = undefined;
        const normalized = normalizeDest(key.dest, &dest_buf) orelse return null;
        if (!std.mem.eql(u8, normalized, key.dest)) return null; // 맞추지 않은 목적지는 키가 아니다
        return std.fmt.bufPrint(out, "{s}\tssh\t{s}\t{s}\n", .{ verb, key.dest, key.path }) catch null;
    }
    return std.fmt.bufPrint(out, "{s}\t{x}\t{s}\n", .{ verb, key.volume, key.path }) catch null;
}

/// 한 줄의 최대 길이 — 버퍼를 잡는 자리(파일 덧붙이기·다시 쓰기)가 이 값을 쓴다.
pub const max_line_bytes: usize = std.fs.max_path_bytes + max_dest_bytes + 32;

/// 개행으로 끝난 줄만 돈다 — 마지막 개행 뒤의 조각(끊긴 줄)은 버린다.
fn completeLines(contents: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const end = if (std.mem.lastIndexOfScalar(u8, contents, '\n')) |i| i else 0;
    return std.mem.splitScalar(u8, contents[0..end], '\n');
}

const LegacyLine = struct { root: []const u8, decision: Decision };

fn legacyLine(raw: []const u8) ?LegacyLine {
    const entry = std.mem.trimEnd(u8, raw, "\r");
    const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse return null;
    const verb = entry[0..tab];
    const root = entry[tab + 1 ..];
    if (root.len == 0) return null;
    const decision: Decision = if (std.mem.eql(u8, verb, "allow")) .allow else if (std.mem.eql(u8, verb, "deny")) .deny else return null;
    return .{ .root = root, .decision = decision };
}

/// 앱 전체의 신뢰 표. 창(세션)마다 캐시하지 않는다 — 한 창의 결정이 다른 창에 서야 한다. 각 창은 `generation` 을 기억해 두고 달라지면
/// 자기 클라이언트에 결정을 다시 적용한다(거부면 서버를 내린다).
pub const Store = struct {
    entries: std.ArrayList(Owned) = .empty,
    /// 묻는 중인 키와 그 창 — **한 키는 한 창만 묻는다**(두 창이 같은 저장소를 동시에 묻지 않게). 다른 창은 답을 기다린다.
    claims: std.ArrayList(Claim) = .empty,
    /// 결정이 바뀔 때마다 오른다.
    generation: u64 = 0,

    /// `changed_at` — 그 항목의 결정이 마지막으로 바뀐 세대(다시 묻는 중인 창이 「그 뒤에 다른 데서 답이 왔나」를 본다).
    /// `decision == null` 은 **실행 중에 잊은** 표시다(`forget`) — 결정은 없고, 각 창이 「언제 잊었나」를 보고 제 서버를 내린다. 파일에서
    /// 읽은 `forget` 줄은 이 표시를 남기지 않고 항목을 지운다(시작할 때 잊은 것은 그냥 결정이 없는 것이다).
    const Owned = struct {
        volume: u64,
        path: []const u8,
        dest: []const u8,
        decision: ?Decision,
        changed_at: u64,

        fn key(self: Owned) Key {
            return .{ .volume = self.volume, .path = self.path, .dest = self.dest };
        }
    };

    /// 결정이 있는 항목을 **읽기 전용으로** 돈다(경로는 빌린 `[]const u8`) — 표 밖에서 항목을 고치는 길을 열지 않는다(계획 WT2a
    /// 「신뢰 부여는 사용자의 답으로만」). 이번 실행에 잊은 것은 건너뛴다.
    pub fn decided(self: *const Store) Decided {
        return .{ .items = self.entries.items };
    }

    pub const Decided = struct {
        items: []const Owned,
        i: usize = 0,

        pub fn next(self: *Decided) ?struct { key: Key, decision: Decision } {
            while (self.i < self.items.len) {
                const e = self.items[self.i];
                self.i += 1;
                const d = e.decision orelse continue;
                return .{ .key = e.key(), .decision = d };
            }
            return null;
        }
    };
    const Claim = struct {
        volume: u64,
        path: []u8,
        dest: []u8,
        owner: usize,

        fn key(self: Claim) Key {
            return .{ .volume = self.volume, .path = self.path, .dest = self.dest };
        }
    };

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| freeOwned(allocator, e.path, e.dest);
        self.entries.deinit(allocator);
        for (self.claims.items) |c| freeOwned(allocator, c.path, c.dest);
        self.claims.deinit(allocator);
        self.* = .{};
    }

    /// 키의 두 문자열을 복사한다(목적지가 비면 빈 조각 — 로컬 키).
    fn dupeKey(allocator: std.mem.Allocator, key: Key) !struct { path: []u8, dest: []u8 } {
        const path = try allocator.dupe(u8, key.path);
        errdefer allocator.free(path);
        const dest = try allocator.dupe(u8, key.dest);
        return .{ .path = path, .dest = dest };
    }

    fn freeOwned(allocator: std.mem.Allocator, path: []const u8, dest: []const u8) void {
        allocator.free(path);
        allocator.free(dest);
    }

    pub fn get(self: *const Store, key: Key) ?Decision {
        for (self.entries.items) |e| if (e.key().eql(key)) return e.decision;
        return null;
    }

    /// 그 키의 결정이 마지막으로 바뀐 세대(없으면 `null`).
    pub fn changedAt(self: *const Store, key: Key) ?u64 {
        for (self.entries.items) |e| if (e.key().eql(key)) return e.changed_at;
        return null;
    }

    /// 결정을 둔다. 바뀌었으면 세대를 올리고 `true`.
    pub fn put(self: *Store, allocator: std.mem.Allocator, key: Key, decision: Decision) !bool {
        for (self.entries.items) |*e| {
            if (!e.key().eql(key)) continue;
            if (e.decision == decision) return false;
            self.generation +%= 1;
            e.decision = decision;
            e.changed_at = self.generation;
            return true;
        }
        const owned = try dupeKey(allocator, key);
        errdefer freeOwned(allocator, owned.path, owned.dest);
        try self.entries.append(allocator, .{ .volume = key.volume, .path = owned.path, .dest = owned.dest, .decision = decision, .changed_at = self.generation +% 1 });
        self.generation +%= 1;
        return true;
    }

    /// 결정을 잊는다(계획 WT4) — 표시(`decision = null`)를 남겨 세대를 올린다. 결정이 없었으면 `false`.
    pub fn forget(self: *Store, key: Key) bool {
        for (self.entries.items) |*e| {
            if (!e.key().eql(key)) continue;
            if (e.decision == null) return false;
            self.generation +%= 1;
            e.decision = null;
            e.changed_at = self.generation;
            return true;
        }
        return false;
    }

    /// 항목을 통째로 지운다(파일의 `forget` 줄 — 표시를 남기지 않는다).
    fn drop(self: *Store, allocator: std.mem.Allocator, key: Key) void {
        for (self.entries.items, 0..) |e, i| {
            if (!e.key().eql(key)) continue;
            freeOwned(allocator, e.path, e.dest);
            _ = self.entries.orderedRemove(i);
            return;
        }
    }

    /// 같은 결정을 다시 답했다 — 결정은 그대로지만 「그 뒤에 답이 섰다」를 남긴다(세대·`changed_at` 이 오른다). 다른 창에서 같은 저장소를
    /// 「다시 묻기」 중이던 클라이언트가 이 답을 제 물음의 답으로 본다(같은 질문을 또 하지 않게). 항목이 없으면 아무것도 안 한다.
    pub fn touch(self: *Store, key: Key) void {
        for (self.entries.items) |*e| {
            if (!e.key().eql(key)) continue;
            self.generation +%= 1;
            e.changed_at = self.generation;
            return;
        }
    }

    /// 새 형식의 파일 내용을 읽어 둔다(마지막 줄이 이긴다). 못 읽는 줄·끊긴 마지막 줄은 건너뛴다.
    pub fn load(self: *Store, allocator: std.mem.Allocator, contents: []const u8) !void {
        var it = completeLines(contents);
        while (it.next()) |raw| {
            const e = parseLine(raw) orelse continue;
            if (e.decision) |d| {
                _ = try self.put(allocator, e.key, d);
            } else self.drop(allocator, e.key);
        }
    }

    /// 옛 형식을 합친다 — ① root 마다 마지막 줄 ② `canon` 으로 실제 키 ③ 같은 키에 결정이 갈리면(표에 이미 있던 것까지) **거부가
    /// 이긴다**. 키를 못 구하는 root(사라졌거나 지금 못 여는 경로 — 마운트 안 된 디스크)는 버린다 — 그 저장소는 다음에 다시 묻는다.
    /// 합친 root 수를 돌려준다.
    /// `canon(ctx, root, buf)` 는 `buf` 에 실제 경로를 담은 키를 낸다.
    pub fn mergeLegacy(
        self: *Store,
        allocator: std.mem.Allocator,
        contents: []const u8,
        ctx: anytype,
        comptime canon: fn (@TypeOf(ctx), []const u8, *[std.fs.max_path_bytes]u8) ?Key,
    ) !usize {
        // ① root 마다 마지막 줄 — 줄 순서대로 덮어쓴다(root 수만큼만 든다).
        var finals: std.ArrayList(LegacyLine) = .empty;
        defer finals.deinit(allocator);
        var it = completeLines(contents);
        while (it.next()) |raw| {
            const l = legacyLine(raw) orelse continue;
            for (finals.items) |*f| {
                if (std.mem.eql(u8, f.root, l.root)) {
                    f.decision = l.decision;
                    break;
                }
            } else try finals.append(allocator, l);
        }
        var merged: usize = 0;
        for (finals.items) |f| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const key = canon(ctx, f.root, &buf) orelse continue; // ②
            const decision: Decision = if (self.get(key)) |had| (if (had == .deny or f.decision == .deny) .deny else .allow) else f.decision; // ③
            _ = try self.put(allocator, key, decision);
            merged += 1;
        }
        return merged;
    }

    /// 표 전체를 새 형식으로(이관 뒤 파일을 한 번 다시 쓴다). 적을 수 없는 경로(탭·개행)는 빠진다.
    pub fn serialize(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            if (e.decision == null) continue; // 잊은 것은 적지 않는다
            var buf: [max_line_bytes]u8 = undefined;
            const l = line(e.decision, e.key(), &buf) orelse continue;
            try out.appendSlice(allocator, l);
        }
        return out.toOwnedSlice(allocator);
    }

    /// 그 키를 묻는 창(없으면 `null`).
    pub fn claimant(self: *const Store, key: Key) ?usize {
        for (self.claims.items) |c| if (c.key().eql(key)) return c.owner;
        return null;
    }

    /// 그 키를 `owner` 가 묻겠다고 잡는다. 다른 창이 이미 잡았으면 `false`(그 창의 답을 기다린다), 비었거나 제 것이면 `true`.
    pub fn claim(self: *Store, allocator: std.mem.Allocator, key: Key, owner: usize) !bool {
        if (self.claimant(key)) |o| return o == owner;
        const owned = try dupeKey(allocator, key);
        errdefer freeOwned(allocator, owned.path, owned.dest);
        try self.claims.append(allocator, .{ .volume = key.volume, .path = owned.path, .dest = owned.dest, .owner = owner });
        return true;
    }

    /// `owner` 가 잡은 자리를 놓는다(답했거나 답 없이 닫혔다). `key` 가 `null` 이면 그 창의 자리 전부(창이 닫힌다).
    pub fn release(self: *Store, allocator: std.mem.Allocator, key: ?Key, owner: usize) void {
        var i: usize = 0;
        while (i < self.claims.items.len) {
            const c = self.claims.items[i];
            const hit = c.owner == owner and if (key) |k| c.key().eql(k) else true;
            if (!hit) {
                i += 1;
                continue;
            }
            freeOwned(allocator, c.path, c.dest);
            _ = self.claims.swapRemove(i);
        }
    }
};

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자용 — 옛 root 를 그대로 키로(볼륨 1).
fn identityCanon(_: void, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ?Key {
    if (root.len == 0 or root[0] != '/') return null;
    @memcpy(buf[0..root.len], root);
    return .{ .volume = 1, .path = buf[0..root.len] };
}

test "LST1 옛 형식 이관 — root 마다 마지막 줄이 이긴다(어느 순서든); 모르는 동사·탭 없는 줄·끊긴 마지막 줄은 무시 (§8.2a)" {
    const a = testing.allocator;
    var s: Store = .{};
    defer s.deinit(a);
    const f = "allow\t/a\nweird\t/a\nallow /b\ndeny\t/a\r\nallow\t/c\ndeny\t/d\nallow\t/d\nallow\t/e";
    _ = try s.mergeLegacy(a, f, {}, identityCanon);
    try testing.expectEqual(@as(?Decision, .deny), s.get(.{ .volume = 1, .path = "/a" })); // 허용 뒤 거부
    try testing.expectEqual(@as(?Decision, .allow), s.get(.{ .volume = 1, .path = "/d" })); // 거부 뒤 허용 — 첫 줄이 아니다
    try testing.expectEqual(@as(?Decision, .allow), s.get(.{ .volume = 1, .path = "/c" }));
    try testing.expect(s.get(.{ .volume = 1, .path = "/b" }) == null); // 탭이 아니다
    try testing.expect(s.get(.{ .volume = 1, .path = "/e" }) == null); // 개행으로 안 끝난 마지막 줄 — 끊긴 줄일 수 있다
    try testing.expectEqual(@as(usize, 3), s.entries.items.len);
}

test "LST2 줄 만들기·읽기 — 되읽으면 같은 키와 결정; 탭·개행이 든 경로는 못 적고, 칸 수·동사·볼륨·상대 경로가 틀린 줄은 안 읽는다" {
    var buf: [96]u8 = undefined;
    const k: Key = .{ .volume = 0x1000012, .path = "/x/y z" };
    const l = line(.allow, k, &buf).?;
    try testing.expectEqualStrings("allow\t1000012\t/x/y z\n", l);
    const e = parseLine(std.mem.trimEnd(u8, l, "\n")).?;
    try testing.expect(e.key.eql(k));
    try testing.expectEqual(@as(?Decision, .allow), e.decision);
    try testing.expectEqualStrings("forget\t1000012\t/x/y z\n", line(null, k, &buf).?);
    try testing.expectEqual(@as(?Decision, null), parseLine("forget\t1\t/x").?.decision);
    try testing.expect(line(.deny, .{ .volume = 1, .path = "/bad\tpath" }, &buf) == null);
    try testing.expect(line(.deny, .{ .volume = 1, .path = "/bad\npath" }, &buf) == null);
    var tiny: [4]u8 = undefined;
    try testing.expect(line(.deny, .{ .volume = 1, .path = "/x" }, &tiny) == null);
    try testing.expect(parseLine("allow\t/x") == null); // 옛 형식은 새 표에 안 들어온다
    try testing.expect(parseLine("allow\tzz\t/x") == null);
    try testing.expect(parseLine("allow\t\t/x") == null);
    try testing.expect(parseLine("allow\t1\tx") == null); // 상대 경로
    try testing.expect(parseLine("allow\t1\t/x\textra") == null);
    try testing.expect(parseLine("maybe\t1\t/x") == null);
    try testing.expectEqual(@as(?Decision, .deny), parseLine("deny\t1\t/x\r").?.decision);
}

test "LST3 표 — 키는 볼륨과 경로 둘 다; 결정이 바뀔 때만 세대가 오르고, 읽으면 마지막 줄이 이긴다" {
    const a = testing.allocator;
    var s: Store = .{};
    defer s.deinit(a);
    const k: Key = .{ .volume = 1, .path = "/r" };
    try testing.expect(s.get(k) == null);
    try testing.expect(try s.put(a, k, .allow));
    try testing.expectEqual(@as(u64, 1), s.generation);
    try testing.expect(!try s.put(a, k, .allow)); // 같은 답 — 세대 그대로
    try testing.expectEqual(@as(u64, 1), s.generation);
    try testing.expect(s.get(.{ .volume = 2, .path = "/r" }) == null); // 같은 경로, 다른 볼륨
    try testing.expect(s.get(.{ .volume = 1, .path = "/r/sub" }) == null); // 부모의 결정이 자식으로 새지 않는다
    try testing.expect(s.get(.{ .volume = 1, .path = "/" }) == null); // 자식의 결정이 부모로 새지 않는다(적대적 1회차 A12)
    try testing.expect(s.get(.{ .volume = 1, .path = "/rr" }) == null);
    try testing.expectEqual(@as(?u64, 1), s.changedAt(k));
    _ = try s.put(a, .{ .volume = 1, .path = "/other" }, .allow); // 다른 키의 변경은 그 키의 세대가 아니다
    try testing.expect(try s.put(a, k, .deny));
    try testing.expectEqual(@as(?Decision, .deny), s.get(k));
    try testing.expectEqual(@as(u64, 3), s.generation);
    try testing.expectEqual(@as(?u64, 3), s.changedAt(k));
    try testing.expectEqual(@as(?u64, 2), s.changedAt(.{ .volume = 1, .path = "/other" }));
    s.touch(k); // 같은 답을 다시 — 결정은 그대로, 「답이 섰다」만 남는다
    try testing.expectEqual(@as(?Decision, .deny), s.get(k));
    try testing.expectEqual(@as(u64, 4), s.generation);
    try testing.expectEqual(@as(?u64, 4), s.changedAt(k));
    s.touch(.{ .volume = 9, .path = "/none" }); // 없는 키는 그대로
    try testing.expectEqual(@as(u64, 4), s.generation);

    var t: Store = .{};
    defer t.deinit(a);
    // 마지막 줄은 개행이 없다 — 덧붙이다 끊긴 줄(`/r/sub` 가 `/r` 로 잘렸을 수 있다)이라 읽지 않는다.
    try t.load(a, "allow\t1\t/r\nallow\t/old\ngarbage\ndeny\t1\t/r\nallow\t2\t/r\nallow\t1\t/q");
    try testing.expectEqual(@as(?Decision, .deny), t.get(k));
    try testing.expectEqual(@as(?Decision, .allow), t.get(.{ .volume = 2, .path = "/r" }));
    try testing.expect(t.get(.{ .volume = 1, .path = "/q" }) == null);
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
}

test "LST4 옛 형식 이관 — root 마다 마지막 줄, 실제 키로 모아 갈리면(표에 있던 것까지) 거부가 이기고, 키를 못 구하는 root 는 버린다" {
    const a = testing.allocator;
    var s: Store = .{};
    defer s.deinit(a);
    _ = try s.put(a, .{ .volume = 1, .path = "/private/kept" }, .deny); // 표에 이미 거부 — 옛 허용이 못 이긴다
    const Canon = struct {
        fn f(_: void, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ?Key {
            if (std.mem.eql(u8, root, "/gone")) return null;
            // `/tmp/…` 와 `/private/tmp/…` 는 한 저장소다(심링크).
            const real = if (std.mem.startsWith(u8, root, "/tmp/")) "/private" else "";
            const p = std.fmt.bufPrint(buf, "{s}{s}", .{ real, root }) catch return null;
            return .{ .volume = 1, .path = p };
        }
    };
    const legacy =
        "deny\t/tmp/a\nallow\t/tmp/a\n" ++ // 같은 root — 마지막 줄(허용)
        "deny\t/private/tmp/a\n" ++ // 같은 저장소의 다른 이름 — 거부가 이긴다
        "allow\t/tmp/b\n" ++
        "allow\t/gone\n" ++ // 사라진 경로 — 버린다
        "allow\t/private/kept\n";
    try testing.expectEqual(@as(usize, 4), try s.mergeLegacy(a, legacy, {}, Canon.f));
    try testing.expectEqual(@as(?Decision, .deny), s.get(.{ .volume = 1, .path = "/private/tmp/a" }));
    try testing.expectEqual(@as(?Decision, .allow), s.get(.{ .volume = 1, .path = "/private/tmp/b" }));
    try testing.expectEqual(@as(?Decision, .deny), s.get(.{ .volume = 1, .path = "/private/kept" }));
    try testing.expect(s.get(.{ .volume = 1, .path = "/gone" }) == null);
    try testing.expectEqual(@as(usize, 3), s.entries.items.len);

    // 다시 쓴 표를 되읽으면 같은 결정이다.
    const text = try s.serialize(a);
    defer a.free(text);
    var r: Store = .{};
    defer r.deinit(a);
    try r.load(a, text);
    for (s.entries.items) |e| try testing.expectEqual(@as(?Decision, e.decision), r.get(.{ .volume = e.volume, .path = e.path }));
    try testing.expectEqual(s.entries.items.len, r.entries.items.len);
}

test "LST5 묻는 자리 — 한 키는 한 창만; 제 것은 다시 잡혀도 하나, 놓으면 다른 창이 잡고, 창이 닫히면 그 창의 자리 전부를 놓는다" {
    const a = testing.allocator;
    var s: Store = .{};
    defer s.deinit(a);
    const k: Key = .{ .volume = 1, .path = "/r" };
    const other: Key = .{ .volume = 1, .path = "/q" };
    try testing.expect(try s.claim(a, k, 10));
    try testing.expect(try s.claim(a, k, 10));
    try testing.expectEqual(@as(usize, 1), s.claims.items.len);
    try testing.expect(!try s.claim(a, k, 20)); // 다른 창 — 기다린다
    try testing.expect(try s.claim(a, other, 20)); // 다른 키는 그 창이 묻는다
    try testing.expectEqual(@as(?usize, 10), s.claimant(k));
    s.release(a, k, 20); // 남의 자리는 못 놓는다
    try testing.expectEqual(@as(?usize, 10), s.claimant(k));
    s.release(a, k, 10);
    try testing.expect(s.claimant(k) == null);
    try testing.expect(try s.claim(a, k, 20));
    s.release(a, null, 20); // 창이 닫혔다
    try testing.expectEqual(@as(usize, 0), s.claims.items.len);
    try testing.expectEqual(@as(u64, 0), s.generation); // 묻는 자리는 결정이 아니다
}

test "LST13 잊기 — 실행 중에는 표시를 남겨 세대를 올리고(창들이 제 서버를 내린다), 파일의 `forget` 줄은 항목을 지운다; 다시 쓰면 잊은 것은 빠진다 (계획 WT4)" {
    const a = testing.allocator;
    var s: Store = .{};
    defer s.deinit(a);
    const k: Key = .{ .volume = 1, .path = "/r" };
    try testing.expect(!s.forget(k)); // 결정이 없으면 잊을 것도 없다
    _ = try s.put(a, k, .allow);
    const g = s.generation;
    try testing.expect(s.forget(k));
    try testing.expect(s.get(k) == null);
    try testing.expectEqual(g + 1, s.generation);
    try testing.expectEqual(@as(?u64, g + 1), s.changedAt(k)); // 언제 잊었나
    try testing.expect(!s.forget(k)); // 두 번은 아니다
    try testing.expect(try s.put(a, k, .deny)); // 잊은 뒤 다시 답하면 바뀐 것이다
    try testing.expectEqual(@as(?Decision, .deny), s.get(k));
    try testing.expect(s.forget(k));
    _ = try s.put(a, .{ .volume = 1, .path = "/q" }, .allow);
    const text = try s.serialize(a);
    defer a.free(text);
    try testing.expectEqualStrings("allow\t1\t/q\n", text); // 잊은 /r 은 적지 않는다
    var d = s.decided();
    const only = d.next().?; // 잊은 /r 은 목록에도 없다
    try testing.expectEqualStrings("/q", only.key.path);
    try testing.expect(d.next() == null);

    var t: Store = .{};
    defer t.deinit(a);
    try t.load(a, "allow\t1\t/r\nforget\t1\t/r\nallow\t1\t/q\nforget\t1\t/none\n");
    try testing.expect(t.get(k) == null);
    try testing.expect(t.changedAt(k) == null); // 시작할 때 잊은 것은 표시 없이 지운다
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try t.load(a, "deny\t1\t/r\n"); // 잊은 뒤의 결정은 다시 선다
    try testing.expectEqual(@as(?Decision, .deny), t.get(k));
}

test "LST-R1 원격 키 (계획 workspace-trust WT7a) — 네 칸 줄로 왕복하고 같은 경로의 로컬 키와 갈리며, 목적지는 호스트만 소문자로 맞춘다; 맞추지 않은 목적지·빈 값·제어 문자는 키가 아니다" {
    var buf: [max_line_bytes]u8 = undefined;
    // 왕복.
    const remote: Key = .{ .volume = 0, .path = "/home/me/repo", .dest = "me@openclaw" };
    const l = line(.allow, remote, &buf).?;
    try testing.expectEqualStrings("allow\tssh\tme@openclaw\t/home/me/repo\n", l);
    const back = parseLine(l[0 .. l.len - 1]).?;
    try testing.expect(back.key.eql(remote) and back.key.isRemote() and back.decision.? == .allow);
    try testing.expect(parseLine("forget\tssh\tme@openclaw\t/home/me/repo").?.decision == null);
    // 같은 경로라도 로컬 키와 다르다 — 원격 결정이 이 기계의 같은 경로에 서지 않는다.
    const local: Key = .{ .volume = 0, .path = "/home/me/repo" };
    try testing.expect(!local.eql(remote) and !local.isRemote());
    // 목적지 정규화 — 호스트만 소문자, 계정은 그대로.
    var d: [max_dest_bytes]u8 = undefined;
    try testing.expectEqualStrings("Me@openclaw", normalizeDest("Me@OpenClaw", &d).?);
    try testing.expectEqualStrings("openclaw", normalizeDest("openClaw", &d).?);
    try testing.expectEqualStrings("a@b@host", normalizeDest("a@b@HOST", &d).?);
    try testing.expect(normalizeDest("", &d) == null);
    try testing.expect(normalizeDest("me@", &d) == null);
    try testing.expect(normalizeDest("host\x1b", &d) == null);
    try testing.expect(normalizeDest("ho\tst", &d) == null);
    var long: [max_dest_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(normalizeDest(&long, &d) == null);
    // 맞추지 않은 목적지는 적지도 읽지도 않는다(같은 기계가 두 키로 갈리지 않게).
    try testing.expect(line(.allow, .{ .volume = 0, .path = "/r", .dest = "OpenClaw" }, &buf) == null);
    try testing.expect(parseLine("allow\tssh\tOpenClaw\t/r") == null);
    // 원격 줄의 모양 규칙 — 둘째 칸은 `ssh`, 경로는 절대, 빈 목적지 없음.
    try testing.expect(parseLine("allow\tsh\thost\t/r") == null);
    try testing.expect(parseLine("allow\tssh\thost\tr") == null);
    try testing.expect(parseLine("allow\tssh\t\t/r") == null);
    try testing.expect(parseLine("allow\tssh\thost\t/r\textra") == null);
    // 로컬 줄은 그대로다.
    try testing.expect(parseLine("allow\t1000012\t/x/y z").?.key.eql(.{ .volume = 0x1000012, .path = "/x/y z" }));
}

test "LST-R2 원격 키는 표에서 로컬 키와 같은 규칙으로 산다 — 결정·잊기·묻는 자리·다시 쓰기, 같은 경로의 로컬 결정과 섞이지 않는다 (계획 WT7a)" {
    var s: Store = .{};
    defer s.deinit(testing.allocator);
    const remote: Key = .{ .volume = 0, .path = "/srv/app", .dest = "openclaw" };
    const local: Key = .{ .volume = 7, .path = "/srv/app" };
    try testing.expect(try s.put(testing.allocator, remote, .allow));
    try testing.expect(try s.put(testing.allocator, local, .deny));
    try testing.expectEqual(@as(?Decision, .allow), s.get(remote));
    try testing.expectEqual(@as(?Decision, .deny), s.get(local));
    // 다시 쓰기 — 두 줄 모두 제 형식으로.
    const text = try s.serialize(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "allow\tssh\topenclaw\t/srv/app\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "deny\t7\t/srv/app\n") != null);
    var re: Store = .{};
    defer re.deinit(testing.allocator);
    try re.load(testing.allocator, text);
    try testing.expectEqual(@as(?Decision, .allow), re.get(remote));
    try testing.expectEqual(@as(?Decision, .deny), re.get(local));
    // 묻는 자리 — 원격 키는 그 키로만 잡힌다.
    try testing.expect(try s.claim(testing.allocator, remote, 1));
    try testing.expect(!(try s.claim(testing.allocator, remote, 2)));
    try testing.expect(try s.claim(testing.allocator, local, 2));
    s.release(testing.allocator, remote, 1);
    try testing.expect(s.claimant(remote) == null and s.claimant(local).? == 2);
    // 잊기 — 원격만.
    try testing.expect(s.forget(remote));
    try testing.expect(s.get(remote) == null and s.get(local).? == .deny);
    // 파일의 forget 줄도 원격 키로 지운다.
    try re.load(testing.allocator, "forget\tssh\topenclaw\t/srv/app\n");
    try testing.expect(re.get(remote) == null and re.get(local).? == .deny);
}
