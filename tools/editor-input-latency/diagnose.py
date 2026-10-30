#!/usr/bin/env python3
"""별도 cohort에서 blink 주기만 바꿔 색 복구의 프레임 재요청 의존성을 관측한다."""
import argparse, hashlib, json, pathlib, subprocess, sys
HERE=pathlib.Path(__file__).resolve().parent

def main():
 p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args();out=a.output.resolve();repo=HERE.parents[1]
 if out.exists() or out==repo or repo in out.parents:p.error('new external output required')
 out.mkdir();base=(HERE/'run.py').read_text();proof={'base_runner_sha256':hashlib.sha256(base.encode()).hexdigest(),'variants':[]}
 for blink in [500,100]:
  text=base.replace('pathlib.Path(__file__).resolve().parents[2]',repr(repo).replace('PosixPath','pathlib.Path'))
  old=r'editor.wrap = false\n'
  if text.count(old)!=1:raise ValueError('config anchor changed')
  text=text.replace(old,old+'cursor.blink-interval-ms = '+str(blink)+r'\n')
  text=text.replace("env['MARU_DEBUG']='1'","env['MARU_LATENCY_DIAGNOSTIC']='1'")
  runner=out/('runner-'+str(blink)+'.py');runner.write_text(text)
  dest=out/('blink-'+str(blink))
  subprocess.run([sys.executable,str(runner),'--build',str(a.build),'--output',str(dest),'--sizes','50000','--flows','typing','--events','6','--repetitions','1','--diagnostic'],check=True)
  manifest=json.loads((dest/'manifest.json').read_text());row={'blink_ms':blink,'runner_sha256':hashlib.sha256(runner.read_bytes()).hexdigest(),'runs':[]}
  for run in manifest['runs']:
   result=json.loads((dest/run['path']/'result.json').read_text());t=result['rows'][-1]['timing']
   row['runs'].append({'mode':run['mode'],'last_syntax_ms':(t[6]-t[1])/1e6,'last_full_ms':(t[9]-t[1])/1e6,'frame_generations':t[10]-t[8]})
  proof['variants'].append(row);(out/'diagnosis.json').write_text(json.dumps(proof,indent=2))
 print(json.dumps(proof,indent=2))
if __name__=='__main__':main()
