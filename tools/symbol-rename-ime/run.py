#!/usr/bin/env python3
"""Actual symbol-name IME GUI with an explicit controlled or local clangd process and raw wire."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from prepare import load,prepare
from server import describe_clangd,prepare_clangd
from verify import CASES,SENTINEL,MAIN,OTHER,PREFIX,validate,validate_diagnostic

HERE=Path(__file__).resolve().parent;REPO=HERE.parents[1]
shared=load('symbol_first_save_runner',REPO/'tools/untitled-save-ime/run.py')
base_launch=shared.base_launch


def run(app,output,scene,capture_app,fake,server=None,unicode_prefix=False):
    def launch(binary,env,gui,**kwargs):
        root=Path(env['MARU_PALETTE_IME']);project=root/'project'
        subprocess.run(['/usr/bin/git','init','-q',str(project)],check=True,
            env=dict(PATH=os.environ['PATH'],HOME=str(root/'home'),GIT_CONFIG_NOSYSTEM='1'),timeout=15)
        prefix=PREFIX if unicode_prefix else ''
        main=('// RENAMEFAIL\n' if scene=='server-error' else '')+prefix+MAIN
        other=(prefix+'int base(void);\n' if server else '')+prefix+OTHER
        (project/'main.c').write_text(main);(project/'other.c').write_text(other)
        if server:
            if describe_clangd(server['path'])!=server:raise ValueError('clangd changed before launch')
            prepare_clangd(project)
            (root/'server.json').write_text(json.dumps(server,indent=2)+'\n')
        argv=[server['path'],'--background-index','--log=verbose'] if server else [str(fake)]
        cfg=dict(root=str(root),argv=argv,wire=True,wire_limit_bytes=4*1024*1024,inherit_process_group=True,
                 server_environment=dict(PATH=os.environ['PATH'],HOME=str(root/'home'),
                    MARU_FAKE_LSP_RENAME_DOCCHANGES='1' if scene=='korean' else ''))
        # Presence enables this fake-server option; omit it for the changes-map control.
        if scene!='korean':cfg['server_environment'].pop('MARU_FAKE_LSP_RENAME_DOCCHANGES')
        if scene=='korean':cfg['server_environment']['MARU_FAKE_LSP_UTF16']='1'
        if server:cfg['server_environment']={k:v for k,v in cfg['server_environment'].items() if not k.startswith('MARU_FAKE_')}
        (root/'proxy.json').write_text(json.dumps(cfg))
        proxy=root/'lsp_proxy.py'
        proxy.write_bytes((REPO/'tools/editor-theme-gallery/lsp_proxy.py').read_bytes())
        wrapper=root/'lsp-proxy'
        wrapper.write_text('#!/bin/sh\nexec '+shlex.join([sys.executable,str(proxy),str(root/'proxy.json')])+' 2>'+shlex.quote(str(root/'proxy-bootstrap.stderr'))+'\n')
        wrapper.chmod(0o700)
        config=Path(env['MARU_CONFIG']);config.write_text(config.read_text()+
            'lsp.enabled = true\nlsp.shell-environment = false\nlsp.repository-environment = false\nworkspace.restore = false\n')
        env.update(MARU_NATIVE_EDITOR=str((project/'main.c').resolve()),MARU_LSP_SERVER_OVERRIDE=str(wrapper),MARU_SYMBOL_UNICODE='1' if unicode_prefix else '0')
        (root/'case.json').write_text(json.dumps(dict(scenario=scene,main=main,other=other,unicode_prefix=unicode_prefix,root=str(project.resolve()),server=server or {'kind':'controlled'}),ensure_ascii=False)+'\n')
        return base_launch(binary,env,gui,**kwargs)
    shared.base_launch=launch
    files=('run.py','server.py','prepare.py','probe.zig.inc','finish.swift.inc','verify.py')
    hashes={name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in files}
    (output/'symbol-harness.json').write_text(json.dumps(dict(files_sha256=hashes,server=server or {'kind':'controlled','sha256':hashlib.sha256(fake.read_bytes()).hexdigest()},
        proxy_sha256=hashlib.sha256((REPO/'tools/editor-theme-gallery/lsp_proxy.py').read_bytes()).hexdigest(),scope='local clangd SDK' if server else 'controlled LSP fixture, not real SDK'),indent=2)+'\n')
    try:
        result=shared.run(app,output,scene,capture_app)
        if server and describe_clangd(server['path'])!=server:
            (output/'validation.json').write_text(json.dumps(dict(passed=False,error='clangd changed during run'))+'\n')
            raise ValueError('clangd changed during run')
        return result
    finally:shared.base_launch=base_launch


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--app',type=Path);p.add_argument('--case',choices=CASES,default='hanja')
    p.add_argument('--capture-app',type=Path,default=Path.home()/'Applications/Maru Screen Capture.app')
    p.add_argument('--clangd',type=Path,help='explicit local clangd executable; no automatic install')
    p.add_argument('--unicode-prefix',action='store_true',help='Korean and non-BMP comment before symbols; clangd only')
    p.add_argument('--prepare-only',action='store_true');args=p.parse_args();out=args.output.resolve()
    server=describe_clangd(args.clangd) if args.clangd else None
    if args.unicode_prefix and not server:p.error('--unicode-prefix requires --clangd')
    if server and args.case=='server-error':p.error('forced server-error is a controlled-server case')
    if out.exists() or out.is_relative_to(REPO.resolve()):p.error('a new external output directory is required')
    if not args.capture_app.is_dir():p.error('an existing authorized capture app is required')
    out.mkdir(parents=True,mode=0o700);app=args.app.resolve() if args.app else None
    if app is None:
        snapshot=out/'snapshot';prepare(REPO,snapshot)
        if args.prepare_only:print(snapshot);return
        with (out/'build.log').open('w') as log:subprocess.run(['mise','exec','--','zig','build','macos-app-build','-j2'],cwd=snapshot,stdout=log,stderr=subprocess.STDOUT,check=True)
        app=snapshot/'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    fake=out/'fake-lsp'
    if not server:
        with (out/'fake-build.log').open('w') as log:subprocess.run(['mise','exec','--','zig','build-exe','tools/fake_lsp.zig','-lc','-O','Debug','-femit-bin='+str(fake)],cwd=REPO,stdout=log,stderr=subprocess.STDOUT,check=True)
    print(json.dumps(run(app,out,args.case,args.capture_app,fake,server,args.unicode_prefix),ensure_ascii=False))


if __name__=='__main__':main()
