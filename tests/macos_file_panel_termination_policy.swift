@main
struct FilePanelTerminationPolicyTests {
    static func main() {
        // Active clean normal + inactive protected normal/quick: protected identity wins.
        precondition(FilePanelTerminationPolicy.firstProtectedIndex([false, true, false]) == 1)
        precondition(FilePanelTerminationPolicy.firstProtectedIndex([false, false, true]) == 2)
        precondition(FilePanelTerminationPolicy.firstProtectedIndex([false, false]) == nil)

        // Current protected fault/SessionEnded is retained; clean fault keeps legacy teardown.
        precondition(FilePanelTerminationPolicy.shouldHoldCurrentSurface(tickSucceeded: false, currentProtected: true))
        precondition(!FilePanelTerminationPolicy.shouldHoldCurrentSurface(tickSucceeded: false, currentProtected: false))
        precondition(!FilePanelTerminationPolicy.shouldHoldCurrentSurface(tickSucceeded: true, currentProtected: true))

        // A protected quick cannot be recreated merely to apply chrome/minimal-tabs config.
        precondition(!FilePanelTerminationPolicy.mayRecreateQuickSurface(currentProtected: true))
        precondition(FilePanelTerminationPolicy.mayRecreateQuickSurface(currentProtected: false))

        var faultLatch = FilePanelProtectedTickFaultLatch()
        precondition(faultLatch.record(tickSucceeded: false, currentProtected: true))
        for _ in 0..<100 {
            precondition(!faultLatch.record(tickSucceeded: false, currentProtected: true))
        }
        precondition(!faultLatch.record(tickSucceeded: true, currentProtected: true))
        precondition(faultLatch.record(tickSucceeded: false, currentProtected: true))
        precondition(!faultLatch.record(tickSucceeded: false, currentProtected: false))
        precondition(faultLatch.record(tickSucceeded: false, currentProtected: true))
    }
}
