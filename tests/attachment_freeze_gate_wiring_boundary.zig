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
//! 못 돌리므로 — 관문이 **payload 를 읽기 전에** 있는지를 여기서 글자로 잰다. 새 RPC 가 `admitRuntimeOperation`
//! 만 지나 곧바로 payload 를 읽으면 ③ 이 이름을 대며 실패한다.

const std = @import("std");

const runtime_path = "src/platform/macos/session_host/remote_runtime.zig";
const attachment_path = "src/platform/macos/session_host/remote_attachment.zig";

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

test "재접속 얼림 관문: 비변경 RPC·detach 는 payload 를 읽기 전에 관문을 지나고, 관문 없는 새 RPC 는 이름이 불린다" {
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

    // ④ 탭 닫기: 얼린 동안에는 detach 를 보내지 않는다.
    const detach = try fnBody(src, "detachBestEffort");
    const skip_at = try expectOnce(detach, "if (self.freezeAction(.detach) != .proceed) {", "detachBestEffort");
    try expectBefore(detach, skip_at, "attachment.streamId()", "detachBestEffort");

    // ⑤ 같은 꼴의 새 구멍: `self` 의 함수가 수명 관문만 지나 곧바로 payload 를 읽으면 실패한다. 그 사이에
    //    변경 관문(`mutationAllowed`/`gateMutation` — isLive 를 본다)이나 얼림 관문이 있어야 한다.
    const admit = "try self.admitRuntimeOperation();";
    var at: usize = 0;
    var offenders: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, admit)) |found| : (at = found + admit.len) {
        const fn_start = std.mem.lastIndexOf(u8, src[0..found], " fn ") orelse continue;
        const fn_end = std.mem.indexOfPos(u8, src, found, " fn ") orelse src.len;
        const tail = src[found..fn_end];
        const read_rel = firstPayloadRead(tail) orelse continue;
        const between = tail[0..read_rel];
        const gated = std.mem.indexOf(u8, between, "mutationAllowed()") != null or
            std.mem.indexOf(u8, between, "gateMutation(") != null or
            std.mem.indexOf(u8, between, "freezeAction(") != null;
        if (gated) continue;
        const name_end = std.mem.indexOfScalarPos(u8, src, fn_start + 4, '(') orelse fn_start + 4;
        std.debug.print("수명 관문만 지나 payload 를 읽는다: fn {s}\n", .{src[fn_start + 4 .. name_end]});
        offenders += 1;
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
