//! Bounded process proof for the ended-purge quarantine's single-winner rule.
//!
//! The driver forks only to exec a fresh worker. The worker creates threads after exec, so this
//! fixture never invokes the thread runtime from a fork child that inherited an arbitrary test
//! process. A bounded parent watchdog converts deadlock into a deterministic gate failure.

const std = @import("std");
const quarantine = @import("ended_purge_quarantine.zig");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const worker_argument = "--worker";
const worker_count = 8;

fn reserveConcurrent(
    registry: *quarantine.Registry,
    operation_generation: u64,
    out: *quarantine.Reservation,
    won: *bool,
) void {
    registry.reserve(29, operation_generation, 1, out) catch return;
    won.* = true;
}

fn runWorker() !void {
    var registry = quarantine.Registry.init();
    var reservations = [_]quarantine.Reservation{.{}} ** worker_count;
    var won = [_]bool{false} ** worker_count;
    var threads: [worker_count]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |*thread| thread.join();

    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, reserveConcurrent, .{
            &registry,
            @as(u64, @intCast(index + 1)),
            &reservations[index],
            &won[index],
        });
        started += 1;
    }
    for (&threads) |*thread| thread.join();
    started = 0;

    var winner_count: usize = 0;
    var winner_index: usize = 0;
    for (won, 0..) |did_win, index| {
        if (!did_win) continue;
        winner_count += 1;
        winner_index = index;
    }
    if (winner_count != 1) return error.InvalidWinnerCount;
    if (!registry.release(&reservations[winner_index])) return error.WinnerReleaseFailed;
}

fn waitWorkerBounded(child: std.c.pid_t) !void {
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) {
            const wait_status: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(wait_status) or std.c.W.EXITSTATUS(wait_status) != 0)
                return error.WorkerFailed;
            return;
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            terminateAndReap(child);
            return error.WaitFailed;
        }
        var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    terminateAndReap(child);
    return error.WorkerTimedOut;
}

fn terminateAndReap(child: std.c.pid_t) void {
    _ = std.c.kill(child, std.c.SIG.KILL);
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(child, &status, 0);
        if (waited == child or (waited < 0 and std.posix.errno(waited) == .CHILD)) return;
        if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
        return;
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const executable_raw = args.next() orelse return error.MissingExecutable;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, worker_argument) or args.next() != null)
            return error.UnexpectedArgument;
        return runWorker();
    }

    // Prepare every child input before fork. The child path below performs only async-signal-safe
    // libc calls until exec replaces the inherited process image.
    const executable = try init.gpa.dupeZ(u8, executable_raw);
    defer init.gpa.free(executable);
    const worker = try init.gpa.dupeZ(u8, worker_argument);
    defer init.gpa.free(worker);
    const child_argv = [_:null]?[*:0]const u8{ executable.ptr, worker.ptr };

    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = execv(executable.ptr, &child_argv);
        std.c._exit(127);
    }
    try waitWorkerBounded(child);
}
