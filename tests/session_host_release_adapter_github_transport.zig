//! Release provenance가 임의 URL이나 불완전한 첫 page를 GitHub 관측으로 승격하지 못하게 한다.
//!
//! Request plan은 endpoint와 pagination을 닫고, macOS leaf는 token을 argv/log가 아닌 clean child
//! environment로만 전달한다. 실제 release workflow 배선과 CLI 공급망 권위는 이 gate의 범위가 아니다.

const std = @import("std");
const transport = @import("release_adapter_github_transport");
const transport_macos = @import("release_adapter_github_transport_macos");

const sha = "0123456789abcdef0123456789abcdef01234567";

test "GitHub transport closes every scalar endpoint" {
    const cases = [_]struct { request: transport.Request, expected: []const u8 }{
        .{ .request = .repository, .expected = "repos/ohah/maru" },
        .{ .request = .{ .workflow_run = 333 }, .expected = "repos/ohah/maru/actions/runs/333" },
        .{ .request = .{ .published_release = "v1.2.3" }, .expected = "repos/ohah/maru/releases/tags/v1.2.3" },
        .{ .request = .{ .tag_ref = "v1.2.3" }, .expected = "repos/ohah/maru/git/ref/tags/v1.2.3" },
        .{ .request = .{ .annotated_tag = sha }, .expected = "repos/ohah/maru/git/tags/" ++ sha },
        .{ .request = .environment, .expected = "repos/ohah/maru/environments/release" },
    };
    for (cases) |case| {
        var storage: transport.EndpointStorage = undefined;
        const plan = try transport.plan(&storage, case.request);
        try std.testing.expectEqualStrings(case.expected, plan.endpoint);
        try std.testing.expect(!plan.paginated);
        try std.testing.expectEqual(transport.PageShape.none, plan.page_shape);
    }
}

test "GitHub transport closes collection queries and flattening" {
    const cases = [_]struct { request: transport.Request, expected: []const u8, shape: transport.PageShape }{
        .{
            .request = .draft_releases,
            .expected = "repos/ohah/maru/releases?per_page=100",
            .shape = .array,
        },
        .{
            .request = .{ .attempt_jobs = .{ .run_id = 333, .attempt = 2 } },
            .expected = "repos/ohah/maru/actions/runs/333/attempts/2/jobs?per_page=100",
            .shape = .jobs,
        },
        .{
            .request = .{ .deployments = .{ .source_sha = sha } },
            .expected = "repos/ohah/maru/deployments?sha=" ++ sha ++ "&environment=release&per_page=100",
            .shape = .array,
        },
        .{
            .request = .{ .deployment_statuses = 44 },
            .expected = "repos/ohah/maru/deployments/44/statuses?per_page=100",
            .shape = .array,
        },
    };
    for (cases) |case| {
        var storage: transport.EndpointStorage = undefined;
        const plan = try transport.plan(&storage, case.request);
        try std.testing.expectEqualStrings(case.expected, plan.endpoint);
        try std.testing.expect(plan.paginated);
        try std.testing.expectEqual(case.shape, plan.page_shape);
    }
}

test "GitHub transport rejects noncanonical identity before argv construction" {
    var storage: transport.EndpointStorage = undefined;
    try std.testing.expectError(error.InvalidId, transport.plan(&storage, .{ .workflow_run = 0 }));
    try std.testing.expectError(error.InvalidId, transport.plan(&storage, .{ .attempt_jobs = .{ .run_id = 1, .attempt = 0 } }));
    try std.testing.expectError(error.InvalidTag, transport.plan(&storage, .{ .published_release = "v1.2.3/extra" }));
    try std.testing.expectError(error.InvalidSha, transport.plan(&storage, .{ .annotated_tag = "ABC" }));
}

test "GitHub transport argv is fixed and never contains the token" {
    var endpoint_storage: transport.EndpointStorage = undefined;
    const plan = try transport.plan(&endpoint_storage, .{ .deployment_statuses = 44 });
    var args_storage: transport.ArgsStorage = undefined;
    const args = transport.args(&args_storage, plan);
    const expected = [_][]const u8{
        "api",      "--method",                                             "GET",      "--hostname",                       "github.com",
        "--header", "Accept: application/vnd.github+json",                  "--header", "X-GitHub-Api-Version: 2022-11-28", "--paginate",
        "--slurp",  "repos/ohah/maru/deployments/44/statuses?per_page=100",
    };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try std.testing.expectEqualStrings(want, got);
    for (args) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "secret-token") == null);
}

test "GitHub transport token is bounded and control free" {
    try transport.validateToken("github-actions-token");
    try std.testing.expectError(error.InvalidToken, transport.validateToken(""));
    try std.testing.expectError(error.InvalidToken, transport.validateToken("line\nbreak"));
    var oversized: [transport.max_token_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidToken, transport.validateToken(&oversized));
}

test "GitHub transport rejects non-JSON and oversized flattened output" {
    try transport.validateOutput("{\"id\":1}");
    try std.testing.expectError(error.InvalidResponse, transport.validateOutput("{}{}"));
    var oversized: [transport.max_response_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.ResponseTooLarge, transport.validateOutput(&oversized));

    var oversized_scalar: [transport.max_token_bytes + 6]u8 = undefined;
    oversized_scalar[0] = '{';
    oversized_scalar[1] = '"';
    @memset(oversized_scalar[2 .. oversized_scalar.len - 3], 'x');
    oversized_scalar[oversized_scalar.len - 3] = '"';
    oversized_scalar[oversized_scalar.len - 2] = ':';
    oversized_scalar[oversized_scalar.len - 1] = '0';
    // Close the object by replacing the last payload byte: {"<4097 bytes>":0}.
    var complete: [oversized_scalar.len + 1]u8 = undefined;
    @memcpy(complete[0..oversized_scalar.len], &oversized_scalar);
    complete[complete.len - 1] = '}';
    try std.testing.expectError(error.InvalidResponse, transport.validateOutput(&complete));

    var escaped_scalar: [2 + 6 * (transport.max_token_bytes + 1)]u8 = undefined;
    escaped_scalar[0] = '"';
    var escaped_cursor: usize = 1;
    for (0..transport.max_token_bytes + 1) |_| {
        @memcpy(escaped_scalar[escaped_cursor..][0..6], "\\u0061");
        escaped_cursor += 6;
    }
    escaped_scalar[escaped_cursor] = '"';
    try std.testing.expectError(error.InvalidResponse, transport.validateOutput(&escaped_scalar));

    // The bound is per scalar, not an aggregate allocation budget: many small values stay valid.
    var many_scalars: [9 * 1024]u8 = undefined;
    many_scalars[0] = '[';
    var many_cursor: usize = 1;
    for (0..2048) |index| {
        if (index != 0) {
            many_scalars[many_cursor] = ',';
            many_cursor += 1;
        }
        @memcpy(many_scalars[many_cursor..][0..3], "\"x\"");
        many_cursor += 3;
    }
    many_scalars[many_cursor] = ']';
    many_cursor += 1;
    try transport.validateOutput(many_scalars[0..many_cursor]);
}

test "GitHub transport directly flattens slurped pages without jq" {
    var endpoint_storage: transport.EndpointStorage = undefined;
    var output: [transport.max_response_bytes]u8 = undefined;
    const arrays = try transport.plan(&endpoint_storage, .{ .deployment_statuses = 44 });
    try std.testing.expectEqualStrings(
        "[{\"id\":3},{\"id\":2},{\"id\":1}]",
        try transport.normalizeOutput(
            std.testing.allocator,
            arrays,
            "[[{\"id\":3},{\"id\":2}],[{\"id\":1}]]",
            &output,
        ),
    );
    const jobs = try transport.plan(&endpoint_storage, .{ .attempt_jobs = .{ .run_id = 333, .attempt = 2 } });
    try std.testing.expectEqualStrings(
        "{\"total_count\":2,\"jobs\":[{\"id\":1},{\"id\":2}]}",
        try transport.normalizeOutput(
            std.testing.allocator,
            jobs,
            "[{\"total_count\":2,\"jobs\":[{\"id\":1}]},{\"total_count\":2,\"jobs\":[{\"id\":2}]}]",
            &output,
        ),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        transport.normalizeOutput(
            std.testing.allocator,
            jobs,
            "[{\"total_count\":1,\"jobs\":[]},{\"total_count\":2,\"jobs\":[]}]",
            &output,
        ),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        transport.normalizeOutput(
            std.testing.allocator,
            jobs,
            "[{\"total_count\":2,\"jobs\":[{\"id\":1}]}]",
            &output,
        ),
    );
    var oversized_scalar: [transport.max_token_bytes + 7]u8 = undefined;
    oversized_scalar[0] = '[';
    oversized_scalar[1] = '[';
    oversized_scalar[2] = '"';
    @memset(oversized_scalar[3 .. oversized_scalar.len - 3], 'x');
    oversized_scalar[oversized_scalar.len - 3] = '"';
    oversized_scalar[oversized_scalar.len - 2] = ']';
    oversized_scalar[oversized_scalar.len - 1] = ']';
    try std.testing.expectError(
        error.InvalidResponse,
        transport.normalizeOutput(
            std.testing.allocator,
            arrays,
            &oversized_scalar,
            &output,
        ),
    );
}

test "GitHub transport execution passes only token and prompt guard in child environment" {
    const Fake = struct {
        pub fn capture(
            _: *@This(),
            executable: []const u8,
            child_args: []const []const u8,
            environment: []const []const u8,
            output: []u8,
            budget_ns: i128,
        ) ![]const u8 {
            try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
            try std.testing.expect(budget_ns > 0);
            for (child_args) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "secret-token") == null);
            try std.testing.expectEqual(@as(usize, 2), environment.len);
            try std.testing.expectEqualStrings("GH_TOKEN=secret-token", environment[0]);
            try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[1]);
            @memcpy(output[0..2], "{}");
            return output[0..2];
        }
    };
    var fake = Fake{};
    var output: [transport.max_response_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{}",
        try transport_macos.fetchWith(
            &fake,
            std.testing.allocator,
            "/opt/trusted/gh",
            "secret-token",
            .repository,
            &output,
            std.time.ns_per_s,
        ),
    );
    try std.testing.expectError(
        error.InvalidBudget,
        transport_macos.fetchWith(
            &fake,
            std.testing.allocator,
            "/opt/trusted/gh",
            "secret-token",
            .repository,
            &output,
            0,
        ),
    );
}

test "GitHub transport rejects executor output outside the supplied bounded buffer" {
    const Fake = struct {
        pub fn capture(_: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            return "{}";
        }
    };
    var fake = Fake{};
    var output: [transport.max_response_bytes]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCapture,
        transport_macos.fetchWith(
            &fake,
            std.testing.allocator,
            "/opt/trusted/gh",
            "secret-token",
            .repository,
            &output,
            std.time.ns_per_s,
        ),
    );
}

test "GitHub transport product execution fails closed on child failure" {
    var output: [transport.max_response_bytes]u8 = undefined;
    try std.testing.expectError(
        error.ChildFailed,
        transport_macos.fetch(
            std.testing.io,
            std.testing.allocator,
            "/usr/bin/false",
            "secret-token",
            .repository,
            &output,
            std.time.ns_per_s,
        ),
    );
    try std.testing.expectError(
        error.InvalidExecutable,
        transport_macos.fetch(
            std.testing.io,
            std.testing.allocator,
            "relative/gh",
            "secret-token",
            .repository,
            &output,
            std.time.ns_per_s,
        ),
    );
}

test "GitHub transport product leaf admits only stdout as REST bytes" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_github_transport_macos.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "process.runCaptureEnvironmentStdout(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "process.runCaptureEnvironment(") == null);
}
