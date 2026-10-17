#!/usr/bin/env python3
"""Prepare an external source copy for the two-runtime partial-frame AppKit experiment.

The copy reuses CR6e-c3c actions and read projections. Its artifact has a distinct
schema: the sibling is deliberately terminated, so the baseline validator must
never accept it. No fault gate is compiled into the source checkout's product.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from prepare import replace_once
from partial_order import configure_adoption_order


def write_manifest(repo, snapshot, optimize, nonvisual_diagnostic, adoption_order="target-first"):
    """Fingerprint the finished source copy and signed binaries, including after a rebuild."""
    names = ['src/platform/macos/session_host/remote_term_backend.zig',
             'src/platform/macos/session_host/client_slot.zig',
             'src/platform/macos/session_host/framing.zig',
             'src/platform/macos/session_host/client.zig',
             'src/platform/macos/session_host/reconnect_reducer.zig',
             'src/platform/macos/session_host/host_reconnect_runtime_transaction.zig',
             'tools/remote-restart-app/partial_order.py',
             'src/platform/macos/session_host/remote_runtime.zig',
             'src/platform/macos/session_host/cr6c_appkit_smoke.zig',
             'src/platform/macos/MaruAppHost.swift', 'src/platform/macos/app_session.zig',
             'build.zig', 'tools/remote-restart-app/partial_target.py']
    manifest = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
                'schema': 'maru.partial-gui-source-copy.v2', 'adoption_order': adoption_order, 'build_mode': optimize,
                'nonvisual_diagnostic': nonvisual_diagnostic,
                'source_hashes': {n: hashlib.sha256((snapshot / n).read_bytes()).hexdigest() for n in names},
                'binary_hashes': {n: hashlib.sha256((snapshot / 'zig-out/Maru.app/Contents/MacOS' / n).read_bytes()).hexdigest()
                                 for n in ['maru', 'maru-macos-app']}}
    (snapshot / 'partial-source.json').write_text(json.dumps(manifest, indent=2) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--snapshot', required=True)
    ap.add_argument('--dependency-root', required=True)
    ap.add_argument('--optimize', choices=['Debug', 'ReleaseFast'], default='ReleaseFast')
    ap.add_argument('--nonvisual-diagnostic', action='store_true')
    ap.add_argument('--adoption-order', choices=['target-first', 'healthy-first'], default='target-first')
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    snapshot = Path(args.snapshot).resolve()
    if snapshot.exists() or snapshot.is_relative_to(repo):
        raise RuntimeError('use a new external snapshot path')
    dependency = Path(args.dependency_root).resolve()
    for name in ('web/package.json', 'web/bun.lock'):
        if (repo / name).read_bytes() != (dependency / name).read_bytes():
            raise RuntimeError('dependency snapshot mismatch: ' + name)
    snapshot.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache',
                    '--exclude=zig-out', '--exclude=node_modules', '--exclude=references',
                    '--exclude=.env*', str(repo) + '/', str(snapshot) + '/'], check=True)
    (snapshot / 'web/node_modules').symlink_to(dependency / 'web/node_modules', target_is_directory=True)

    def edit(name, old, new):
        path = snapshot / name
        path.write_text(replace_once(path.read_text(), old, new))

    backend = 'src/platform/macos/session_host/remote_term_backend.zig'
    path = snapshot / backend
    path.write_text(path.read_text() + '\n' + (repo / 'tools/remote-restart-app/partial_backend.zig.inc').read_text())
    edit(backend, '    pub fn maintenanceEventTick(self: *RemoteTermBackend) void {',
         '    pub fn maintenanceEventTick(self: *RemoteTermBackend) void {\n        if (partialGuiReceivePaused()) return;')
    edit(backend, '    fn drainRemoteNow(rr: *RemoteRuntime) DrainSummary {',
         '    fn drainRemoteNow(rr: *RemoteRuntime) DrainSummary {\n        if (partialGuiReceivePaused()) return .{};')
    edit('src/platform/macos/app_session.zig', '    defer backend.maintenanceEventTick();',
         '    if (session_host.remote_term_backend.partialGuiBeforeCoordinator(backend)) return .idle;\n    defer backend.maintenanceEventTick();')
    runtime = 'src/platform/macos/session_host/remote_runtime.zig'
    edit(runtime, '''    ) client_mod.ClientError!void {
        switch (self.currentGeneration().connection) {
            .legacy => |client| try client.ingestReadableOutOfBandEvidence(),''', '''    ) client_mod.ClientError!void {
        if (@import("remote_term_backend.zig").partialGuiReceivePaused()) return error.AdminBusy;
        switch (self.currentGeneration().connection) {
            .legacy => |client| try client.ingestReadableOutOfBandEvidence(),''')
    edit(runtime, '    pub fn resizeWithCell(self: *RemoteRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) ResizeError!void {',
         '    pub fn resizeWithCell(self: *RemoteRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) ResizeError!void {\n        if (@import("remote_term_backend.zig").partialGuiReceivePaused()) return error.AdminBusy;')
    edit('src/platform/macos/session_host/client_slot.zig',
         '        if (!self.retiredNodeReadyForReclaim(0)) return error.NotReady;\n        const node_digest = retiredClientNodeDigest(node);',
         '''        if (!self.retiredNodeReadyForReclaim(0)) {
            std.debug.print("PARTIAL_RECLAIM valid={} borrows={d} operation={d} rpc_empty={} cleanup_pins={d} active_cleanup={d} client_ready={} parser={d} stream={d} events={d} batches={d} partial={} fd={d} unusable={}\\n", .{
                self.retiredNodeValidAt(0), node.stack_borrows, node.active_operation_generation,
                node.rpc_free_evidence.emptyExact(), node.pin_owner.cleanup_pin_count, node.pin_owner.active_cleanup,
                node.client.canRetireFromGenerationNode(), node.client.parser.bufferedBytes(),
                node.client.screen_inbox.pending_stream.items.len, node.client.pending_events.items.len,
                node.client.screen_inbox.pending_batches.items.len, node.client.screen_inbox.partial_batch != null,
                node.client.fd, node.client.unusable,
            });
            return error.NotReady;
        }
        const node_digest = retiredClientNodeDigest(node);''')

    harness = 'src/platform/macos/session_host/cr6c_appkit_smoke.zig'
    edit(harness, '        const self: *AutoReconnectFault = @ptrCast(@alignCast(context));',
         '        const self: *AutoReconnectFault = @ptrCast(@alignCast(context));\n        if (std.c.getenv("MARU_PARTIAL_GUI") != null) return .continue_serving;')
    # Keep the target's ordinary initial marker, then emit dense PTY output only on the actor's file.
    target = snapshot / 'tools/remote-restart-app/partial_target.py'
    target.write_text('''import os, sys, time
from pathlib import Path
root = Path(os.environ['MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT'])
print('CR6C-RECOVERED-MARKER\\nCR6E-C3C-SIBLING-LIVE', flush=True)
while not (root / 'partial-dense').exists(): time.sleep(.01)
sys.stdout.write('\\x1b[H' + ''.join(chr(33+j%90) for j in range(200*120)))
sys.stdout.flush()
while True: time.sleep(1)
''')
    old = r'''"{\"argv\":[\"/bin/sh\",\"-c\",\"printf 'CR6C-RECOVERED-MARKER\\nCR6E-C3C-SIBLING-LIVE\\n'; exec /bin/cat\"],\"cols\":80,\"rows\":24}"'''
    params = json.dumps(dict(argv=['/usr/bin/python3', '-u', str(target)], cols=80, rows=24), separators=(',', ':'))
    edit(harness, old, json.dumps(params))
    edit(harness, '    var params_buf: [80]u8 = undefined;\n    const params = try std.fmt.bufPrint(&params_buf, "{{\\"runtime_id\\":\\"{s}\\"}}", .{&runtime_id});', '''    const partial_identity = try std.fmt.allocPrint(allocator,
        "{{\\"socket\\":\\"{s}\\",\\"host_id\\":\\"{s}\\",\\"target\\":\\"{s}\\",\\"healthy\\":\\"{s}\\"}}", .{ socket, host_text, sibling_runtime_id, runtime_id });
    defer allocator.free(partial_identity);
    const partial_path = try std.fmt.allocPrint(allocator, "{s}/partial-identities.json", .{artifact_root});
    defer allocator.free(partial_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial_path, .data = partial_identity });
    var params_buf: [80]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "{{\\"runtime_id\\":\\"{s}\\"}}", .{&runtime_id});''')
    edit(harness, '    schema: []const u8 = "maru.session-host-cr6e-c3c-appkit.v2",',
         '    schema: []const u8 = "' + ('maru.session-host-partial-nonvisual-diagnostic.v1' if args.nonvisual_diagnostic else 'maru.session-host-partial-appkit-experiment.v1') + '",')
    # A real error envelope is expected for the terminated target; preserve the primary's checks.
    edit(harness, 'sibling_runtime_survived = std.mem.indexOf(u8, sibling_live, &sibling_runtime_id) != null;',
         'sibling_runtime_survived = std.mem.indexOf(u8, sibling_live, "\\"error\\"") != null and std.mem.indexOf(u8, sibling_live, &sibling_runtime_id) == null;')
    edit(harness, 'sibling_controller_zero = std.mem.indexOf(u8, sibling_live, "\\"has_controller\\":false") != null;',
         'sibling_controller_zero = std.mem.indexOf(u8, sibling_live, "\\"error\\"") != null;')
    edit(harness, 'sibling_observer_zero = std.mem.indexOf(u8, sibling_live, "\\"observer_count\\":0") != null;',
         'sibling_observer_zero = std.mem.indexOf(u8, sibling_live, "\\"error\\"") != null;')

    # Read-only resize diagnostics distinguish a missed AppKit resize from a backend rejection.
    edit(backend, '        return rr.resizeWithCell(size.cols, size.rows, cell.width, cell.height);',
         '''        rr.resizeWithCell(size.cols, size.rows, cell.width, cell.height) catch |err| {
            std.debug.print("PARTIAL_GUI_RESIZE runtime={s} cols={d} rows={d} error={s}\\n", .{ rr.runtimeIdHex(), size.cols, size.rows, @errorName(err) });
            return err;
        };
        std.debug.print("PARTIAL_GUI_RESIZE runtime={s} cols={d} rows={d} error=none\\n", .{ rr.runtimeIdHex(), size.cols, size.rows });''')
    swift = 'src/platform/macos/MaruAppHost.swift'
    edit(swift, '                guard armSessionHostAutoReconnectDisconnect() else {',
         '                guard window.firstResponder === view, armSessionHostAutoReconnectDisconnect() else {')
    edit(swift, '''                  probe.async_wake_marker_present != 0,
                  probe.c3c_sibling_live != 0,
                  probe.c3c_sibling_controller != 0 else { return }
            sessionHostAutoReconnectSiblingLiveAfter = true
            sessionHostAutoReconnectSiblingControllerAfter = true''', '''                  probe.async_wake_marker_present != 0 else { return }
            sessionHostAutoReconnectSiblingLiveAfter = probe.c3c_sibling_live != 0
            sessionHostAutoReconnectSiblingControllerAfter = probe.c3c_sibling_controller != 0''')
    edit(swift, '''            guard window.makeFirstResponder(view),
                  sendSessionHostAutoReconnectInput(view: view, window: window) else {''', '''            guard window.firstResponder === view,
                  sendSessionHostAutoReconnectInput(view: view, window: window) else {''')
    edit(swift, '        stage=\(sessionHostRecoverySmokeStage)',
         '        cols=\(probe.cols) rows=\(probe.rows) before_cols=\(sessionHostAutoReconnectColsBefore) before_rows=\(sessionHostAutoReconnectRowsBefore)\n        stage=\(sessionHostRecoverySmokeStage)')
    configure_adoption_order(edit, args.adoption_order)
    if args.nonvisual_diagnostic:
        # Keep capture observations false. Only this separately fingerprinted source copy may
        # advance its diagnostic driver without a drawable; it cannot pass the GUI validator.
        declaration = '    @discardableResult\n    private func captureSessionHostRecoverySmokeFrame(_ label: String, in surface: TerminalSurface) -> Bool {'
        edit(swift, declaration, '''    private var isPartialNonvisualDiagnostic: Bool {
        ProcessInfo.processInfo.environment["MARU_PARTIAL_NONVISUAL_DIAGNOSTIC"] == "1"
    }
''' + declaration + '\n        if isPartialNonvisualDiagnostic { return false }')
        path = snapshot / swift
        text = path.read_text()
        for old, new, count in [
            ('guard sessionHostRecoverySmokeBeforeCapture else', 'guard isPartialNonvisualDiagnostic || sessionHostRecoverySmokeBeforeCapture else', 2),
            ('guard sessionHostRecoverySmokeAfterCapture else', 'guard isPartialNonvisualDiagnostic || sessionHostRecoverySmokeAfterCapture else', 1),
            ('if !sessionHostRecoverySmokeAfterCapture {', 'if !isPartialNonvisualDiagnostic && !sessionHostRecoverySmokeAfterCapture {', 1),
        ]:
            if text.count(old) != count:
                raise RuntimeError('diagnostic capture control changed: ' + old)
            text = text.replace(old, new)
        path.write_text(text)
        # The nonvisual probe tests normal Quit after the current policy retains a failed job.
        # Record that recovery did not finish, but let the owned child exit normally so the outer
        # harness can verify runtime identity, detached authority, and complete host cleanup.
        edit(swift, '''            failSessionHostRecoverySmoke("auto-reconnect-timeout")
            return''', '''            failSessionHostRecoverySmoke("auto-reconnect-timeout")
            if isPartialNonvisualDiagnostic { exitCode = 0 }
            return''')
        edit(harness, '        if (failure.len != 0) return error.InvalidRecoverySummary;',
             '        if (failure.len != 0 and !std.mem.eql(u8, failure, "auto-reconnect-timeout")) return error.InvalidRecoverySummary;')
    edit('build.zig', '        session_host_cr6e_c3c_appkit_step.dependOn(&run_session_host_cr6e_c3c_validator.step);',
         '        session_host_cr6e_c3c_appkit_step.dependOn(&run_session_host_cr6e_c3c.step);')
    # Build only: the actor must be running before the GUI gate is launched.
    subprocess.run(['zig', 'build', 'macos-app-bundle', '-Doptimize=' + args.optimize, '-j8'], cwd=snapshot, check=True)
    write_manifest(repo, snapshot, args.optimize, args.nonvisual_diagnostic, args.adoption_order)


if __name__ == '__main__':
    main()
