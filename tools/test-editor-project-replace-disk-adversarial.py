#!/usr/bin/env python3
"""격리 소스에서 디스크 바꾸기 보호 조건의 실제 판정력을 검사한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = (args.output or Path(tempfile.mkdtemp(prefix="maru-disk-apply-adversarial-"))).resolve()
    if output == repo or repo in output.parents or (output.exists() and any(output.iterdir())):
        parser.error("Output must be a new empty directory outside the repository")
    source = output / "source"
    source.mkdir(parents=True)
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                    "--exclude=node_modules", "--exclude=references", "--exclude=.env*",
                    str(repo) + "/", str(source) + "/"], check=True, timeout=120)
    for name in ("node_modules", "web/node_modules"):
        if (repo / name).exists():
            (source / name).symlink_to(repo / name, target_is_directory=True)
    build = source / "build.zig"
    b = build.read_text()
    old = '.filters = &.{".test.RPA"}'
    assert b.count(old) == 1
    b = b.replace(old, '.filters = &.{".test.RPA14", ".test.RPA15", ".test.RPA16", ".test.RPA17", ".test.RPA20", ".test.RPA21"}')
    b = b.replace('run_apply_host.addArg("--maru-expect-tests=27");', 'run_apply_host.addArg("--maru-expect-tests=10");')
    build.write_text(b)
    path = source / "src/platform/macos/app_session/editor/search/preview.zig"
    original = path.read_text()
    mutations = [
        ("late-loaded-content", '!std.mem.eql(u8, doc.opened.?.file.content, transaction.plan.?.before)',
         '(!std.mem.eql(u8, doc.opened.?.file.content, transaction.plan.?.before) and false)', False),
        ("input-changed-during-check", 'state.settings_stamp != settingsStamp(self) or self.ime_active',
         'false or self.ime_active', False),
        ("replaced-root-after-check", 'if (@as(u64, @intCast(root.device)) != target.identity.device or root.stat.inode != target.identity.inode)',
         'if ((@as(u64, @intCast(root.device)) != target.identity.device or root.stat.inode != target.identity.inode) and false)', False),
        ("equivalent-content-comparison", '!std.mem.eql(u8, doc.opened.?.file.content, transaction.plan.?.before)',
         '!std.mem.eql(u8, transaction.plan.?.before, doc.opened.?.file.content)', True),
    ]
    results = []

    def run(name, text, expected):
        path.write_text(text)
        command = ["mise", "exec", "--", "zig", "build", "test-editor-project-replace-apply", "-j2"]
        result = subprocess.run(command, cwd=source, text=True, capture_output=True, timeout=900)
        log = result.stdout + result.stderr
        (output / (name + ".log")).write_text(log)
        if (result.returncode == 0) != expected or (not expected and "FAIL (" not in log):
            raise RuntimeError(f"{name}: unexpected result; compilation failure is not a killed mutation")
        results.append(dict(name=name, exit_code=result.returncode, expected_pass=expected,
                            source_sha256=hashlib.sha256(text.encode()).hexdigest()))
        print(name, "verified", flush=True)

    try:
        run("control", original, True)
        for name, old, new, expected in mutations:
            if original.count(old) != 1:
                raise RuntimeError(f"Non-unique anchor: {name}")
            run(name, original.replace(old, new), expected)
        run("restored-control", original, True)
    finally:
        path.write_text(original)
    (output / "results.json").write_text(json.dumps(dict(
        scope="real rg/AppSession disk apply; focused RPA14/15/16/17/20/21 and neutral Plan; not GUI or OS IME",
        results=results), ensure_ascii=False, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
