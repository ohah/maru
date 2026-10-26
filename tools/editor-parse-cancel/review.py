#!/usr/bin/env python3
"""독립 검증기가 기록 손상을 거절하는지 별도 사본으로 확인한다."""
import argparse, json, shutil, tempfile
from pathlib import Path
from verify import verify
p=argparse.ArgumentParser();p.add_argument('output',type=Path);args=p.parse_args()
root=args.output.resolve()
verify(root)
checks=[]
for fault in ('summary','row','missing','binary_identity','fixture_identity'):
    with tempfile.TemporaryDirectory(prefix='maru-handoff-review-') as temp:
        copy=Path(temp)
        for item in root.iterdir():
            if item.name in ('source','fixtures','tool-snapshot','archived-test'): (copy/item.name).symlink_to(item,target_is_directory=item.is_dir())
            elif item.is_file(): shutil.copy2(item,copy/item.name)
        if fault in ('summary','row','binary_identity'):
            path=copy/'result.json';data=json.loads(path.read_text())
            if fault=='summary': data['summary']['flat-3000.zig']['cases']['p50']+=1
            if fault=='row': data['rows'][0]['callbacks']+=1
            if fault=='binary_identity': data['binary_sha256']='0'*64
            path.write_text(json.dumps(data))
        elif fault=='fixture_identity':
            path=copy/'manifest.json';data=json.loads(path.read_text());data['inputs']['flat-3000.zig']['sha256']='0'*64;path.write_text(json.dumps(data))
        else:
            path=copy/'run-0-flat-3000.zig.log';lines=path.read_text().splitlines();path.write_text('\n'.join(line for line in lines if not line.startswith('CANCEL iteration=1 ')))
        try: verify(copy)
        except ValueError as error: checks.append({'fault':fault,'rejected':str(error)})
        else: raise RuntimeError('accepted corruption: '+fault)
print(json.dumps({'normal_records':50,'rejected':checks},indent=2))
