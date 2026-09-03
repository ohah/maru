//! Closed transaction order for baseline-A signed product evidence.
//!
//! Leaf runners retain signing, candidate, and filesystem semantics. This owner prevents workflow
//! callers from exchanging candidates between leaves or publishing an aggregate after authority
//! drift, and it gives every attempted child one deterministic cleanup path.

pub const Error = error{CleanupFailed};

const child_count: usize = 3;

pub fn runWith(steps: anytype) !void {
    // The deadline is borrowed from the final-address product owner. A failed start is pristine,
    // and this phase never destroys candidate authority owned by its caller.
    const deadline = steps.startDeadline() catch |err| return err;
    steps.validateInitialCandidate(deadline) catch |err| return err;

    var attempted: usize = 1;
    steps.runDefaultFalse(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateCandidateAfterDefault(deadline) catch |err| return fail(steps, attempted, err);

    attempted = 2;
    steps.runSignedAppQuit(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateCandidateAfterQuit(deadline) catch |err| return fail(steps, attempted, err);

    attempted = 3;
    steps.publishEvidence(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateFinalCandidate(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateFinalDeadline(deadline) catch |err| return fail(steps, attempted, err);
}

fn fail(steps: anytype, attempted: usize, original: anyerror) anyerror {
    if (!unwind(steps, attempted)) return error.CleanupFailed;
    return original;
}

/// Cleanup remains best-effort after the first failure. Each child retains its own retry authority
/// when cleanup fails, while later children are still released so unrelated capabilities do not
/// become stranded.
fn unwind(steps: anytype, attempted: usize) bool {
    var clean = true;
    var cursor = @min(attempted, child_count);
    while (cursor > 0) {
        cursor -= 1;
        switch (cursor) {
            2 => steps.cleanupEvidence() catch {
                clean = false;
            },
            1 => steps.cleanupSignedAppQuit() catch {
                clean = false;
            },
            0 => steps.cleanupDefaultFalse() catch {
                clean = false;
            },
            else => unreachable,
        }
    }
    return clean;
}
