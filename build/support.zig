//! `build.zig` 와 `build/` 아래 게이트 등록 파일들이 **함께 쓰는** 헬퍼.
//!
//! 이 파일이 따로 있는 이유는 하나다 — `build.zig` 를 import 하면 순환이 된다.
//! 그래서 두 쪽이 다 필요한 것만 여기로 내리고, 각 파일은 머리에서 지역 별칭으로
//! 받아 **본문을 한 글자도 바꾸지 않는다**(그 무변경이 분해의 안전 근거다).
const std = @import("std");

pub fn addProjectTest(b: *std.Build, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var configured = options;
    configured.test_runner = .{
        .path = b.path("tools/simple_test_runner.zig"),
        .mode = .simple,
    };
    return b.addTest(configured);
}

pub fn linkSessionHostNotificationAdapter(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (b.sysroot) |sdk| {
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
