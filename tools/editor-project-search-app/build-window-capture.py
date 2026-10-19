#!/usr/bin/env python3
"""화면 기록 허용 뒤 재사용할 고정 경로의 창 캡처 앱을 만든다."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if output.suffix != ".app" or output.exists() or output == repo or repo in output.parents:
        parser.error("Output must be a new .app outside the repository; existing grants are never overwritten")
    executable = output / "Contents/MacOS/capture"
    executable.parent.mkdir(parents=True)
    info = {"CFBundleExecutable": "capture", "CFBundleIdentifier": "dev.maru.screen-capture-helper",
            "CFBundleName": "Maru Screen Capture", "CFBundlePackageType": "APPL", "LSUIElement": True}
    (output / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    with tempfile.TemporaryDirectory(prefix="maru-window-capture-build-") as temporary:
        source = Path(temporary) / "main.swift"
        shutil.copyfile(Path(__file__).with_name("native-window-capture.swift.inc"), source)
        subprocess.run(["swiftc", "-parse-as-library", str(source), "-framework", "AppKit",
                        "-framework", "ScreenCaptureKit", "-o", str(executable)], check=True, timeout=60)
    subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True, timeout=30)
    print(output)


if __name__ == "__main__":
    main()
