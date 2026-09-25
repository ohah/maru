//! sidecar 의 `cef_settings_t`(W1b). 경로는 모두 절대여야 한다 — 상대면 CEF 가 조용히 기본값으로 간다.

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const layout = @import("layout.zig");

pub const Paths = struct {
    /// 실행 파일 디렉터리 — helper·프레임워크가 함께 산다(C1).
    install_dir: []const u8,
    /// 프로필(쿠키·저장소). maru 가 번들 ID 별로 준다 — 비우면 CEF 기본 경로를 다른 CEF 앱과 나눠 singleton 에 걸린다.
    profile_dir: []const u8,
};

pub const Error = error{PathTooLong};

/// 채운 문자열은 프로세스가 끝날 때까지 쥔다(CEF 가 초기화 중에만 읽지만 비우는 순서를 두지 않는다).
pub fn build(api: *const library.Api, paths: Paths) Error!c.cef_settings_t {
    var settings = object.zeroed(c.cef_settings_t);
    settings.no_sandbox = 0;
    settings.windowless_rendering_enabled = 1;
    // 우리 스위치(app.zig)만 쓰고, 명령줄로 들어온 Chromium 스위치는 받지 않는다.
    settings.command_line_args_disabled = 1;
    settings.persist_session_cookies = 1;
    settings.log_severity = c.LOGSEVERITY_WARNING;

    var buf: layout.PathBuf = undefined;
    library.setString(api, &settings.browser_subprocess_path, try layout.join(&buf, paths.install_dir, layout.helper_name));
    library.setString(api, &settings.framework_dir_path, try layout.join(&buf, paths.install_dir, layout.framework_dir_name));
    // 번들이 없으면 렌더러가 resources.pak·icudtl.dat·locales 를 못 찾아 조용히 안 뜬다(PoC 실측).
    const resources = try layout.join(&buf, paths.install_dir, layout.framework_dir_name ++ "/Resources");
    library.setString(api, &settings.resources_dir_path, resources);
    library.setString(api, &settings.locales_dir_path, resources);
    library.setString(api, &settings.root_cache_path, paths.profile_dir);
    library.setString(api, &settings.cache_path, paths.profile_dir);
    return settings;
}
