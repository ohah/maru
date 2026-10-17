#!/usr/bin/env python3
"""Run the external-copy AppKit experiment and retain failures as failures."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import hashlib
import subprocess
import time

from partial_order import adoption_order, validate_order_evidence

PARTIAL_CLOSE_PATTERN = r'^session host closed client connection: slot=\d+ reason=client_closing why=socket_error site=ended_purge_tracker err=PartialFrame(?: |$)'


def validate_quit_evidence(evidence, identities):
    """A normal exit alone is insufficient: verify runtime identity and all cleanup counters."""
    identity = evidence['identity']
    for field in ('host_id', 'runtime_id', 'host_pid', 'child_pid'):
        if not identity[field + '_before'] or identity[field + '_before'] != identity[field + '_after']:
            raise RuntimeError('healthy runtime identity changed: ' + field)
    if identity['runtime_id_after'] != identities['healthy'] or identity['host_id_after'] != identities['host_id']:
        raise RuntimeError('wrong healthy runtime or host was verified')
    cleanup = evidence['cleanup']
    for field in ('worker', 'jobs', 'completion', 'cr5_jobs', 'admissions', 'resident_leases', 'backend_runtimes', 'clients', 'fds', 'child_processes_remaining'):
        if cleanup[field] != 0:
            raise RuntimeError('cleanup remains: ' + field)
    if cleanup['fd_before'] != cleanup['fd_after'] or not all(cleanup[k] for k in ('daemon_reaped', 'socket_removed', 'host_artifacts_removed')):
        raise RuntimeError('owned host cleanup is incomplete')


def validate_gui_evidence(evidence, identities, text, order):
    # Recheck raw reproduction evidence when judging saved artifacts as well as live runs.
    if not re.search(PARTIAL_CLOSE_PATTERN, text, re.M):
        raise RuntimeError('missing actual ended-purge PartialFrame diagnosis')
    if evidence['schema'] != 'maru.session-host-partial-appkit-experiment.v1':
        raise RuntimeError('baseline or nonvisual artifact cannot prove the partial GUI experiment')
    validate_quit_evidence(evidence, identities)
    validate_order_evidence(text, identities, order)
    required = {'historical_before_count', 'historical_after_count', 'disconnect_after_count',
                'input_count', 'copy_count', 'resize_count'}
    continuity = evidence['continuity']
    if set(continuity) != required or any(type(value) is not int or value != 1 for value in continuity.values()):
        raise RuntimeError('incomplete AppKit continuity evidence')
    if evidence['sibling'] != dict(runtime_id=identities['target'], live_before=True, live_after=False,
                                   controller_before=True, controller_after=False):
        raise RuntimeError('target termination projection is incomplete')
    timestamps = evidence['input_frame']
    if not 0 < timestamps['dispatch_ns'] < timestamps['submit_ns'] or timestamps['latency_ns'] != timestamps['submit_ns'] - timestamps['dispatch_ns']:
        raise RuntimeError('input did not precede the submitted Metal frame')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--snapshot', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--reuse-completed-fixture', action='store_true')
    args = ap.parse_args()
    snapshot = Path(args.snapshot).resolve()
    output = Path(args.output).resolve()
    if output.exists():
        raise RuntimeError('preserve existing run evidence; use a new output directory')
    if not (snapshot / 'partial-source.json').is_file():
        raise RuntimeError('snapshot was not prepared for this experiment')
    manifest = json.loads((snapshot / 'partial-source.json').read_text())
    order = adoption_order(manifest)
    nonvisual_diagnostic = manifest.get('nonvisual_diagnostic', False)
    for name, digest in manifest.get('source_hashes', {}).items():
        if hashlib.sha256((snapshot / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('prepared source changed: ' + name)
    for name, digest in manifest['binary_hashes'].items():
        if hashlib.sha256((snapshot / 'zig-out/Maru.app/Contents/MacOS' / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('prepared binary changed: ' + name)
    screen = subprocess.check_output(['swift', '-e', 'import CoreGraphics; print((CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as Any)'], text=True)
    if screen.strip() != 'nil' and not nonvisual_diagnostic:
        raise RuntimeError('screen is locked or lock state is unrecognized: ' + screen.strip())
    spec = importlib.util.spec_from_file_location('pressure', snapshot / 'tools/test-runtime-end-pressure.py')
    pressure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pressure)
    output.mkdir(parents=True)
    home = snapshot / 'zig-out/maru-macos-app/session-host-cr6e-c3c-home'
    previous_identity_bytes = None
    # A previous gate removes this dedicated fixture root. Never accept stale identity markers.
    if home.exists():
        if not args.reuse_completed_fixture:
            raise RuntimeError('use a fresh prepared snapshot or explicitly reuse a completed fixture')
        previous = json.loads((home / 'partial-identities.json').read_text())
        previous_identity_bytes = (home / 'partial-identities.json').read_bytes()
        summary = (snapshot / 'zig-out/maru-macos-app/app.summary.txt').read_text()
        if Path(previous['socket']).exists() or 'session_host_reconnect_final_backend_runtimes=0\n' not in summary:
            raise RuntimeError('previous owned fixture has not completed teardown')
        processes = subprocess.check_output(['ps', '-axww', '-o', 'pid=,comm='], text=True)
        for line in processes.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1].startswith(str(snapshot) + '/'):
                raise RuntimeError('an executable from the previous snapshot is still running: ' + parts[0])
    env = dict(os.environ, MARU_PARTIAL_GUI='1')
    if nonvisual_diagnostic:
        env['MARU_PARTIAL_NONVISUAL_DIAGNOSTIC'] = '1'
    result = {'schema': 'maru.partial-gui-run.v1', 'partial_frame_verified': False,
              'gui_gate_exit': None, 'error': None,
              'validation_scope': 'nonvisual_appkit_diagnostic' if nonvisual_diagnostic else 'actual_appkit_gui',
              'gui_continuity_verified': False,
              'screen_lock_at_launch': screen.strip(), 'adoption_order': order, 'canonical_order_verified': False}
    with (output / 'gate.log').open('wb') as log:
        gate = subprocess.Popen(['zig', 'build', 'macos-session-host-cr6e-c3c-appkit',
                                 '-Doptimize=' + manifest.get('build_mode', 'ReleaseFast'), '-j8'], cwd=snapshot, env=env,
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        awake = subprocess.Popen(['/usr/bin/caffeinate', '-d', '-w', str(gate.pid)],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            def wait(predicate, timeout=15):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    value = predicate()
                    if value:
                        return value
                    if gate.poll() is not None:
                        raise RuntimeError('GUI gate ended before the expected observation')
                    time.sleep(.01)
                raise TimeoutError('GUI experiment observation deadline expired')

            def fresh_identity():
                path = home / 'partial-identities.json'
                try:
                    raw = path.read_bytes()
                    return raw != previous_identity_bytes and bool(json.loads(raw))
                except (FileNotFoundError, json.JSONDecodeError):
                    return False
            wait(fresh_identity, 240)
            identities = json.loads((home / 'partial-identities.json').read_text())
            result['identities'] = identities
            endpoint = Path(identities['socket'])
            if endpoint.name != identities['host_id'] + '.sock' or not str(endpoint.parent.parent).startswith('/tmp/maru-product-test-'):
                raise RuntimeError('unexpected fixture endpoint')
            # This fixture forks the daemon in-process; it inherits fd 2 and deliberately never
            # executes the CLI's redirectStderrToHostLog. The real host diagnosis is in gate.log.
            host_log = output / 'gate.log'
            wait(lambda: (home / 'partial-paused').exists())
            (home / 'partial-dense').touch(exist_ok=False)

            def dense_snapshot():
                peer = pressure.Peer(endpoint)
                try:
                    if peer.hello['host_id'] != identities['host_id']:
                        raise RuntimeError('host identity mismatch')
                    attachment = peer.call('runtime.attach', dict(runtime_id=identities['target'], mode='observer'))
                    snapshot_bytes = peer.snapshot(attachment['stream_id'])
                    return len(snapshot_bytes) if len(snapshot_bytes) > 500000 else 0
                finally:
                    peer.close()
            result['dense_snapshot_bytes'] = wait(dense_snapshot)
            (home / 'partial-resync').touch(exist_ok=False)
            wait(lambda: (home / 'partial-resync-sent').exists() or (home / 'partial-resync-error').exists())
            if (home / 'partial-resync-error').exists():
                raise RuntimeError('product resync request failed before the runtime termination')
            # The RPC reply precedes the producer's later turn. This delay only induces scheduling;
            # success still requires the real host's exact PartialFrame close diagnosis below.
            time.sleep(.2)
            pressure.terminate(endpoint, identities['target'])
            wait(lambda: re.search(PARTIAL_CLOSE_PATTERN, host_log.read_text(), re.M), 5)
            shutil.copy2(host_log, output / 'host-at-partial-frame.log')
            result['partial_frame_verified'] = True
            (home / 'partial-release').touch(exist_ok=False)
            (home / 'c3c-after-disconnect-output').touch(exist_ok=False)
        except Exception as error:
            result['error'] = str(error)
            if 'host_log' in locals() and host_log.exists():
                shutil.copy2(host_log, output / 'host-at-failure.log')
        finally:
            # Release scheduling even on a failed reproduction; let the owned harness exercise its
            # ordinary timeout/teardown. Never shut down a user app or shared session-host namespace.
            if home.exists():
                (home / 'partial-release').touch(exist_ok=True)
            try:
                result['gui_gate_exit'] = gate.wait(timeout=90)
            except subprocess.TimeoutExpired:
                # Do not kill a process tree whose identities were not independently enumerated.
                result['error'] = 'owned gate did not finish; inspect exact child identities before cleanup'
            if gate.poll() is not None:
                awake.wait(timeout=5)
            for source in [home / 'partial-identities.json', snapshot / 'partial-source.json',
                           snapshot / 'zig-out/maru-macos-app/app.summary.txt',
                           snapshot / 'tests/artifacts/session-host/cr6e-c3c-appkit.json']:
                if source.exists():
                    shutil.copy2(source, output / source.name)
            captures = home / 'captures'
            if captures.exists():
                shutil.copytree(captures, output / 'captures')
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if nonvisual_diagnostic and result['error'] is None and result['gui_gate_exit'] == 0 and result['partial_frame_verified']:
        try:
            evidence = json.loads((output / 'cr6e-c3c-appkit.json').read_text())
            if evidence['schema'] != 'maru.session-host-partial-nonvisual-diagnostic.v1':
                raise RuntimeError('wrong nonvisual diagnostic artifact')
            validate_quit_evidence(evidence, identities)
            validate_order_evidence((output / 'gate.log').read_text(), identities, order)
            result['canonical_order_verified'] = True
            result['normal_quit_verified'] = True
            result['healthy_pid_preserved_through_quit'] = True
        except Exception as error:
            result['error'] = str(error)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if not nonvisual_diagnostic and result['error'] is None and result['gui_gate_exit'] == 0 and result['partial_frame_verified']:
        try:
            evidence = json.loads((output / 'cr6e-c3c-appkit.json').read_text())
            validate_gui_evidence(evidence, identities, (output / 'gate.log').read_text(), order)
            result['canonical_order_verified'] = True
            result['gui_continuity_verified'] = True
        except Exception as error:
            result['error'] = str(error)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    if result['error'] is not None or not result['partial_frame_verified'] or result['gui_gate_exit'] != 0:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
