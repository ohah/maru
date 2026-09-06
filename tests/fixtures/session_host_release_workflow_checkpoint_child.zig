//! Actual child process for fixed workflow checkpoint init/advance tests.

const std = @import("std");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse return error.MissingRoot;
    const operation = args.next() orelse return error.MissingOperation;
    const expected = try checkpoint.decodeRootIdentity(args.next() orelse return error.MissingRootIdentity);
    const stage_text = args.next();
    if (args.next() != null) return error.TooManyArguments;
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path_z = std.fmt.bufPrintZ(&root_storage, "{s}", .{root_path}) catch return error.InvalidRoot;
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, root_path_z, expected);
    defer root.deinit() catch {};
    const workflow = workflowContext();
    if (std.mem.eql(u8, operation, "init")) {
        if (stage_text != null) return error.TooManyArguments;
        try checkpoint.initialize(&root, workflow);
        return;
    }
    if (!std.mem.eql(u8, operation, "advance")) return error.InvalidOperation;
    const text = stage_text orelse return error.MissingStage;
    const stage: phase.Stage = inline for (@typeInfo(phase.Stage).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) break @enumFromInt(field.value);
    } else return error.InvalidStage;
    _ = try checkpoint.advance(init.gpa, &root, stage, .succeeded, workflow);
}

fn workflowContext() context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}
