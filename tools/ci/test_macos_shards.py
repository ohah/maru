"""Failure controls for graph coverage, trust decisions and partial reruns."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import macos_shards as m


class Shards(unittest.TestCase):
    def setUp(self):
        self.env = dict(GITHUB_EVENT_NAME='pull_request', GITHUB_REF='refs/pull/1/merge',
                        GITHUB_SHA='head', GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
                        WORKERS_RESULT='success', CHANGES_RESULT='success', RUNTIME_CHANGED='true')
        self.plans = [dict(schema=1, shard=i, count=3, catalog=['a', 'b', 'c'],
                           selected=[chr(97+i)], compile_artifacts=1, warm_test_runs=0) for i in range(3)]
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)

    def report(self, i, data, attempt=1, mode='test'):
        return dict(schema=1, shard=i, mode=mode, head='head', run_id='123', run_attempt=attempt,
                    result='success', manifest_sha256=m.sha(data),
                    stages=[dict(name=n, result='success', seconds=0.1) for n, _ in m.sequence(i, mode)])

    def write(self, i, attempt=1, mode='test'):
        p = self.directory / f'macos-only-shard-{i}-attempt-{attempt}'
        p.mkdir(parents=True)
        data = json.dumps(self.plans[i]).encode()
        (p/'macos-only-manifest.json').write_bytes(data)
        (p/'macos-only-receipt.json').write_text(json.dumps(self.report(i, data, attempt, mode)))
        return p

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            m.verify(self.directory, self.env)

    def test_trust_matrix(self):
        trusted = ['push', 'refs/heads/main', 'true', 'success']
        self.assertEqual(m.mode_for(*trusted), 'compile')
        for field, values in enumerate([['pull_request', 'workflow_dispatch', ''], ['refs/heads/topic', '', 'refs/pull/1/merge'], ['false', '', 'TRUE'], ['failure', 'skipped', 'cancelled', '']]):
            for value in values:
                with self.subTest(field=field, value=value):
                    args = trusted.copy(); args[field] = value
                    self.assertEqual(m.mode_for(*args), 'test')

    def test_all_extra_gates_once(self):
        actual = [n for i in range(3) for n, _ in m.sequence(i, 'test') if n != 'native-gates']
        self.assertEqual(len(actual), 12)
        self.assertEqual(len(set(actual)), 12)
        self.assertEqual(set(actual), {x[2] for x in m.EXTRAS})
        for i in range(3):
            self.assertEqual(len(m.sequence(i, 'compile')), 1)
            self.assertIn('compile-macos-only', m.sequence(i, 'compile')[0][1])
            self.assertIn(f'-Dmacos-only-shard={i}/3', m.sequence(i, 'test')[0 if i else 1][1])
        for index in [-1, 3, True, '1']:
            with self.assertRaises(ValueError): m.sequence(index, 'test')

    def test_coverage(self):
        full = dict(self.plans[0], shard=None, count=1, selected=['a', 'b', 'c'])
        self.assertEqual(m.coverage(self.plans, full), 3)
        mutations = [('missing', lambda p: p.pop()), ('overlap', lambda p: p[1].update(selected=['a'])),
                     ('catalog', lambda p: p[1].update(catalog=['a','b','c','d'])),
                     ('order', lambda p: p.reverse()), ('empty', lambda p: p[0].update(selected=[]))]
        for name, mutate in mutations:
            with self.subTest(name=name):
                plans=copy.deepcopy(self.plans); mutate(plans)
                with self.assertRaises(ValueError): m.coverage(plans)
        full['selected']=['a']
        with self.assertRaises(ValueError): m.coverage(self.plans, full)

    def test_manifest_rejections(self):
        for key, value in [('schema',True), ('schema',2), ('shard',True), ('count',True), ('count',4),
                           ('selected',['z']), ('selected',['a','a']), ('catalog',['c','b','a']),
                           ('catalog',[]), ('catalog',[1]), ('compile_artifacts',0),
                           ('compile_artifacts',True), ('warm_test_runs',1), ('warm_test_runs',False)]:
            with self.subTest(key=key, value=value):
                plan=dict(self.plans[0]); plan[key]=value
                with self.assertRaises(ValueError): m.manifest(plan, 0)

    def test_receipt_rejections(self):
        data=json.dumps(self.plans[0]).encode(); valid=self.report(0,data)
        m.receipt(valid,data,0,'test','head','123',1)
        for key,value in [('schema',True), ('shard',True), ('mode','compile'), ('head','stale'),
                          ('run_id','other'), ('run_attempt',2), ('run_attempt',True),
                          ('result','failed'), ('manifest_sha256','wrong'), ('stages',[]), ('stages',[None])]:
            with self.subTest(key=key):
                report=copy.deepcopy(valid); report[key]=value
                with self.assertRaises(ValueError): m.receipt(report,data,0,'test','head','123',1)
        for field,value in [('result','failed'),('seconds',-1),('seconds',True),('seconds',float('nan')),('seconds',float('inf'))]:
            with self.subTest(field=field,value=value):
                report=copy.deepcopy(valid); report['stages'][0][field]=value
                with self.assertRaises(ValueError): m.receipt(report,data,0,'test','head','123',1)

    def test_aggregate_requires_worker_success(self):
        for state in ['failed','failure','cancelled','skipped','']:
            with self.subTest(state=state):
                self.env['WORKERS_RESULT']=state
                with self.assertRaises(ValueError): self.verify()
        self.env.update(CHANGES_RESULT='success', RUNTIME_CHANGED='false', WORKERS_RESULT='skipped')
        self.verify()
        self.env['WORKERS_RESULT']='success'
        with self.assertRaises(ValueError): self.verify()
        self.env.update(CHANGES_RESULT='failure', WORKERS_RESULT='skipped')
        with self.assertRaises(ValueError): self.verify()

    def test_partial_rerun(self):
        for i in range(3): self.write(i)
        self.verify()
        self.write(1,2)
        self.verify()
        (self.directory/'macos-only-shard-1-attempt-1'/'macos-only-receipt.json').write_text('broken prior failure')
        self.verify()
        (self.directory/'macos-only-shard-1-attempt-2'/'macos-only-receipt.json').unlink()
        with self.assertRaises(OSError): self.verify()

    def test_empty_latest_attempt(self):
        for i in range(3): self.write(i)
        (self.directory/'macos-only-shard-1-attempt-2').mkdir()
        with self.assertRaises(OSError): self.verify()

    def test_full_manifest_identity(self):
        for key, value in [('count',True),('count',0),('shard',True),('shard',-1)]:
            with self.subTest(key=key,value=value):
                plan=dict(self.plans[0],shard=None,count=1); plan[key]=value
                with self.assertRaises(ValueError): m.manifest(plan)

    def test_runner_success_and_stale_artifacts(self):
        old=Path.cwd()
        try:
            os.chdir(self.directory)
            out=Path('zig-out'); out.mkdir()
            manifest=out/'macos-only-manifest.json'; report=out/'macos-only-receipt.json'
            manifest.write_text('stale'); report.write_text('stale')
            def child(command):
                if 'test-macos-only' in command:
                    self.assertFalse(manifest.exists())
                    self.assertFalse(report.exists())
                    manifest.write_text(json.dumps(self.plans[1]))
                return subprocess.CompletedProcess(command,0)
            with patch.dict(os.environ,self.env,clear=True), patch.object(m.subprocess,'run',side_effect=child):
                with contextlib.redirect_stdout(io.StringIO()): m.run(1)
            m.receipt(json.loads(report.read_text()),manifest.read_bytes(),1,'test','head','123',2)
        finally: os.chdir(old)

    def test_future_attempt(self):
        for i in range(3): self.write(i,3)
        with self.assertRaises(ValueError): self.verify()

    def test_missing_shard(self):
        self.write(0); self.write(1)
        with self.assertRaises(ValueError): self.verify()

    def test_main_warm_receipts(self):
        for i in range(3): self.write(i, mode='compile')
        with self.assertRaises(ValueError): self.verify()
        self.env.update(GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main', PROVEN_MACOS_ONLY='true')
        self.verify()

    def test_failed_command_never_success(self):
        # Exercise the runner, not merely hand-written receipts.
        old=Path.cwd()
        try:
            os.chdir(self.directory)
            with patch.dict(os.environ,self.env,clear=True), patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],1)):
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(subprocess.CalledProcessError): m.run(0)
            report=json.loads(Path('zig-out/macos-only-receipt.json').read_text())
            self.assertEqual(report['result'],'failed')
            self.assertEqual(len(report['stages']),1)
        finally: os.chdir(old)

    def test_workflow_contract(self):
        # Bun is already pinned for CI; parse YAML rather than matching indentation.
        root=Path(__file__).resolve().parents[2]
        result=subprocess.run(['bun','-e', 'console.log(JSON.stringify(Bun.YAML.parse(await Bun.file(process.argv[1]).text())))', str(root/'.github/workflows/ci.yml')],capture_output=True,text=True,check=True)
        jobs=json.loads(result.stdout)['jobs']; worker=jobs['macos-only-shard']; aggregate=jobs['macos-only-gates']
        self.assertEqual(worker['strategy'],dict(**{'fail-fast':False,'max-parallel':3,'matrix':{'shard':[0,1,2]}}))
        self.assertEqual(aggregate['name'],'macOS-only gates')
        self.assertEqual(aggregate['needs'],['changes','macos-only-shard'])
        self.assertIn('always()',aggregate['if'])
        self.assertEqual(worker['timeout-minutes'],90)
        self.assertNotIn('proven_macos_only',worker['if'])
        caches=[s for s in worker['steps'] if s.get('uses','').startswith('actions/cache/')]
        self.assertEqual(len(caches),2)
        self.assertEqual(caches[0]['with']['key'],caches[1]['with']['key'])
        for step in caches:
            self.assertIn('macos-only-s${{ matrix.shard }}of3-',step['with']['key'])
        self.assertIn("github.event_name == 'push'",caches[1]['if'])
        self.assertIn("github.ref == 'refs/heads/main'",caches[1]['if'])
        uploads=[s for s in worker['steps'] if s.get('uses','').startswith('actions/upload-artifact')]
        self.assertEqual(len(uploads),3)
        paths=uploads[0]['with']['path'].splitlines()
        self.assertEqual({str(Path(p).parent) for p in paths},{'zig-out'})
        self.assertEqual(uploads[0]['with']['name'],'macos-only-shard-${{ matrix.shard }}-attempt-${{ github.run_attempt }}')
        self.assertTrue(all(s['if']=='always()' for s in uploads))


if __name__=='__main__': unittest.main()
