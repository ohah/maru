#!/usr/bin/env python3
"""고정 주기의 별도 producer와 앱을 소유한다. 실패 원시 자료는 지우거나 재사용하지 않는다."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import time
import protocol
import verify

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def provider_fingerprints():
    # 내용은 기록하지 않고 격리되지 않은 외부 설정의 변경 여부만 검사한다.
    home=pathlib.Path(os.path.expanduser('~'))
    codex=pathlib.Path(os.environ.get('CODEX_HOME',str(home/'.codex')))
    claude=pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR',str(home/'.claude')))
    paths=[codex/'hooks.json',codex/'config.toml',claude/'settings.json']
    return {str(p):verify.sha(p) if p.is_file() else None for p in paths}


def trial(build, target, size, mode, flow, period, count, kind, rep, observer=None, summary_control=None, environment_filter=None, fold_control=None, fixture_kind="flat", bracket_control=None, fold_reuse_control=None, frame_wake_control=None, deferred_retry_control=None, observer_posts_control=None, observer_work_control=None):
    target.mkdir(mode=0o700)
    (target/'profile').mkdir();(target/'host').mkdir(mode=0o700)
    data = protocol.fixture(size,fixture_kind)
    (target/'document.zig').write_bytes(data)
    (target/'config').write_text('session.keep-alive-after-quit = false\nlsp.enabled = false\neditor.wrap = false\n')
    state = json.loads((build/'source.json').read_text())
    if state.get('observer_work_control'):
        if observer_work_control not in ('untimed','timed') or observer_posts_control!='cached_posts' or deferred_retry_control!='with_retry':raise ValueError('observer work label and fixed controls required')
    elif observer_work_control is not None:raise ValueError('observer work build required')
    if state.get('observer_posts_control'):
        if observer_posts_control not in ('repeated_posts','cached_posts'):raise ValueError('observer posts label required')
    elif observer_posts_control is not None:raise ValueError('observer posts build required')
    if state.get('deferred_retry_control'):
        if deferred_retry_control not in ('without_retry','with_retry') or frame_wake_control!='immediate':raise ValueError('deferred retry label and target candidate required')
    elif deferred_retry_control is not None:raise ValueError('deferred retry build required')
    if state.get('frame_wake_control'):
        if frame_wake_control not in ('scheduled','immediate'):raise ValueError('frame wake label required')
    elif frame_wake_control is not None:raise ValueError('frame wake build required')
    if state.get('parse_stages') and observer is None:

        raise ValueError('parse stage build requires diagnostic observer')
    if summary_control is not None and (state.get('summary_control') is not True or summary_control not in ('disabled','prepared')):
        raise ValueError('verified summary control build/mode required')
    if fold_control is not None and (state.get('fold_control') is not True or fold_control not in ('disabled','prepared')):
        raise ValueError('verified fold control build/mode required')
    if bracket_control is not None and (state.get('bracket_control') is not True or bracket_control not in ('disabled','prepared')):raise ValueError('verified bracket control build/mode required')
    if fold_reuse_control is not None and (state.get('fold_reuse_control') is not True or fold_reuse_control not in ('disabled','prepared')):raise ValueError('verified fold reuse build/mode required')
    if sum(x is not None for x in [summary_control,fold_control,bracket_control,fold_reuse_control])>1:raise ValueError('one cache control required')
    app = build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    producer = build/'producer'
    if verify.sha(app) != state['app_sha256'] or verify.sha(producer) != state['producer_sha256']:
        raise ValueError('build drift')
    env = {k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
    if observer is not None:env=observer.environment(env)
    elif environment_filter is not None:env=environment_filter(env)
    # 생산자/복원 도구에는 앱의 가상 profile을 넘기지 않고 같은 환경 허용 목록만 적용한다.
    auxiliary_environment=dict(env)
    profile = str(target/'profile')
    env.update(CFFIXED_USER_HOME=profile,XDG_CONFIG_HOME=profile+'/.config',XDG_CACHE_HOME=profile+'/.cache',XDG_STATE_HOME=profile+'/.state',
        MARU_CONFIG=str(target/'config'),MARU_SESSION_HOST_ROOT=str(target/'host'),MARU_EDITOR_BACKUP_ROOT=str(target/'backups'),
        MARU_NO_WORKSPACE_RESTORE='1',MARU_NATIVE_EDITOR=str(target/'document.zig'),MARU_FT_WINDOW_SIZE='960x600',
        MARU_MACOS_APP_SMOKE_MS='180000',MARU_EDITOR_IME_SMOKE='1',MARU_LATENCY_MODE=mode,MARU_LATENCY_FLOW=flow,
        MARU_LATENCY_OUTPUT=str(target/'app.json'),MARU_STREAM_READY=str(target/'ready.json'),MARU_STREAM_POSTS=str(target/'posts.json'),
        MARU_STREAM_SOURCE_RECORD=str(target/'source-record.json'),MARU_STREAM_COUNT=str(count),MARU_STREAM_WAIT_MS='30000')
    if observer_work_control == 'timed':env['MARU_STREAM_OBSERVER_WORK']='1'
    if observer_posts_control == 'cached_posts':env['MARU_STREAM_CACHE_POSTS']='1'
    if deferred_retry_control == 'with_retry':env['MARU_STREAM_DEFERRED_FRAME_RETRY']='1'
    if frame_wake_control == 'immediate':env['MARU_STREAM_IMMEDIATE_PARSE_FRAME']='1'
    if kind == 'main-pause': env['MARU_STREAM_MAIN_PAUSE_MS']='500'
    if kind == 'drop-present': env.update(MARU_STREAM_DROP_PRESENT='1',MARU_STREAM_WAIT_MS='7000')
    if summary_control=='disabled':env['MARU_STREAM_SKIP_SUMMARY_PREPARATION']='1'
    if fold_control=='disabled':env['MARU_STREAM_SKIP_FOLD_PREPARATION']='1'
    if bracket_control=='disabled':env['MARU_STREAM_SKIP_BRACKET_PREPARATION']='1'
    if fold_reuse_control=='disabled':env['MARU_STREAM_SKIP_FOLD_REUSE']='1'
    meta = {'count':count,'mode':mode,'flow':flow,'size':size,'repeat':rep,'shared':flow=='shared','period_ns':period*1_000_000,'lateness_ns':20_000_000,
            'kind':kind,'fixture_bytes':len(data),'fixture_sha256':hashlib.sha256(data).hexdigest(),
            'fixture_tail_sha256':hashlib.sha256(data[3:]).hexdigest(),'load_before':os.getloadavg(),
            'provider_before':provider_fingerprints(),'diagnostic':observer is not None,'observer_work_control':observer_work_control,'observer_posts_control':observer_posts_control,'deferred_retry_control':deferred_retry_control,'frame_wake_control':frame_wake_control,'target_frame_control':state.get('target_frame_control',False),'observer_cpu':state.get('observer_cpu',False),'display_stages':state.get('display_stages',False),'summary_control':summary_control,'fold_control':fold_control,'fixture_kind':fixture_kind,'bracket_control':bracket_control,'fold_reuse_control':fold_reuse_control}
    child = sender = None
    failure = None
    with (target/'app.log').open('w') as log, (target/'producer.log').open('w') as sender_log:
        try:
            child = subprocess.Popen([str(app)],cwd=target,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            meta['app_pid']=child.pid
            deadline = time.monotonic()+70
            while not (target/'ready.json').exists():
                if child.poll() is not None: raise RuntimeError('app exited before ready')
                if time.monotonic()>deadline: raise RuntimeError('app readiness timeout')
                time.sleep(.02)
            ready = json.loads((target/'ready.json').read_text())
            if ready['pid']!=child.pid or ready['count']!=count or ready['source']!='com.apple.keylayout.ABC' or ready['initial_tail_sha256']!=meta['fixture_tail_sha256']:
                raise ValueError('ready document identity')
            # 진단 관측자의 연결 완료 뒤에만 생산자를 시작한다. 생산자의 게시 일정은 여전히 독립적이다.
            if observer is not None: meta['observer_start']=observer.start(child.pid,target)
            command = [str(producer),'--ready',str(target/'ready.json'),'--output',str(target/'posts.json'),'--stop',str(target/'app.json'),
                       '--period-ns',str(meta['period_ns']),'--lateness-ns',str(meta['lateness_ns'])]
            if kind == 'skip': command += ['--skip-seq','3']
            sender = subprocess.Popen(command,stdout=sender_log,stderr=subprocess.STDOUT,start_new_session=True,env=auxiliary_environment,cwd=target)
            meta['producer_pid']=sender.pid
            meta['app_exit']=child.wait(timeout=50)
            meta['producer_exit']=sender.wait(timeout=3)
        except Exception as error:
            failure = str(error)
        finally:
            if child is not None and child.poll() is None:
                if not (target/'posts.json').exists(): (target/'posts.json').write_text(json.dumps({'error':'runner_abort'}))
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill();child.wait()
            if sender is not None and sender.poll() is None:
                sender.terminate()
                try: sender.wait(timeout=2)
                except subprocess.TimeoutExpired: sender.kill();sender.wait()
            if observer is not None:
                try: meta['observer_stop']=observer.stop()
                except Exception as error: failure=failure or 'observer cleanup: '+str(error)
            if child is not None and (target/'source-record.json').exists():
                try:
                    finished = json.loads((target/'app.json').read_text()) if (target/'app.json').exists() else {}
                    if finished.get('restored') is True:
                        recovery = {'exit':0,'status':'restored_in_app'}
                    else:
                        recovered = subprocess.run([str(producer),'--recover-source',str(target/'source-record.json'),'--expected-pid',str(child.pid)],capture_output=True,text=True,timeout=5,env=auxiliary_environment,cwd=target)
                        recovery = {'exit':recovered.returncode,'stdout':recovered.stdout,'stderr':recovered.stderr}
                        if recovered.returncode: failure = failure or 'input source recovery failed'
                except Exception as error:
                    recovery = {'exit':-1,'error':str(error)};failure=failure or 'source recovery unavailable'
                (target/'source-recovery.json').write_text(json.dumps(recovery,indent=2))
    meta['load_after']=os.getloadavg()
    meta['provider_after']=provider_fingerprints()
    if meta['provider_before']!=meta['provider_after']: failure=failure or 'external provider configuration changed'
    meta['disk_unchanged']=verify.sha(target/'document.zig')==meta['fixture_sha256']
    for name in ['app.json','posts.json','app.log','producer.log','config','ready.json','source-record.json','source-recovery.json']:
        if (target/name).is_file(): meta[name+'_sha256']=verify.sha(target/name)
    if failure is None:
        a = json.loads((target/'app.json').read_text());p = json.loads((target/'posts.json').read_text())
        try:
            meta['validation']=verify.classify(a,p,meta)
        except (ValueError,KeyError,TypeError) as error: failure=str(error)
    meta['error']=failure
    (target/'record.json').write_text(json.dumps(meta,indent=2)+'\n')
    return meta


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--build',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path)
    p.add_argument('--sizes',default='3000,50000');p.add_argument('--periods',default='100,50');p.add_argument('--flows',default='typing,shared')
    p.add_argument('--modes',default='sync,async');p.add_argument('--repetitions',type=int,default=3);p.add_argument('--count',type=int,default=30)
    p.add_argument('--kind',choices=['normal','main-pause','drop-present','skip'],default='normal')
    a=p.parse_args();out=a.output.resolve();build=a.build.resolve();protocol.count(a.count)
    sizes=list(map(int,a.sizes.split(',')));periods=list(map(int,a.periods.split(',')));flows=a.flows.split(',');modes=a.modes.split(',')
    if out.exists() or out==ROOT or ROOT in out.parents or a.repetitions<1 or not set(sizes)<={3000,50000} or not set(flows)<={'typing','shared'} or not set(modes)<={'sync','async'} or any(x<20 or x>200 for x in periods): p.error('new external output and bounded matrix required')
    if any(not xs or len(xs)!=len(set(xs)) for xs in [sizes,periods,flows,modes]): p.error('unique nonempty dimensions required')
    source=json.loads((build/'source.json').read_text())
    if source.get('harness')!=protocol.NAME: p.error('independent stream build required')
    if source.get('summary_control') or source.get('fold_control') or source.get('bracket_control') or source.get('fold_reuse_control'):p.error('use cache study for the controlled experiment build')
    if verify.sha(build/'producer')!=source['producer_sha256'] or verify.sha(build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app')!=source['app_sha256']: p.error('immutable build required')
    if a.kind=='skip' and a.count<4: p.error('skip control needs at least four inputs')
    subprocess.run([str(build/'producer'),'--preflight'],check=True)
    out.mkdir(mode=0o700)
    manifest={'schema':1,'protocol':protocol.NAME,'build':str(build),'source':source,'runner_sha256':verify.sha(__file__),'verifier_sha256':verify.sha(HERE/'verify.py'),
              'sizes':sizes,'periods':periods,'flows':flows,'modes':modes,'repetitions':a.repetitions,'count':a.count,'kind':a.kind,'runs':[],
              'host':{'macos':platform.mac_ver()[0],'logical_cpus':os.cpu_count(),'architecture':platform.machine()}}
    for size in sizes:
        for period in periods:
            for flow in flows:
                for rep in range(a.repetitions):
                    for mode in (modes if rep%2==0 else list(reversed(modes))):
                        name=f'{size}-{period}-{flow}-{rep}-{mode}'
                        print(name,flush=True)
                        result=trial(build,out/name,size,mode,flow,period,a.count,a.kind,rep)
                        manifest['runs'].append({'path':name,'record_sha256':verify.sha(out/name/'record.json')})
                        (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                        if result['error'] is not None: raise RuntimeError(name+': '+result['error'])
    print(out)


if __name__=='__main__': main()
