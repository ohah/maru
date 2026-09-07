//! Single source of truth for public validator process exit and stderr vocabularies.

pub const Stage3 = enum(u8) { success, local_failure, audit_required, cleanup_failed };
pub const Aggregate = enum(u8) { success, audit_required, cleanup_failed };
pub const Publication = enum(u8) { success, audit_required, cleanup_failed };
pub const Cleanup = enum(u8) { success, audit_required, cleanup_required, descriptor_close_failed };

pub fn stage3ExitCode(outcome: Stage3) u8 {
    return switch (outcome) {
        .success => 0,
        .local_failure => 20,
        .audit_required => 21,
        .cleanup_failed => 22,
    };
}

pub fn stage3StderrLine(outcome: Stage3) []const u8 {
    return switch (outcome) {
        .success => "success\n",
        .local_failure => "local_failure\n",
        .audit_required => "audit_required\n",
        .cleanup_failed => "cleanup_failed\n",
    };
}

pub fn aggregateExitCode(outcome: Aggregate) u8 {
    return commonExitCode(outcome);
}

pub fn aggregateStderrLine(outcome: Aggregate) []const u8 {
    return commonStderrLine(outcome);
}

pub fn publicationExitCode(outcome: Publication) u8 {
    return commonExitCode(outcome);
}

pub fn publicationStderrLine(outcome: Publication) []const u8 {
    return commonStderrLine(outcome);
}

pub fn cleanupExitCode(outcome: Cleanup) u8 {
    return switch (outcome) {
        .success => 0,
        .audit_required => 21,
        .cleanup_required => 22,
        .descriptor_close_failed => 23,
    };
}

pub fn cleanupStderrLine(outcome: Cleanup) []const u8 {
    return switch (outcome) {
        .success => "success\n",
        .audit_required => "audit_required\n",
        .cleanup_required => "cleanup_required\n",
        .descriptor_close_failed => "descriptor_close_failed\n",
    };
}

fn commonExitCode(outcome: anytype) u8 {
    return switch (outcome) {
        .success => 0,
        .audit_required => 21,
        .cleanup_failed => 22,
    };
}

fn commonStderrLine(outcome: anytype) []const u8 {
    return switch (outcome) {
        .success => "success\n",
        .audit_required => "audit_required\n",
        .cleanup_failed => "cleanup_failed\n",
    };
}
