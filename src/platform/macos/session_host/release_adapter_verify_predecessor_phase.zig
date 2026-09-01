//! Closed transaction order for post-publish predecessor verification.
//!
//! The summary is encoded while authenticated private owners are live, but its pathname is not
//! opened until every private owner has been cleaned. This prevents a passed audit artifact from
//! coexisting with an indeterminate private cleanup.

pub const Error = error{CleanupFailed};

const private_owner_count: usize = 6;

pub fn runWith(steps: anytype) !void {
    var completed: usize = 0;
    // startDeadline failure is failure-pristine: no cleanup capability exists until it returns.
    const deadline = steps.startDeadline() catch |err| return err;
    completed += 1;
    completed += 1;
    steps.prepareWorkspace(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.prepareCandidate(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.materializeManifest(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticateManifest(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticateAssets(deadline) catch |err| return fail(steps, deadline, completed, err);

    const prepared = steps.prepareSummary(deadline) catch |err|
        return fail(steps, deadline, completed, err);
    defer steps.releaseSummary(prepared);

    if (!unwindTo(steps, deadline, private_owner_count, 1)) {
        steps.cleanupDeadline(deadline) catch {};
        return error.CleanupFailed;
    }
    steps.validatePublication(deadline) catch |err| {
        steps.cleanupDeadline(deadline) catch return error.CleanupFailed;
        return err;
    };
    steps.cleanupDeadline(deadline) catch return error.CleanupFailed;
    try steps.publishSummary(prepared);
}

fn fail(steps: anytype, deadline: anytype, completed: usize, original: anyerror) anyerror {
    if (!unwind(steps, deadline, completed)) return error.CleanupFailed;
    return original;
}

/// Cleanup remains best-effort so one failed capability cannot strand unrelated owners. The
/// failing owner itself remains live for the product execution's explicit retry path.
fn unwind(steps: anytype, deadline: anytype, completed: usize) bool {
    return unwindTo(steps, deadline, completed, 0);
}

fn unwindTo(steps: anytype, deadline: anytype, completed: usize, floor: usize) bool {
    var clean = true;
    var cursor = @min(completed, private_owner_count);
    while (cursor > floor) {
        cursor -= 1;
        switch (cursor) {
            5 => steps.cleanupAssets(deadline) catch {
                clean = false;
            },
            4 => steps.cleanupAuthenticated(deadline) catch {
                clean = false;
            },
            3 => steps.cleanupMaterialized(deadline) catch {
                clean = false;
            },
            2 => steps.cleanupCandidate(deadline) catch {
                clean = false;
            },
            1 => steps.cleanupWorkspace(deadline) catch {
                clean = false;
            },
            0 => steps.cleanupDeadline(deadline) catch {
                clean = false;
            },
            else => unreachable,
        }
    }
    return clean;
}
