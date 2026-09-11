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
//! ⚠️ **빈 재고를 못 박는 게이트는 아무것도 안 잡는다.** 그래서 「원격 갈래가 존재한다」도 함께
//! 단언한다 — 갈래가 사라지면(누가 로컬로 되돌리면) 이 게이트가 먼저 빨개진다.

const std = @import("std");

const backend_path = "src/platform/macos/agent_image_scan_backend.zig";
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
