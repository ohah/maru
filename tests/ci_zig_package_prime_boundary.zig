//! CI 의 Zig 의존성은 **저장소 사본에서만** 온다 — 외부 다운로드가 끊겨 잡이 빨개지는 일을 원리상 없앤다.
//!
//! 2026-09-29 main CI 의 「실제 타 UID peer 거부 스모크」 실패는 테스트가 아니라 첫 `zig build` 가 tree-sitter tarball 을
//! GitHub 에서 받다가 `HttpConnectionClosing` 으로 죽은 것이었다. Zig 0.16 은 `<global_cache>/p/<hash>.tar.gz` 가 있으면
//! 내려받지 않으므로, `tools/ci/prime-zig-packages.sh` 가 `vendor/zig-packages` 의 사본을 거기 채운다.
//!
//! 이 장치는 **조용히** 무너진다 — 채우기 스텝이 빠진 잡이나 사본이 빠진 의존성은 Zig 가 그냥 네트워크로 받아 초록이다.
//! 그래서 두 가지를 센다: ⑴ Zig 를 설치하는 모든 `mise-action` 바로 다음 스텝이 채우기다 ⑵ 사본 집합 == build.zig.zon 해시
//! 집합(빠진 것도 남는 것도 없다).
const std = @import("std");

const prime_step =
    "\n      - name: Zig 패키지를 저장소 사본에서 채운다(외부 다운로드 0)\n" ++
    "        run: sh tools/ci/prime-zig-packages.sh\n";

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(2 * 1024 * 1024));
}

test "every mise-action step is immediately followed by the vendored zig package prime step" {
    const allocator = std.testing.allocator;
    const workflows_dir = ".github/workflows";
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, workflows_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var installs: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workflows_dir, entry.name });
        defer allocator.free(path);
        const text = try read(allocator, path);
        defer allocator.free(text);

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "\n      - uses: jdx/mise-action@")) |install| {
            installs += 1;
            // 그 스텝의 끝 = 다음 스텝 머리(같은 6칸 들여쓰기의 `- `) 또는 빈 줄. 그 자리에 채우기가 서야 한다 —
            // 사이에 다른 스텝이 끼면 그 스텝의 `zig` 가 먼저 네트워크로 받는다.
            const body_start = install + 1;
            const next_step = std.mem.indexOfPos(u8, text, body_start, "\n      - ") orelse text.len;
            const blank = std.mem.indexOfPos(u8, text, body_start, "\n\n") orelse text.len;
            const end = @min(next_step, blank);
            if (!std.mem.startsWith(u8, text[end..], prime_step)) {
                const line = 1 + count(text[0..install], "\n") + 1;
                std.debug.print("{s}:{d}: mise-action 바로 다음이 Zig 패키지 채우기 스텝이 아니다\n", .{ path, line });
                return error.MiseActionWithoutPackagePrime;
            }
            at = end + prime_step.len;
        }
        // 채우기 스텝은 설치 뒤에만 선다 — 설치 없는 곳에 홀로 있으면 zig 가 없어 그 스텝이 죽는다.
        try std.testing.expectEqual(count(text, "\n      - uses: jdx/mise-action@"), count(text, prime_step));
    }
    // 0 이면 위 검사가 아무것도 안 잰 것이다(디렉터리·들여쓰기 형식이 바뀜).
    try std.testing.expect(installs >= 20);
}

test "vendored zig packages are exactly the build.zig.zon dependency hashes" {
    const allocator = std.testing.allocator;
    const zon = try read(allocator, "build.zig.zon");
    defer allocator.free(zon);

    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer wanted.deinit(allocator);
    const key = ".hash = \"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, zon, at, key)) |start| {
        const value_start = start + key.len;
        const value_end = std.mem.indexOfScalarPos(u8, zon, value_start, '"') orelse return error.MalformedZon;
        try wanted.put(allocator, zon[value_start..value_end], {});
        at = value_end;
    }
    try std.testing.expect(wanted.count() >= 1);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "vendor/zig-packages", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var found: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tar.gz")) {
            std.debug.print("vendor/zig-packages/{s}: tarball 이 아닌 파일\n", .{entry.name});
            return error.UnexpectedVendorFile;
        }
        const hash = entry.name[0 .. entry.name.len - ".tar.gz".len];
        if (!wanted.contains(hash)) {
            std.debug.print("vendor/zig-packages/{s}: build.zig.zon 에 없는 사본 — sh tools/ci/vendor-zig-packages.sh\n", .{entry.name});
            return error.StaleVendoredPackage;
        }
        found += 1;
    }
    if (found != wanted.count()) {
        std.debug.print("사본 {d} 개 / 의존성 {d} 개 — 빠진 의존성은 CI 에서 네트워크로 받는다. sh tools/ci/vendor-zig-packages.sh\n", .{ found, wanted.count() });
        return error.MissingVendoredPackage;
    }
}
