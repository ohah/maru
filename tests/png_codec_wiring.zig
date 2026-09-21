//! PNG 코덱(wuffs) C 배선이 **maru 루트 모듈을 세우는 모든 자리**에 붙어 있는지 센다.
//!
//! `src/terminal/png.zig` 는 C 함수를 부른다. 그 C 를 안 매단 타깃이 하나라도 있으면 그 빌드는
//! 「undefined symbol」로 죽는다 — 그리고 그 자리는 대개 **wasm·mobile·cross** 처럼 CI 에서 제일
//! 늦게 도는 이름이라, 발견이 가장 비싼 순간에 온다(`build.zig` 의 tree-sitter 주석이 같은 사고를
//! 적어 두고 있다: "wasm·mobile 빌드가 같은 root 를 쓰므로 거기 C 를 매달면 그 둘이 깨진다").
//!
//! 그래서 **자리 수를 센다**: 같은 그래프를 독립 루트로 세우는 `src/maru.zig`,
//! `src/cross_target_surface.zig`, `src/app.zig`가 나오는 만큼 `attachPngCodec(b, ...)`도
//! 나와야 한다. 새 타깃을 더하면서 배선을 잊으면 여기서 먼저 걸린다.
const std = @import("std");
/// **`build.zig` 하나가 아니라 빌드 소스 전체**를 읽는다 — 등록이 `build/` 아래로 갈렸고,
/// 그 정의는 `support/build_source.zig` 가 소유한다(이름으로 열면 절반만 보인다).
const build_source = @import("support/build_source.zig");

fn readBuildZig(allocator: std.mem.Allocator) ![]u8 {
    return build_source.read(allocator);
}

/// 겹치지 않게 세되 **주석 줄은 뺀다**. 설명문에 적힌 한 줄이 판정을 뒤집으면 안 된다
/// (`perf_gate_mode_boundary.zig` 가 같은 사고를 겪었다).
fn countOutsideComments(text: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, needle)) |at| {
            total += 1;
            from = at + needle.len;
        }
    }
    return total;
}

test "PNG 코덱 배선: maru 루트 모듈 자리마다 attachPngCodec 이 있다" {
    const text = try readBuildZig(std.testing.allocator);
    defer std.testing.allocator.free(text);

    // **루트 파일 종류가 셋이다.** `cross_target_surface.zig`와 `app.zig`는 `maru.zig`가 아니지만
    // 같은 그래프를 자기 루트로 다시 세운다. app 루트를 세던 세 focused gate에서 이 inventory가
    // 빠져 실제로 `no module named 'png_codec'`가 났다.
    const roots = countOutsideComments(text, "b.path(\"src/maru.zig\")") +
        countOutsideComments(text, "b.path(\"src/cross_target_surface.zig\")") +
        countOutsideComments(text, "b.path(\"src/app.zig\")");
    const attaches = countOutsideComments(text, "attachPngCodec(b,");

    // **양성 대조**: 둘 다 실제로 있어야 한다. 0 == 0 으로 공허하게 통과하면 이름을 바꾼 날
    // 판정자가 아무것도 안 지키게 된다.
    try std.testing.expect(roots >= 10);
    try std.testing.expectEqual(roots, attaches);
}

test "PNG 코덱 배선: 셰임과 의존성이 제자리에 있다" {
    const text = try readBuildZig(std.testing.allocator);
    defer std.testing.allocator.free(text);

    // C 번역 단위·셰임 헤더 경로·상류 헤더 경로 셋이 함께 있어야 배선이 선다.
    try std.testing.expect(std.mem.indexOf(u8, text, "src/terminal/png_wuffs.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/terminal/wuffs_cshim") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b.lazyDependency(\"wuffs\"") != null);

    // **안 쓰는 가지를 끊는 두 플래그**. 떼면 wasm 배포물이 커진다(실측 `-O2`: object 410,480 → 1,096,368 B).
    // 크기는 판정자가 직접 못 재는 자리라 플래그 존재로 지킨다.
    try std.testing.expect(std.mem.indexOf(u8, text, "WUFFS_CONFIG__STATIC_FUNCTIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WUFFS_CONFIG__DST_PIXEL_FORMAT__ALLOW_RGBA_NONPREMUL") != null);

    // **재배포 의무**(third-party-licenses.md §번들 코드 라이브러리). wuffs 컴파일 산출물이 exe 에
    // 링크되므로 라이선스 전문을 번들에 넣어야 한다. 복사와 검사가 **둘 다** 있어야 한다 — 검사만
    // 남으면 번들이 소리 내어 죽고(그건 발견된다), **둘 다 사라지면 조용히 라이선스 없이 출하된다**.
    // 그 조용한 쪽을 여기서 막는다(폰트·tree-sitter 가 같은 이유로 각자 게이트를 갖는다).
    try std.testing.expect(std.mem.indexOf(u8, text, "Resources/Licenses/wuffs-LICENSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "for lic in tree-sitter-LICENSE wuffs-LICENSE ") != null);

    const zon = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig.zon", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".wuffs = .{") != null);
}
