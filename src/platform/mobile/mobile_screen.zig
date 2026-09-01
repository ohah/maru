//! 폰이 **원격 화면 레코드를 조립하는 자리**(S11-5). `maru attach --stream` 이 stdout 으로 흘리는
//! 프레임을 읽어 `screen_assembler` 에 먹인다.
//!
//! **OS 를 안 부른다.** 소켓도 시계도 없고, 호출자가 바이트를 밀어 넣는다 — 컨트롤 축의
//! `mobile_control.zig` 와 같은 부류다(계약 §4a).
//!
//! **프레이밍은 세션 호스트가 정했다**([§8](../../../docs/persistent-session-host.md)):
//! `"MRSS" | kind:u8 | reserved:u8 x3 | len:u32 LE | payload(len)`.
//! magic 은 셸이 끼워 넣은 잡음(프로필 배너 등)과 첫 프레임을 가르는 자리다 — 컨트롤 축이
//! `hello` 를 찾는 것과 같은 이유다.

const std = @import("std");
const maru = @import("maru");

const stream = maru.session.screen_stream;
const assembler = maru.session.screen_assembler;

/// 프레임 헤더 크기. 값의 단일 출처는 세션 호스트 §8 이고 여기는 그 소비자다.
pub const header_bytes: usize = 12;
pub const magic = "MRSS";

/// 덩어리 종류. 소비자가 "처음부터 다시" 와 "이어서" 를 갈라야 한다.
pub const Kind = enum(u8) { snapshot = 0, delta = 1 };

/// **한 프레임의 상한.** 세션 호스트의 레코드 스트림 상한과 같은 값을 쓴다 — 그보다 큰 것은
/// 우리가 만든 것이 아니므로 받지 않는다.
pub const max_frame = stream.max_record_stream_bytes;

/// magic 을 찾기 전에 버릴 수 있는 잡음의 상한. 강제 명령 서버는 배너를 길게 뱉을 수 있지만
/// 무한히 기다리면 화면이 영영 안 선다(컨트롤 축의 `max_noise` 와 같은 뜻).
pub const max_noise = 64 * 1024;

pub const State = enum {
    /// 아직 첫 프레임을 못 찾았다(잡음을 버리는 중).
    waiting_first,
    /// 화면이 섰다.
    ready,
    /// 껐다 — 이유는 `off_reason`.
    off,
};

pub const OffReason = enum {
    none,
    /// 잡음이 상한을 넘었다 — 프레임이 올 자리가 아니다.
    too_much_noise,
    /// 한 프레임이 상한을 넘었다.
    frame_too_large,
    /// 레코드가 우리 코덱이 아니거나 깨졌다.
    malformed,
};

/// 폰이 드는 원격 화면. **조립기 하나**를 소유하고 프레임을 그것에 먹인다.
pub const Screen = struct {
    state: State = .waiting_first,
    off_reason: OffReason = .none,
    /// 조립 결과. 화면을 그리는 쪽이 `rowRuns` 로 읽는다.
    inner: assembler.ScreenAssembler,
    /// 조립 중인 프레임. 헤더를 다 못 받았거나 payload 가 덜 왔으면 여기 쌓인다.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// magic 전에 버린 바이트.
    noise: usize = 0,
    /// 받은 프레임 수(진단용). snapshot·delta 를 갈라 센다.
    snapshots: usize = 0,
    deltas: usize = 0,

    /// 폰이 드는 이미지 재조립 상한. 데스크톱 기본(512 MiB)을 그대로 쓰면 손상되거나 악의적인
    /// delta 하나가 앱을 통째로 죽인다 — 폰은 그 예산을 못 든다.
    pub const max_image_bytes = 16 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) Screen {
        var inner = assembler.ScreenAssembler.init(allocator);
        inner.limitReassembledImage(max_image_bytes);
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Screen, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        self.inner.deinit();
        self.* = undefined;
    }

    /// 바이트를 밀어 넣는다. **삼킨 만큼**을 돌려준다 — 껐어도 삼킨다(안 삼키면 호출자가 같은
    /// 조각을 들고 영원히 맴돈다).
    pub fn feed(self: *Screen, allocator: std.mem.Allocator, bytes: []const u8) usize {
        if (self.state == .off) return bytes.len;
        self.pending.appendSlice(allocator, bytes) catch {
            self.fail(.frame_too_large);
            return bytes.len;
        };
        self.drain();
        return bytes.len;
    }

    fn fail(self: *Screen, reason: OffReason) void {
        self.state = .off;
        self.off_reason = reason;
    }

    /// 쌓인 것에서 완성된 프레임을 꺼내 적용한다.
    fn drain(self: *Screen) void {
        while (true) {
            const buf = self.pending.items;
            // magic 을 찾는다. **첫 프레임 전에는 잡음이 올 수 있다**(셸 배너).
            const start = std.mem.indexOf(u8, buf, magic) orelse {
                // magic 의 앞부분이 걸쳐 있을 수 있으니 마지막 3바이트는 남긴다.
                const keep = @min(buf.len, magic.len - 1);
                const dropped = buf.len - keep;
                if (dropped > 0) {
                    if (self.state == .waiting_first) {
                        self.noise += dropped;
                        if (self.noise > max_noise) return self.fail(.too_much_noise);
                    } else {
                        // 프레임 사이에 쓰레기가 끼는 것은 우리 스트림이 아니라는 뜻이다.
                        return self.fail(.malformed);
                    }
                    std.mem.copyForwards(u8, self.pending.items[0..keep], buf[dropped..]);
                    self.pending.items.len = keep;
                }
                return;
            };
            if (start > 0) {
                if (self.state == .waiting_first) {
                    self.noise += start;
                    if (self.noise > max_noise) return self.fail(.too_much_noise);
                } else {
                    return self.fail(.malformed);
                }
                std.mem.copyForwards(u8, self.pending.items, buf[start..]);
                self.pending.items.len = buf.len - start;
            }
            if (self.pending.items.len < header_bytes) return; // 헤더가 덜 왔다
            const head = self.pending.items;
            const len = std.mem.readInt(u32, head[8..12], .little);
            if (len > max_frame) return self.fail(.frame_too_large);
            const total = header_bytes + len;
            if (head.len < total) return; // payload 가 덜 왔다
            const kind_byte = head[4];
            const payload = head[header_bytes..total];
            self.apply(kind_byte, payload) catch return self.fail(.malformed);
            const rest = head.len - total;
            std.mem.copyForwards(u8, self.pending.items, head[total..]);
            self.pending.items.len = rest;
        }
    }

    fn apply(self: *Screen, kind_byte: u8, payload: []const u8) !void {
        switch (kind_byte) {
            @intFromEnum(Kind.snapshot) => {
                try self.inner.applySnapshot(payload);
                self.snapshots += 1;
            },
            @intFromEnum(Kind.delta) => {
                // **첫 덩어리가 delta 면 base 가 없다** — 우리 스트림은 snapshot 으로 시작한다.
                if (self.state != .ready) return error.OutOfOrder;
                try self.inner.applyDelta(payload);
                self.deltas += 1;
            },
            else => return error.UnknownKind,
        }
        self.state = .ready;
    }

    /// 그 행의 run 들. 화면을 그리는 쪽이 이것을 셀로 편다.
    pub fn rowRuns(self: *const Screen, row: u16) []const stream.Run {
        return self.inner.rowRuns(row);
    }

    /// 원격 화면의 행 수. 창이 그보다 낮으면 그리는 쪽이 **아래 몇 행**을 고른다(S11-6).
    pub fn rowCount(self: *const Screen) u16 {
        return self.inner.rowCount();
    }

    /// 원격 커서(칸·보임·모양). **조립기가 이미 들고 있었는데 폰이 안 꺼내 썼다** — 그래서 원격
    /// 화면에 커서가 아예 안 그려졌고, 보는 사람은 그 세션이 어디에 서 있는지 알 수 없었다.
    pub fn cursor(self: *const Screen) stream.Cursor {
        return self.inner.cursor;
    }
};

test "이미지 재조립 상한이 폰 값이다 — 데스크톱 예산을 안 든다" {
    // 데스크톱 기본은 512 MiB 다. 폰에서 그대로 쓰면 손상되거나 악의적인 delta 하나가 앱을 죽인다.
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    try std.testing.expectEqual(Screen.max_image_bytes, s.inner.image_cap);
    try std.testing.expect(Screen.max_image_bytes < 512 * 1024 * 1024);
}

test "잡음 뒤에 와도 첫 화면을 찾는다" {
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    const frame = try snapshotFrame(a, "가", 2);
    defer a.free(frame);
    // 셸 배너가 앞에 붙어 온다 — 그것 때문에 화면이 안 서면 안 된다.
    _ = s.feed(a, "Welcome to ubuntu\n");
    _ = s.feed(a, frame);
    try std.testing.expectEqual(State.ready, s.state);
    try std.testing.expectEqual(@as(usize, 1), s.snapshots);
    const runs = s.rowRuns(0);
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqualStrings("가", runs[0].grapheme);
    try std.testing.expectEqual(@as(u8, 2), runs[0].width);
}

test "프레임이 조각나 와도 이어 붙인다" {
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    const frame = try snapshotFrame(a, "A", 1);
    defer a.free(frame);
    // 헤더 한가운데에서 끊어 준다 — SSH 조각은 우리 프레임 경계를 모른다.
    for (frame) |b| _ = s.feed(a, &[_]u8{b});
    try std.testing.expectEqual(State.ready, s.state);
    try std.testing.expectEqualStrings("A", s.rowRuns(0)[0].grapheme);
}

test "첫 덩어리가 delta 면 받지 않는다 — base 가 없다" {
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    var frame = try snapshotFrame(a, "A", 1);
    defer a.free(frame);
    frame[4] = @intFromEnum(Kind.delta); // snapshot 을 delta 로 위조
    _ = s.feed(a, frame);
    try std.testing.expectEqual(State.off, s.state);
    try std.testing.expectEqual(OffReason.malformed, s.off_reason);
}

test "상한을 넘는 길이는 조립하지 않는다" {
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    var head: [header_bytes]u8 = @splat(0);
    @memcpy(head[0..4], magic);
    std.mem.writeInt(u32, head[8..12], max_frame + 1, .little);
    _ = s.feed(a, &head);
    try std.testing.expectEqual(State.off, s.state);
    try std.testing.expectEqual(OffReason.frame_too_large, s.off_reason);
}

test "잡음이 상한을 넘으면 끈다 — 영영 기다리지 않는다" {
    const a = std.testing.allocator;
    var s = Screen.init(a);
    defer s.deinit(a);
    var junk: [4096]u8 = @splat('x');
    var sent: usize = 0;
    while (sent <= max_noise) : (sent += junk.len) _ = s.feed(a, &junk);
    try std.testing.expectEqual(State.off, s.state);
    try std.testing.expectEqual(OffReason.too_much_noise, s.off_reason);
}

/// 한 글자짜리 화면을 담은 프레임(테스트용). 프로듀서(`--stream`)와 같은 모양이다.
fn snapshotFrame(a: std.mem.Allocator, grapheme: []const u8, width: u8) ![]u8 {
    var runs = [_]stream.Run{.{ .grapheme = grapheme, .width = width, .count = 1 }};
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    const meta = try stream.encodeScreenMeta(a, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = width,
        .rows = 1,
        .active_screen = 0,
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer a.free(meta);
    try stream.appendRecord(&body, a, meta);
    const row = try stream.encodeRow(a, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = 0, .runs = &runs });
    defer a.free(row);
    try stream.appendRecord(&body, a, row);

    var out = try a.alloc(u8, header_bytes + body.items.len);
    @memset(out[0..header_bytes], 0);
    @memcpy(out[0..4], magic);
    out[4] = @intFromEnum(Kind.snapshot);
    std.mem.writeInt(u32, out[8..12][0..4], @intCast(body.items.len), .little);
    @memcpy(out[header_bytes..], body.items);
    return out;
}
