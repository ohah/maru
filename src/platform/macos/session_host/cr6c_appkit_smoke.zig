//! CR6c actual-AppKit recovery harness.
//!
//! The harness owns only one unique current daemon/runtime, then execs the real Swift app bundle.
//! The app itself performs discovery and the NSEvent row action; this process never calls the
//! AppSession recovery action or constructs its projection.

const std = @import("std");
const client_mod = @import("client.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");

extern "c" fn usleep(useconds: c_uint) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const app_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_APP_EXE") orelse
        return error.MissingAppExecutable;
    const app_path = std.mem.span(app_raw);
    if (app_path.len == 0 or app_path[0] != '/') return error.InvalidAppExecutable;
    const app_path_z = try allocator.dupeZ(u8, app_path);
    defer allocator.free(app_path_z);
    const product_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_PRODUCT_EXE") orelse
        return error.MissingProductExecutable;
    const product_path = std.mem.span(product_raw);
    if (product_path.len == 0 or product_path[0] != '/') return error.InvalidProductExecutable;
    const product_path_z = try allocator.dupeZ(u8, product_path);
    defer allocator.free(product_path_z);

    try short_endpoint.prepareCurrentUserNamespace();
    var base_buf: [96]u8 = undefined;
    const base = try short_endpoint.userRootPathIn(&base_buf, std.c.getuid());
    var dir_buf: [192]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&dir_buf, base);
    const host_id = (@as(u128, @intCast(std.c.getpid())) << 64) | 0xC6C0_A77C_17A0_0001;
    var socket_buf: [160]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    const dir_z = try allocator.dupeZ(u8, session_dir);
    defer allocator.free(dir_z);
    const socket_z = try allocator.dupeZ(u8, socket);
    defer allocator.free(socket_z);
    var host_buf: [33]u8 = undefined;
    const host_text = try std.fmt.bufPrintZ(&host_buf, "{x:0>32}", .{host_id});

    // This harness owns exactly this PID-keyed host entry. Cleanup runs only after the later
    // terminateAndReap defer, so no live daemon can recreate files underneath it; sibling/user
    // hosts in the shared per-UID namespace are never enumerated or mutated here.
    var artifacts_owned = true;
    defer if (artifacts_owned) {
        _ = cleanupExactHostArtifacts(io, session_dir, socket, host_id);
    };

    const daemon_pid = std.c.fork();
    if (daemon_pid < 0) return error.ForkFailed;
    if (daemon_pid == 0) {
        _ = std.c.setsid();
        const argv = [_:null]?[*:0]const u8{
            product_path_z.ptr,
            "__session-host",
            dir_z.ptr,
            socket_z.ptr,
            host_text.ptr,
        };
        _ = std.c.execve(product_path_z.ptr, &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    var daemon_owned = true;
    defer if (daemon_owned) terminateAndReap(daemon_pid);

    var admin: ?client_mod.Client = null;
    var attempts: usize = 0;
    while (attempts < 250 and admin == null) : (attempts += 1) {
        admin = client_mod.Client.connect(allocator, socket, .gui) catch null;
        if (admin == null) _ = usleep(20 * 1000);
    }
    if (admin == null) return error.DaemonNotReady;
    defer if (admin) |*client| client.deinit();
    const spawn = try admin.?.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/sh\",\"-c\",\"printf 'CR6C-RECOVERED-MARKER\\n'; exec /bin/cat\"],\"cols\":80,\"rows\":24}",
    );
    defer allocator.free(spawn);
    const runtime_id = client_mod.extractRuntimeId(spawn) orelse return error.RuntimeIdMissing;
    const inventory = try admin.?.call(
        "runtime.inventory",
        "{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}",
    );
    defer allocator.free(inventory);
    std.debug.print("CR6c provisioning inventory: {s}\n", .{inventory});
    admin.?.deinit();
    admin = null;
    // Recovery discovery is a launch-time snapshot. Let the product poll owner observe the
    // provisioning GUI disconnect before the AppKit process takes that snapshot; otherwise the
    // still-attached runtime is correctly excluded and this fixture becomes scheduler-dependent.
    _ = usleep(250 * 1000);
    var runtime_id_z: [33]u8 = undefined;
    @memcpy(runtime_id_z[0..32], &runtime_id);
    runtime_id_z[32] = 0;
    if (setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&runtime_id_z), 1) != 0)
        return error.EnvironmentFailed;

    const app_pid = std.c.fork();
    if (app_pid < 0) return error.ForkFailed;
    if (app_pid == 0) {
        const argv = [_:null]?[*:0]const u8{app_path_z.ptr};
        _ = std.c.execve(app_path_z.ptr, &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    try waitForExactExit(app_pid, 30_000);

    // AppKit teardown must detach from, not terminate, the keep-alive runtime.
    var params_buf: [80]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&runtime_id});
    var verification_client = try client_mod.Client.connect(allocator, socket, .gui);
    var verification_client_owned = true;
    defer if (verification_client_owned) verification_client.deinit();
    const still_live = try verification_client.call("runtime.get", params);
    defer allocator.free(still_live);
    std.debug.print("CR6c post-AppKit runtime.get: {s}\n", .{still_live});
    if (std.mem.indexOf(u8, still_live, &runtime_id) == null) return error.RuntimeDidNotSurviveAppExit;
    if (std.mem.indexOf(u8, still_live, "\"has_controller\":false") == null)
        return error.ControllerAuthoritySurvivedAppExit;
    if (std.mem.indexOf(u8, still_live, "\"observer_count\":0") == null)
        return error.ObserverAuthoritySurvivedAppExit;

    verification_client.deinit();
    verification_client_owned = false;
    terminateAndReap(daemon_pid);
    daemon_owned = false;
    if (!cleanupExactHostArtifacts(io, session_dir, socket, host_id))
        return error.ArtifactCleanupFailed;
    artifacts_owned = false;
}

fn waitForExactExit(pid: c_int, timeout_ms: usize) !void {
    var status: c_int = 0;
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            const unsigned: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(unsigned) or std.c.W.EXITSTATUS(unsigned) != 0) {
                std.debug.print("CR6c AppKit child wait status=0x{x}\n", .{unsigned});
                return error.AppFailed;
            }
            return;
        }
        if (rc < 0) return error.WaitFailed;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) break;
    }
    return error.AppTimedOut;
}

fn terminateAndReap(pid: c_int) void {
    _ = std.c.kill(pid, std.posix.SIG.TERM);
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 400) : (attempts += 1) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return;
        if (rc < 0) return;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) return;
    }
}

fn cleanupExactHostArtifacts(
    io: std.Io,
    session_dir: [:0]const u8,
    socket: [:0]const u8,
    host_id: u128,
) bool {
    _ = std.c.unlink(socket.ptr);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id) catch
        return false;
    std.Io.Dir.cwd().deleteTree(io, host_dir) catch {};
    var log_buf: [768]u8 = undefined;
    const log_path = std.fmt.bufPrintZ(&log_buf, "{s}/host-{x:0>32}.log", .{ session_dir, host_id }) catch
        return false;
    _ = std.c.unlink(log_path.ptr);

    return access(socket.ptr, 0) != 0 and
        access(host_dir.ptr, 0) != 0 and
        access(log_path.ptr, 0) != 0;
}
