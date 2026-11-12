//! 성능 trace 의 순수 절반(W9e② — docs/plans/web-osr-backend.md 「W9e② 결정·실측」). CEF 를 모른다 — `tracing.zig` 가 CDP 를 내고 받은 JSON 을
//! 여기서 푼다: 고정 범주와 `Tracing.start` 인자, `Page.getFrameTree` 의 프레임 id, `Page.frameAttached`·`frameNavigated` 의 프레임 id,
//! `Tracing.tracingComplete`·`bufferUsage`·`IO.read` 의 답, 그 탭 가족의 프레임 집합(상한 65 536).
//!
//! 범주는 **고정**이다(에이전트가 고르지 않는다 — PLAN v2 §4.1): DevTools 성능 목록에서 다른 탭 주소가 실린 `loading`(실측 o2→o3), 스크립트 원문·
//! 지운 프레임 주소가 실린 `disabled-by-default-devtools.v8-source-rundown(-sources)`·`target-rundown`(t6·a1 #4), 다른 탭의 입력 시각이 실린
//! `latencyInfo`(a1_inp)를 뺐다. 범주만으로는 못 막는다(같은 프로세스의 남의 프레임 — o1) — maru 의 거르기(F1–F4)가 주 방어다.
//!
//! 시험이 증명하는 것: 시작 인자(압축 없는 스트림·버퍼 32 MiB·스크린샷 범주의 있고 없음·빠진 범주), 프레임 트리의 id 를 깊이까지 모은다, 사건의
//! 프레임 id, 끝 사건의 스트림·잃은 자료, 버퍼 사용률, `IO.read` 답(base64·eof), 프레임 집합의 중복 없음·상한·잘못된 id 거절, gzip 흐름
//! (조각으로 먹이고 꽉 찬 단위만 내줘도 끝에 원문 그대로 풀린다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;

/// 고정 범주(스크린샷은 `screenshots` 일 때만).
pub const base_categories = [_][]const u8{
    "-*",
    "devtools.timeline",
    "disabled-by-default-devtools.timeline",
    "disabled-by-default-devtools.timeline.frame",
    "disabled-by-default-devtools.timeline.stack",
    "disabled-by-default-devtools.timeline.invalidationTracking",
    "disabled-by-default-layout_shift.debug",
    "disabled-by-default-v8.cpu_profiler",
    "v8.execute",
    "toplevel",
    "blink.console",
    "blink.user_timing",
};
pub const screenshot_category = "disabled-by-default-devtools.screenshot";
/// 뺀 범주(시험이 시작 인자에 없음을 본다 — 이름이 바뀌어 다시 들어오지 않게).
pub const excluded_categories = [_][]const u8{ "loading", "latencyInfo", "disabled-by-default-devtools.v8-source-rundown", "disabled-by-default-devtools.v8-source-rundown-sources", "disabled-by-default-devtools.target-rundown" };

/// 버퍼(32 MiB — 적대 페이지는 1 s 에 93.8 % — a3_flood, 그래서 90 % 자동 멈춤과 `covered_ms`), 스크린샷 상한(CDP 기본 450).
pub const buffer_kb: u32 = 32 * 1024;
pub const screenshot_max: u32 = 450;
/// 버퍼 사용률 보고 간격(ms)과 자동 멈춤 문턱.
pub const buffer_report_ms: u32 = 500;
pub const buffer_stop_fraction: f64 = 0.9;
/// 한 번에 읽는 스트림 크기 — 압축하지 않은 JSON 이라 gzip 때(64 KiB × 160 회 314 ms — 실측 t8)보다 크게 읽는다(약 8 배 크다).
pub const read_bytes: u32 = 128 * 1024;

/// `Tracing.start` 인자.
pub fn startParams(screenshots: bool, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // 압축하지 않은 스트림을 받아 sidecar 가 gzip 으로 묶는다(`GzStream`). Chromium 의 gzip 스트림은 압축을 **BEST_EFFORT** 작업으로 돌리는데
    // (`CreateCompressedStringEndpoint(…, compress_with_background_priority=true)`), 그 작업은 「시작이 끝남」(보이는 탭이 한 번 그려짐 — 실패해도
    // 3 분) 전까지 막혀 있다: 보이는 탭 없이 숨은 에이전트 탭만 있는 sidecar 에서 `Tracing.end` 의 완료가 30 s 넘게 오지 않았다(판정
    // tr-hidden-focus — 다른 보이는 탭을 두거나 먼저 보이게 그리면 왔고, 압축 없는 스트림은 늘 왔다). 압축 없는 스트림은 USER_VISIBLE 이다.
    try w.writeAll("{\"transferMode\":\"ReturnAsStream\",\"streamFormat\":\"json\",");
    try w.print("\"bufferUsageReportingInterval\":{d},", .{buffer_report_ms});
    if (screenshots) try w.print("\"screenshotMaxCount\":{d},", .{screenshot_max});
    try w.print("\"traceConfig\":{{\"recordMode\":\"recordUntilFull\",\"traceBufferSizeInKb\":{d},\"includedCategories\":[", .{buffer_kb});
    for (base_categories, 0..) |cat, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{cat});
    }
    if (screenshots) try w.print(",\"{s}\"", .{screenshot_category});
    try w.writeAll("]}}");
    return w.buffered();
}

/// 가족 프레임 집합(중복 없음, 상한 `max_trace_frames_total`). id 는 `trace_fields.frameIdOk` 꼴만 받는다(16 진 1..64).
pub const FrameSet = struct {
    ids: std.ArrayList([msg.max_trace_frame_id_bytes]u8) = .empty,
    lens: std.ArrayList(u8) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    overflow: bool = false,

    pub fn deinit(self: *FrameSet, gpa: std.mem.Allocator) void {
        self.ids.deinit(gpa);
        self.lens.deinit(gpa);
        self.seen.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const FrameSet) usize {
        return self.lens.items.len;
    }

    pub fn get(self: *const FrameSet, i: usize) []const u8 {
        return self.ids.items[i][0..self.lens.items[i]];
    }

    /// 더한다(이미 있으면 그대로). 잘못된 id 는 버린다(거짓). 상한을 넘으면 `overflow`.
    pub fn add(self: *FrameSet, gpa: std.mem.Allocator, id: []const u8) !bool {
        if (!protocol.trace_fields.frameIdOk(id)) return false;
        var upper: [msg.max_trace_frame_id_bytes]u8 = undefined;
        for (id, upper[0..id.len]) |c, *o| o.* = std.ascii.toUpper(c);
        const key = std.hash.Wyhash.hash(0, upper[0..id.len]);
        if (self.seen.contains(key)) return true;
        if (self.count() >= msg.max_trace_frames_total) {
            self.overflow = true;
            return false;
        }
        try self.seen.put(gpa, key, {});
        try self.ids.append(gpa, upper);
        try self.lens.append(gpa, @intCast(id.len));
        return true;
    }
};

/// `Page.getFrameTree` 답(`{"frameTree":{"frame":{"id":…},"childFrames":[…]}}`)의 프레임 id 를 모두 더한다. 모양이 아니면 거짓.
pub fn collectFrameTree(gpa: std.mem.Allocator, json: []const u8, set: *FrameSet) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const tree = parsed.value.object.get("frameTree") orelse return false;
    return walkTree(gpa, tree, set, 0);
}

fn walkTree(gpa: std.mem.Allocator, node: std.json.Value, set: *FrameSet, depth: usize) !bool {
    if (depth > 128 or node != .object) return false;
    const frame = node.object.get("frame") orelse return false;
    if (frame != .object) return false;
    const id = frame.object.get("id") orelse return false;
    if (id != .string) return false;
    _ = try set.add(gpa, id.string);
    if (node.object.get("childFrames")) |kids| {
        if (kids != .array) return false;
        for (kids.array.items) |k| if (!try walkTree(gpa, k, set, depth + 1)) return false;
    }
    return true;
}

/// 사건의 프레임 id(`Page.frameAttached` 의 `frameId`, `Page.frameNavigated` 의 `frame.id`) — 다른 사건이거나 모양이 아니면 null.
/// `out` 에 복사해 돌려준다.
pub fn eventFrameId(gpa: std.mem.Allocator, method: []const u8, params: []const u8, out: *[msg.max_trace_frame_id_bytes]u8) ?[]const u8 {
    const attached = std.mem.eql(u8, method, "Page.frameAttached");
    const navigated = std.mem.eql(u8, method, "Page.frameNavigated");
    if (!attached and !navigated) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, params, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const id = if (attached) parsed.value.object.get("frameId") else blk: {
        const f = parsed.value.object.get("frame") orelse return null;
        if (f != .object) return null;
        break :blk f.object.get("id");
    };
    const v = id orelse return null;
    if (v != .string or v.string.len == 0 or v.string.len > out.len) return null;
    @memcpy(out[0..v.string.len], v.string);
    return out[0..v.string.len];
}

/// `Page.getFrameTree` 답의 주 프레임 id(`frameTree.frame.id`) — `out` 에 복사한다. 모양이 아니거나 id 꼴(`frameIdOk`)이 아니면 null.
pub fn mainFrameId(gpa: std.mem.Allocator, json: []const u8, out: *[msg.max_trace_frame_id_bytes]u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tree = parsed.value.object.get("frameTree") orelse return null;
    if (tree != .object) return null;
    const frame = tree.object.get("frame") orelse return null;
    if (frame != .object) return null;
    const id = frame.object.get("id") orelse return null;
    if (id != .string or !protocol.trace_fields.frameIdOk(id.string)) return null;
    @memcpy(out[0..id.string.len], id.string);
    return out[0..id.string.len];
}

/// `Page.frameNavigated` 가 bfcache 되살림인가(`type:"BackForwardCacheRestore"`). 되살린 문서의 하위 프레임은 `frameAttached` 를 다시 내지 않는다 —
/// 부른 쪽이 그 탭의 프레임 트리를 다시 받아 집합에 더한다(적대 검증 2 회차 A2-2: 그 탭 자신의 iframe 이 남의 프레임으로 보여 통째로 버렸다).
pub fn isBfcacheRestore(gpa: std.mem.Allocator, method: []const u8, params: []const u8) bool {
    if (!std.mem.eql(u8, method, "Page.frameNavigated")) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, params, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const t = parsed.value.object.get("type") orelse return false;
    return t == .string and std.mem.eql(u8, t.string, "BackForwardCacheRestore");
}

/// 가족 위젯의 layer tree 묶기(적대 검증 1 회차 A1-1): maru 의 거르기는 `SetLayerTreeId{frame, layerTreeId}` 로 가족 프레임의 layer tree 를 알고
/// 그 밖의 layer tree 이벤트(컴포지터만 쓰는 남의 위젯 — 같은 프로세스 사용자 iframe 의 CSS 애니메이션)를 남의 것으로 버린다. 그런데
/// `SetLayerTreeId` 는 주 스레드 프레임마다만 나온다 — 주 스레드가 쉬는 가족 위젯(제 CSS 애니메이션만 도는 에이전트 탭)은 묶이지 않았다(실측
/// a1-selfanim: 0 개). 그래서 기록이 시작되면 가족 탭마다 **격리된 world** 에서 빈 `requestAnimationFrame` 하나를 걸어 주 스레드 프레임 하나를
/// 부른다(페이지 world 의 `requestAnimationFrame` 을 페이지가 바꿔도 듣는다, 페이지는 격리된 world 를 보지 못한다).
pub const bind_world_name = "maru-trace";

/// `Page.createIsolatedWorld` 인자(그 탭 주 프레임에). id 는 `frameIdOk` 꼴(16 진)이라 JSON 을 깨지 않는다.
pub fn bindWorldParams(frame_id: []const u8, buf: []u8) ![]const u8 {
    if (!protocol.trace_fields.frameIdOk(frame_id)) return error.InvalidFrameId;
    return std.fmt.bufPrint(buf, "{{\"frameId\":\"{s}\",\"worldName\":\"{s}\",\"grantUniveralAccess\":false}}", .{ frame_id, bind_world_name });
}

/// `Page.createIsolatedWorld` 답의 `executionContextId`.
pub fn contextIdOf(gpa: std.mem.Allocator, json: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("executionContextId") orelse return null;
    return if (v == .integer and v.integer > 0) v.integer else null;
}

/// 그 world 에서 주 스레드 프레임 하나를 부르는 `Runtime.evaluate` 인자.
pub fn bindRafParams(context_id: i64, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"expression\":\"requestAnimationFrame(function(){{}})\",\"contextId\":{d},\"silent\":true,\"returnByValue\":true}}", .{context_id});
}

/// gzip 상한 안에 원 JSON `feed` 바이트를 더 먹여도 끝까지(`finish`) 상한을 넘지 않는가 — 넘을 수 있으면 부른 쪽은 거기서 자른다(적대 검증 4 회차
/// A4-1: 화면이 바쁜 페이지의 스크린샷은 거의 압축되지 않아 버퍼 90 % 멈춤으로는 16 MiB 를 묶지 못했고 trace 가 통째로 `too_large` 였다).
/// `sent` 는 이미 보낸 gzip, `unsent` 는 압축기가 내놓았지만 아직 보내지 않은 것. 최악(압축이 전혀 안 됨)은 먹인 만큼 + 저장 블록 머리(64 KiB 마다
/// 5 바이트) + 압축기가 쥔 창 둘 + 끝(꼬리 8 바이트·마지막 블록) — 넉넉히 잡는다.
pub fn gzFits(cap: u64, sent: u64, unsent: u64, feed: u64) bool {
    const worst = sent + unsent + feed + feed / 1024 + 2 * std.compress.flate.max_window_len + 4096;
    return worst <= cap;
}

pub const Complete = struct {
    data_loss: bool,
    /// 스트림 핸들(없으면 빈 글 — 탭이 닫혀 끝났다 등). `out` 을 빌린다.
    stream: []const u8,
};

/// `Tracing.tracingComplete` 의 인자.
pub fn parseComplete(gpa: std.mem.Allocator, params: []const u8, out: []u8) ?Complete {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, params, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    const loss = if (o.get("dataLossOccurred")) |v| (v == .bool and v.bool) else false;
    var stream: []const u8 = "";
    if (o.get("stream")) |v| if (v == .string and v.string.len <= out.len and handleOk(v.string)) {
        @memcpy(out[0..v.string.len], v.string);
        stream = out[0..v.string.len];
    };
    return .{ .data_loss = loss, .stream = stream };
}

/// 스트림 핸들의 모양(JSON 에 그대로 이어 붙이므로 글자를 가린다) — 숫자·영문·`-`·`_`·`.`, 1..64.
pub fn handleOk(h: []const u8) bool {
    if (h.len == 0 or h.len > 64) return false;
    for (h) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

/// `Tracing.bufferUsage` 의 사용률(0..1) — 없으면 null(`percentFull` 이 이름과 달리 0..1 이다 — CDP).
pub fn parseBufferUsage(gpa: std.mem.Allocator, params: []const u8) ?f64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, params, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("percentFull") orelse (parsed.value.object.get("value") orelse return null);
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

pub const ReadResult = struct {
    eof: bool,
    /// 원 바이트 수(`out` 에 썼다).
    len: usize,
};

/// `IO.read` 답(`{"base64Encoded":true,"data":"…","eof":false}`)을 원 바이트로 `out` 에 푼다. 모양이 아니거나 `out` 이 모자라면 null.
pub fn parseRead(gpa: std.mem.Allocator, json: []const u8, out: []u8) ?ReadResult {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    const eof = if (o.get("eof")) |v| (v == .bool and v.bool) else false;
    const data = o.get("data") orelse return null;
    if (data != .string) return null;
    const b64 = if (o.get("base64Encoded")) |v| (v == .bool and v.bool) else false;
    if (!b64) {
        if (data.string.len > out.len) return null;
        @memcpy(out[0..data.string.len], data.string);
        return .{ .eof = eof, .len = data.string.len };
    }
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(data.string) catch return null;
    if (n > out.len) return null;
    dec.decode(out[0..n], data.string) catch return null;
    return .{ .eof = eof, .len = n };
}

/// 받은 원 JSON 을 gzip 으로 묶는 흐름(sidecar 가 maru 에 보내는 `trace_data` 는 그대로 gzip — maru 의 거르기는 바뀌지 않는다). 내보낸 쪽 버퍼를
/// 가리키므로 힙에 둔다(`create`). UI 스레드에서 읽기 한 번(128 KiB)마다 부른다 — level 1(ReleaseSafe 약 180 MB/s, Debug 14 MB/s — 실측 bench).
pub const GzStream = struct {
    out: std.Io.Writer.Allocating,
    window: [std.compress.flate.max_window_len]u8,
    comp: std.compress.flate.Compress,
    /// `out` 에서 이미 내준 바이트.
    taken: usize = 0,
    /// 지금까지 만든 gzip 바이트.
    total: u64 = 0,
    finished: bool = false,

    pub fn create(gpa: std.mem.Allocator) !*GzStream {
        const self = try gpa.create(GzStream);
        errdefer gpa.destroy(self);
        self.* = .{ .out = try .initCapacity(gpa, 64 * 1024), .window = undefined, .comp = undefined };
        errdefer self.out.deinit();
        self.comp = try std.compress.flate.Compress.init(&self.out.writer, &self.window, .gzip, .level_1);
        return self;
    }

    pub fn destroy(self: *GzStream, gpa: std.mem.Allocator) void {
        self.out.deinit();
        gpa.destroy(self);
    }

    pub fn feed(self: *GzStream, bytes: []const u8) !void {
        if (self.finished) return error.Finished;
        try self.comp.writer.writeAll(bytes);
    }

    pub fn finish(self: *GzStream) !void {
        if (self.finished) return;
        self.finished = true;
        try self.comp.writer.flush();
        try self.comp.finish();
    }

    /// 내보낼 바이트 — 끝나기 전에는 `unit` 의 배수만(조각을 꽉 채워 보낸다), 끝난 뒤에는 남은 것 모두.
    pub fn ready(self: *GzStream, unit: usize) []const u8 {
        const all = self.out.written()[self.taken..];
        if (self.finished) return all;
        return all[0 .. all.len - all.len % unit];
    }

    /// `ready` 에서 `n` 바이트를 내줬다. 남은 것을 앞으로 당긴다(버퍼가 trace 길이만큼 자라지 않게).
    pub fn took(self: *GzStream, n: usize) void {
        self.taken += n;
        self.total += n;
        const buf = self.out.written();
        const rest = buf.len - self.taken;
        std.mem.copyForwards(u8, buf[0..rest], buf[self.taken..]);
        self.out.shrinkRetainingCapacity(rest);
        self.taken = 0;
    }
};

const testing = std.testing;

test "W9e②: gzip 흐름 — 조각으로 먹이고 꽉 찬 단위만 내주며 당겨도, 끝에 모두 풀면 원문 그대로" {
    const gpa = testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.appendSlice(gpa, "{\"traceEvents\":[");
    var prng: std.Random.DefaultPrng = .init(7);
    for (0..40_000) |i| {
        if (i > 0) try raw.append(gpa, ',');
        var b: [160]u8 = undefined;
        try raw.appendSlice(gpa, try std.fmt.bufPrint(&b, "{{\"name\":\"Task\",\"ts\":{d},\"dur\":{d},\"pid\":1,\"args\":{{\"r\":{d}}}}}", .{ i * 7, prng.random().int(u16), prng.random().int(u64) }));
    }
    try raw.appendSlice(gpa, "]}");
    const gz = try GzStream.create(gpa);
    defer gz.destroy(gpa);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var off: usize = 0;
    var piece: usize = 1;
    while (off < raw.items.len) {
        const n = @min(piece, raw.items.len - off);
        try gz.feed(raw.items[off .. off + n]);
        off += n;
        piece = piece * 3 + 17; // 1 바이트부터 커지는 조각
        if (piece > read_bytes) piece = read_bytes;
        const r = gz.ready(msg.trace_chunk_bytes);
        try testing.expect(r.len % msg.trace_chunk_bytes == 0);
        try got.appendSlice(gpa, r);
        gz.took(r.len);
    }
    try gz.finish();
    const last = gz.ready(msg.trace_chunk_bytes);
    try got.appendSlice(gpa, last);
    gz.took(last.len);
    try testing.expectEqual(@as(u64, got.items.len), gz.total);
    try testing.expectError(error.Finished, gz.feed("x"));
    try testing.expect(got.items.len < raw.items.len / 2);
    var in: std.Io.Reader = .fixed(got.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    try testing.expectEqualSlices(u8, raw.items, out.written());
}

test "W9e②: 시작 인자 — 압축 없는 스트림(gzip 은 sidecar 가)·32 MiB·고정 범주, 스크린샷은 고를 때만, 뺀 범주는 없다" {
    var buf: [2048]u8 = undefined;
    const with = try startParams(true, &buf);
    try testing.expect(std.mem.indexOf(u8, with, "\"transferMode\":\"ReturnAsStream\"") != null);
    try testing.expect(std.mem.indexOf(u8, with, "streamCompression") == null);
    try testing.expect(std.mem.indexOf(u8, with, "\"traceBufferSizeInKb\":32768") != null);
    try testing.expect(std.mem.indexOf(u8, with, "\"disabled-by-default-devtools.screenshot\"") != null);
    try testing.expect(std.mem.indexOf(u8, with, "\"screenshotMaxCount\":450") != null);
    for (excluded_categories) |cat| {
        var q: [128]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&q, "\"{s}\"", .{cat});
        try testing.expect(std.mem.indexOf(u8, with, quoted) == null);
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, with, .{});
    defer parsed.deinit();
    const without = try startParams(false, &buf);
    try testing.expect(std.mem.indexOf(u8, without, "screenshot") == null);
}

test "W9e②: 프레임 집합 — 트리의 id 를 깊이까지 모으고 중복 없음(대소문자 무시), 사건의 id, 잘못된 id 는 버림, 상한 넘음" {
    const gpa = testing.allocator;
    var set: FrameSet = .{};
    defer set.deinit(gpa);
    const tree = "{\"frameTree\":{\"frame\":{\"id\":\"AA11\",\"url\":\"x\"},\"childFrames\":[{\"frame\":{\"id\":\"BB22\"},\"childFrames\":[{\"frame\":{\"id\":\"cc33\"}}]},{\"frame\":{\"id\":\"aa11\"}}]}}";
    try testing.expect(try collectFrameTree(gpa, tree, &set));
    try testing.expectEqual(@as(usize, 3), set.count());
    try testing.expectEqualStrings("CC33", set.get(2));
    try testing.expect(!try collectFrameTree(gpa, "{\"nope\":1}", &set));
    var out: [msg.max_trace_frame_id_bytes]u8 = undefined;
    try testing.expectEqualStrings("DD44", eventFrameId(gpa, "Page.frameAttached", "{\"frameId\":\"DD44\",\"parentFrameId\":\"AA11\"}", &out).?);
    try testing.expectEqualStrings("EE55", eventFrameId(gpa, "Page.frameNavigated", "{\"frame\":{\"id\":\"EE55\",\"url\":\"u\"},\"type\":\"Navigation\"}", &out).?);
    try testing.expect(eventFrameId(gpa, "Page.lifecycleEvent", "{\"frameId\":\"FF\"}", &out) == null);
    try testing.expect(!try set.add(gpa, "AB\"C")); // JSON 을 깰 글자
    try testing.expect(!try set.add(gpa, ""));
    var big: FrameSet = .{};
    defer big.deinit(gpa);
    var idb: [16]u8 = undefined;
    for (0..msg.max_trace_frames_total) |i| _ = try big.add(gpa, try std.fmt.bufPrint(&idb, "{x}", .{i}));
    try testing.expect(!big.overflow);
    try testing.expect(!try big.add(gpa, "FFFFFFFFFFFF"));
    try testing.expect(big.overflow);
}

test "W9e②: 끝 사건·버퍼 사용률·IO.read 답을 푼다 — 스트림 핸들 모양, base64, eof, 모자란 버퍼" {
    const gpa = testing.allocator;
    var hb: [64]u8 = undefined;
    const c = parseComplete(gpa, "{\"dataLossOccurred\":true,\"stream\":\"12\",\"traceFormat\":\"json\",\"streamCompression\":\"gzip\"}", &hb).?;
    try testing.expect(c.data_loss);
    try testing.expectEqualStrings("12", c.stream);
    try testing.expectEqualStrings("", parseComplete(gpa, "{\"dataLossOccurred\":false,\"stream\":\"a\\\"b\"}", &hb).?.stream); // 핸들에 따옴표
    try testing.expectEqual(@as(f64, 0.938), parseBufferUsage(gpa, "{\"percentFull\":0.938,\"eventCount\":5,\"value\":0.938}").?);
    var out: [16]u8 = undefined;
    const r = parseRead(gpa, "{\"base64Encoded\":true,\"data\":\"H4sIAAA=\",\"eof\":false}", &out).?;
    try testing.expect(!r.eof and r.len == 5);
    try testing.expectEqualSlices(u8, "\x1f\x8b\x08\x00\x00", out[0..5]);
    try testing.expect(parseRead(gpa, "{\"base64Encoded\":true,\"data\":\"\",\"eof\":true}", &out).?.eof);
    try testing.expect(parseRead(gpa, "{\"base64Encoded\":true,\"data\":\"QUJDREVGR0hJSktMTU5PUFFSU1RVVldY\",\"eof\":false}", &out) == null); // 16 바이트를 넘는다
    try testing.expect(parseRead(gpa, "{\"eof\":true}", &out) == null);
}

test "W9e② A1-1·A2-2: 주 프레임 id·bfcache 되살림·격리된 world 인자와 답" {
    const gpa = testing.allocator;
    var out: [msg.max_trace_frame_id_bytes]u8 = undefined;
    try testing.expectEqualStrings("AA11", mainFrameId(gpa, "{\"frameTree\":{\"frame\":{\"id\":\"AA11\"},\"childFrames\":[{\"frame\":{\"id\":\"BB22\"}}]}}", &out).?);
    try testing.expect(mainFrameId(gpa, "{\"frameTree\":{\"frame\":{\"id\":\"A\\\"B\"}}}", &out) == null); // JSON 을 깰 글자
    try testing.expect(mainFrameId(gpa, "{\"nope\":1}", &out) == null);
    try testing.expect(isBfcacheRestore(gpa, "Page.frameNavigated", "{\"frame\":{\"id\":\"AA\"},\"type\":\"BackForwardCacheRestore\"}"));
    try testing.expect(!isBfcacheRestore(gpa, "Page.frameNavigated", "{\"frame\":{\"id\":\"AA\"},\"type\":\"Navigation\"}"));
    try testing.expect(!isBfcacheRestore(gpa, "Page.frameAttached", "{\"type\":\"BackForwardCacheRestore\"}"));
    var b: [256]u8 = undefined;
    const w = try bindWorldParams("aa11", &b);
    const pw = try std.json.parseFromSlice(std.json.Value, gpa, w, .{});
    defer pw.deinit();
    try testing.expectEqualStrings("aa11", pw.value.object.get("frameId").?.string);
    try testing.expectError(error.InvalidFrameId, bindWorldParams("x\"y", &b));
    try testing.expectEqual(@as(?i64, 42), contextIdOf(gpa, "{\"executionContextId\":42}"));
    try testing.expect(contextIdOf(gpa, "{\"executionContextId\":\"42\"}") == null);
    const r = try bindRafParams(42, &b);
    const pr = try std.json.parseFromSlice(std.json.Value, gpa, r, .{});
    defer pr.deinit();
    try testing.expectEqual(@as(i64, 42), pr.value.object.get("contextId").?.integer);
    try testing.expect(std.mem.indexOf(u8, pr.value.object.get("expression").?.string, "requestAnimationFrame") != null);
}

test "W9e② A4-1: gzip 상한 — 압축이 안 되는 자료를 상한 앞에서 자르면 끝까지 상한 안이다" {
    const gpa = testing.allocator;
    const cap: u64 = 600 * 1024;
    const gz = try GzStream.create(gpa);
    defer gz.destroy(gpa);
    var prng: std.Random.DefaultPrng = .init(11);
    var piece: [read_bytes]u8 = undefined;
    var sent: u64 = 0;
    var cut = false;
    var rounds: usize = 0;
    while (rounds < 100) : (rounds += 1) {
        prng.random().bytes(&piece); // 스크린샷처럼 거의 압축되지 않는다
        if (!gzFits(cap, sent, gz.ready(1).len, piece.len)) {
            cut = true;
            break;
        }
        try gz.feed(&piece);
        const r = gz.ready(msg.trace_chunk_bytes);
        sent += r.len;
        gz.took(r.len);
    }
    try testing.expect(cut); // 상한에 닿아 잘랐다
    try gz.finish();
    sent += gz.ready(msg.trace_chunk_bytes).len;
    try testing.expect(sent <= cap);
    try testing.expect(sent > cap / 2); // 너무 일찍 자르지 않는다
    try testing.expect(gzFits(cap, 0, 0, 1024));
    try testing.expect(!gzFits(cap, cap, 0, 0));
}
