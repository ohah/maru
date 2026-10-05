#!/usr/bin/env python3
"""실제 AppSession 저장·복원을 독립 프로세스로 실행한다. 사용자 저장소를 사용하지 않는다."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="maru-editor-recovery-process-") as temporary:
        root = Path(temporary)
        (root / "document.txt").write_text("disk\n")
        env = os.environ.copy()
        env.update({
            "MARU_EDITOR_RECOVERY_FIXTURE": str(root),
            "MARU_EDITOR_BACKUP_ROOT": str(root / "backups"),
            "MARU_TEST_KEEP_ONLY_PREFIX": "app_session.editor.mod.test.editor recovery restore process ",
        })

        def run(phase):
            env["MARU_EDITOR_RECOVERY_PHASE"] = phase
            result = subprocess.run([binary, "--maru-expect-passed=1"], env=env,
                                    capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(f"{phase}: {result.stdout}\n{result.stderr}")
            for line in result.stderr.splitlines():
                if "recovery_process phase=" in line:
                    print(line[line.index("recovery_process phase="):])

        run("write")
        records = sorted((root / "backups").glob("d-*.bak"))
        assert len(records) == 2, records
        before = {str(path): digest(path) for path in records}
        checkpoint = root / "checkpoint"
        checkpoint_before = checkpoint.read_bytes()
        run("restore")
        run("restore")
        assert before == {str(path): digest(path) for path in records}
        assert checkpoint.read_bytes() == checkpoint_before
        assert (root / "document.txt").read_text() == "disk\n"
        records[0].write_bytes(b"damaged")
        run("invalid")
        assert records[0].read_bytes() == b"damaged"
        assert digest(records[1]) == before[str(records[1])]
        assert checkpoint.read_bytes() == checkpoint_before
        checkpoint.write_bytes(checkpoint_before.replace(b"maru.workspace.v1", b"maru.workspace.v999", 1))
        legacy = checkpoint.read_bytes()
        run("old-format")
        assert checkpoint.read_bytes() == legacy
        print("recovery_process record_preserved=true disk_unchanged=true invalid_window_preserved=true legacy_preserved=true")


if __name__ == "__main__":
    main()
