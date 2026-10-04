//! 저장된 workspace 를 **읽지 못한 실행이 침묵하지 않는지**, 그리고 그 실행이 **파일을 덮지 않는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-10-05 — 헤더가 `maru.workspace.v2` 로 바뀐 빌드를 설치하자 v1 저장본이 `BadHeader` 로 거절됐다. 앱은
//! 매 실행 빈 창으로 떴고 로그에는 `workspace checkpoint: skipped: restore_incomplete latch is set` 한 줄뿐이었다
//! — host 에는 세션 34 개가 살아 있었는데 사용자에게는 「세션이 다 날아갔다」로 보였다. 원인을 찾는 데 파서를 떼어
//! 사본에 돌려야 했다. 파일이 보존된 덕분에 헤더 한 줄만 고쳐 레이아웃을 되찾았다.
//!
//! 그래서 둘을 잰다. ① Zig 의 window_count ABI 가 parse 실패의 **오류 이름**을 남긴다. ② Swift 의 `count < 0` 갈래가
//! 결과를 한 줄 남기고, **래치를 세워 파일을 보존한다**(self-heal 덮어쓰기로 바꾸면 살아 있는 host runtime 과의 유일한
//! 연결 정보가 기본 창 상태로 덮인다 — docs/workspace-restore.md 「checkpoint 보호」).

const std = @import("std");

const abi_path = "src/platform/macos/app_host_abi.zig";
const swift_path = "src/platform/macos/MaruAppHost.swift";

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

fn expectCount(haystack: []const u8, needle: []const u8, want: usize, what: []const u8) !void {
    const n = countAll(haystack, needle);
    if (n != want) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — {d} 번이어야 한다\n", .{ what, needle, n, want });
        return error.WiringChanged;
    }
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "workspace window_count 는 parse 실패의 오류 이름을 남기고 -1 을 돌려준다" {
    const a = std.testing.allocator;
    const raw = try read(a, abi_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);
    const body = try fnBody(src, "maru_macos_app_session_workspace_window_count");

    // parse 의 catch 가 오류를 **잡아 이름을 남긴 뒤** -1 을 돌려준다. 이름 없는 `catch return -1` 로 돌아가면
    // 「왜 복원이 안 되나」가 다시 로그에서 사라진다.
    try expectCount(
        body,
        "var parsed = maru.session.workspace.parse(parse_allocator, tp[0..text_len]) catch |err| { " ++
            "std.log.scoped(.app).warn(\"workspace parse failed: {s} bytes={d}\", .{ @errorName(err), text_len }); " ++
            "return -1; };",
        1,
        "window_count 의 parse 실패 기록",
    );
    try expectCount(body, "parse(parse_allocator, tp[0..text_len]) catch return -1", 0, "이름 없는 parse 실패");
}

test "workspace 를 읽지 못한 실행은 결과를 한 줄 남기고 래치를 세워 파일을 보존한다" {
    const a = std.testing.allocator;
    const raw = try read(a, swift_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // `count < 0` 갈래 전체를 한 문장으로 잡는다 — 조건·기록·래치·조기 반환이 이 순서로 붙어 있어야 한다.
    // 기록을 빼거나, 래치를 빼 self-heal(덮어쓰기)로 바꾸거나, 조건 밖으로 옮기면 이 연속이 깨진다.
    try expectCount(
        src,
        "if count < 0 { " ++
            "fputs(\"maru: workspace restore skipped — saved workspace did not parse; starting with a default window, keeping the file\\n\", stderr) " ++
            "workspaceRestoreIncomplete = true return true }",
        1,
        "restoreWorkspace 의 parse 실패 갈래",
    );
}
