//! **원격 활동의 오프셋이 로컬 syscall 로 새는 자리가 0 인가**(RAV3 — [계획](../../docs/plans/remote-agent-activity.md) §6.3).
//!
//! ## 왜 산문으로는 안 되는가
//!
//! 계약 §2.1 은 「저쪽 오프셋은 이쪽 syscall 에 절대 안 간다」인데, 그 규율이 깨지는 모양은 **조용하다**:
//! 원격 경로가 로컬에도 같은 모양으로 있으면(양쪽 macOS · 같은 사용자 이름 → `~/.claude/projects/…`)
//! `openFile` 이 **성공해서** 남의 대화가 이 세션 이름표 밑에 뜬다. 갤러리가 실제로 그 결함을 냈고
//! (계약 §4.1.2), 원격 파일 트리도 같은 축에서 같은 게이트를 세웠다(RF §5 — 「산문으로 두면 반드시
//! 샌다」, 그 게이트가 만들어진 계기가 「여섯 곳이 옛 축에 남아 있었다」였다).
//!
//! ## 무엇을 세는가
//!
//! 원격 소스의 바이트를 읽는 **네 소비자**가 있고(계약 §6.3), 그 전부가 `Hit` 의 오프셋으로 파일을
//! 연다. 원격 갈래는 그 넷을 **지나기 전에** 갈라져야 한다.
//!
//! 이 게이트는 **원격 갈래가 로컬 파일을 여는 자리를 지나지 않는다**를 소스에서 센다 — 원격 워커
//! (`remoteScan`·`remoteResultFromWire`)가 파일 열기·stat 토큰을 **하나도** 안 들어야 한다.
//!
//! 🔥 **처음에는 워커만 셌고 그것이 결함이었다**(적대적 N1). 계약 §6.3 은 「대상은 **넷**」이라고
//! 적어 두었는데 — 디코드 워커 · 본문 검색 워커 · 펼침 · 썸네일 — 그 넷은 **결과를 소비하는 쪽**이라
//! 워커 밖에 있다. 원격 `Hit` 을 그대로 받아 `chain.get(file_index)` → `Dir.cwd().openFile` 로 가고
//! 있었다. 게이트가 자기가 덮는다고 적은 범위를 **실제로는 안 덮고** 있었던 것이다.
//!
//! 그래서 이제 **경로를 주는 한 곳**(`pathFor`/`pathForIndex`)에 원격 가드가 있는지, 그리고 그 가드를
//! **우회하는 `chain.get` 직접 호출이 없는지**를 함께 센다.
//!
//! ⚠️ **빈 재고를 못 박는 게이트는 아무것도 안 잡는다.** 그래서 「원격 갈래가 존재한다」도 함께
//! 단언한다 — 갈래가 사라지면(누가 로컬로 되돌리면) 이 게이트가 먼저 빨개진다.

const std = @import("std");

const backend_path = "src/platform/macos/agent_image_scan_backend.zig";
const decode_path = "src/platform/macos/agent_image_decode_backend.zig";
const activity_path = "src/platform/macos/app_session/agent_activity.zig";

fn readSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buffer);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buffer);
    return buffer;
}

/// 로컬 파일시스템을 만지는 토큰. 원격 갈래 안에 이것이 있으면 §2.1 위반이다.
const local_fs_tokens = [_][]const u8{
    "openFile",
    "openDir",
    "readPositional",
    "fstat",
    "fstatat",
    "statFile",
    "deleteFile",
};

/// `fn <name>(` 부터 다음 최상위 `\n}` 까지 — 함수 본문을 거칠게 자른다.
fn bodyOf(src: []const u8, decl: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, decl) orelse return null;
    const rest = src[at..];
    const end = std.mem.indexOf(u8, rest, "\n}\n") orelse return null;
    return rest[0 .. end + 2];
}

test "RAV3 §6.3: 원격 스캔 갈래는 로컬 파일시스템을 안 만진다" {
    const gpa = std.testing.allocator;
    const backend_src = try readSource(gpa, std.testing.io, backend_path);
    defer gpa.free(backend_src);
    for ([_][]const u8{
        "fn remoteScan(",
        "fn remoteResultFromWire(",
    }) |decl| {
        const body = bodyOf(backend_src, decl) orelse {
            std.debug.print("원격 갈래 `{s}` 를 못 찾았다 — 갈래가 사라졌거나 이름이 바뀌었다.\n" ++
                "  이 게이트는 **그 갈래가 있다**를 전제로 선다(빈 재고는 아무것도 안 잡는다).\n", .{decl});
            return error.TestUnexpectedResult;
        };
        for (local_fs_tokens) |token| {
            if (std.mem.indexOf(u8, body, token) != null) {
                std.debug.print("🔥 원격 갈래 `{s}` 안에 로컬 파일시스템 토큰 `{s}` 가 있다.\n" ++
                    "  저쪽 오프셋을 이쪽 syscall 에 넘기면 **같은 모양의 로컬 경로가 열려** 남의 대화가 뜬다\n" ++
                    "  (계약 §2.1 · 갤러리 §4.1.2 가 실제로 낸 결함). 바이트는 wire 로만 온다.\n", .{ decl, token });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "RAV3 §6.3: 원격 소스는 로컬 체인 탐색을 안 지난다" {
    const gpa = std.testing.allocator;
    const activity_src = try readSource(gpa, std.testing.io, activity_path);
    defer gpa.free(activity_src);
    // `buildChain` 은 `~/.codex/sessions` 를 **로컬** 디렉터리로 훑어 부모 rollout 을 찾는다. 원격
    // 경로에 대고 부르면 이쪽 파일을 뒤진다 — 저쪽에서 체인을 푸는 것은 RAV4 다.
    const marker = "if (self.agent_activity.source_remote)\n        remoteHeadChain(path)";
    if (std.mem.indexOf(u8, activity_src, marker) == null) {
        std.debug.print("🔥 원격 소스가 `buildChain`(로컬 디렉터리 탐색)으로 흘러간다.\n" ++
            "  원격이면 `remoteHeadChain` 으로 갈라야 한다(계약 §2.1).\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "RAV3 §6.3: 원격 소스는 로컬 신선도 stat 을 안 지난다" {
    const gpa = std.testing.allocator;
    const activity_src = try readSource(gpa, std.testing.io, activity_path);
    defer gpa.free(activity_src);
    // `stampOf` 는 로컬 `stat` 이다. 원격 경로로 부르면 같은 모양의 로컬 파일 크기를 자국으로 삼아
    // 「안 자랐다」고 오판한다(또는 없는 파일이라 0).
    const marker = "if (self.agent_activity.source_remote) .{} else stampOf(self, path)";
    if (std.mem.indexOf(u8, activity_src, marker) == null) {
        std.debug.print("🔥 원격 소스가 `stampOf`(로컬 stat)로 흘러간다(계약 §2.1).\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "RAV3: 원격 실패를 「없다」로 말하지 않는다" {
    const gpa = std.testing.allocator;
    const activity_src = try readSource(gpa, std.testing.io, activity_path);
    defer gpa.free(activity_src);
    // 왕복이 실패하면 자리가 0 개로 오는데, 그것을 그냥 그리면 화면이 「활동이 없습니다」라고
    // 거짓말한다 — 계약 §2.2 가 가장 크게 여기는 갈림이다.
    const marker = "if (self.agent_activity.remote_failed) return maru.i18n.t(.agent_activity_remote_unsupported);";
    if (std.mem.indexOf(u8, activity_src, marker) == null) {
        std.debug.print("🔥 원격 왕복 실패가 「활동이 없습니다」로 보인다(계약 §2.2).\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "RAV3 §6.3: 경로를 주는 한 곳이 원격을 막는다 — 네 소비자가 그 문을 지난다" {
    const gpa = std.testing.allocator;
    const activity_src = try readSource(gpa, std.testing.io, activity_path);
    defer gpa.free(activity_src);

    // 🔥 적대적 N1: 디코드·본문 검색·펼침·썸네일이 **원격 `Hit` 으로 로컬 파일을 열고** 있었다.
    // 소비자마다 가드를 두면 넷 중 하나를 잊고, 그 하나가 조용히 남의 파일을 연다.
    const guard = "fn pathForIndex(self: *const AppSession, file_index: u8) ?[]const u8 {\n" ++
        "    if (self.agent_activity.source_remote) return null;";
    if (std.mem.indexOf(u8, activity_src, guard) == null) {
        std.debug.print("🔥 경로를 주는 한 곳(`pathForIndex`)에 원격 가드가 없다.\n" ++
            "  그 경로는 곧바로 `Dir.cwd().openFile` 로 간다(계획 §6.3 의 네 소비자).\n", .{});
        return error.TestUnexpectedResult;
    }

    // **그 문을 우회하는 자리가 없어야 한다.** `chain.get` 직접 호출은 `pathForIndex` 안의 하나뿐이다.
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, activity_src, at, "chain.get(")) |found| {
        count += 1;
        at = found + 1;
    }
    // **두 문만 허용한다**: `pathForIndex`(로컬 open 으로 가는 값) · `remotePathForIndex`(ssh argv 로
    // 가는 값). 둘은 같은 문자열을 주지만 **가는 곳이 반대**라 합치면 안 된다 — 그 판단을 호출자에게
    // 맡기는 순간 한 번의 실수가 남의 파일을 연다.
    if (count != 2) {
        std.debug.print("🔥 `chain.get(` 호출이 {d} 곳이다 — 둘이어야 한다" ++
            "(`pathForIndex` 와 `remotePathForIndex`).\n  다른 자리는 두 문을 **우회한다**.\n", .{count});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, activity_src, "fn remotePathForIndex(self: *const AppSession, file_index: u8) ?[]const u8 {\n" ++
        "    if (!self.agent_activity.source_remote) return null;") == null)
    {
        std.debug.print("🔥 저쪽 경로를 주는 문(`remotePathForIndex`)이 로컬을 안 막는다.\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "RAV5b §6.3: 원격 펼침 워커도 로컬 파일시스템을 안 만진다" {
    const gpa = std.testing.allocator;
    const activity_src = try readSource(gpa, std.testing.io, activity_path);
    defer gpa.free(activity_src);

    // 원격 펼침은 **저쪽 구간을 당겨온다**(RAV5b). 그 워커 안에 로컬 파일 열기가 생기면 저쪽
    // 오프셋이 이쪽 파일에 닿는다 — §13.6 N1 이 잡은 그 사고가 새 워커에서 되살아난다.
    const body = bodyOf(activity_src, "fn remoteDetailWorker(") orelse {
        std.debug.print("원격 펼침 워커를 못 찾았다 — 갈래가 사라졌거나 이름이 바뀌었다.\n", .{});
        return error.TestUnexpectedResult;
    };
    for (local_fs_tokens) |token| {
        if (std.mem.indexOf(u8, body, token) != null) {
            std.debug.print("🔥 `remoteDetailWorker` 안에 로컬 파일시스템 토큰 `{s}` 가 있다(계약 §2.1).\n", .{token});
            return error.TestUnexpectedResult;
        }
    }

    // **로컬과 같은 규칙으로 푼다** — 푸는 함수가 하나여야 원격 펼침이 로컬과 같은 글자를 보여 준다.
    if (std.mem.indexOf(u8, activity_src, "op.detail.command = decodeDetailPart(self, outcome.command") == null) {
        std.debug.print("🔥 원격 펼침이 `decodeDetailPart`(단일 출처)를 안 지난다(계약 §2.3).\n", .{});
        return error.TestUnexpectedResult;
    }

    // **못 당겨온 것을 「빈 명령」으로 그리지 않는다**(계약 §2.2).
    if (std.mem.indexOf(u8, activity_src, "if (op.detail.remote_failed and row < rows_fit)") == null) {
        std.debug.print("🔥 원격 펼침 실패가 「빈 명령」으로 보인다(계약 §2.2).\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "RAV6 §6.3: 원격 그림도 로컬 파일을 안 연다" {
    const gpa = std.testing.allocator;
    const decode_src = try readSource(gpa, std.testing.io, decode_path);
    defer gpa.free(decode_src);

    // 디코드 워커는 **원격이면 구간을 당겨온다**. 그 갈래 안에 로컬 파일 열기가 생기면 저쪽 오프셋이
    // 이쪽 그림을 디코드한다 — §13.6 N1 이 잡은 그 사고가 픽셀 축에서 되살아난다.
    const body = bodyOf(decode_src, "fn fetchRemoteBase64(") orelse {
        std.debug.print("원격 그림 갈래를 못 찾았다 — 갈래가 사라졌거나 이름이 바뀌었다.\n", .{});
        return error.TestUnexpectedResult;
    };
    for (local_fs_tokens) |token| {
        if (std.mem.indexOf(u8, body, token) != null) {
            std.debug.print("🔥 `fetchRemoteBase64` 안에 로컬 파일시스템 토큰 `{s}` 가 있다(계약 §2.1).\n", .{token});
            return error.TestUnexpectedResult;
        }
    }

    // **잘린 payload 를 디코드하지 않는다.** 잘린 base64 는 깨진 그림이거나 더 나쁘게는 다른 그림이다.
    if (std.mem.indexOf(u8, decode_src, "if (bytes.len != len) return null;") == null) {
        std.debug.print("🔥 짧게 온 그림 payload 를 그대로 디코드한다(RF4 의 「잘린 내용이 온전한 척」 규율 위반).\n", .{});
        return error.TestUnexpectedResult;
    }

    // **워커가 갈린다** — 원격이면 `openFile` 을 지나지 않는다.
    if (std.mem.indexOf(u8, decode_src, "const b64 = if (job.remote) |r|") == null) {
        std.debug.print("🔥 디코드 워커에 원격 갈래가 없다 — 원격 그림이 로컬 경로로 간다.\n", .{});
        return error.TestUnexpectedResult;
    }
}
