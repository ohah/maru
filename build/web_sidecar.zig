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
    /// macOS CI 잡이 도는 `test-macos-only` — macOS 전용 시험은 여기에도 짝으로 붙인다(ubuntu `check` 는 못 만든다).
    macos_only_test_step: *std.Build.Step,
    /// macOS SDK 경로(build.zig 가 구한 것). host 는 `maru` 모듈을 안 받으므로 프레임워크 경로를 직접 붙인다.
    macos_sdk: ?[]const u8,
    /// maru 버전(`build.zig.zon`) — `maru-chromium` manifest 에 적는다.
    maru_version: []const u8,
};

/// ① 의 시험 수(inbox 2 + dispatch 8 + registry 2 + title_gate 2 + ring_receiver 8 + ring_producer 2 + input_map 2 + dialog_table 3 + 입구 파일의 `test {}` 블록 1). 시험을 더하거나 빼면 같이 고친다 —
/// 조용히 빠지는 것을 러너가 잡는다.
const pure_test_count = 30;

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
    // 링 시험(ring_receiver·ring_producer)은 실제 IOSurface 를 만든다.
    linkMacosFrameworks(b, ctx, pure_tests, &.{ "IOSurface", "CoreFoundation" });
    const run_pure_tests = b.addRunArtifact(pure_tests);
    run_pure_tests.addArg(b.fmt("--maru-expect-tests={d}", .{pure_test_count}));
    const pure_step = b.step("test-web-sidecar", "Run web OSR sidecar tests that need no CEF SDK");
    pure_step.dependOn(&run_pure_tests.step);
    // manifest 생성기는 빌드하는 기계에서 돈다(교차 빌드에서도) — 대상이 아니라 host 로 만든다.
    const host_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/session/web_sidecar/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("tools/web_sidecar_manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "web_sidecar_protocol", .module = host_protocol_mod }},
    });
    const manifest_tests = addProjectTest(b, .{ .root_module = manifest_mod });
    const run_manifest_tests = b.addRunArtifact(manifest_tests);
    run_manifest_tests.addArg("--maru-expect-tests=1");
    pure_step.dependOn(&run_manifest_tests.step);
    // kqueue·mach·IOSurface 를 쓰는 macOS 전용 시험이다 — 다른 대상의 기본 test 에는 걸지 않는다. macOS CI 잡은
    // `test-macos-only` 만 돌리므로 거기에도 짝으로 붙인다(한 줄 `if` 로 두었을 때 CI 어디에서도 안 돌았다 — W7a1 적대 검증 8 차).
    if (ctx.target.result.os.tag == .macos) {
        ctx.test_step.dependOn(&run_pure_tests.step);
        ctx.macos_only_test_step.dependOn(&run_pure_tests.step);
    }
    ctx.test_step.dependOn(&run_manifest_tests.step); // manifest 생성기는 순수 Zig — 어느 대상에서나 돈다

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
    sidecar_step.dependOn(copyFramework(b, sdk, dest));

    // W7a1: `maru-chromium` 설치물 — host·helper·프레임워크에 CEF·Chromium 라이선스와 manifest 를 더한다(판정자는 뺀다).
    // formula 는 이 디렉터리를 그대로 `libexec` 에 둔다(maru 는 `opt/maru-chromium/libexec/maru-web-host` 를 찾는다).
    // formula 는 기본 prefix 로 빌드해 `zig-out/maru-chromium/*` 를 `libexec` 로 옮기고 `-Doptimize=ReleaseFast` 를 준다
    // (`--prefix libexec` 면 `libexec/maru-chromium/` 이 되어 maru 가 못 찾는다 — W7a1 적대 검증).
    const dist_step = b.step("web-sidecar-dist", "Build the maru-chromium install tree into zig-out/maru-chromium (needs -Dcef-sdk; formulas add -Doptimize=ReleaseFast)");
    const dist: std.Build.InstallDir = .{ .custom = "maru-chromium" };
    // 옛 빌드가 남긴 파일(이름이 바뀐 것 등)이 설치물에 섞이지 않게 먼저 비운다 — 아래 설치는 모두 이 뒤에 온다.
    const clean_dist = b.addSystemCommand(&.{ "/bin/rm", "-rf" });
    clean_dist.addArg(b.getInstallPath(dist, ""));
    var dist_installs: [5]*std.Build.Step = undefined;
    for ([_]*std.Build.Step.Compile{ host, helper }, 0..) |artifact, i| {
        dist_installs[i] = &b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = dist } }).step;
    }
    dist_installs[2] = copyFramework(b, sdk, dist);
    // CEF 는 BSD(LICENSE.txt), Chromium 과 그 제3자 라이선스 전부는 CREDITS.html 이다 — 둘 다 재배포 의무다.
    dist_installs[3] = &b.addInstallFileWithDir(.{ .cwd_relative = b.fmt("{s}/LICENSE.txt", .{sdk}) }, dist, "licenses/CEF-LICENSE.txt").step;
    dist_installs[4] = &b.addInstallFileWithDir(.{ .cwd_relative = b.fmt("{s}/CREDITS.html", .{sdk}) }, dist, "licenses/CHROMIUM-CREDITS.html").step;
    const manifest_exe = b.addExecutable(.{ .name = "web-sidecar-manifest", .root_module = manifest_mod });
    const make_manifest = b.addRunArtifact(manifest_exe);
    const manifest_file = make_manifest.addOutputFileArg("maru-chromium.json");
    make_manifest.addFileArg(.{ .cwd_relative = b.fmt("{s}/include/cef_version.h", .{sdk}) });
    make_manifest.addFileArg(.{ .cwd_relative = b.fmt("{s}/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{sdk}) });
    make_manifest.addArg(switch (ctx.target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @panic("maru-chromium 은 arm64·x86_64 macOS 만 만든다"),
    });
    make_manifest.addArg(ctx.maru_version);
    const install_manifest = &b.addInstallFileWithDir(manifest_file, dist, "maru-chromium.json").step;
    // W7b: 다 깐 뒤 Mach-O 를 Homebrew 가 고칠 것이 없는 모양(dylib·프레임워크 ID 를 `@rpath/…`)으로 맞추고 재서명·확인한다
    // — Homebrew 의 소스 설치 relocation 이 CEF dylib 에서 중간에 실패해 프레임워크 서명을 깨뜨렸다(9 차 적대 검증 실측).
    const fix_macho = b.addSystemCommand(&.{ "/bin/sh", "tools/web-sidecar-dist-macho.sh" });
    fix_macho.setCwd(b.path("."));
    fix_macho.addArg(b.getInstallPath(dist, ""));
    fix_macho.has_side_effects = true;
    for (dist_installs ++ [_]*std.Build.Step{install_manifest}) |install| {
        install.dependOn(&clean_dist.step);
        fix_macho.step.dependOn(install);
    }
    dist_step.dependOn(&fix_macho.step);
}

/// 프레임워크는 실행 파일 옆에 **실제 파일**로 둔다 — 샌드박스는 링크를 실제 경로로 풀어 그 밖을 못 읽는다(C1 실측).
/// APFS 복제(cp -c)라 323MB 라도 즉시 끝난다.
fn copyFramework(b: *std.Build, sdk: []const u8, dest: std.Build.InstallDir) *std.Build.Step {
    const framework_name = "Chromium Embedded Framework.framework";
    const copy_framework = b.addSystemCommand(&.{ "/bin/sh", "-c", "rm -rf \"$1\" && mkdir -p \"$(dirname \"$1\")\" && cp -Rc \"$2\" \"$1\"", "sh" });
    copy_framework.addArg(b.getInstallPath(dest, framework_name));
    copy_framework.addArg(b.fmt("{s}/Release/{s}", .{ sdk, framework_name }));
    return &copy_framework.step;
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
