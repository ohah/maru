#!/usr/bin/env python3
"""별도 프로세스의 전체 peak RSS를 기록한다. 큐의 추가 메모리로 해석하지 않는다."""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('dataset',type=Path);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
root=args.dataset.resolve();out=args.output.resolve()
if out.exists(): p.error('new output required')
result=json.loads((root/'result.json').read_text());binary=root/'archived-test'
if hashlib.sha256(binary.read_bytes()).hexdigest()!=result['binary_sha256']:p.error('binary hash mismatch')
out.mkdir(parents=True)
rows=[]
for name in result['summary']:
    command=['/usr/bin/time','-l',str(binary),'--maru-expect-tests=2','--maru-expect-passed=2']
    with (out/(name+'.log')).open('xb') as log:
        subprocess.run(command,cwd=root/'source',env=dict(os.environ,MARU_HANDOFF_FILE=str(root/'fixtures'/name),MARU_HANDOFF_FAULT='none'),stdout=log,stderr=subprocess.STDOUT,check=True)
    text=(out/(name+'.log')).read_text()
    matches=re.findall(r'^\s*(\d+)\s+maximum resident set size\s*$',text,re.M)
    if len(matches)!=1 or 'All 2 tests passed.' not in text:raise ValueError('missing successful RSS record')
    rows.append({'fixture':name,'peak_rss_bytes':int(matches[0]),'command':command,'log_sha256':hashlib.sha256((out/(name+'.log')).read_bytes()).hexdigest()})
(out/'result.json').write_text(json.dumps({'binary_sha256':result['binary_sha256'],'population':'five separate processes, 20 repetitions each; includes initial parse','rows':rows},indent=2)+'\n')
print(json.dumps(rows,indent=2))
