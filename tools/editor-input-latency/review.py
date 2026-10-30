#!/usr/bin/env python3
"""실제 원시 자료의 독립 사본에서 판정자가 오염을 거절하는지 확인한다."""
import argparse, copy, hashlib, json, os, pathlib, shutil
import verify

def main():
 p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args();root=a.root.resolve();out=a.output.resolve()
 if out.exists() or root==out or root in out.parents:p.error('new independent output required')
 verify.verify(root);out.mkdir();original=json.loads((root/'manifest.json').read_text());results=[]
 cases=[('foreground','foreground/text'),('dropped','presentation order'),('generation','stale frame generation'),('mode','actual parse mode'),('missing_pair','missing paired run')]
 for name,wanted in cases:
  dest=out/name;dest.mkdir();m=copy.deepcopy(original)
  for fixture in root.glob('flat-*.zig'):os.link(fixture,dest/fixture.name)
  for run in m['runs']:
   d=dest/run['path'];d.mkdir()
   for n in ['app.log','document.zig']:os.link(root/run['path']/n,d/n)
   shutil.copy2(root/run['path']/'result.json',d/'result.json')
  if name=='missing_pair':m['runs'].pop()
  else:
   r=next(x for x in m['runs'] if x['mode']=='async');path=dest/r['path']/'result.json';v=json.loads(path.read_text());row=v['rows'][0]
   if name=='foreground':row['foreground']=False
   elif name=='dropped':row['timing'][5]=0
   elif name=='generation':row['timing'][7]=row['before'][0]
   elif name=='mode':row['after'][6]&=1
   path.write_text(json.dumps(v));r['result_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
  (dest/'manifest.json').write_text(json.dumps(m))
  try:verify.verify(dest)
  except ValueError as error:
   if str(error)!=wanted:raise AssertionError((name,str(error),wanted))
   results.append({'fault':name,'rejected':str(error)})
  else:raise AssertionError('corruption survived: '+name)
 verify.verify(root);(out/'review.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
if __name__=='__main__':main()
