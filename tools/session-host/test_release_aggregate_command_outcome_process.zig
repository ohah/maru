//! Executes the real validator binary and byte-checks closed stage-5/6 failures.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const validator_input = args.next() orelse return error.MissingValidator;
    if (args.next() != null) return error.TooManyArguments;
    const validator = try std.Io.Dir.cwd().realPathFileAlloc(init.io, validator_input, init.gpa);
    defer init.gpa.free(validator);

    inline for (.{ "prepare-candidate-aggregate", "finalize-candidate-aggregate" }) |command| {
        try expectAuditRequired(init, &.{ validator, command });

        // The validator owns 39 command slots. Supplying the command plus 39 values forces the
        // append boundary after the command is known, where the closed aggregate outcome applies.
        var overflow_argv: [41][]const u8 = @splat("x");
        overflow_argv[0] = validator;
        overflow_argv[1] = command;
        try expectAuditRequired(init, &overflow_argv);
    }
}

fn expectAuditRequired(init: std.process.Init, argv: []const []const u8) !void {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try expectExit(result.term, 21);
    if (result.stdout.len != 0) return error.UnexpectedStdout;
    if (!std.mem.eql(u8, result.stderr, "audit_required\n")) return error.UnexpectedStderr;
}

fn expectExit(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |code| if (code != expected) return error.UnexpectedExit,
        else => return error.UnexpectedTermination,
    }
}
