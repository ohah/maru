//! 설치 배치(W1b, docs/plans/web-osr-backend.md C1) — `maru-web-host`·`maru-web-helper`·프레임워크가 **한 디렉터리**에
//! 실제 파일로 산다. 번들이 없으면 샌드박스는 실행 파일 디렉터리를 번들 경로로 써서 그 밖을 못 읽는다(실측).

const std = @import("std");

pub const framework_dir_name = "Chromium Embedded Framework.framework";
pub const framework_binary_name = "Chromium Embedded Framework";
pub const helper_name = "maru-web-helper";
pub const sandbox_library_rel = framework_dir_name ++ "/Libraries/libcef_sandbox.dylib";

pub const PathBuf = [std.fs.max_path_bytes:0]u8;

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

/// 실행 파일이 사는 디렉터리의 절대 경로. CEF 는 경로가 절대여야 받는다(상대면 조용히 기본값으로 간다).
/// `realpath` 로 푼다 — brew `opt/` 링크 경로로 띄워도 샌드박스가 됐다(실측), 푼 경로도 같은 디렉터리다.
pub fn executableDir(out: *PathBuf) error{PathTooLong}![]const u8 {
    var raw: PathBuf = undefined;
    var size: u32 = raw.len;
    if (_NSGetExecutablePath(&raw, &size) != 0) return error.PathTooLong;
    const resolved = std.c.realpath(&raw, out) orelse return error.PathTooLong;
    const full = std.mem.span(resolved);
    return std.fs.path.dirname(full) orelse full;
}

/// `dir` 아래 `name` 의 경로를 0 종료 문자열로 만든다.
pub fn join(out: *PathBuf, dir: []const u8, name: []const u8) error{PathTooLong}![:0]const u8 {
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ dir, name }) catch error.PathTooLong;
}
