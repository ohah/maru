#!/usr/bin/env python3
"""제품 백업 뒤 SIGKILL하고 checkpoint가 없는 새 프로세스에서 복구한다."""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="maru-backup-discovery-") as temporary:
        root = Path(temporary)
        document = root / "document.txt"
        document.write_bytes(b"disk\n")
        env = os.environ.copy()
        env.update({
            "MARU_EDITOR_DISCOVERY_FIXTURE": str(root),
            "MARU_EDITOR_BACKUP_ROOT": str(root / "backups"),
            "MARU_TEST_KEEP_ONLY_PREFIX": "app_session.editor.mod.test.editor backup discovery process ",
            "MARU_EDITOR_DISCOVERY_PHASE": "write",
        })
        with (root / "writer.log").open("wb") as log:
            writer = subprocess.Popen([binary, "--maru-expect-passed=1"], env=env,
                                      stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    pid, status = os.waitpid(writer.pid, os.WUNTRACED | os.WNOHANG)
                    if pid:
                        assert os.WIFSTOPPED(status), (status, (root / "writer.log").read_text())
                        break
                    time.sleep(0.02)
                else:
                    raise TimeoutError("writer did not reach the backup/checkpoint boundary")
                assert "ready_for_kill" in (root / "writer.log").read_text()
                writer.kill()
                assert writer.wait(timeout=10) == -signal.SIGKILL
            finally:
                if writer.poll() is None:
                    writer.kill()
                    writer.wait(timeout=10)
        assert not (root / "checkpoint").exists()
        records = sorted((root / "backups").glob("d-*.bak"))
        assert len(records) == 2, records
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in records}
        assert sorted(len(p.read_bytes().split(b"\n\n", 1)[1]) for p in records) == [0, 7]
        env["MARU_EDITOR_DISCOVERY_PHASE"] = "recover"
        # 원본 파일이 없어도 두 백업을 각각 복구한다. 재시도 역시 동일한 원본을 보존한다.
        document.unlink()
        for _ in range(2):
            result = subprocess.run([binary, "--maru-expect-passed=1"], env=env,
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr
            assert "recovered=true empty_dirty=true independent=true" in result.stderr
            assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in records}
            assert not document.exists()
        print("discovery_process sigkill=true checkpoint_absent=true missing_original=true "
              "independent_copies=true empty_dirty=true sources_preserved=true retry=true")


if __name__ == "__main__":
    main()
