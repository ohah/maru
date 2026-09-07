//! Closed transaction order for upgrade-B signed product evidence.
//!
//! Concrete leaf runners retain signer, filesystem, and predecessor semantics. This owner exists
//! so a workflow caller cannot exchange either release between the one-runtime and near-max runs,
//! skip an authority fence, or publish an aggregate under a different deadline.

pub const Error = error{CleanupFailed};

const output_count: usize = 4;

pub fn runWith(steps: anytype) !void {
    // Starting the deadline and the initial read-only fence create no output, so failures there
    // are pristine. A leaf is counted as attempted before its call because a failing child may
    // already have created its private output and therefore still needs its exact cleanup path.
    const deadline = steps.startDeadline() catch |err| return err;
    steps.validateInitialAuthorities(deadline) catch |err| return err;

    var attempted: usize = 1;
    steps.materializePredecessor(deadline) catch |err| return fail(steps, attempted, err);

    attempted = 2;
    steps.runSignedOne(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateAuthoritiesAfterOne(deadline) catch |err| return fail(steps, attempted, err);

    attempted = 3;
    steps.runSignedNearMax(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateAuthoritiesAfterNearMax(deadline) catch |err| return fail(steps, attempted, err);

    attempted = 4;
    steps.publishEvidence(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateFinalAuthorities(deadline) catch |err| return fail(steps, attempted, err);
    steps.validateFinalDeadline(deadline) catch |err| return fail(steps, attempted, err);
}

fn fail(steps: anytype, attempted: usize, original: anyerror) anyerror {
    if (!unwind(steps, attempted)) return error.CleanupFailed;
    return original;
}

/// Continue after one cleanup error so unrelated outputs do not become stranded. Each concrete
/// owner keeps its own retry capability if its cleanup fails.
fn unwind(steps: anytype, attempted: usize) bool {
    var clean = true;
    var cursor = @min(attempted, output_count);
    while (cursor > 0) {
        cursor -= 1;
        switch (cursor) {
            3 => steps.cleanupEvidence() catch {
                clean = false;
            },
            2 => steps.cleanupNearMax() catch {
                clean = false;
            },
            1 => steps.cleanupOne() catch {
                clean = false;
            },
            0 => steps.cleanupPredecessor() catch {
                clean = false;
            },
            else => unreachable,
        }
    }
    return clean;
}
