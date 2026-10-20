//! `build.zig` 와 `build/` 아래 게이트 등록 파일들이 **함께 쓰는** 헬퍼.
//!
//! 이 파일이 따로 있는 이유는 하나다 — `build.zig` 를 import 하면 순환이 된다.
//! 그래서 두 쪽이 다 필요한 것만 여기로 내리고, 각 파일은 머리에서 지역 별칭으로
//! 받아 **본문을 한 글자도 바꾸지 않는다**(그 무변경이 분해의 안전 근거다).
const std = @import("std");
const Translator = @import("translate_c").Translator;
/// 러너(`tools/simple_test_runner.zig`)가 «무엇을 돌릴지» 고르는 env 이름 — 러너와 이 파일이 같은 목록을 본다.
const test_selection_env = @import("../tools/test_runner_selection_env.zig");

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

/// **설정(configure) 결과를 env 와 상관없이 재사용하지 못하게 한다.** `build()` 맨 앞에서 한 번 부른다.
///
/// Zig 0.17 은 `build.zig` 를 따로 도는 configurer 가 실행해 그래프를 파일로 직렬화하고, 그 파일을 **캐시**한다.
/// 캐시 키는 `-D` 인자·대상·`build.zig` 소스뿐이고 **env 는 없다**(`lib/compiler/Maker.zig` `configure`). 그런데
/// `Run.setEnvironmentVariable` 은 그 순간 configurer 의 env **전체**를 복사해(`getEnvMapInternal`) 직렬화 파일에
/// 박고, make 단계는 그 사본**만** 쓴다(`Maker/Step/Run.zig` — 사본이 있으면 지금 셸의 env 를 안 본다).
/// 그래서 env 를 하나라도 심는 run 스텝(이 저장소에 150 곳이 넘는다)은 **처음 설정한 셸의 env 를 영영 되풀이**했다:
/// `MARU_TEST_KEEP_ONLY_PREFIX=… zig build test-macos-app-host-abi` 가 6,816 개를 다 돌았고(2026-10-21 리뷰 보고),
/// 거꾸로 그 변수를 건 채 처음 설정하면 이후 **걸지 않은** 실행이 좁혀진 채로 돈다(최소 재현: 두 경우 다 확인).
/// Zig 0.16 은 `build.zig` 를 매 실행 같은 프로세스에서 돌려 사본이 늘 지금의 env 였다 — 이 함수가 그 의미를 되돌린다.
///
/// 대가는 매 `zig build` 마다 configurer 를 다시 도는 것이다(실측 약 0.3 초 — configurer 컴파일은 그대로 캐시된다).
/// **왜 스텝마다 고치지 않나**: 사본을 안 만들려면 `setEnvironmentVariable` 150 곳을 전부 `/usr/bin/env K=V` 로 바꿔야
/// 하고, 앞으로 한 곳이라도 원래 API 를 쓰면 같은 사고가 조용히 돌아온다. 원인이 «설정 캐시가 env 를 모른다» 이니
/// 그 캐시를 끄는 것이 한 자리에서 닫힌다.
pub fn configureFromCallerEnvironment(b: *std.Build) void {
    b.graph.poisonCache();
}

/// **좁힌 실행과 전체 실행이 서로의 캐시를 쓰지 않게 한다.** `build()` 맨 끝에서(모든 스텝이 생긴 뒤) 부른다.
///
/// 결과를 캐시하는 run 스텝(`expectExitCode`·출력 캡처 — 예: `test-session-host`)은 env 사본이 없으면 지금 셸의 env 를
/// 물려주지만 **캐시 키에는 넣지 않는다**(`Maker/Step/Run.zig` 는 직렬화된 env 사본만 해시한다). 그래서 좁히는
/// 변수를 걸어도 앞선 전체 실행의 «통과»가 그대로 재사용되고, 거꾸로 좁힌 실행의 «통과»가 다음 전체 실행 자리에
/// 남는다 — 전체가 한 번도 안 돌았는데 초록이 되는 쪽이 더 나쁘다.
/// 좁히는 변수가 걸린 실행에서만 테스트 바이너리를 도는 run 스텝을 «부작용 있음»으로 바꾼다: 그 실행은 늘 돌고
/// 캐시에 결과를 **쓰지도 않는다**(`finalizeManifestAndWatch` 를 건너뛴다). 변수가 없으면 아무것도 바꾸지 않아
/// 평소 캐시는 그대로다.
///
/// ⚠️ 테스트 바이너리를 돌면서 **출력 파일·캡처를 만드는** run 스텝은 지금 없다(2026-10-21 설정 비교: 바뀌는
/// 1,684 스텝 중 출력 인자 0). 생기면 좁힌 실행이 같은 출력 자리를 덮을 수 있으니 그때 다시 본다.
pub fn uncacheTestRunsWhenNarrowed(b: *std.Build) void {
    const narrowed = for (test_selection_env.names) |name| {
        const value = b.graph.environ_map.get(name) orelse continue;
        // 러너는 빈 값을 «안 걸림»으로 본다(`envPrefix`) — 같은 규칙.
        if (value.len != 0) break true;
    } else false;
    if (!narrowed) return;

    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var stack: std.ArrayList(*std.Build.Step) = .empty;
    for (b.top_level_steps.values()) |top| stack.append(b.allocator, &top.step) catch @panic("OOM");
    while (stack.pop()) |step| {
        const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
        if (entry.found_existing) continue;
        stack.appendSlice(b.allocator, step.dependencies.items) catch @panic("OOM");
        const run = step.cast(std.Build.Step.Run) orelse continue;
        for (run.argv.items) |arg| switch (arg) {
            .artifact => |decorated| if (decorated.artifact.kind.isTest()) {
                run.has_side_effects = true;
                break;
            },
            else => {},
        };
    }
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
        // Foundation.tbd 가 부르는 `/usr/lib/libobjc.A.dylib` — build.zig 의 SDK 주석 (3).
        compile.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    }
    compile.root_module.addIncludePath(b.path("src/platform/macos"));
    // `-isysroot` 는 build.zig 의 `objc_macos_flags` 주석과 같은 이유다(Zig 0.17 에는 `b.sysroot` 가 없다).
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/platform/macos/session_host_notification_adapter.m"),
        .flags = if (macos_sdk) |sdk|
            b.allocator.dupe([]const u8, &.{ "-fobjc-arc", "-fno-sanitize=undefined", "-isysroot", sdk, "-iframeworkwithsysroot", "/System/Library/Frameworks", "-iwithsysroot", "/usr/include" }) catch @panic("OOM")
        else
            &.{ "-fobjc-arc", "-fno-sanitize=undefined", "-iframeworkwithsysroot", "/System/Library/Frameworks", "-iwithsysroot", "/usr/include" },
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
