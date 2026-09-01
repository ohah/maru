//! Closed transaction order for pre-publish validation.
//!
//! Leaf modules retain all domain parsing and authority checks. This owner exists so no caller can
//! reorder them, publish before private cleanup, or forget to unwind an earlier successful owner.

pub const Error = error{CleanupFailed};

const private_owner_count: usize = 12;

pub fn runWith(steps: anytype) !void {
    var completed: usize = 0;
    // This leaf must be failure-pristine: a failed call cannot return the cleanup capability.
    const deadline = steps.startDeadline() catch |err| return err;
    completed += 1;
    completed += 1;
    steps.prepareWorkspace(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.prepareCandidate(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticateCurrentRelease(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticateCurrentInput(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticatePredecessorInput(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.authenticatePredecessorAssets(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.observeProduct(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.composeEvidence(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.composeAssetFiles(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.attestAssets(deadline) catch |err| return fail(steps, deadline, completed, err);
    completed += 1;
    steps.composeCompatibility(deadline) catch |err| return fail(steps, deadline, completed, err);
    steps.composeObservation(deadline) catch |err| {
        steps.cleanupObservation();
        return fail(steps, deadline, completed, err);
    };

    if (!unwindTo(steps, deadline, private_owner_count, 1)) {
        steps.cleanupDeadline(deadline) catch {};
        steps.cleanupObservation();
        return error.CleanupFailed;
    }
    steps.validatePublication(deadline) catch |err| {
        steps.cleanupDeadline(deadline) catch {
            steps.cleanupObservation();
            return error.CleanupFailed;
        };
        steps.cleanupObservation();
        return err;
    };
    steps.cleanupDeadline(deadline) catch {
        steps.cleanupObservation();
        return error.CleanupFailed;
    };
    steps.publishSummary() catch |err| {
        steps.cleanupObservation();
        return err;
    };
    steps.cleanupObservation();
}

fn fail(steps: anytype, deadline: anytype, completed: usize, original: anyerror) anyerror {
    if (!unwind(steps, deadline, completed)) return error.CleanupFailed;
    return original;
}

/// Cleanup is best-effort across every opened owner. A failing owner keeps its own retry authority,
/// while later cleanup still runs so one failure cannot strand unrelated capabilities.
fn unwind(steps: anytype, deadline: anytype, completed: usize) bool {
    return unwindTo(steps, deadline, completed, 0);
}

fn unwindTo(steps: anytype, deadline: anytype, completed: usize, floor: usize) bool {
    var clean = true;
    var cursor = @min(completed, private_owner_count);
    while (cursor > floor) {
        cursor -= 1;
        switch (cursor) {
            11 => steps.cleanupCompatibility(deadline) catch {
                clean = false;
            },
            10 => steps.cleanupAssetAttestations(deadline) catch {
                clean = false;
            },
            9 => steps.cleanupAssetFiles(deadline) catch {
                clean = false;
            },
            8 => steps.cleanupEvidence(deadline) catch {
                clean = false;
            },
            7 => steps.cleanupProduct(deadline) catch {
                clean = false;
            },
            6 => steps.cleanupPredecessorAssets(deadline) catch {
                clean = false;
            },
            5 => steps.cleanupPredecessorInput(deadline) catch {
                clean = false;
            },
            4 => steps.cleanupCurrentInput(deadline) catch {
                clean = false;
            },
            3 => steps.cleanupCurrentRelease(deadline) catch {
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
