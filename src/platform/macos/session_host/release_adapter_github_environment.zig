//! Strict semantic parser for GitHub deployment-environment REST responses.
//!
//! This preserves configured protection facts without promoting them to proof that the current
//! workflow job passed those rules. Unknown future rule types remain wire-compatible but never
//! count as recognized protection. This module validates captured bytes; it does not authenticate
//! the transport that produced them.

const std = @import("std");
const contract = @import("release_adapter_contract");
const github_json = @import("release_adapter_github_json");

pub const max_response_bytes = github_json.max_response_bytes;

const StrictU64 = struct {
    value: u64,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StrictU64 {
        // GitHub's schema uses JSON integers. Quoted numbers are a different wire type and must
        // not become trusted merely because a generic parser can coerce them.
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};

const ProtectionRule = struct {
    id: StrictU64,
    type: []const u8,
    wait_timer: ?StrictU64 = null,
    prevent_self_review: ?bool = null,
    reviewers: ?[]const Reviewer = null,
};

const Reviewer = struct {
    type: []const u8,
    reviewer: ReviewerIdentity,
};

const ReviewerIdentity = struct {
    id: StrictU64,
};

const DeploymentBranchPolicy = struct {
    protected_branches: bool,
    custom_branch_policies: bool,
};

const ApiEnvironment = struct {
    id: StrictU64,
    name: []const u8,
    can_admins_bypass: ?bool = null,
    protection_rules: []const ProtectionRule,
    deployment_branch_policy: ?DeploymentBranchPolicy,
};

pub const Observation = struct {
    id: u64,
    name: []const u8,
    can_admins_bypass: bool,
    required_reviewer_count: u8,
    prevent_self_review: bool,
    wait_timer_minutes: u32,
    branch_policy_rule: bool,
    protected_branches: bool,
    custom_branch_policies: bool,
    unknown_rule_count: u64,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    EnvironmentMismatch,
} || std.mem.Allocator.Error;

pub const Parsed = struct {
    inner: std.json.Parsed(ApiEnvironment),
    bound_observation: Observation,

    pub fn deinit(self: *Parsed) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const Parsed) *const Observation {
        return &self.bound_observation;
    }
};

/// Parses one bounded response and binds it to the contract-owned `release` environment. Returned
/// slices remain valid until `Parsed.deinit`.
pub fn parseAndBind(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    var inner = std.json.parseFromSlice(ApiEnvironment, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    const value = inner.value;
    if (value.id.value == 0 or value.can_admins_bypass == null or value.can_admins_bypass.? or
        !std.mem.eql(u8, value.name, contract.protected_environment_name))
        return error.EnvironmentMismatch;

    var required_reviewer_count: u8 = 0;
    var prevent_self_review = false;
    var wait_timer_minutes: u32 = 0;
    var saw_required_reviewers = false;
    var saw_wait_timer = false;
    var branch_policy_rule = false;
    var unknown_rule_count: u64 = 0;
    for (value.protection_rules, 0..) |rule, index| {
        if (rule.id.value == 0) return error.EnvironmentMismatch;
        for (value.protection_rules[0..index]) |earlier| {
            if (earlier.id.value == rule.id.value) return error.EnvironmentMismatch;
        }

        if (rule.type.len == 0) return error.EnvironmentMismatch;
        if (std.mem.eql(u8, rule.type, "required_reviewers")) {
            if (saw_required_reviewers or rule.wait_timer != null or
                rule.prevent_self_review == null or rule.reviewers == null)
                return error.EnvironmentMismatch;
            const reviewers = rule.reviewers.?;
            if (reviewers.len == 0 or reviewers.len > 6) return error.EnvironmentMismatch;
            for (reviewers, 0..) |reviewer, reviewer_index| {
                if ((!std.mem.eql(u8, reviewer.type, "User") and
                    !std.mem.eql(u8, reviewer.type, "Team")) or reviewer.reviewer.id.value == 0)
                    return error.EnvironmentMismatch;
                for (reviewers[0..reviewer_index]) |earlier| {
                    if (std.mem.eql(u8, earlier.type, reviewer.type) and
                        earlier.reviewer.id.value == reviewer.reviewer.id.value)
                        return error.EnvironmentMismatch;
                }
            }
            saw_required_reviewers = true;
            required_reviewer_count = @intCast(reviewers.len);
            prevent_self_review = rule.prevent_self_review.?;
        } else if (std.mem.eql(u8, rule.type, "wait_timer")) {
            if (saw_wait_timer or rule.reviewers != null or rule.prevent_self_review != null or
                rule.wait_timer == null or rule.wait_timer.?.value == 0 or
                rule.wait_timer.?.value > 43_200)
                return error.EnvironmentMismatch;
            saw_wait_timer = true;
            wait_timer_minutes = @intCast(rule.wait_timer.?.value);
        } else if (std.mem.eql(u8, rule.type, "branch_policy")) {
            if (branch_policy_rule or rule.wait_timer != null or rule.reviewers != null or
                rule.prevent_self_review != null)
                return error.EnvironmentMismatch;
            branch_policy_rule = true;
        } else {
            unknown_rule_count = std.math.add(u64, unknown_rule_count, 1) catch
                return error.EnvironmentMismatch;
            continue;
        }
    }

    const branch_policy = value.deployment_branch_policy;
    if (branch_policy_rule != (branch_policy != null)) return error.EnvironmentMismatch;
    if (branch_policy) |policy| {
        // GitHub exposes these as mutually exclusive modes. Neither protects a ref, while both is
        // not a coherent API state; neither shape may become affirmative evidence.
        if (policy.protected_branches == policy.custom_branch_policies)
            return error.EnvironmentMismatch;
    }

    return .{
        .inner = inner,
        .bound_observation = .{
            .id = value.id.value,
            .name = value.name,
            .can_admins_bypass = value.can_admins_bypass.?,
            .required_reviewer_count = required_reviewer_count,
            .prevent_self_review = prevent_self_review,
            .wait_timer_minutes = wait_timer_minutes,
            .branch_policy_rule = branch_policy_rule,
            .protected_branches = if (branch_policy) |policy| policy.protected_branches else false,
            .custom_branch_policies = if (branch_policy) |policy| policy.custom_branch_policies else false,
            .unknown_rule_count = unknown_rule_count,
        },
    };
}

/// Public only so std's allocation-failure harness can cover the complete successful path.
pub fn parseAndBindForTest(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = try parseAndBind(allocator, bytes);
    parsed.deinit();
}
