"""Verifier regressions; controlled children are not AppKit evidence."""
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).with_name('run.py')
spec = importlib.util.spec_from_file_location('runner', SOURCE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def states():
    fields = dict(hash='abc', bytes='10', dirty='true', anchor='1', focus='2', wrap='true',
                  folded='1', fold_heads_hash='def', doc_line='3', piece='0', col='1',
                  shared='true', hit_rows='5')
    seed = [dict(fields, view=str(v), label='0') for v in range(2)]
    restore = [dict(fields, view=str(v), label=str(label)) for label in range(20, 24) for v in range(2)]
    return [dict(phase='seed', states=seed), dict(phase='restore', states=restore)]


class RunnerTests(unittest.TestCase):
    def test_restore_corruption(self):
        self.assertEqual(runner.compare_states('control', states()), [])
        for field in ('hash', 'bytes', 'dirty', 'anchor', 'focus', 'wrap', 'folded',
                      'fold_heads_hash', 'doc_line', 'piece', 'col', 'shared', 'hit_rows'):
            with self.subTest(field=field):
                data = states()
                data[1]['states'][0][field] = '0' if field == 'hit_rows' else 'corrupt'
                self.assertTrue(runner.compare_states(field, data))
        for count in ('-1', '-999'):
            data = states()
            data[1]['states'][0]['hit_rows'] = count
            self.assertTrue(runner.compare_states(count, data))
        for kind in ('missing', 'duplicate'):
            data = states()
            if kind == 'missing':
                data[1]['states'].pop()
            else:
                data[1]['states'][-1] = copy.deepcopy(data[1]['states'][0])
            self.assertTrue(runner.compare_states(kind, data))

    def test_backup_and_process_guards_under_optimization(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            app = base / 'child'
            app.write_text('''#!/usr/bin/env python3
import os,time,sys
from pathlib import Path
p=Path(os.environ['MARU_SHARED_RESTORE_OUTPUT'])
(p/'child.pid').write_text(str(os.getpid()))
(p/'frame.ppm').write_bytes(bytes([80,54,10,49,32,49,10,50,53,53,10,0,0,0]))
print('SHARED_CLOSE event=one_closed count=1 hash=abc dirty=true',flush=True)
end=time.monotonic()+5
while time.monotonic()<end and not (p/'one-close-verified').exists(): time.sleep(.01)
print('SHARED_RESTORE_FINISH success=true',flush=True)
sys.exit(7)
''')
            app.chmod(0o700)
            for optimized in (False, True):
                for backup in ('missing', 'extra', 'wrong', 'valid'):
                    with self.subTest(optimized=optimized, backup=backup):
                        root = base / f'{optimized}-{backup}'
                        root.mkdir()
                        (root/'home').mkdir()
                        (root/'backups').mkdir()
                        (root/'config').write_text('')
                        (root/'sample.zig').write_bytes(b'original')
                        if backup != 'missing':
                            body = b'wrong' if backup == 'wrong' else '// 미저장 복원 검증\n'.encode()+b'original'
                            (root/'backups/a.bak').write_bytes(b'header\n\n'+body)
                        if backup == 'extra':
                            (root/'backups/b.bak').write_bytes(b'header\n\n'+body)
                        script = ('import importlib.util; from pathlib import Path; '
                                  f's=importlib.util.spec_from_file_location("r",{str(SOURCE)!r}); '
                                  'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                                  f'm.run(Path({str(app)!r}),Path({str(root)!r}),"close",Path({str(root / "sample.zig")!r}))')
                        result = subprocess.run([sys.executable]+(['-O'] if optimized else [])+['-c',script],
                                                capture_output=True, timeout=15)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(b'AssertionError', result.stderr)
                        self.assertEqual((root/'close/one-close-verified').exists(), backup == 'valid')
                        pid = int((root/'close/child.pid').read_text())
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)

    def test_git_discovery_environment_isolation(self):
        clean = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        with tempfile.TemporaryDirectory() as temp:
            outer = Path(temp)/'outer'
            outer.mkdir()
            subprocess.run(['git','init','--quiet',str(outer)], env=clean, check=True)
            config = (outer/'.git/config').read_bytes()
            overrides = {'GIT_DIR':str(outer/'.git'), 'GIT_WORK_TREE':str(outer),
                         'GIT_COMMON_DIR':str(outer/'.git'), 'GIT_INDEX_FILE':str(outer/'foreign-index')}
            previous = dict(os.environ)
            try:
                os.environ.update(overrides)
                for key in overrides:
                    root = outer/key
                    root.mkdir()
                    runner.prepare_lsp_root(root)
                    top = subprocess.check_output(['git','-C',str(root),'rev-parse','--show-toplevel'],env=clean,text=True).strip()
                    self.assertEqual(Path(top).resolve(),root.resolve())
                    self.assertEqual((root/'lsp-trust').read_text(),f'allow\t{root}\n')
                for key,value in overrides.items(): self.assertEqual(os.environ[key],value)
                self.assertEqual((outer/'.git/config').read_bytes(),config)
                self.assertFalse((outer/'foreign-index').exists())
            finally:
                os.environ.clear()
                os.environ.update(previous)


if __name__ == '__main__':
    unittest.main()
