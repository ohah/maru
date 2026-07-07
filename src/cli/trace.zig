//! `maru trace` 서브커맨드의 **순수 인자 파싱**. 실제 파일 I/O·env·변환은 `main.zig`(디스패처)가, 익명화/파싱
//! 로직은 `observability.trace`·`redact`가 갖는다(파일도 목적별로 분리 — docs/project-rules.md). 현재 서브커맨드:
//! `anonymize`(캡처한 trace의 PII를 일반화해 fixture로 커밋 가능하게 만든다).

const std = @import("std");

pub const ParseError = error{ UnknownSubcommand, MissingInput };

pub const Command = union(enum) {
    /// `maru trace anonymize <input> [output]` — trace의 PII(경로·IP·user@host·유저명)를 익명화한다.
    /// output이 없으면 stdout으로 낸다.
    anonymize: struct { input: []const u8, output: ?[]const u8 },
};

/// args = "trace" 뒤 토큰들(첫 토큰이 서브커맨드).
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.UnknownSubcommand;
    if (std.mem.eql(u8, args[0], "anonymize")) {
        if (args.len < 2) return error.MissingInput;
        return .{ .anonymize = .{ .input = args[1], .output = if (args.len >= 3) args[2] else null } };
    }
    return error.UnknownSubcommand;
}

test "trace CLI parse: anonymize input [output]" {
    {
        const c = try parse(&[_][]const u8{ "anonymize", "in.trace" });
        try std.testing.expect(c == .anonymize);
        try std.testing.expectEqualStrings("in.trace", c.anonymize.input);
        try std.testing.expect(c.anonymize.output == null);
    }
    {
        const c = try parse(&[_][]const u8{ "anonymize", "in.trace", "out.trace" });
        try std.testing.expectEqualStrings("out.trace", c.anonymize.output.?);
    }
    try std.testing.expectError(error.MissingInput, parse(&[_][]const u8{"anonymize"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&[_][]const u8{"bogus"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&[_][]const u8{}));
}
