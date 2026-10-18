//! `build.zig` 와 `build/` 아래 게이트 등록 파일들이 **함께 쓰는** 헬퍼.
//!
//! 이 파일이 따로 있는 이유는 하나다 — `build.zig` 를 import 하면 순환이 된다.
//! 그래서 두 쪽이 다 필요한 것만 여기로 내리고, 각 파일은 머리에서 지역 별칭으로
//! 받아 **본문을 한 글자도 바꾸지 않는다**(그 무변경이 분해의 안전 근거다).
const std = @import("std");
const Translator = @import("translate_c").Translator;

var array_repeat_module: ?*std.Build.Module = null;
var type_info_fields_module: ?*std.Build.Module = null;

pub fn setArrayRepeatModule(module: *std.Build.Module) void {
    array_repeat_module = module;
}

pub fn setTypeInfoFieldsModule(module: *std.Build.Module) void {
    type_info_fields_module = module;
}

fn collectModules(
    b: *std.Build,
    module: *std.Build.Module,
    repeat_module: ?*std.Build.Module,
    type_fields_module: ?*std.Build.Module,
    modules: *std.array_hash_map.Auto(*std.Build.Module, void),
) void {
    if (module == repeat_module or module == type_fields_module or modules.contains(module)) return;
    modules.putNoClobber(b.graph.arena, module, {}) catch @panic("OOM");
    for (module.import_table.values()) |dependency| {
        collectModules(b, dependency, repeat_module, type_fields_module, modules);
    }
}

/// Makes the Zig 0.17 compatibility helper visible from every module in one compile graph.
/// Multiple source modules in a single graph must share one imported module for a source file;
/// relative imports of the helper would otherwise claim the same file from several modules.
pub fn attachArrayRepeatImports(b: *std.Build, root: *std.Build.Module) void {
    const repeat_module = array_repeat_module;
    const type_fields_module = type_info_fields_module;
    if (repeat_module == null and type_fields_module == null) return;
    var modules: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    collectModules(b, root, repeat_module, type_fields_module, &modules);
    for (modules.keys()) |module| {
        if (repeat_module) |repeat| module.addImport("array_repeat", repeat);
        if (type_fields_module) |type_fields| module.addImport("type_info_fields", type_fields);
    }
}

/// 0.17 exposes the package root as `Build.root`, a cache path. Build steps that
/// still need a concrete pathname (for example an environment variable consumed
/// by a host process) resolve the root here instead of relying on `pathFromRoot`.
pub fn rootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
}

/// Resolves an install destination as a LazyPath so Run steps can consume it
/// without the removed Build.getInstallPath API.
pub fn installPath(b: *std.Build, dir: std.Build.InstallDir, sub_path: []const u8) std.Build.LazyPath {
    const relative_dir = switch (dir) {
        .prefix => "",
        .bin => "bin",
        .lib => "lib",
        .header => "include",
        .custom => |path| path,
    };
    const relative_path = if (relative_dir.len == 0)
        sub_path
    else if (sub_path.len == 0)
        relative_dir
    else
        b.fmt("{s}/{s}", .{ relative_dir, sub_path });
    return b.graph.path(.install_prefix, relative_path);
}

/// Runs a binary with another build artifact exposed as an environment value.
/// Zig 0.17 Run.setEnvironmentVariable accepts strings, while artifact paths
/// need to remain lazy so cache changes and cross-build output paths are tracked.
pub fn addRunWithArtifactEnv(
    b: *std.Build,
    key: []const u8,
    value: *std.Build.Step.Compile,
    executable: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"/usr/bin/env"});
    run.addArtifactArg2(value, .{ .prefix = b.fmt("{s}=", .{key}), .make_absolute = true });
    run.addArtifactArg2(executable, .{ .make_absolute = true });
    return run;
}

pub fn addProjectTest(b: *std.Build, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var configured = options;
    attachArrayRepeatImports(b, configured.root_module);
    configured.test_runner = .{
        .path = b.path("tools/simple_test_runner.zig"),
        .mode = .simple,
    };
    return b.addTest(configured);
}

pub fn linkSessionHostNotificationAdapter(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    macos_sdk: ?[]const u8,
) void {
    attachSessionHostNotificationCImport(b, compile.root_module);
    if (macos_sdk) |sdk| {
        compile.root_module.addSystemFrameworkPath(.{
            .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}),
        });
    }
    compile.root_module.addIncludePath(b.path("src/platform/macos"));
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/platform/macos/session_host_notification_adapter.m"),
        .flags = &.{
            "-fobjc-arc",
            "-fno-sanitize=undefined",
            "-iframeworkwithsysroot",
            "/System/Library/Frameworks",
            "-iwithsysroot",
            "/usr/include",
        },
    });
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/platform/macos/session_host_notification_route.c"),
        .flags = &.{},
    });
    compile.root_module.linkFramework("Foundation", .{});
    compile.root_module.linkFramework("UserNotifications", .{});
}

/// Provides the former `@cImport` header bindings through Zig 0.17's build-time translator.
/// The module is target-specific because translated C integer and ABI types must match each
/// product/cross-check executable that imports the macOS adapter.
pub fn attachSessionHostNotificationCImport(b: *std.Build, root: *std.Build.Module) void {
    const target = root.resolved_target orelse @panic("notification adapter root module has no resolved target");
    const optimize = root.optimize orelse .debug;
    const translator = Translator.init(b.dependency("translate_c", .{}), .{
        .name = b.fmt("session-host-notification-{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(optimize),
        }),
        .c_source_file = b.path("src/platform/macos/session_host_notification_adapter.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translator.addIncludePath(b.path("src/platform/macos"));
    root.addImport("session_host_notification_c", translator.mod);
}

fn attachTranslatedHeaderImport(
    b: *std.Build,
    root: *std.Build.Module,
    import_name: []const u8,
    module_name: []const u8,
    wrapper_name: []const u8,
    wrapper_source: []const u8,
    include_dir: ?std.Build.LazyPath,
) void {
    const target = root.resolved_target orelse @panic("translated C import root module has no resolved target");
    const optimize = root.optimize orelse .debug;
    const wrapper = b.addWriteFiles().add(wrapper_name, wrapper_source);
    const translator = Translator.init(b.dependency("translate_c", .{}), .{
        .name = b.fmt("{s}-{s}-{s}-{s}", .{
            module_name,
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(optimize),
        }),
        .c_source_file = wrapper,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (include_dir) |dir| translator.addIncludePath(dir);
    root.addImport(import_name, translator.mod);
}

pub fn attachMobileHostAbiCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "mobile_host_abi_c",
        "maru-mobile-host-abi",
        "maru_mobile_host_abi_translate.h",
        "#include <mobile_host_abi.h>\n",
        b.path("src/platform/mobile"),
    );
}

pub fn attachNotificationRouteCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "session_host_notification_route_c",
        "maru-session-host-notification-route",
        "maru_session_host_notification_route_translate.h",
        "#include <session_host_notification_route.h>\n",
        b.path("src/platform/macos"),
    );
}

pub fn attachReleaseAdapterDmgCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "release_adapter_dmg_c",
        "maru-release-adapter-dmg",
        "maru_release_adapter_dmg_translate.h",
        "#include <sys/mount.h>\n",
        null,
    );
}

pub fn attachDarwinPerfCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "darwin_perf_c",
        "maru-darwin-perf",
        "maru_darwin_perf_translate.h",
        "#include <libproc.h>\n#include <sys/resource.h>\n#include <sys/proc_info.h>\n",
        null,
    );
}

pub fn attachAppHostAbiCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "app_host_abi_c",
        "maru-app-host-abi",
        "maru_app_host_abi_translate.h",
        "#include <app_host_abi.h>\n",
        b.path("src/platform/macos"),
    );
}

pub fn attachSshPumpCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "ssh_pump_c",
        "maru-ssh-pump",
        "maru_ssh_pump_translate.h",
        "#include <ssh_pump.h>\n",
        b.path("src/platform/mobile_host"),
    );
}

pub fn attachLibvtermCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "libvterm_c",
        "maru-libvterm-oracle",
        "maru_libvterm_oracle_translate.h",
        "#include <vterm.h>\n#include <vterm_shim.h>\n",
        b.path("tests/oracle"),
    );
}

pub fn attachGhosttyOracleCImport(b: *std.Build, root: *std.Build.Module) void {
    attachTranslatedHeaderImport(
        b,
        root,
        "ghostty_oracle_c",
        "maru-ghostty-oracle",
        "maru_ghostty_oracle_translate.h",
        "#include <ghostty_shim.h>\n",
        b.path("tests/oracle"),
    );
    root.addIncludePath(b.path("references/ghostty/include"));
}

/// `src/maru.zig` 루트 모듈에 PNG 코덱(wuffs)을 매단다.
///
/// **maru 루트 모듈을 세우는 자리는 전부 이걸 불러야 한다.** PNG 디코드는 코어 기능이고
/// (kitty `f=100` · `window.background-image`), 한 자리가 빠지면 그 타깃에서 링크가 깨진다.
/// `tests/png_codec_wiring.zig` 가 `build.zig` 안의 자리 수를 세어 누락을 잡는다.
///
/// **C 를 `maru` 모듈에 직접 안 매단다** — 같은 모듈에 붙는 ObjC 어댑터들이 wuffs 셰임 헤더를
/// 보게 되기 때문이다(`src/terminal/wuffs_cshim/README.md`). 전용 모듈로 갈라 include 경로가
/// `png_wuffs.c` 하나에만 닿게 한다.
pub fn attachPngCodec(b: *std.Build, maru: *std.Build.Module) void {
    attachArrayRepeatImports(b, maru);
    const codec = b.createModule(.{
        .root_source_file = b.path("src/terminal/png_codec.zig"),
        .target = maru.resolved_target,
        .optimize = maru.optimize,
        .pic = maru.pic,
    });
    if (b.lazyDependency("wuffs", .{})) |dep| {
        // 셰임이 시스템 헤더보다 **먼저** 검색돼야 한다 — wasm32-freestanding 에는 libc 가 없고,
        // 타깃마다 다른 헤더를 보면 wasm 에서만 터지는 결함이 생긴다(그 빌드가 제일 늦게 돈다).
        codec.addIncludePath(b.path("src/terminal/wuffs_cshim"));
        codec.addIncludePath(dep.path("release/c"));
        codec.addCSourceFile(.{
            .file = b.path("src/terminal/png_wuffs.c"),
            .flags = &.{
                "-std=c11",
                // 제3자 C 를 우리 UBSan 정책으로 재단하지 않는다(tree-sitter 배선과 같은 결).
                "-fno-sanitize=undefined",
                // **wuffs 전체가 한 파일이다.** 아래 둘이 안 쓰는 가지를 컴파일 단계에서 끊는다
                // (실측 `-O2`: object 1,096,368 → 410,480 B).
                //  · STATIC_FUNCTIONS: 안 쓰는 코덱·헬퍼가 내부 링크가 돼 죽은 코드로 걷힌다.
                //  · DST_PIXEL_FORMAT 허용 목록: 우리는 RGBA_NONPREMUL 하나만 요청한다.
                "-DWUFFS_CONFIG__STATIC_FUNCTIONS",
                "-DWUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST",
                "-DWUFFS_CONFIG__DST_PIXEL_FORMAT__ALLOW_RGBA_NONPREMUL",
            },
        });
    }
    maru.addImport("png_codec", codec);
}
