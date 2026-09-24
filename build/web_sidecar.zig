//! 웹 OSR sidecar 빌드(W1b, docs/plans/web-osr-backend.md) — 두 갈래다.
//!
//! ① CEF 를 모르는 부분(명령 상자·명령 처리)의 시험은 **기본 `test`** 에 건다. SDK 없이 어느 호스트에서나 돈다.
//! ② `maru-web-host`·`maru-web-helper`·판정자는 `-Dcef-sdk=<경로>` 가 있을 때만 `web-sidecar` 스텝이 만든다.
//!    CEF 는 프로젝트 규칙 「의존성」 예외 ③ 이라 기본 빌드·`mise run check` 는 SDK 없이 돈다. SDK 는
//!    `tools/cef-sdk-fetch.sh` 가 해시를 확인해 캐시에 푼다(`zig fetch` 는 .tar.bz2 를 못 푼다 — 실측).

const std = @import("std");
const support = @import("support.zig");
const addProjectTest = support.addProjectTest;

pub const Context = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    /// macOS SDK 경로(build.zig 가 구한 것). host 는 `maru` 모듈을 안 받으므로 프레임워크 경로를 직접 붙인다.
    macos_sdk: ?[]const u8,
};

/// ① 의 시험 수(inbox 2 + dispatch 8 + registry 2 + title_gate 2 + ring_receiver 6 + 입구 파일의 `test {}` 블록 1). 시험을 더하거나 빼면 같이 고친다 —
/// 조용히 빠지는 것을 러너가 잡는다.
const pure_test_count = 21;

pub fn register(b: *std.Build, ctx: Context) void {
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/session/web_sidecar/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });

    const pure_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/web_sidecar/pure_tests.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "web_sidecar_protocol", .module = protocol_mod }},
        }),
    });
    const run_pure_tests = b.addRunArtifact(pure_tests);
    run_pure_tests.addArg(b.fmt("--maru-expect-tests={d}", .{pure_test_count}));
    const pure_step = b.step("test-web-sidecar", "Run web OSR sidecar tests that need no CEF SDK");
    pure_step.dependOn(&run_pure_tests.step);
    ctx.test_step.dependOn(&run_pure_tests.step);

    const sidecar_step = b.step("web-sidecar", "Build maru-web-host/helper and the W1b judge into zig-out/web-sidecar (needs -Dcef-sdk)");
    const sdk = b.option([]const u8, "cef-sdk", "CEF SDK directory for the web OSR sidecar (tools/cef-sdk-fetch.sh prints it)") orelse {
        sidecar_step.dependOn(&b.addFail("web-sidecar 는 -Dcef-sdk=<경로> 가 필요하다 — `mise run web-sidecar-sdk` 가 받아 경로를 알려 준다").step);
        return;
    };
    if (ctx.target.result.os.tag != .macos) {
        sidecar_step.dependOn(&b.addFail("web-sidecar 는 macOS 대상에서만 만든다").step);
        return;
    }

    const host = sidecarExe(b, ctx, sdk, protocol_mod, "maru-web-host", "src/platform/macos/web_sidecar/host_main.zig");
    // 픽셀 링(W2) — IOSurface 세 장을 만들고 mach 로 넘긴다. helper 는 샌드박스 전 적재를 줄이려 붙이지 않는다.
    linkMacosFrameworks(b, ctx, host, &.{ "IOSurface", "CoreFoundation" });
    const helper = sidecarExe(b, ctx, sdk, protocol_mod, "maru-web-helper", "src/platform/macos/web_sidecar/helper_main.zig");
    const judge = b.addExecutable(.{
        .name = "maru-web-judge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/web_sidecar_judge/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "web_sidecar_protocol", .module = protocol_mod }},
        }),
    });
    // 판정자는 host 의 창 수(CGWindowList)를 세고, maru 역할로 픽셀 링을 받는다(IOSurface).
    linkMacosFrameworks(b, ctx, judge, &.{ "CoreGraphics", "CoreFoundation", "IOSurface" });
    judge.root_module.addImport("web_sidecar_ring", b.createModule(.{
        .root_source_file = b.path("src/platform/macos/web_sidecar/ring.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "web_sidecar_protocol", .module = protocol_mod }},
    }));

    const dest: std.Build.InstallDir = .{ .custom = "web-sidecar" };
    for ([_]*std.Build.Step.Compile{ host, helper, judge }) |artifact| {
        sidecar_step.dependOn(&b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = dest } }).step);
    }
    // 프레임워크는 실행 파일 옆에 **실제 파일**로 둔다 — 샌드박스는 링크를 실제 경로로 풀어 그 밖을 못 읽는다(C1 실측).
    // APFS 복제(cp -c)라 323MB 라도 즉시 끝난다.
    const framework_name = "Chromium Embedded Framework.framework";
    const copy_framework = b.addSystemCommand(&.{ "/bin/sh", "-c", "rm -rf \"$1\" && mkdir -p \"$(dirname \"$1\")\" && cp -Rc \"$2\" \"$1\"", "sh" });
    copy_framework.addArg(b.getInstallPath(dest, framework_name));
    copy_framework.addArg(b.fmt("{s}/Release/{s}", .{ sdk, framework_name }));
    sidecar_step.dependOn(&copy_framework.step);
}

fn sidecarExe(
    b: *std.Build,
    ctx: Context,
    sdk: []const u8,
    protocol_mod: *std.Build.Module,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "web_sidecar_protocol", .module = protocol_mod }},
        }),
    });
    // 헤더만 쓴다 — 함수는 실행 중에 dlopen 한 프레임워크에서 찾으므로 프레임워크를 링크하지 않는다.
    exe.root_module.addIncludePath(.{ .cwd_relative = sdk });
    exe.root_module.addIncludePath(b.path("src/platform/macos/web_sidecar/shim"));
    return exe;
}

fn linkMacosFrameworks(b: *std.Build, ctx: Context, artifact: *std.Build.Step.Compile, names: []const []const u8) void {
    if (ctx.macos_sdk) |macos_sdk| artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{macos_sdk}) });
    for (names) |name| artifact.root_module.linkFramework(name, .{});
}
