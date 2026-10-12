//! 신뢰 감사 기록(계획 docs/plans/workspace-trust-audit.md) — 신뢰 결정이 **언제·어디서** 바뀌었나. 순수 계산: 줄 형식·읽기·키의 마지막
//! 기록·시각 표기. 파일 읽기·쓰기·돌리기와 시계는 호출자(`trust_store`).
//!
//! 파일 `lsp-trust-log` 는 신뢰 파일(`lsp-trust` — `trust.zig`) 옆에 따로 둔다. 신뢰 파일의 줄에 칸을 더하면 옛 빌드가 그 줄을 모두
//! 무시해 결정을 잃는다(2026-10-12 사용자 결정). 줄마다 `‹unix ms›\t‹동사›\t‹출처›\t‹상대›\t‹키›` 이고, 키는 신뢰 파일과 같은 칸이다 —
//! 로컬 `‹볼륨 16진›\t‹실제 경로›`, 원격 `ssh\t‹목적지›\t‹원격 실제 경로›`. **개행으로 끝나지 않은 줄은 읽지 않는다**(신뢰 파일과 같다).

const std = @import("std");
const trust = @import("trust.zig");

/// 결정을 바꾼 자리(2026-10-12 사용자 결정 — 종류 넷). 철회는 `manage`·`control` 의 `deny` 다(동사를 따로 두지 않는다 — 표에 선 것은
/// 거부다).
pub const Source = enum {
    /// 신뢰 시트의 답(언어 서버가 묻든 소스 컨트롤이 묻든).
    sheet,
    /// 앱 안의 관리 상자(신뢰 목록·「이 저장소」 명령).
    manage,
    /// 컨트롤 플레인(`lsp.trust.revoke|forget` — CLI).
    control,
    /// 옛 자리(설정 파일 옆 `lsp-trust`)의 이관.
    migrate,
};

/// 컨트롤 플레인 연결의 소켓 상대(계획 TA2). 이름은 실행 파일 이름이다.
pub const Peer = struct { pid: i32, name: []const u8 };

/// 상대 이름의 상한 — 넘으면 자른다(글자 경계에서).
pub const max_peer_name_bytes: usize = 64;

pub const Record = struct {
    at_ms: i64,
    /// `null` 은 잊기다.
    decision: ?trust.Decision,
    source: Source,
    peer: ?Peer = null,
    key: trust.Key,
};

/// 한 줄의 최대 길이 — 신뢰 파일 줄에 시각·출처·상대 칸을 더한 만큼.
pub const max_line_bytes: usize = trust.max_line_bytes + 20 + 8 + 12 + max_peer_name_bytes + 16;

/// 지금 파일이 이 크기를 넘으면 덧붙이기 전에 `.1` 로 옮긴다(파일은 둘까지).
pub const max_file_bytes: usize = 256 * 1024;

/// 상대 이름을 줄에 적을 모양으로 — 탭·개행·제어 문자는 `?`, 상한에서 UTF-8 글자 경계로 자른다. 빈 이름은 `?` 하나(칸이 비면 `pid:` 가
/// 된다 — 읽을 수 없는 모양은 아니지만 「이름 없음」을 보이게).
pub fn cleanPeerName(name: []const u8, out: *[max_peer_name_bytes]u8) []const u8 {
    if (name.len == 0) {
        out[0] = '?';
        return out[0..1];
    }
    var n = @min(name.len, max_peer_name_bytes);
    if (n < name.len) {
        // 이어지는 바이트(10xxxxxx)에서 끊지 않는다.
        while (n > 0 and (name[n] & 0xC0) == 0x80) n -= 1;
    }
    for (name[0..n], 0..) |c, i| out[i] = if (c < 0x20 or c == 0x7f) '?' else c;
    return out[0..n];
}

/// 붙일 한 줄(개행 포함). 키를 신뢰 파일 줄로 적을 수 없으면(`trust.line` 이 거절하는 모양) `null`. `out` 이 모자라도 `null`.
pub fn line(rec: Record, out: []u8) ?[]const u8 {
    var key_buf: [trust.max_line_bytes]u8 = undefined;
    // 신뢰 파일 줄을 빌려 키 칸을 만든다 — 키 규칙(탭·개행 금지·목적지 정규화)이 한 자리에 산다.
    const key_line = trust.line(.allow, rec.key, &key_buf) orelse return null;
    const key_cols = key_line["allow\t".len .. key_line.len - 1];
    const verb = if (rec.decision) |d| @tagName(d) else "forget";
    var name_buf: [max_peer_name_bytes]u8 = undefined;
    if (rec.peer) |p| {
        return std.fmt.bufPrint(out, "{d}\t{s}\t{s}\t{d}:{s}\t{s}\n", .{ rec.at_ms, verb, @tagName(rec.source), p.pid, cleanPeerName(p.name, &name_buf), key_cols }) catch null;
    }
    return std.fmt.bufPrint(out, "{d}\t{s}\t{s}\t-\t{s}\n", .{ rec.at_ms, verb, @tagName(rec.source), key_cols }) catch null;
}

/// 한 줄을 읽는다(빌린 문자열). 모양이 틀리면 `null` — 무시한다.
pub fn parseLine(raw: []const u8) ?Record {
    const entry = std.mem.trimEnd(u8, raw, "\r");
    var it = std.mem.splitScalar(u8, entry, '\t');
    const at_text = it.next() orelse return null;
    const verb = it.next() orelse return null;
    const source_text = it.next() orelse return null;
    const peer_text = it.next() orelse return null;
    const at_ms = std.fmt.parseInt(i64, at_text, 10) catch return null;
    if (at_ms < 0) return null;
    const source = std.meta.stringToEnum(Source, source_text) orelse return null;
    const peer: ?Peer = if (std.mem.eql(u8, peer_text, "-")) null else blk: {
        const colon = std.mem.indexOfScalar(u8, peer_text, ':') orelse return null;
        const pid = std.fmt.parseInt(i32, peer_text[0..colon], 10) catch return null;
        if (pid <= 0) return null;
        const name = peer_text[colon + 1 ..];
        if (name.len == 0 or name.len > max_peer_name_bytes) return null;
        break :blk .{ .pid = pid, .name = name };
    };
    // 나머지는 신뢰 파일 줄의 키 칸 — 같은 읽기를 지난다(동사 자리에 실제 동사를 둔다).
    const rest = entry[at_text.len + verb.len + source_text.len + peer_text.len + 4 ..];
    var key_buf: [trust.max_line_bytes]u8 = undefined;
    const as_trust = std.fmt.bufPrint(&key_buf, "{s}\t{s}", .{ verb, rest }) catch return null;
    const e = trust.parseLine(as_trust) orelse return null;
    // `trust.parseLine` 의 키는 `key_buf` 를 빌린다 — 원래 줄의 같은 자리로 옮긴다.
    const offset = at_text.len + source_text.len + peer_text.len + 3;
    return .{
        .at_ms = at_ms,
        .decision = e.decision,
        .source = source,
        .peer = peer,
        .key = .{ .volume = e.key.volume, .path = rebase(entry, &key_buf, e.key.path, offset), .dest = rebase(entry, &key_buf, e.key.dest, offset) },
    };
}

/// `buf` 를 빌린 조각을 원래 줄 `entry` 의 같은 자리로 옮긴다(`buf` 는 `entry` 의 키 칸 앞에 동사만 붙인 사본이라 위치가 `offset` 만큼
/// 어긋난다). 빈 조각은 빈 조각.
fn rebase(entry: []const u8, buf: []const u8, part: []const u8, offset: usize) []const u8 {
    if (part.len == 0) return "";
    const start = @intFromPtr(part.ptr) - @intFromPtr(buf.ptr);
    return entry[start + offset ..][0..part.len];
}

/// 완성된 줄(개행으로 끝난 줄)의 기록을 차례로 돈다 — 마지막 개행 뒤의 조각(끊긴 줄)과 못 읽는 줄은 건너뛴다.
pub const Records = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(contents: []const u8) Records {
        const end = if (std.mem.lastIndexOfScalar(u8, contents, '\n')) |i| i else 0;
        return .{ .it = std.mem.splitScalar(u8, contents[0..end], '\n') };
    }

    pub fn next(self: *Records) ?Record {
        while (self.it.next()) |raw| if (parseLine(raw)) |r| return r;
        return null;
    }
};

/// 그 키의 마지막 기록(없으면 `null`). 파일의 줄 순서가 시간 순서다(시각 칸이 아니라 — 시계는 되돌아갈 수 있다).
pub fn lastFor(contents: []const u8, key: trust.Key) ?Record {
    var last: ?Record = null;
    var it = Records.init(contents);
    while (it.next()) |r| {
        if (r.key.eql(key)) last = r;
    }
    return last;
}

/// 목록 행의 시각 — 올해면 `MM-DD HH:MM`, 다른 해면 `YYYY-MM-DD`(로컬 시각). 행의 주인은 저장소 경로라 상세 칸을 짧게 둔다(패널은 60 칸까지
/// — 계획 workspace-trust-audit 「목록 행」). `at_offset_s`·`now_offset_s` 는 **각 시점의** UTC 오프셋(서머타임 — 호출자가 구한다). 1970
/// 이전이면 빈 조각.
pub fn formatStamp(buf: []u8, at_ms: i64, at_offset_s: i64, now_ms: i64, now_offset_s: i64) []const u8 {
    const at = localDate(at_ms, at_offset_s) orelse return "";
    const now = localDate(now_ms, now_offset_s);
    if (now != null and now.?.year == at.year) {
        return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ at.month, at.day, at.hour, at.minute }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ at.year, at.month, at.day }) catch "";
}

/// CLI 의 기록 시각 — 늘 `YYYY-MM-DD HH:MM:SS`(로컬 시각, `offset_s` 는 그 시점의 UTC 오프셋). 1970 이전이면 빈 조각.
pub fn formatFull(buf: []u8, at_ms: i64, offset_s: i64) []const u8 {
    const at = localDate(at_ms, offset_s) orelse return "";
    const second: u8 = @intCast(@mod(@divFloor(at_ms, std.time.ms_per_s) + offset_s, 60));
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ at.year, at.month, at.day, at.hour, at.minute, second }) catch "";
}

const LocalDate = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 };

fn localDate(ms: i64, offset_s: i64) ?LocalDate {
    const local = @divFloor(ms, std.time.ms_per_s) + offset_s;
    if (local < 0) return null;
    const day: i64 = @divFloor(local, std.time.s_per_day);
    const secs_in_day: u17 = @intCast(local - day * std.time.s_per_day);
    const year_day = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1, // `day_index` 는 0-based 다
        .hour = @intCast(secs_in_day / 3600),
        .minute = @intCast((secs_in_day % 3600) / 60),
    };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TAL1 줄 왕복과 거절 — 로컬·원격·잊기·상대, 칸 수·동사·출처·시각·상대 모양·끊긴 줄 닫기(`\\t\\n`) (계획 workspace-trust-audit)" {
    var buf: [max_line_bytes]u8 = undefined;
    // 로컬 허용, 상대 없음.
    const local: trust.Key = .{ .volume = 0x1a2b, .path = "/Users/me/repo x" };
    const l1 = line(.{ .at_ms = 1760000000123, .decision = .allow, .source = .sheet, .key = local }, &buf).?;
    try testing.expectEqualStrings("1760000000123\tallow\tsheet\t-\t1a2b\t/Users/me/repo x\n", l1);
    const r1 = parseLine(l1[0 .. l1.len - 1]).?;
    try testing.expect(r1.key.eql(local) and r1.decision.? == .allow and r1.source == .sheet and r1.peer == null and r1.at_ms == 1760000000123);
    // 빌린 경로는 원래 줄의 것이다(읽기 버퍼가 아니라).
    try testing.expect(@intFromPtr(r1.key.path.ptr) >= @intFromPtr(l1.ptr) and @intFromPtr(r1.key.path.ptr) < @intFromPtr(l1.ptr) + l1.len);
    // 원격 잊기, 컨트롤 상대.
    const remote: trust.Key = .{ .volume = 0, .path = "/srv/app", .dest = "me@openclaw" };
    const l2 = line(.{ .at_ms = 5, .decision = null, .source = .control, .peer = .{ .pid = 4321, .name = "maru" }, .key = remote }, &buf).?;
    try testing.expectEqualStrings("5\tforget\tcontrol\t4321:maru\tssh\tme@openclaw\t/srv/app\n", l2);
    const r2 = parseLine(l2[0 .. l2.len - 1]).?;
    try testing.expect(r2.key.eql(remote) and r2.decision == null and r2.source == .control);
    try testing.expectEqualStrings("maru", r2.peer.?.name);
    try testing.expectEqual(@as(i32, 4321), r2.peer.?.pid);
    try testing.expect(@intFromPtr(r2.key.dest.ptr) >= @intFromPtr(l2.ptr) and @intFromPtr(r2.key.dest.ptr) < @intFromPtr(l2.ptr) + l2.len);
    // 철회 = 관리 상자의 거부.
    const l3 = line(.{ .at_ms = 9, .decision = .deny, .source = .manage, .key = local }, &buf).?;
    try testing.expectEqual(Source.manage, parseLine(l3[0 .. l3.len - 1]).?.source);
    // 상대 이름의 탭·제어 문자는 줄을 깨지 않는다.
    const l4 = line(.{ .at_ms = 1, .decision = .deny, .source = .control, .peer = .{ .pid = 7, .name = "a\tb\x1b" }, .key = local }, &buf).?;
    try testing.expectEqualStrings("a?b?", parseLine(l4[0 .. l4.len - 1]).?.peer.?.name);
    // 키 규칙은 신뢰 파일과 같다 — 탭이 든 경로·맞추지 않은 목적지는 못 적는다.
    try testing.expect(line(.{ .at_ms = 1, .decision = .allow, .source = .sheet, .key = .{ .volume = 1, .path = "/a\tb" } }, &buf) == null);
    try testing.expect(line(.{ .at_ms = 1, .decision = .allow, .source = .sheet, .key = .{ .volume = 0, .path = "/r", .dest = "OpenClaw" } }, &buf) == null);
    var tiny: [8]u8 = undefined;
    try testing.expect(line(.{ .at_ms = 1, .decision = .allow, .source = .sheet, .key = local }, &tiny) == null);
    // 거절할 모양.
    try testing.expect(parseLine("x\tallow\tsheet\t-\t1\t/r") == null); // 시각
    try testing.expect(parseLine("-1\tallow\tsheet\t-\t1\t/r") == null);
    try testing.expect(parseLine("1\tmaybe\tsheet\t-\t1\t/r") == null); // 동사
    try testing.expect(parseLine("1\tallow\tagent\t-\t1\t/r") == null); // 출처
    try testing.expect(parseLine("1\tallow\tsheet\tpid\t1\t/r") == null); // 상대 — 콜론 없음
    try testing.expect(parseLine("1\tallow\tsheet\t0:x\t1\t/r") == null); // pid 0
    try testing.expect(parseLine("1\tallow\tsheet\t3:\t1\t/r") == null); // 빈 이름
    try testing.expect(parseLine("1\tallow\tsheet\t-\t1\tr") == null); // 상대 경로
    try testing.expect(parseLine("1\tallow\tsheet\t-\t1") == null); // 칸 모자람
    try testing.expect(parseLine("1\tallow\tsheet\t-\tssh\tHost\t/r") == null); // 맞추지 않은 목적지
    try testing.expect(parseLine("1\tallow\tsheet\t-\t1\t/r\textra") == null);
    // 끊긴 줄을 `\t\n` 으로 닫은 모양은 어느 칸 수로도 읽히지 않는다(잘린 경로가 부모의 기록이 되지 않게).
    for ([_][]const u8{
        "1\tallow\tsheet\t-\t1a2b\t/Users/me/re\t", // 로컬 경로에서 끊김 — 칸이 하나 남아 원격 칸 수가 되지만 `ssh` 가 아니다
        "1\tallow\tsheet\t-\t1a\t", // 볼륨에서 끊김 — 빈 경로
        "1\tallow\tsheet\t-\tssh\tme@open\t", // 목적지에서 끊김 — 빈 경로
        "1\tallow\tsheet\t-\tssh\tme@openclaw\t/srv/a\t", // 원격 경로에서 끊김 — 칸이 넘친다
        "1\tallow\tsheet\t43:ma\t", // 상대에서 끊김
        "1\tall\t",
    }) |closed| try testing.expect(parseLine(closed) == null);
}

test "TAL1b 상대 이름 다듬기 — 빈 이름은 `?`, 상한은 UTF-8 글자 경계에서 자른다" {
    var out: [max_peer_name_bytes]u8 = undefined;
    try testing.expectEqualStrings("?", cleanPeerName("", &out));
    try testing.expectEqualStrings("node", cleanPeerName("node", &out));
    // 63 바이트 + 3 바이트 한글 하나 — 64 에서 끊으면 글자 가운데다. 63 에서 끊는다.
    const long = "a" ** 63 ++ "가";
    try testing.expectEqualStrings("a" ** 63, cleanPeerName(long, &out));
    const exact = "b" ** max_peer_name_bytes;
    try testing.expectEqualStrings(exact, cleanPeerName(exact ++ "c", &out));
}

test "TAL2 키의 마지막 기록과 시각 표기 — 줄 순서가 이기고 끊긴 마지막 줄·다른 키·못 읽는 줄은 건너뛴다; 그 시점의 오프셋·자정 경계" {
    const k: trust.Key = .{ .volume = 1, .path = "/r" };
    const contents =
        "10\tallow\tsheet\t-\t1\t/r\n" ++
        "garbage\n" ++
        "30\tdeny\tmanage\t-\t1\t/r\n" ++
        "20\tforget\tcontrol\t9:maru\t1\t/r\n" ++ // 시각이 되돌아가도 줄 순서가 이긴다
        "40\tallow\tsheet\t-\t2\t/r\n" ++ // 다른 볼륨
        "50\tallow\tsheet\t-\t1\t/r/sub\n" ++ // 다른 경로
        "60\tallow\tsheet\t-\t1\t/r"; // 끊긴 마지막 줄
    const last = lastFor(contents, k).?;
    try testing.expectEqual(@as(i64, 20), last.at_ms);
    try testing.expect(last.decision == null and last.source == .control);
    try testing.expect(lastFor(contents, .{ .volume = 3, .path = "/r" }) == null);
    try testing.expect(lastFor("", k) == null);
    var n: usize = 0;
    var it = Records.init(contents);
    while (it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 5), n);

    var buf: [32]u8 = undefined;
    // 2026-10-12 05:30:00 UTC.
    const at: i64 = 1791783000 * 1000;
    const later = at + 30 * std.time.ms_per_day;
    try testing.expectEqualStrings("10-12 05:30", formatStamp(&buf, at, 0, later, 0)); // 올해 — 날짜와 시각
    try testing.expectEqualStrings("10-12 14:30", formatStamp(&buf, at, 9 * 3600, later, 9 * 3600)); // KST
    try testing.expectEqualStrings("10-11 22:30", formatStamp(&buf, at, -7 * 3600, later, -7 * 3600)); // 자정을 넘어 전날
    try testing.expectEqualStrings("2026-10-12", formatStamp(&buf, at, 0, at + 100 * std.time.ms_per_day, 0)); // 다른 해 — 날짜만
    // 해의 경계는 **그 시점의** 오프셋으로 — 2026-12-31 20:00 UTC 는 KST 로 2027-01-01 이다(지금도 2027 이면 올해).
    const eve: i64 = 1798747200 * 1000;
    try testing.expectEqualStrings("01-01 05:00", formatStamp(&buf, eve, 9 * 3600, eve + std.time.ms_per_day, 9 * 3600));
    try testing.expectEqualStrings("2026-12-31", formatStamp(&buf, eve, 0, eve + 2 * std.time.ms_per_day, 9 * 3600));
    try testing.expectEqualStrings("01-01 00:00", formatStamp(&buf, 999, 0, 0, 0)); // 초 아래는 버린다
    try testing.expectEqualStrings("", formatStamp(&buf, 0, -3600, 0, 0));
    try testing.expectEqualStrings("1970-01-01", formatStamp(&buf, 0, 0, 0, -3600)); // 지금을 못 구하면(1970 이전) 해를 붙인다
    // CLI — 늘 날짜·초까지.
    try testing.expectEqualStrings("2026-10-12 14:30:00", formatFull(&buf, at, 9 * 3600));
    try testing.expectEqualStrings("2026-10-11 22:30:59", formatFull(&buf, at + 59_999, -7 * 3600));
    try testing.expectEqualStrings("", formatFull(&buf, 0, -1));
}
