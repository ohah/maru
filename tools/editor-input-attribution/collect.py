#!/usr/bin/env python3
"""고정한 GUI 앱의 준비 뒤 기록을 붙인다. 프로파일의 시간은 정상 성능 모집단으로 집계하지 않는다."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'editor-input-stream'))
import run as stream
import verify
from observer import Profiler


def main():
    p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--modes',default='sync,async');p.add_argument('--repetitions',type=int,default=3)
    args=p.parse_args();output=args.output.resolve();build=args.build.resolve();modes=args.modes.split(',')
    if output.exists() or output==ROOT or ROOT in output.parents or not modes or len(modes)!=len(set(modes)) or not set(modes)<={'sync','async'} or args.repetitions<1:p.error('new external output and bounded modes required')
    output.mkdir(mode=0o700)
    source=json.loads((build/'source.json').read_text())
    binary=build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    verify.require(verify.sha(binary)==source['app_sha256'],'app drift')
    manifest=dict(schema=1,kind='input-attribution-diagnostic',build=str(build),source=source,
                  repetitions=args.repetitions,modes=modes,runs=[],collector_sha256=verify.sha(__file__),complete=False,tools={})
    for path in [HERE/'collect.py',HERE/'observer.py',HERE.parent/'editor-input-stream/run.py',HERE.parent/'editor-input-stream/verify.py',HERE.parent/'editor-input-stream/protocol.py']:
        name=str(path.relative_to(ROOT));copy=output/'tool-snapshot'/name;copy.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,copy)
        manifest['tools'][name]=verify.sha(copy)
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for rep in range(args.repetitions):
        for mode in modes if rep%2==0 else list(reversed(modes)):
            if shutil.disk_usage(output).free<512*1024*1024:raise RuntimeError('insufficient space before next profile')
            folder=output/(str(rep)+'-'+mode)
            print(folder.name,flush=True)
            result=stream.trial(build,folder,50000,mode,'shared',100,30,'normal',rep,observer=Profiler())
            manifest['runs'].append(dict(path=folder.name,record_sha256=verify.sha(folder/'record.json')))
            (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
            if result['error'] is not None:raise RuntimeError('invalid diagnostic run: '+str(result['error']))
            for command in [
                ['xcrun','xctrace','export','--input',str(folder/'profile.trace'),'--toc','--output',str(folder/'toc.xml')],
                ['xcrun','xctrace','export','--input',str(folder/'profile.trace'),'--xpath','/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]','--output',str(folder/'time-profile.xml')],
            ]:
                with (folder/('export-'+('toc' if '--toc' in command else 'profile')+'.log')).open('xb') as log:
                    subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    verify.require(all(verify.sha(ROOT/n)==h for n,h in manifest['tools'].items()),'collection tools changed')
    manifest['complete']=True
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(output,flush=True)


if __name__=='__main__':main()
