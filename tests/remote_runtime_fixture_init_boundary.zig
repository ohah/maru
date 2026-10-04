//! `RemoteRuntime` 테스트 fixture 가 **제품 constructor 가 in-place 로 세우는 값 칸을 빠짐없이 세우는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-10-05 — main 의 `session host macOS (ReleaseFast)` 에서 `2c3e C2 … selected text` 판정자만 `ProtocolError` 로 죽었다.
//! fixture(`testing_api.initializeTestGeneration`)는 `var runtime: RemoteRuntime = undefined` 에서 필요한 owner 만 조립하는데,
//! 제품 constructor 가 `false` 로 세우는 선택 bool 둘(`selection_all`·`selection_host_authoritative`)을 세우지 않았다. 필드
//! 기본값은 in-place 초기화에 안 먹으므로 ReleaseFast 에서는 쓰레기 바이트가 `selected_text` 요청의 0/1 칸을 넘었고, 인코더가
//! 요청을 쓰기도 전에 거절했다. Debug 는 0xAA 의 최하위 비트로 false 가 되어 통과했고, ReleaseFast 잡은 수동 실행에서만 돌아
//! 결함은 셀 픽셀 필드가 구조체 배치를 바꿀 때까지 잠복했다.
//!
//! 값 판정(`runC2TypedFamilySocket` 의 0xFF 독)은 session-host 테스트 바이너리라 PR 에서 안 돈다. 그래서 여기서 글자로 잰다:
//! 제품 constructor 의 초기화 블록이 대입하는 `self.<칸>` 은 fixture 본체가 `runtime.<칸>` 으로 대입하거나, 아래 제외 목록에
//! **이유와 함께** 있어야 한다. 제외 목록은 썩지 않게 — 제품이 더는 세우지 않거나 fixture 가 이미 세우는 칸이 남아 있으면 빨갛다.

const std = @import("std");

const runtime_path = "src/platform/macos/session_host/remote_runtime.zig";

/// fixture 공통 입구가 **일부러** 세우지 않는 칸과 그 이유.
const Excluded = struct { field: []const u8, why: []const u8 };
const excluded = [_]Excluded{
    // 입력 경로는 판정자마다 따로 조립한다. 일부 판정자는 공통 입구를 부르기 **전에** 이 칸들을 세우므로(remote_runtime 의
    // 붙여넣기 재생 판정자, remote_term_backend 의 blocking flush 판정자) 공통 입구가 덮으면 그 준비를 지운다.
    .{ .field = "direct_input", .why = "입력 경로는 판정자별 조립 — 공통 입구 앞에서 세우는 판정자가 있다" },
    .{ .field = "direct_input_offset", .why = "입력 경로는 판정자별 조립" },
    .{ .field = "input_batches", .why = "입력 경로는 판정자별 조립" },
    .{ .field = "paused_input_metadata", .why = "입력 경로는 판정자별 조립 — 공통 입구 앞에서 세우는 판정자가 있다" },
    .{ .field = "paused_paste_store", .why = "입력 경로는 판정자별 조립 — 공통 입구 앞에서 세우는 판정자가 있다" },
    .{ .field = "pending_controls", .why = "입력 경로는 판정자별 조립 — 공통 입구 앞에서 세우는 판정자가 있다" },
    .{ .field = "blocking_flush_active", .why = "입력 경로는 판정자별 조립 — 공통 입구 앞에서 세우는 판정자가 있다" },
    // 프로세스 신원·final-address owner 는 `initializePendingOwners`/`initializePendingEventOwner` 가 판정자마다 세운다 —
    // 할당과 신원 등록이 따라와서 공통 입구가 빈 값으로 덮으면 먼저 세운 owner 가 샌다.
    .{ .field = "pending_event_owner", .why = "initializePendingOwners 가 신원과 함께 세운다" },
    .{ .field = "runtime_lifetime", .why = "initializePendingOwners 가 신원과 함께 세운다" },
};

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    const n = countAll(haystack, needle);
    if (n != 1) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — 한 번이어야 한다\n", .{ what, needle, n });
        return error.WiringChanged;
    }
    return std.mem.indexOf(u8, haystack, needle).?;
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// `<receiver>.<칸> =` 꼴의 **직접 대입**만 모은다 — `<receiver>.<칸>.x = …`(안쪽 대입)·`==`(비교)는 칸 대입이 아니다.
fn collectAssigned(
    allocator: std.mem.Allocator,
    body: []const u8,
    comptime receiver: []const u8,
    into: *std.StringArrayHashMapUnmanaged(void),
) !void {
    const prefix = receiver ++ ".";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, prefix)) |f| {
        at = f + prefix.len;
        // `other_runtime.` 처럼 앞이 식별자 글자면 다른 receiver 다.
        if (f > 0 and isIdent(body[f - 1])) continue;
        var end = at;
        while (end < body.len and isIdent(body[end])) end += 1;
        if (end == at) continue;
        var rest = end;
        if (rest < body.len and body[rest] == ' ') rest += 1;
        if (rest + 1 >= body.len or body[rest] != '=' or body[rest + 1] == '=') continue;
        try into.put(allocator, body[at..end], {});
    }
}

/// 제품 constructor 의 in-place 초기화 블록 — generation owner 를 세운 직후부터 pending event owner 를 세우기까지.
fn productInitBlock(src: []const u8, comptime name: []const u8) ![]const u8 {
    const body = try fnBody(src, name);
    const start = try expectOnce(body, "try self.initializeGenerationOwner(connection, allocator, io, size);", name ++ " 초기화 시작");
    const finish = try expectOnce(body, "try self.initializePendingEventOwner();", name ++ " 초기화 끝");
    if (finish <= start) return error.WiringChanged;
    return body[start..finish];
}

fn isExcluded(field: []const u8) bool {
    for (excluded) |e| if (std.mem.eql(u8, e.field, field)) return true;
    return false;
}

test "RemoteRuntime fixture — 제품 constructor 가 세우는 값 칸을 공통 입구도 세운다(제외는 이유와 함께)" {
    const a = std.testing.allocator;
    const raw = try read(a, runtime_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    var product: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer product.deinit(a);
    try collectAssigned(a, try productInitBlock(src, "spawnWithConnection"), "self", &product);
    try collectAssigned(a, try productInitBlock(src, "attachExistingWithConnection"), "self", &product);
    // 블록을 잘못 잘라 빈 집합을 재면 아무것도 안 잰 채 초록이 된다.
    if (product.count() < 10) {
        std.debug.print("제품 초기화 블록의 대입 칸이 {d} 개뿐이다 — 블록 경계가 어긋났다\n", .{product.count()});
        return error.WiringChanged;
    }

    var fixture: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer fixture.deinit(a);
    try collectAssigned(a, try fnBody(src, "initializeTestGeneration"), "runtime", &fixture);

    var missing: usize = 0;
    for (product.keys()) |field| {
        if (fixture.contains(field) or isExcluded(field)) continue;
        std.debug.print("fixture 공통 입구(initializeTestGeneration)가 제품이 세우는 칸 «{s}» 를 세우지 않는다\n", .{field});
        missing += 1;
    }
    // 제외 목록이 썩지 않게: 제품이 더는 세우지 않는 칸, fixture 가 이미 세우는 칸은 목록에서 빠져야 한다.
    var stale: usize = 0;
    for (excluded) |e| {
        if (!product.contains(e.field)) {
            std.debug.print("제외 «{s}» 는 제품 초기화 블록이 더는 세우지 않는다 — 목록에서 뺀다\n", .{e.field});
            stale += 1;
        } else if (fixture.contains(e.field)) {
            std.debug.print("제외 «{s}» 는 fixture 가 이미 세운다 — 목록에서 뺀다\n", .{e.field});
            stale += 1;
        }
        if (e.why.len == 0) stale += 1;
    }
    if (missing != 0 or stale != 0) return error.FixtureInitDrift;
}

test "RemoteRuntime fixture — C2 판정자는 fixture 앞에서 runtime 을 0xFF 로 독칠하고 값 칸을 단언한다" {
    const a = std.testing.allocator;
    const raw = try read(a, runtime_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // 이 판정자는 session-host 바이너리라 PR 에서 안 돈다. 독칠이 빠지면 같은 누락이 Debug 에서 다시 숨으므로 자리를 잠근다.
    // 본체 안에 peer 의 `fn run(` 이 있어 `fnBody` 로는 잘린다 — 다음 `test "` 까지를 본체로 본다.
    const start = std.mem.indexOf(u8, src, "fn runC2TypedFamilySocket(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, start, "test \"") orelse return error.FunctionMissing;
    const body = src[start..end];
    const decl_at = try expectOnce(body, "var runtime: RemoteRuntime = undefined;", "runtime 선언");
    const poison_at = try expectOnce(body, "@memset(std.mem.asBytes(&runtime), 0xFF);", "독칠");
    const init_at = try expectOnce(body, "try initGenerationRuntimeAggregateFixture(&runtime, &adapter, &client);", "fixture 초기화");
    const all_at = try expectOnce(body, "try testing.expect(!runtime.selection_all);", "선택 전체 단언");
    const auth_at = try expectOnce(body, "try testing.expect(!runtime.selection_host_authoritative);", "host 권위 선택 단언");
    const request_at = try expectOnce(body, "switch (tag) { .resize => try runtime.resize(80, 24),", "요청 실행");
    if (!(decl_at < poison_at and poison_at < init_at and init_at < all_at and all_at < auth_at and auth_at < request_at))
        return error.WiringChanged;
}
