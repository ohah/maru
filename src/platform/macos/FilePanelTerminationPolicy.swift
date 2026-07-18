enum FilePanelTerminationPolicy {
    /// App-wide quit always gives the first protected session priority over the active session.
    /// Keeping this index decision pure makes normal-window/quick ordering executable without AppKit.
    static func firstProtectedIndex(_ protected: [Bool]) -> Int? {
        protected.firstIndex(of: true)
    }

    /// A successful tick never enters teardown. Every non-OK result must retain its current surface
    /// when Zig reports protected file state, regardless of whether the surface is normal or quick.
    static func shouldHoldCurrentSurface(tickSucceeded: Bool, currentProtected: Bool) -> Bool {
        !tickSucceeded && currentProtected
    }

    /// Recreating a quick session to apply session-shaped config is destructive and therefore uses
    /// the same current-surface protection rule as a tick failure.
    static func mayRecreateQuickSurface(currentProtected: Bool) -> Bool {
        !currentProtected
    }
}

struct FilePanelProtectedTickFaultLatch {
    private(set) var notified = false

    /// Returns true only on the first protected non-OK tick. Recovery or protection resolution
    /// rearms the edge so a later independent fault is visible again.
    mutating func record(tickSucceeded: Bool, currentProtected: Bool) -> Bool {
        guard !tickSucceeded, currentProtected else {
            notified = false
            return false
        }
        guard !notified else { return false }
        notified = true
        return true
    }
}
