//! Closed ordering for one provisioned Notification Center product transaction.
//!
//! The phase knows no filesystem, AppKit, AX, or signing APIs. Those belong to the concrete
//! adapter; keeping the order here makes it impossible for one adapter revision to omit a
//! candidate/helper revalidation between the two real OS interactions.

pub fn runWith(steps: anytype) !void {
    const deadline = try steps.startDeadline();
    try steps.validateInitialAuthorities(deadline);
    steps.runGuiZero(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.validateAfterGuiZero(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.runGuiLiveThenQuit(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.validateAfterGuiLiveThenQuit(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.cleanupNotifications(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.validateAfterCleanup(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.publishEvidence(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.validateFinalAuthorities(deadline) catch |err| return failAfterAttempt(steps, err);
    steps.validateFinalDeadline(deadline) catch |err| return failAfterAttempt(steps, err);
}

fn failAfterAttempt(steps: anytype, original: anyerror) anyerror {
    steps.cleanupAttempted() catch return error.CleanupFailed;
    return original;
}
