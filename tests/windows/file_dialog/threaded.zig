//! Opt-in integration probe: actual detached Zig worker and native owned modal.
const std = @import("std");
const picker = @import("picker");
extern fn maru_picker_probe_directory() ?[*:0]const u16;
extern fn maru_picker_probe_owner() ?*anyopaque;
extern fn maru_picker_probe_pump() void;
extern fn maru_picker_probe_modal(?*anyopaque) bool;
extern fn maru_picker_probe_enabled(?*anyopaque) bool;
extern fn maru_picker_probe_destroy(?*anyopaque) void;
extern fn maru_picker_probe_tick() u64;
extern fn maru_picker_probe_pause() void;

pub fn main() !void {
    const native_directory = maru_picker_probe_directory() orelse return error.TempDirectoryFailed;
    const directory = try std.unicode.wtf16LeToWtf8Alloc(std.heap.smp_allocator, std.mem.span(native_directory));
    defer std.heap.smp_allocator.free(directory);
    for (directory) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    const owner = maru_picker_probe_owner() orelse return error.CreateOwnerFailed;
    defer maru_picker_probe_destroy(owner);
    for ([_]picker.Kind{ .file, .directory }, 0..) |kind, index| {
        var request = try picker.Picker.start(std.heap.smp_allocator, .{
            .kind = kind,
            .initial_directory = directory,
            .owner = owner,
            .token = 100 + index,
            .title = "Maru private Zig worker picker probe",
        });
        defer request.deinit();
        const deadline = maru_picker_probe_tick() + 15000;
        while (!maru_picker_probe_modal(owner)) {
            maru_picker_probe_pump();
            if (request.poll()) |taken| {
                var result = taken;
                defer result.deinit();
                return error.CompletedBeforeVisibleModal;
            }
            if (maru_picker_probe_tick() >= deadline) return error.DialogVisibilityTimeout;
            maru_picker_probe_pause();
        }
        if (maru_picker_probe_enabled(owner)) return error.ModalOwnerWasNotDisabled;
        request.cancel();
        const canceled_deadline = maru_picker_probe_tick() + 10000;
        while (true) {
            maru_picker_probe_pump();
            if (request.poll()) |taken| {
                var result = taken;
                defer result.deinit();
                if (result.token != 100 + index) return error.WrongResultToken;
                if (result.value != .canceled) return error.CancelWasNotPreserved;
                if (request.poll() != null) return error.ResultReplayed;
                break;
            }
            if (maru_picker_probe_tick() >= canceled_deadline) return error.CancelCompletionTimeout;
            maru_picker_probe_pause();
        }
        maru_picker_probe_pump();
        if (maru_picker_probe_modal(owner)) return error.DialogStillVisible;
        if (!maru_picker_probe_enabled(owner)) return error.OwnerWasNotRestored;
        std.debug.print("kind={s} actual_zig_worker=true modal_seen=true canceled=true token_verified=true owner_restored=true\n", .{@tagName(kind)});
    }
}
