"""Order oracle and source-copy controls; synthetic records are not actual GUI evidence."""
import unittest
import copy
import json
import subprocess
import sys
import tempfile
from run_partial import validate_gui_evidence
from pathlib import Path
from partial_order import adoption_order, validate_order_evidence, configure_adoption_order


class OrderTests(unittest.TestCase):
    identities = dict(host_id='3' * 32, healthy='1' * 32, target='2' * 32)

    def trace(self, order='healthy-first'):
        ids = [self.identities['healthy'], self.identities['target']]
        if order == 'target-first': ids.reverse()
        rows = [f'PARTIAL_GUI_ROW host={self.identities["host_id"]} job=7 index={i} handle={9+i} runtime={rid}'
                for i, rid in enumerate(ids)]
        index = ids.index(self.identities['target'])
        rows.append(f'PARTIAL_GUI_GONE host={self.identities["host_id"]} job=7 index={index} runtime={self.identities["target"]} prior={"published_new" if index else "none"}')
        return ('session host closed client connection: slot=0 reason=client_closing why=socket_error site=ended_purge_tracker err=PartialFrame\n'
                + '\n'.join(rows) + '\n')

    def test_manifest_requires_explicit_version_and_order(self):
        for order in ['healthy-first', 'target-first']:
            self.assertEqual(adoption_order(dict(schema='maru.partial-gui-source-copy.v2', adoption_order=order)), order)
        for manifest in [{}, dict(schema='maru.partial-gui-source-copy.v1', adoption_order='healthy-first'),
                         dict(schema='maru.partial-gui-source-copy.v2'),
                         dict(schema='maru.partial-gui-source-copy.v2', adoption_order='unknown')]:
            with self.assertRaises(RuntimeError): adoption_order(manifest)

    def test_both_orders_require_actual_canonical_identity(self):
        for order in ['healthy-first', 'target-first']:
            validate_order_evidence(self.trace(order), self.identities, order)
        with self.assertRaises(RuntimeError):
            validate_order_evidence(self.trace('target-first'), self.identities, 'healthy-first')
        for changed in [self.trace().replace('job=7', 'job=8', 1),
                        self.trace().replace('handle=10', 'handle=9'),
                        self.trace().replace('runtime=' + '1' * 32, 'runtime=' + '4' * 32),
                        self.trace().replace('host=' + '3' * 32, 'host=' + '4' * 32, 1)]:
            with self.assertRaises(RuntimeError): validate_order_evidence(changed, self.identities, 'healthy-first')

    def test_prior_publication_and_ordered_gone_observation_are_required(self):
        text = self.trace()
        for changed in [text.replace('prior=published_new', 'prior=published_old'),
                        text.replace('prior=published_new', 'prior=frozen_unavailable'),
                        text.replace('index=1 runtime=', 'index=0 runtime='),
                        text.replace('PARTIAL_GUI_GONE ', 'payload PARTIAL_GUI_GONE '),
                        '\n'.join(reversed(text.splitlines())), text + text,
                        text + 'PARTIAL_GUI_ROW malformed\n']:
            with self.assertRaises(RuntimeError): validate_order_evidence(changed, self.identities, 'healthy-first')

    def gui_evidence(self):
        identity = {}
        for key, value in dict(host_id=self.identities['host_id'], runtime_id=self.identities['healthy'], host_pid=123, child_pid=124).items():
            identity[key + '_before'] = identity[key + '_after'] = value
        cleanup = dict.fromkeys(['worker', 'jobs', 'completion', 'cr5_jobs', 'admissions', 'resident_leases',
                                 'backend_runtimes', 'clients', 'fds', 'child_processes_remaining'], 0)
        cleanup.update(fd_before=10, fd_after=10, daemon_reaped=True, socket_removed=True, host_artifacts_removed=True)
        evidence = dict(schema='maru.session-host-partial-appkit-experiment.v1', identity=identity, cleanup=cleanup,
                        continuity=dict.fromkeys(['historical_before_count', 'historical_after_count', 'disconnect_after_count',
                                                  'input_count', 'copy_count', 'resize_count'], 1),
                        sibling=dict(runtime_id=self.identities['target'], live_before=True, live_after=False,
                                     controller_before=True, controller_after=False),
                        input_frame=dict(dispatch_ns=10, submit_ns=20, latency_ns=10))
        return evidence

    def test_gui_oracle_requires_all_continuity_fields_and_cleanup(self):
        evidence = self.gui_evidence()
        validate_gui_evidence(evidence, self.identities, self.trace(), 'healthy-first')
        for mutate in [lambda e: e.update(continuity={}),
                       lambda e: e['continuity'].pop('copy_count'),
                       lambda e: e['continuity'].update(input_count=True),
                       lambda e: e['cleanup'].update(resident_leases=1),
                       lambda e: e['input_frame'].update(dispatch_ns=30),
                       lambda e: e.update(schema='maru.session-host-partial-nonvisual-diagnostic.v1')]:
            broken = copy.deepcopy(evidence); mutate(broken)
            with self.assertRaises(RuntimeError): validate_gui_evidence(broken, self.identities, self.trace(), 'healthy-first')

    def test_artifact_mutator_cli_on_explicit_synthetic_fixture(self):
        with tempfile.TemporaryDirectory(prefix='maru-partial-synthetic-') as raw:
            root = Path(raw)
            (root / 'partial-source.json').write_text(json.dumps(dict(schema='maru.partial-gui-source-copy.v2', adoption_order='healthy-first')))
            (root / 'result.json').write_text(json.dumps(dict(validation_scope='actual_appkit_gui', gui_gate_exit=0,
                gui_continuity_verified=True, canonical_order_verified=True, partial_frame_verified=True,
                error=None, adoption_order='healthy-first', identities=self.identities)))
            (root / 'cr6e-c3c-appkit.json').write_text(json.dumps(self.gui_evidence()))
            (root / 'gate.log').write_text(self.trace())
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('test_partial_oracle.py')),
                                     '--artifact', str(root)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('rejected not_previously_published', result.stdout)
            self.assertIn('rejected empty_continuity', result.stdout)

    def test_source_copy_changes_adoption_and_returns_focus_without_product_write(self):
        repo = Path(__file__).resolve().parents[2]
        names = ['src/platform/macos/MaruAppHost.swift', 'src/platform/macos/session_host/cr6c_appkit_smoke.zig']
        source = {name: (repo / name).read_text() for name in names}
        original = dict(source)
        def edit(name, old, new):
            self.assertEqual(source[name].count(old), 1, old)
            source[name] = source[name].replace(old, new)
        configure_adoption_order(edit, 'healthy-first')
        swift = source[names[0]]
        self.assertIn('partialHealthyFocusReturned', swift)
        self.assertIn('keyCode: 33, characters: "[", modifiers: [.command, .shift]', swift)
        self.assertIn('probe.c3c_historical_count == 1', swift)
        for name in names: self.assertEqual((repo / name).read_text(), original[name])
        unchanged = dict(original)
        configure_adoption_order(lambda *args: self.fail('default order must not patch source'), 'target-first')
        self.assertEqual(original, unchanged)


if __name__ == '__main__': unittest.main()
