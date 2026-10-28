#!/usr/bin/env python3
"""Actual local file-tree IME rename using the existing private GUI/HID launcher."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from prepare import load,prepare
from verify import CASES,SENTINEL,SOURCE,validate,validate_diagnostic

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
# First-save orchestration binds these injected scene helpers during import.
shared=load('file_tree_first_save_runner',REPO/'tools/untitled-save-ime/run.py')
base_launch=shared.base_launch


def run(app,output,scene,capture_app):
    def launch(binary,env,gui,**kwargs):
        root=Path(env['MARU_PALETTE_IME']);project=root/'project'
        # The parent first-save wrapper may already have applied the failure mode.
        project.chmod(0o700)
        source=project/'base';source.write_bytes(SOURCE)
        if scene=='collision':(project/'base韓').write_bytes(SENTINEL)
        info=source.stat()
        (root/'setup.json').write_text(json.dumps(dict(device=info.st_dev,inode=info.st_ino,
            source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))+'\n')
        if scene=='write-failure':project.chmod(0o500)
        return base_launch(binary,env,gui,**kwargs)
    shared.base_launch=launch
    old_validate=shared.common.validate_diagnostic
    def validate_live(report):
        root=Path(report['root']);files=[]
        for path in (root/'project').iterdir():
            info=path.lstat()
            files.append(dict(name=path.name,device=info.st_dev,inode=info.st_ino,
                              sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        (root/'after-identity.json').write_text(json.dumps(dict(pid=report['pid'],root=str(root),files=files))+'\n')
        return validate_diagnostic(report)
    shared.common.validate_diagnostic=validate_live
    names=('run.py','prepare.py','probe.zig.inc','finish.swift.inc','verify.py')
    own={name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in names}
    (output/'file-tree-harness.json').write_text(json.dumps(dict(files_sha256=own,scenario=scene),indent=2)+'\n')
    try:return shared.run(app,output,scene,capture_app)
    finally:
        shared.base_launch=base_launch
        shared.common.validate_diagnostic=old_validate


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--app',type=Path)
    p.add_argument('--case',choices=CASES,default='hanja')
    p.add_argument('--capture-app',type=Path,default=Path.home()/'Applications/Maru Screen Capture.app')
    p.add_argument('--prepare-only',action='store_true');args=p.parse_args()
    output=args.output.resolve()
    if output.exists() or output.is_relative_to(REPO.resolve()):p.error('a new external output directory is required')
    if not args.capture_app.is_dir():p.error('an existing authorized native capture app is required')
    output.mkdir(parents=True,mode=0o700);app=args.app.resolve() if args.app else None
    if app is None:
        snapshot=output/'snapshot';prepare(REPO,snapshot)
        if args.prepare_only:print(snapshot);return
        with (output/'build.log').open('w') as log:
            subprocess.run(['mise','exec','--','zig','build','macos-app-build','-j2'],cwd=snapshot,stdout=log,stderr=subprocess.STDOUT,check=True)
        app=snapshot/'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    print(json.dumps(run(app,output,args.case,args.capture_app),ensure_ascii=False))


if __name__=='__main__':main()
