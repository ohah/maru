#!/usr/bin/env python3
"""격리된 앱의 복구 목록·선택 후 문서를 제품 Metal 경로로 촬영한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output or Path(tempfile.mkdtemp(prefix="maru-backup-discovery-capture-", dir="/tmp"))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError("Output directory must be empty")
    app = repo / "zig-out/Maru.app/Contents/MacOS/maru-macos-app"
    reports = []
    for mode in ("list", "open"):
        root = output / mode
        root.mkdir()
        home = root / "home"
        home.mkdir()
        backups = root / "backups"
        backups.mkdir(mode=0o700)
        chosen = "d-" + "01" * 16 + ".bak"
        content = "Recovered notes\n\n한글 미저장 편집을 별도 문서로 복구합니다.\n원본 파일은 바뀌지 않습니다.\n".encode()
        for number, body in ((1, content), (2, b"")):
            identity = f"{number:02x}" * 16
            record = backups / f"d-{identity}.bak"
            record.write_bytes((f'maru.editor-backup.v2\ndoc kind=path bytes={len(body)} '
                                f'recovery-id={identity} disk-hash=0000000000000001 '
                                'path="/project/notes.txt"\n\n').encode() + body)
            record.chmod(0o600)
            claim = backups / f"d-{identity}.claim"
            claim.touch(mode=0o600)
        (backups / "u-9.bak").write_bytes(b"maru.editor-backup.v1\ndoc kind=untitled bytes=5 number=9\n\nhello")
        (backups / "u-a.bak").write_bytes(b"damaged")
        for record in backups.glob("*.bak"):
            record.chmod(0o600)
        config = root / "config"
        config.write_text("session.keep-alive-after-quit = false\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("MARU_")}
        ppm = output / f"{mode}.ppm"
        png = output / f"{mode}.png"
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), MARU_CONFIG=str(config),
                   XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(root / "cache"),
                   XDG_STATE_HOME=str(root / "state"), MARU_SESSION_HOST_ROOT=str(root / "host"),
                   MARU_EDITOR_BACKUP_ROOT=str(backups), MARU_EDITOR_RECOVERY_CAPTURE=mode,
                   MARU_EDITOR_RECOVERY_CAPTURE_QUERY=chosen, MARU_SCREENSHOT=str(ppm),
                   MARU_SCREENSHOT_DELAY_MS="3000")
        with (root / "app.log").open("wb") as log:
            child = subprocess.Popen([str(app)], cwd=repo, env=env, stdout=log, stderr=log)
            try:
                code = child.wait(timeout=45)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
        text = (root / "app.log").read_text()
        assert code == 0, (mode, code, text)
        assert "recovery_capture candidates=4" in text, text
        if mode == "open":
            assert f"recovery_capture opened=true dirty=true bytes={len(content)}" in text, text
        assert ppm.exists() and ppm.stat().st_size > 1024, text
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(png)], check=True, capture_output=True)
        reports.append(dict(mode=mode, pid=child.pid, exit_code=code, image=str(png),
                            sha256=hashlib.sha256(png.read_bytes()).hexdigest()))
    result = dict(app_sha256=hashlib.sha256(app.read_bytes()).hexdigest(), captures=reports,
                  scope="actual app and Metal rendering; isolated fixtures and debug command dispatch; not physical keyboard/IME input")
    (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
