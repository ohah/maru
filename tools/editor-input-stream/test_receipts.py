"""원시 파일을 모사한 독립 기록에서 요청 행렬의 누락과 사후 변경을 검출한다."""
import hashlib
import json
import pathlib
import tempfile
import unittest
import protocol
import verify
import summarize
import review
from test_contract import fixture


class Receipts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.build = self.root/'build'
        self.evidence = self.root/'evidence'
        self.run = self.evidence/'run'
        self.run.mkdir(parents=True)
        self.app, self.producer, self.record = fixture()
        data = protocol.fixture(3000)
        digest = hashlib.sha256(data[3:]).hexdigest()
        self.record.update(size=3000, flow='typing', repeat=0, app_exit=0, producer_exit=0,
                           disk_unchanged=True, error=None, fixture_bytes=len(data),
                           fixture_sha256=hashlib.sha256(data).hexdigest(), fixture_tail_sha256=digest)
        self.record.update(provider_before=dict(a=None,b=None,c=None),provider_after=dict(a=None,b=None,c=None))
        self.app['baseline'][5] = len(data)
        self.app['state'][5] = len(data)+4
        self.app['initial_tail_sha256'] = digest
        self.write(self.run/'document.zig', data)
        self.dump(self.run/'app.json', self.app)
        self.dump(self.run/'posts.json', self.producer)
        self.dump(self.run/'ready.json', dict(pid=200, count=4, source='com.apple.keylayout.ABC', initial_tail_sha256=digest))
        self.dump(self.run/'source-record.json', dict(pid=200, original='original', selected='com.apple.keylayout.ABC'))
        self.dump(self.run/'source-recovery.json', dict(exit=0, status='restored_in_app'))
        for name in ['app.log', 'producer.log', 'config']:
            self.write(self.run/name, b'receipt\n')
        self.record['validation'] = verify.classify(self.app, self.producer, self.record)
        for name in ['app.json','posts.json','app.log','producer.log','config','ready.json','source-record.json','source-recovery.json']:
            self.record[name+'_sha256'] = verify.sha(self.run/name)
        self.dump(self.run/'record.json', self.record)
        for name in ['source/zig-out/Maru.app/Contents/MacOS/maru-macos-app', 'producer', 'producer.swift', 'source/witness']:
            self.write(self.build/name, name.encode())
        source = dict(harness=protocol.NAME, optimize='ReleaseFast', head='fixture',
                      app_sha256=verify.sha(self.build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'),
                      producer_sha256=verify.sha(self.build/'producer'), producer_source_sha256=verify.sha(self.build/'producer.swift'),
                      instrumented={'witness':verify.sha(self.build/'source/witness')})
        self.manifest = dict(schema=1, protocol=protocol.NAME, build=str(self.build), source=source,
                             sizes=[3000], periods=[100], flows=['typing'], modes=['async'], repetitions=1, count=4,
                             kind='normal', verifier_sha256=verify.sha(verify.__file__),
                             runs=[dict(path='run', record_sha256=verify.sha(self.run/'record.json'))])
        self.dump(self.evidence/'manifest.json', self.manifest)

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def dump(self, path, value):
        path.write_text(json.dumps(value))

    def read(self):
        return verify.read(self.evidence)

    def test_control(self):
        self.assertEqual(len(self.read()['runs']), 1)

    def test_summary_includes_first_and_all_inputs(self):
        row = summarize.summarize(self.evidence)['conditions'][0]
        self.assertEqual(row['post_to_present_ms'], dict(count=4,median=4,p95=104,maximum=104))
        self.assertEqual(row['coalesced_keys'], 1)
        self.assertEqual(row['memory_per_process_bytes'],[dict(peak=200,baseline_resident=170,final_resident=180)])

    def test_raw_semantic_review_preserves_control(self):
        result=review.review(self.evidence,self.root/'review')
        self.assertEqual(len(result['rejected']),24)
        self.assertEqual(result['normal_controls'],48)

    def test_binary_drift(self):
        self.write(self.build/'producer', b'changed')
        with self.assertRaisesRegex(ValueError, 'producer drift'): self.read()

    def test_private_source_drift(self):
        self.write(self.build/'source/witness', b'changed')
        with self.assertRaisesRegex(ValueError, 'instrumentation drift'): self.read()

    def test_raw_receipt_drift(self):
        self.write(self.run/'app.log', b'changed')
        with self.assertRaisesRegex(ValueError, 'receipt drift'): self.read()

    def test_missing_matrix_member(self):
        self.manifest['modes'].append('sync')
        self.dump(self.evidence/'manifest.json', self.manifest)
        with self.assertRaisesRegex(ValueError, 'incomplete matrix'): self.read()

    def test_duplicate_run(self):
        self.manifest['runs'] *= 2
        self.dump(self.evidence/'manifest.json', self.manifest)
        with self.assertRaisesRegex(ValueError, 'incomplete matrix'): self.read()

    def test_summary_tampering(self):
        self.record['validation']['first_frames'] = 0
        self.dump(self.run/'record.json', self.record)
        self.manifest['runs'][0]['record_sha256'] = verify.sha(self.run/'record.json')
        self.dump(self.evidence/'manifest.json', self.manifest)
        with self.assertRaisesRegex(ValueError, 'derived metrics drift'): self.read()

    def test_profiled_run_cannot_enter_baseline(self):
        self.record['diagnostic']=True
        self.dump(self.run/'record.json',self.record)
        self.manifest['runs'][0]['record_sha256']=verify.sha(self.run/'record.json')
        self.dump(self.evidence/'manifest.json',self.manifest)
        with self.assertRaisesRegex(ValueError,'diagnostic cohort'): self.read()

    def test_path_escape(self):
        self.manifest['runs'][0]['path'] = '../build'
        self.dump(self.evidence/'manifest.json', self.manifest)
        with self.assertRaisesRegex(ValueError, 'run path escape'): self.read()


if __name__ == '__main__': unittest.main()
