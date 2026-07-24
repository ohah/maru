//! Old-image U5 coordinator의 실제 preflight/pathname-exec adapter.

const std = @import("std");
const c = std.c;
const entrypoint = @import("entrypoint.zig");
const upgrade_preflight = @import("upgrade_preflight.zig");
const upgrade_product = @import("upgrade_product_coordinator.zig");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const ProductExecutor = struct {
    allocator: std.mem.Allocator,
    preflight_impl: upgrade_preflight.ProductPreflight = .{},

    pub fn ops(self: *ProductExecutor) upgrade_product.Executor {
        return .{
            .ctx = self,
            .preflight = preflightOpaque,
            .execute = executeOpaque,
        };
    }

    fn preflightOpaque(
        ctx: *anyopaque,
        target: @import("upgrade_owner.zig").VerifiedTarget,
        primary_fd: c.fd_t,
        deadline: @import("upgrade_deadline.zig").Deadline,
    ) upgrade_product.PreflightError!void {
        const self: *ProductExecutor = @ptrCast(@alignCast(ctx));
        return self.preflight_impl.run(target, primary_fd, deadline);
    }

    fn executeOpaque(
        ctx: *anyopaque,
        request: upgrade_product.ExecuteRequest,
    ) upgrade_product.ExecError!void {
        const self: *ProductExecutor = @ptrCast(@alignCast(ctx));
        var buffers: entrypoint.RestoreArgBuffers = .{};
        const args = entrypoint.formatRestoreArgs(
            request.restore,
            &buffers,
        ) catch return error.ExecFailed;
        var owned: [entrypoint.max_invocation_args][:0]u8 = undefined;
        var built: usize = 0;
        defer for (owned[0..built]) |arg| self.allocator.free(arg);
        for (args, 0..) |arg, index| {
            owned[index] = self.allocator.dupeZ(u8, arg) catch
                return error.ExecFailed;
            built += 1;
        }
        var argv: [entrypoint.max_invocation_args + 3:null]?[*:0]const u8 =
            undefined;
        argv[0] = request.target_path.ptr;
        argv[1] = entrypoint.subcommand;
        for (owned, 0..) |arg, index| argv[index + 2] = arg.ptr;
        argv[entrypoint.max_invocation_args + 2] = null;
        // The coordinator's last check precedes argv ownership allocations.
        // Recheck the same absolute budget at the syscall boundary so a slow
        // allocator can never turn an expired attempt into a target exec.
        if (request.deadline.expired()) return error.ExecFailed;
        _ = execv(request.target_path.ptr, &argv);
        return error.ExecFailed;
    }
};
