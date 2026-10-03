//! `maru-chromium` 설치물의 manifest(W7a1, docs/plans/web-osr-backend.md C9)를 만든다 — 빌드 스텝(`web-sidecar-dist`)이
//! 부른다. W7a2 에서 maru 가 sidecar 를 띄우기 전에 이 파일로 제어 채널 버전이 맞는지 볼 것이다 — 지금 maru 는 읽지 않는다. CEF·Chromium 버전은 SDK 의
//! `include/cef_version.h` 에서 읽는다(디렉터리 이름에 기대지 않는다 — formula 가 다른 이름으로 풀 수 있다). arch 는 실제
//! 프레임워크 바이너리의 Mach-O 머리에서 읽고, 빌드 대상과 다르면 멈춘다(arm64 SDK 로 x86_64 를 만들면 틀린 설치물이다).
//!
//! 사용: web-sidecar-manifest <출력 경로> <cef_version.h> <프레임워크 바이너리> <대상 arch> <maru 버전>

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutput;
    const header_path = args.next() orelse return error.MissingHeader;
    const framework_path = args.next() orelse return error.MissingFramework;
    const expected_arch = args.next() orelse return error.MissingArch;
    const maru_version = args.next() orelse return error.MissingVersion;
    if (args.next() != null) return error.TooManyArguments;

    const header = try std.Io.Dir.cwd().readFileAlloc(init.io, header_path, allocator, .limited(64 * 1024));
    defer allocator.free(header);
    const versions = try parseVersions(header);
    const framework = try std.Io.Dir.cwd().openFile(init.io, framework_path, .{});
    defer framework.close(init.io);
    var head: [8]u8 = undefined;
    if (try framework.readPositionalAll(init.io, &head, 0) != head.len) return error.NotMachO;
    const arch = try machoArch(head);
    if (!std.mem.eql(u8, arch, expected_arch)) {
        std.debug.print("web-sidecar-manifest: CEF SDK 의 프레임워크는 {s} 인데 빌드 대상은 {s} 다\n", .{ arch, expected_arch });
        return error.ArchMismatch;
    }
    var buf: [1024]u8 = undefined;
    const json = try render(&buf, versions, arch, maru_version);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = json });
}

const Versions = struct {
    cef: []const u8,
    chromium: [4]u32,
};

fn parseVersions(header: []const u8) !Versions {
    return .{
        .cef = try stringDefine(header, "CEF_VERSION"),
        .chromium = .{
            try numberDefine(header, "CHROME_VERSION_MAJOR"),
            try numberDefine(header, "CHROME_VERSION_MINOR"),
            try numberDefine(header, "CHROME_VERSION_BUILD"),
            try numberDefine(header, "CHROME_VERSION_PATCH"),
        },
    };
}

/// `#define <name> <값>` 의 값(앞뒤 공백을 뗀다). 없으면 오류.
fn defineValue(header: []const u8, name: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "#define ")) continue;
        const rest = std.mem.trimStart(u8, line["#define ".len..], " \t");
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) continue;
        return std.mem.trim(u8, after, " \t");
    }
    return error.MissingDefine;
}

fn stringDefine(header: []const u8, name: []const u8) ![]const u8 {
    const value = try defineValue(header, name);
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.BadDefine;
    const text = value[1 .. value.len - 1];
    // JSON 에 그대로 넣는다 — 따옴표·역슬래시·제어 문자가 없는 버전 글만 받는다.
    for (text) |ch| if (ch < 0x20 or ch == '"' or ch == '\\') return error.BadDefine;
    return text;
}

fn numberDefine(header: []const u8, name: []const u8) !u32 {
    return std.fmt.parseInt(u32, try defineValue(header, name), 10) catch error.BadDefine;
}

/// 64-bit Mach-O 머리(magic·cputype, 리틀 엔디언)의 arch. universal(fat)·32-bit·다른 CPU 는 받지 않는다.
fn machoArch(head: [8]u8) ![]const u8 {
    if (std.mem.readInt(u32, head[0..4], .little) != 0xfeedfacf) return error.NotMachO;
    return switch (std.mem.readInt(u32, head[4..8], .little)) {
        0x0100000c => "arm64",
        0x01000007 => "x86_64",
        else => error.UnknownArch,
    };
}

fn render(buf: []u8, versions: Versions, arch: []const u8, maru_version: []const u8) ![]const u8 {
    for ([_][]const u8{ arch, maru_version }) |text| {
        for (text) |ch| if (ch < 0x20 or ch == '"' or ch == '\\') return error.BadArgument;
    }
    const c = versions.chromium;
    return std.fmt.bufPrint(buf,
        \\{{
        \\  "format": 1,
        \\  "wire_version": {d},
        \\  "maru_version": "{s}",
        \\  "cef_version": "{s}",
        \\  "chromium_version": "{d}.{d}.{d}.{d}",
        \\  "arch": "{s}"
        \\}}
        \\
    , .{ protocol.wire.version, maru_version, versions.cef, c[0], c[1], c[2], c[3], arch });
}

test "versions come from the CEF header and the manifest carries the control-channel version" {
    // `CEF_VERSION_MAJOR` 를 앞에 둔다 — 이름 뒤 공백을 안 보면 그 줄을 `CEF_VERSION` 으로 읽는다.
    const header =
        \\#define CEF_VERSION_MAJOR 154
        \\#define CEF_VERSION "154.0.23+g062ebe4+chromium-154.0.8037.17"
        \\#define CHROME_VERSION_MAJOR 154
        \\#define CHROME_VERSION_MINOR 0
        \\#define CHROME_VERSION_BUILD 8037
        \\#define CHROME_VERSION_PATCH 17
        \\
    ;
    const versions = try parseVersions(header);
    // `CEF_VERSION_MAJOR` 가 `CEF_VERSION` 으로 읽히지 않는다(이름 뒤 공백까지 본다).
    try std.testing.expectEqualStrings("154.0.23+g062ebe4+chromium-154.0.8037.17", versions.cef);
    var buf: [1024]u8 = undefined;
    const json = try render(&buf, versions, "arm64", "0.0.0");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, protocol.wire.version), parsed.value.object.get("wire_version").?.integer);
    try std.testing.expectEqualStrings("154.0.8037.17", parsed.value.object.get("chromium_version").?.string);
    try std.testing.expectEqualStrings("arm64", parsed.value.object.get("arch").?.string);
    // Mach-O 머리에서 arch — universal(fat)·다른 CPU 는 거절.
    try std.testing.expectEqualStrings("arm64", try machoArch(.{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01 }));
    try std.testing.expectEqualStrings("x86_64", try machoArch(.{ 0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01 }));
    try std.testing.expectError(error.NotMachO, machoArch(.{ 0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2 }));
    try std.testing.expectError(error.UnknownArch, machoArch(.{ 0xcf, 0xfa, 0xed, 0xfe, 0x12, 0x00, 0x00, 0x00 }));
    // 없는 정의·따옴표가 깨진 값은 거절한다.
    try std.testing.expectError(error.MissingDefine, parseVersions("#define CEF_VERSION \"1\"\n"));
    try std.testing.expectError(error.BadDefine, stringDefine("#define CEF_VERSION \"a\\\"b\"\n", "CEF_VERSION"));
}
