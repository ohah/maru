#!/usr/bin/env python3
"""실제 전면 HID 입력을 독립 앱 프로세스로 비교한다. 한 번이라도 포커스를 잃으면 거절한다."""
import argparse, hashlib, json, os, pathlib, subprocess, platform

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);p.add_argument('--sizes',default='3000,50000');p.add_argument('--flows',default='typing,ime,shared');p.add_argument('--repetitions',type=int,default=3);p.add_argument('--events',type=int,default=30);p.add_argument('--drop-present',action='store_true');p.add_argument('--diagnostic',action='store_true');a=p.parse_args()
 out=a.output.resolve();build=a.build.resolve();app=build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app';source=json.loads((build/'source.json').read_text())
 if out==pathlib.Path(__file__).resolve().parents[2] or pathlib.Path(__file__).resolve().parents[2] in out.parents or out.exists() or not app.is_file() or sha(app)!=source['app_sha256']:p.error('new output and verified build required')
 if a.events<=5 or a.repetitions<1 or not set(a.flows.split(','))<=set(['typing','ime','shared']):p.error('positive repetitions and at least six events required')
 out.mkdir();manifest={'schema':1,'source':source,'app_sha256':sha(app),'build':str(build),'runner_sha256':sha(pathlib.Path(__file__)),'host':{'macos':platform.mac_ver()[0],'logical_cpus':os.cpu_count()},'diagnostic':a.diagnostic,'fault_drop_present':a.drop_present,'events':a.events,'sizes':list(map(int,a.sizes.split(','))),'flows':a.flows.split(','),'repetitions':a.repetitions,'runs':[]};(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
 for size in map(int,a.sizes.split(',')):
  fixture=out/('flat-'+str(size)+'.zig');fixture.write_text('// \n'+''.join('pub fn f%d() void { const value: u64 = %d; _ = value; }\n'%(i,i) for i in range(size)))
  for flow in a.flows.split(','):
   # AB/BA를 교대하여 실행 순서·열 상태를 한 모드에 몰지 않는다.
   for rep in range(a.repetitions):
    for mode in (['sync','async'] if rep%2==0 else ['async','sync']):
     d=out/('%d-%s-%d-%s'%(size,flow,rep,mode));d.mkdir();(d/'home').mkdir();(d/'host').mkdir(mode=0o700)
     (d/'config').write_text('session.keep-alive-after-quit = false\nlsp.enabled = false\neditor.wrap = false\n')
     document=d/'document.zig';document.write_bytes(fixture.read_bytes())
     env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')};env.update(CFFIXED_USER_HOME=str(d/'home'),XDG_CONFIG_HOME=str(d/'home/.config'),XDG_CACHE_HOME=str(d/'cache'),XDG_STATE_HOME=str(d/'state'),MARU_CONFIG=str(d/'config'),MARU_SESSION_HOST_ROOT=str(d/'host'),MARU_EDITOR_BACKUP_ROOT=str(d/'backups'),MARU_NO_WORKSPACE_RESTORE='1',MARU_NATIVE_EDITOR=str(document),MARU_FT_WINDOW_SIZE='960x600',MARU_MACOS_APP_SMOKE_MS='300000',MARU_EDITOR_IME_SMOKE='1',MARU_LATENCY_OUTPUT=str(d/'result.json'),MARU_LATENCY_MODE=mode,MARU_LATENCY_FLOW=flow,MARU_LATENCY_EVENTS=str(a.events))
     if a.diagnostic:env['MARU_DEBUG']='1'
     if a.drop_present:env['MARU_LATENCY_DROP_PRESENT']='1'
     load_before=os.getloadavg()
     print(d.name,flush=True)
     with (d/'app.log').open('w') as log:
      child=subprocess.Popen([str(app)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
      try:code=child.wait(timeout=330)
      except subprocess.TimeoutExpired:
       child.kill();child.wait();raise RuntimeError('app timeout: '+str(d))
     record={'path':d.name,'mode':mode,'flow':flow,'size':size,'repeat':rep,'exit':code,'pid':child.pid,'load_before':load_before,'load_after':os.getloadavg(),'fixture_sha256':sha(fixture),'disk_unchanged':sha(document)==sha(fixture)}
     if not (d/'result.json').is_file():raise RuntimeError('missing result: '+str(d))
     result=json.loads((d/'result.json').read_text());record['result_sha256']=sha(d/'result.json');record['app_log_sha256']=sha(d/'app.log');manifest['runs'].append(record);(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
     if code or result['error'] is not None or not result['restored'] or not record['disk_unchanged']:raise RuntimeError('invalid run '+str(d)+': '+str(result.get('error')))
 print(out)
if __name__=='__main__':main()
