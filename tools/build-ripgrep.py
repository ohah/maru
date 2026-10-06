#!/usr/bin/env python3
"""승인된 공식 rg 사본을 offline 검증하고 macOS universal helper로 준비한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
VENDOR = REPO / 'vendor/ripgrep/15.2.0'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(output):
    manifest = json.loads((VENDOR / 'manifest.json').read_text())
    output.mkdir(parents=True, exist_ok=True)
    binaries = []
    for asset in manifest['assets']:
        archive = VENDOR / asset['file']
        if sha(archive.read_bytes()) != asset['sha256']:
            raise ValueError('ripgrep archive digest mismatch: ' + asset['file'])
        with tarfile.open(archive, 'r:gz') as package:
            entry = f"ripgrep-{manifest['version']}-{asset['arch']}-apple-darwin/rg"
            candidates = [member for member in package.getmembers() if member.name == entry]
            if len(candidates) != 1 or not candidates[0].isfile() or candidates[0].size > 32 * 1024 * 1024:
                raise ValueError('ripgrep executable member is not a unique regular file')
            binary = package.extractfile(candidates[0]).read()
        if sha(binary) != asset['binary_sha256']:
            raise ValueError('ripgrep binary digest mismatch')
        target = output / (asset['arch'] + '-rg')
        target.write_bytes(binary)
        target.chmod(0o755)
        binaries.append(target)
    licenses = output / 'Licenses'
    licenses.mkdir(exist_ok=True)
    for name, expected in manifest['licenses'].items():
        content = (VENDOR / name).read_bytes()
        if sha(content) != expected:
            raise ValueError('ripgrep license digest mismatch: ' + name)
        (licenses / ('ripgrep-' + name.replace('/', '--'))).write_bytes(content)
    # 한 아키텍처만 universal 앱에 남는 사고를 막는다. 단일 target 앱도 같은 helper를 동봉한다.
    with tempfile.TemporaryDirectory(prefix='assemble-', dir=output) as temporary:
        staged = Path(temporary) / 'rg'
        subprocess.run(['/usr/bin/lipo', '-create', *map(str, binaries), '-output', str(staged)], check=True)
        staged.chmod(0o755)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(staged)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staged)], check=True)
        if set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(staged)], text=True).split()) != {'arm64', 'x86_64'}:
            raise ValueError('ripgrep universal architectures missing')
        os.replace(staged, output / 'rg')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.output.resolve())
