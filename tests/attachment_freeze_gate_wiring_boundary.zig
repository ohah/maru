//! 재접속이 attachment 를 **얼린 동안** payload 에 닿는 자리가 모두 관문을 지나는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-10-05 19:07 — 화면 배치 해석 실패(`frame_malformed`)로 연결이 poison 됐고, 재접속은 곧 붙었다
//! (`reconnect job connected`). 같은 프레임에서 재접속이 host 의 모든 runtime 을 `retirement_prepared` 로 얼렸고,
//! 이어진 창 drain 이 `drainRemote` → `pumpDelta` → `statePtr()` 로 payload 를 읽다
//! `generation attachment is not live: site=payloadMut lifecycle_raw=7` 로 앱이 abort 했다. 유지보수 펌프에는
//! 같은 관문이 이미 있었지만(그래서 프레임 요약이 없었다) 창 drain 이 요약 없이 직접 펌프했다.
//!
//! 판정 자체(`attachment_freeze_gate.zig`)는 순수 테스트가 잰다. 관문을 부르는 자리는 backend·소켓을 써서 PR 에서
//! 못 돌리므로 — 관문이 **payload 를 읽기 전에** 있는지를 여기서 글자로 잰다. 수명 입구(`admitRuntimeOperation`·
//! `admitDestructiveRuntimeOperation`, 수신자 무관)만 지나 payload 에 닿는 함수가 새로 생기면 ⑤ 가 이름을 대며
//! 실패한다 — payload 도우미와 간접 사슬은 손으로 고르지 않고 코드에서 유도한다.

const std = @import("std");

const runtime_path = "src/platform/macos/session_host/remote_runtime.zig";
const attachment_path = "src/platform/macos/session_host/remote_attachment.zig";
const generation_attachment_path = "src/platform/macos/session_host/generation_attachment.zig";

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

/// 첫 `test "` 앞까지 — 테스트 픽스처가 payload 를 직접 만지는 것은 이 계약 밖이다.
fn productRegion(src: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, src, "test \"") orelse src.len;
    return src[0..end];
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

fn expectBefore(haystack: []const u8, first: usize, needle: []const u8, what: []const u8) !void {
    const at = std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("{s}: «{s}» 가 없다\n", .{ what, needle });
        return error.WiringChanged;
    };
    if (first >= at) {
        std.debug.print("{s}: 관문이 «{s}» 보다 뒤에 있다 — payload 를 읽은 뒤에는 이미 늦다\n", .{ what, needle });
        return error.WiringChanged;
    }
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

const payload_reads = [_][]const u8{ "attachment.streamId()", "attachment.statePtr()" };

fn firstPayloadRead(body: []const u8) ?usize {
    var best: ?usize = null;
    for (payload_reads) |needle| {
        if (std.mem.indexOf(u8, body, needle)) |at| {
            if (best == null or at < best.?) best = at;
        }
    }
    return best;
}

test "재접속 얼림 관문: 프레임 drain 은 payload 를 읽기 전에 멈추고 세션을 끝내지 않는다" {
    const a = std.testing.allocator;
    const raw = try read(a, runtime_path);
    defer a.free(raw);
    const all = try normalize(a, raw);
    defer a.free(all);
    const src = productRegion(all);

    // ① 판정 출처: live 는 `GenerationAttachment.isLive` 하나(`backend_api.attachmentLive`)에서만 나온다.
    const freeze = try fnBody(src, "freezeAction");
    _ = try expectOnce(freeze, "attachment_freeze_gate.decide(backend_api.attachmentLive(self), op)", "freezeAction");
    if (std.mem.indexOf(u8, freeze, "lifecycle") != null) {
        std.debug.print("freezeAction: lifecycle 을 직접 읽는다 — isLive 와 판정이 갈라진다\n", .{});
        return error.WiringChanged;
    }

    // ② pumpDelta: 수명 관문 뒤, 첫 payload 읽기·poison 캡처 무장·attachment 분기 앞에서 `.idle` 로 돌아간다.
    const pump = try fnBody(src, "pumpDelta");
    const admit_at = try expectOnce(pump, "try self.admitRuntimeOperation();", "pumpDelta");
    const gate = "if (self.freezeAction(.pump) != .proceed) return .idle;";
    const gate_at = try expectOnce(pump, gate, "pumpDelta");
    if (admit_at >= gate_at) {
        std.debug.print("pumpDelta: 얼림 관문이 수명 관문보다 앞에 있다\n", .{});
        return error.WiringChanged;
    }
    try expectBefore(pump, gate_at, "attachment.statePtr()", "pumpDelta");
    try expectBefore(pump, gate_at, "armReadPumpPoisonCapture(", "pumpDelta");
    try expectBefore(pump, gate_at, "switch (self.currentGeneration().attachment)", "pumpDelta");
}

test "재접속 얼림 관문: 비변경 RPC·detach·terminate 는 payload 를 읽기 전에 관문을 지난다" {
    const a = std.testing.allocator;
    const raw = try read(a, runtime_path);
    defer a.free(raw);
    const all = try normalize(a, raw);
    defer a.free(all);
    const src = productRegion(all);

    // ③ 비변경 RPC 의 입구: 수명 관문 바로 뒤의 얼림 관문(`AdminBusy`)이 첫 payload 읽기 앞에 있다.
    //    수명 관문 문장은 입장 재고(C3-3b2b3)가 «입구마다 한 번» 으로 따로 센다.
    const busy = "if (self.freezeAction(.read_rpc) != .proceed) return error.AdminBusy;";
    inline for (.{ "refreshObservation", "selectedText", "linkAt", "requestResync", "find" }) |name| {
        const body = try fnBody(src, name);
        const admit_at = try expectOnce(body, "try self.admitRuntimeOperation();", name);
        const at = try expectOnce(body, busy, name);
        if (admit_at >= at) {
            std.debug.print("{s}: 얼림 관문이 수명 관문보다 앞에 있다\n", .{name});
            return error.WiringChanged;
        }
        const read_at = firstPayloadRead(body) orelse {
            std.debug.print("{s}: payload 를 읽지 않는다 — 목록을 갱신하라\n", .{name});
            return error.WiringChanged;
        };
        if (at >= read_at) {
            std.debug.print("{s}: 관문이 첫 payload 읽기보다 뒤에 있다\n", .{name});
            return error.WiringChanged;
        }
    }

    // ④ client 쪽 회수(detach)와 runtime 파괴(terminate — 탭 닫기의 close 경로·runtime deinit): 얼린 동안에는
    //    보내지 않는다. 각 관문은 «이미 끝난 attachment» 판정 뒤, 첫 payload 읽기·입력 flush 앞이다.
    const detach = try fnBody(src, "detachBestEffort");
    const skip_at = try expectOnce(detach, "if (self.freezeAction(.detach) != .proceed) {", "detachBestEffort");
    try expectBefore(detach, skip_at, "attachment.streamId()", "detachBestEffort");
    const terminate = try fnBody(src, "terminateBestEffort");
    const terminal_at = try expectOnce(terminate, "if (self.currentAttachmentTerminal()) return;", "terminateBestEffort");
    const term_skip_at = try expectOnce(terminate, "if (self.freezeAction(.terminate) != .proceed) {", "terminateBestEffort");
    if (terminal_at >= term_skip_at) return error.WiringChanged;
    try expectBefore(terminate, term_skip_at, "self.flushQueuedInputBlocking()", "terminateBestEffort");
    try expectBefore(terminate, term_skip_at, "self.callDecodedAfterFlush(", "terminateBestEffort");
}

// ── ⑤ 같은 꼴의 새 구멍을 코드에서 **유도해** 찾는다 ─────────────────────────────────────────────────────
//
// 손으로 고른 목록은 첫 리뷰에서 셋이 샜다(`self` 가 아닌 수신자, `admitDestructiveRuntimeOperation` 뒤의
// `initScreen`, `callDecodedAfterFlush` 를 거친 간접 읽기). 그래서 목록을 코드에서 만든다:
//   1. payload 도우미 = `generation_attachment.zig` 에서 본문이 `payloadMut()`/`payloadConst()` 를 부르는 함수.
//   2. 직접 읽기 = `attachment.<도우미>(`. 관문 없이 직접 읽기(또는 이미 위험한 함수 호출)에 닿는 함수는 위험하다 —
//      고정점까지 넓힌다(`callDecoded*` → `executeDecoded*` → `statePtr()` 같은 사슬).
//   3. 입구 = 어떤 수신자든 `.admitRuntimeOperation()`·`.admitDestructiveRuntimeOperation()`. 입구 뒤 첫 위험 읽기
//      앞에 관문이 없으면 실패한다.
// 관문 = live 를 보는 것: `mutationAllowed()`·`gateMutation(`(둘 다 isLive)·`freezeAction(`·`isLive()`·
// `attachmentLive(`·`screenPumpDrained()`(live 가 아니면 false 를 돌려준다).

const gate_tokens = [_][]const u8{
    "mutationAllowed()", "gateMutation(",   "freezeAction(",
    "isLive()",          "attachmentLive(", "screenPumpDrained()",
};

/// 관문 없이 위험 읽기에 닿지만 **다른 근거로 얼린 창에 오지 않는** 입구. 이유 없는 항목은 두지 않는다.
/// 목록이 낡으면(더는 위반이 아니면) 실패한다 — 근거가 사라진 예외가 남아 새 구멍을 가리지 않게.
const allowlist = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "hasBufferedFrameWork", .why = "유지보수 tick 이 attachmentLive 로 거른 runtime 에만 부른다(remote_term_backend)" },
    .{ .name = "executeReconnectControllerTakeoverUntil", .why = "재접속 job 자신의 전이 — 얼린 쪽이 아니라 후보 세대에 작용" },
    .{ .name = "validateReconnectControllerEvidence", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "abortReconnectControllerEvidence", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "promoteReconnectControllerEvidence", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "validateReconnectPromotedController", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "abortReconnectPromotedController", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "forceReconnectCandidateResizeUntil", .why = "재접속 job 자신의 전이 — 후보 세대" },
    .{ .name = "publishReconnectPromotedCandidateImpl", .why = "재접속 job 자신의 전이 — 후보 세대를 게시" },
};

const FnSpan = struct { name: []const u8, start: usize, end: usize };

fn collectFns(a: std.mem.Allocator, src: []const u8) ![]FnSpan {
    var list: std.ArrayList(FnSpan) = .empty;
    errdefer list.deinit(a);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, " fn ")) |found| : (at = found + 4) {
        const name_start = found + 4;
        var name_end = name_start;
        while (name_end < src.len and (std.ascii.isAlphanumeric(src[name_end]) or src[name_end] == '_')) name_end += 1;
        if (name_end == name_start or name_end >= src.len or src[name_end] != '(') continue;
        try list.append(a, .{ .name = src[name_start..name_end], .start = found, .end = src.len });
    }
    const items = list.items;
    for (items, 0..) |*item, i| {
        if (i + 1 < items.len) item.end = items[i + 1].start;
    }
    return list.toOwnedSlice(a);
}

/// 함수 본문(머리 뒤 첫 `{` 부터).
fn spanBody(src: []const u8, span: FnSpan) []const u8 {
    const text = src[span.start..span.end];
    const brace = std.mem.indexOfScalar(u8, text, '{') orelse return text[text.len..];
    return text[brace..];
}

fn earliest(hay: []const u8, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, hay, needle)) |at| {
            if (best == null or at < best.?) best = at;
        }
    }
    return best;
}

fn gatedBefore(hay: []const u8, limit: usize) bool {
    return earliest(hay[0..limit], &gate_tokens) != null;
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn allowed(name: []const u8) bool {
    for (allowlist) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

test "재접속 얼림 관문: 수명 입구 뒤 관문 없이 payload 에 닿는 함수가 없다 — 도우미·간접 사슬은 코드에서 유도한다" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ga = try normalize(arena, try read(arena, generation_attachment_path));
    const all = try normalize(arena, try read(arena, runtime_path));
    const src = productRegion(all);

    // 1. payload 도우미.
    var helpers: std.ArrayList([]const u8) = .empty;
    const ga_fns = try collectFns(arena, ga);
    for (ga_fns) |span| {
        const body = spanBody(ga, span);
        if (std.mem.indexOf(u8, body, "payloadMut()") == null and std.mem.indexOf(u8, body, "payloadConst()") == null) continue;
        // 접근자 자신과 관문 술어(`allowsMutation`·`mutationDenial` — 호출부가 isLive 뒤에서만 부른다)는 읽기가 아니다.
        inline for (.{ "payloadMut", "payloadConst", "allowsMutation", "mutationDenial" }) |skip| {
            if (std.mem.eql(u8, span.name, skip)) break;
        } else if (!containsName(helpers.items, span.name)) try helpers.append(arena, span.name);
    }
    // 도우미 유도가 비면 판정자가 공허해진다 — 지금 알려진 셋은 반드시 있어야 한다.
    inline for (.{ "statePtr", "streamId", "initScreen" }) |must| {
        if (!containsName(helpers.items, must)) {
            std.debug.print("payload 도우미 유도에서 {s} 가 빠졌다 — 유도 규칙을 확인하라\n", .{must});
            return error.WiringChanged;
        }
    }
    var direct: std.ArrayList([]const u8) = .empty;
    for (helpers.items) |helper| {
        try direct.append(arena, try std.fmt.allocPrint(arena, "attachment.{s}(", .{helper}));
        try direct.append(arena, try std.fmt.allocPrint(arena, "attachment.generation.{s}(", .{helper}));
    }

    // 2. 위험한 함수 — 고정점.
    const rt_fns = try collectFns(arena, src);
    var unsafe_names: std.ArrayList([]const u8) = .empty;
    var reads: std.ArrayList([]const u8) = .empty;
    try reads.appendSlice(arena, direct.items);
    var changed = true;
    while (changed) {
        changed = false;
        for (rt_fns) |span| {
            if (containsName(unsafe_names.items, span.name)) continue;
            const body = spanBody(src, span);
            const first = earliest(body, reads.items) orelse continue;
            if (gatedBefore(body, first)) continue;
            try unsafe_names.append(arena, span.name);
            try reads.append(arena, try std.fmt.allocPrint(arena, ".{s}(", .{span.name}));
            changed = true;
        }
    }

    // 3. 입구 — 어떤 수신자든.
    var offenders: usize = 0;
    var allow_hits = [_]bool{false} ** allowlist.len;
    inline for (.{ ".admitRuntimeOperation()", ".admitDestructiveRuntimeOperation()" }) |entry| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, entry)) |found| : (at = found + entry.len) {
            const span = for (rt_fns) |candidate| {
                if (candidate.start <= found and found < candidate.end) break candidate;
            } else continue;
            const tail = src[found + entry.len .. span.end];
            const first = earliest(tail, reads.items) orelse continue;
            if (gatedBefore(tail, first)) continue;
            if (allowed(span.name)) {
                for (allowlist, 0..) |item, index| {
                    if (std.mem.eql(u8, item.name, span.name)) allow_hits[index] = true;
                }
                continue;
            }
            const read_end = std.mem.indexOfScalarPos(u8, tail, first, '(') orelse first;
            std.debug.print("입구 뒤 관문 없이 payload 에 닿는다: fn {s} ({s} 뒤 «{s}»)\n", .{
                span.name, entry, tail[first..@min(read_end + 1, tail.len)],
            });
            offenders += 1;
        }
    }
    for (allowlist, allow_hits) |item, hit| {
        if (!hit) {
            std.debug.print("allowlist 항목 {s} 는 더는 위반이 아니다 — 지워라 ({s})\n", .{ item.name, item.why });
            offenders += 1;
        }
    }
    if (offenders != 0) return error.WiringChanged;
}

test "화면 배치 해석 실패는 frame_malformed 로 닫기 전에 단계와 오류 이름을 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, attachment_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const helper = try fnBody(src, "logScreenBatchMalformed");
    _ = try expectOnce(helper, "@errorName(err)", "logScreenBatchMalformed");

    const body = try fnBody(src, "pumpScreenInternal");
    const malformed = ".frame_malformed";
    const n = countAll(body, malformed);
    if (n != 4) {
        std.debug.print("pumpScreenInternal: frame_malformed 자리가 {d} 곳 — 4 곳을 전제로 잰다, 목록을 갱신하라\n", .{n});
        return error.WiringChanged;
    }
    // 각 자리 바로 앞(같은 catch 블록 안)에 기록이 있어야 한다.
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, malformed)) |found| : (at = found + malformed.len) {
        const block_start = std.mem.lastIndexOf(u8, body[0..found], "catch |err| {") orelse return error.WiringChanged;
        const block = body[block_start..found];
        if (std.mem.indexOf(u8, block, "logScreenBatchMalformed(") == null) {
            std.debug.print("pumpScreenInternal: frame_malformed 로 닫는 자리에 기록이 없다(offset {d})\n", .{found});
            return error.WiringChanged;
        }
    }
}
