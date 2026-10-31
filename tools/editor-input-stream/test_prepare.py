"""빌드 사본을 동시에 덮었던 실제 사고가 재발하지 않도록 프로세스 잠금을 검사한다."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

FILE = pathlib.Path(__file__).resolve().parents[1]/'editor-input-latency/prepare.py'
SPEC = importlib.util.spec_from_file_location('stream_prepare', FILE)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class Prepare(unittest.TestCase):
    def test_other_process_cannot_own_same_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)/'build'
            lock = prepare.output_lock(output)
            code = 'import importlib.util,sys; s=importlib.util.spec_from_file_location("prepare",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); lock=m.output_lock(sys.argv[2])'
            try:
                result = subprocess.run([sys.executable,'-c',code,str(FILE),str(output)],capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('another preparation owns this output',result.stderr)
            finally:
                lock.close()
            result = subprocess.run([sys.executable,'-c',code,str(FILE),str(output)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_ambiguous_source_anchor_is_rejected(self):
        for value in ['absent','anchor anchor']:
            with self.assertRaises(ValueError): prepare.once(value,'anchor','replacement')
        self.assertEqual(prepare.once('one anchor','anchor','replacement'),'one replacement')


if __name__=='__main__': unittest.main()
