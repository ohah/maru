//! Closed public process vocabulary shared by aggregate command drivers and workflow observers.

pub const Outcome = enum(u8) { success, audit_required, cleanup_failed };

pub fn exitCode(outcome: Outcome) u8 {
    return switch (outcome) {
        .success => 0,
        .audit_required => 21,
        .cleanup_failed => 22,
    };
}

pub fn stderrLine(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .success => "success\n",
        .audit_required => "audit_required\n",
        .cleanup_failed => "cleanup_failed\n",
    };
}
