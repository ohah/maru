#!/usr/bin/env python3
"""준비 뒤 붙인 trace의 주소를 dSYM으로 검증한다. 키별 대기 시간을 CPU 시간으로 바꾸지 않는다."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import shutil
import sys

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'editor-native-sampling'))
import stacks
import symbols
import replay
sys.path.insert(0,str(HERE.parent/'editor-input-stream'))
import verify

ENVIRONMENT_KEYS=set('PATH HOME CODEX_HOME CLAUDE_CONFIG_DIR SHELL USER LOGNAME TMPDIR LANG LC_ALL __CF_USER_TEXT_ENCODING CFFIXED_USER_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME executable_boothash executable_file dyld_file main_stack security_config executable_cdhash ptr_munge th_port MARU_CONFIG MARU_SESSION_HOST_ROOT MARU_EDITOR_BACKUP_ROOT MARU_NO_WORKSPACE_RESTORE MARU_NATIVE_EDITOR MARU_FT_WINDOW_SIZE MARU_MACOS_APP_SMOKE_MS MARU_EDITOR_IME_SMOKE MARU_LATENCY_MODE MARU_LATENCY_FLOW MARU_LATENCY_OUTPUT MARU_STREAM_READY MARU_STREAM_POSTS MARU_STREAM_SOURCE_RECORD MARU_STREAM_COUNT MARU_STREAM_WAIT_MS'.split())


def profile(text,pid,resolution):
    _,table,refs=stacks.exported_table(text)
    own=resolution['plan'];names=resolution['names'];main=set();seen=set();previous=-1
    counts=Counter();inclusive=Counter();selfs=Counter()
    for row in table.findall('row'):
        stacks.require(len(row)==7 and [x.tag for x in row[:6]]==[x[1] for x in stacks.COLUMNS[:6]],'profile row shape')
        process=refs.get(row[2]);thread=refs.get(row[1])
        stacks.require(stacks.integer(refs.get(stacks.one(process,'pid')).text,'pid',True)==pid,'foreign sample PID')
        stacks.require(refs.get(stacks.one(thread,'process')) is process,'thread PID differs')
        tid=stacks.integer(refs.get(stacks.one(thread,'tid')).text,'tid',True)
        stamp=stacks.integer(refs.get(row[0]).text,'time');weight=stacks.integer(refs.get(row[5]).text,'weight',True)
        stacks.integer(refs.get(row[3]).text,'core')
        stacks.require(stamp>=previous and (stamp,tid) not in seen,'duplicate/reordered sample')
        seen.add((stamp,tid));previous=stamp;counts['all_rows']+=1
        stacks.require(refs.get(row[4]).text=='Running','non-running sample')
        if not thread.get('fmt','').startswith('Main Thread '):continue
        main.add(tid);counts['main_rows']+=1;counts['main_weight_ns']+=weight
        if row[-1].tag=='sentinel':
            stacks.require(not row[-1].attrib and not list(row[-1]) and not (row[-1].text or '').strip(),'invalid missing stack')
            selfs['[missing-stack]']+=weight;continue
        frames=refs.get(row[-1]);stacks.require(row[-1].tag=='backtrace' and len(frames)>0 and all(x.tag=='frame' for x in frames),'invalid stack')
        resolved=[]
        for frame in frames:
            pc=symbols.hexadecimal(refs.get(frame).get('addr'))
            if own['lower']<=pc<own['upper']:
                stacks.require(hex(pc) in names,'address coverage missing')
                name=names[hex(pc)]
                resolved.append(name if name and name!='<deduplicated_symbol>' else '[unresolved-target]')
            else:resolved.append('[external-code]')
        selfs[resolved[0]]+=weight
        for name in set(resolved)-{'[external-code]','[unresolved-target]'}:inclusive[name]+=weight
    stacks.require(len(main)==1 and counts['main_rows']>0,'one observed main thread required')
    stacks.require(sum(selfs.values())==counts['main_weight_ns'],'main self weight accounting')
    return dict(counts=dict(counts),main_tid=next(iter(main)),self_weight_ns=dict(selfs.most_common()),inclusive_weight_ns=dict(inclusive.most_common()))


def target_identity(text,pid,binary):
    toc=stacks.xml(text);runs=toc.findall('run')
    verify.require(toc.tag=='trace-toc' and len(runs)==1 and runs[0].get('number')=='1','one trace run required')
    info=stacks.one(runs[0],'info');target=stacks.one(stacks.one(info,'target'),'process')
    verify.require(target.get('type')=='attached' and target.get('pid')==str(pid) and target.get('return-exit-status')=='0' and target.get('termination-reason')=='exit(0)','trace target identity/exit')
    keys=[x.get('key') for x in stacks.one(stacks.one(info,'target'),'environment')]
    verify.require(len(keys)==len(set(keys)) and set(keys)<=ENVIRONMENT_KEYS,'unsafe or duplicate environment key in trace')
    processes=[x for x in stacks.one(runs[0],'processes') if x.get('pid')==str(pid)]
    verify.require(len(processes)==1 and processes[0].get('path')==str(binary),'trace target executable')
    summary=stacks.one(info,'summary')
    verify.require(stacks.one(summary,'template-name').text=='Time Profiler' and stacks.one(summary,'end-reason').text=='Target app exited','trace ended before target exit')
    tables=[x for x in stacks.one(runs[0],'data') if x.get('schema')=='time-profile']
    verify.require(len(tables)==1 and tables[0].get('record-waiting-threads')=='0' and tables[0].get('target-pid')=='SINGLE','time profile table')


def main_tids(text):
    root,_,refs=stacks.exported_table(text)
    return {stacks.integer(refs.get(stacks.one(refs.get(t),'tid')).text,'tid',True) for t in root.iter('thread') if refs.get(t).get('fmt','').startswith('Main Thread ')}


def main():
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--output',required=True,type=Path);args=p.parse_args();root=args.root.resolve();output=args.output.resolve()
    repository=HERE.parents[1]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external analysis output required')
    output.mkdir(mode=0o700)
    manifest=json.loads((root/'manifest.json').read_text());verify.require(manifest['kind']=='input-attribution-diagnostic' and manifest.get('complete') is True,'complete diagnostic manifest required')
    for name,digest in manifest['tools'].items():verify.require(verify.sha(root/'tool-snapshot'/name)==digest,'collection snapshot drift')
    tool_hashes={}
    for path in [HERE/'analyze.py',HERE.parent/'editor-native-sampling/stacks.py',HERE.parent/'editor-native-sampling/symbols.py',HERE.parent/'editor-native-sampling/replay.py',HERE.parent/'editor-input-stream/verify.py',HERE.parent/'editor-input-stream/protocol.py']:
        name=str(path.relative_to(repository));copy=output/'tool-snapshot'/name;copy.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,copy);tool_hashes[name]=verify.sha(copy)
    build=Path(manifest['build']);binary=build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    verify.require(verify.sha(binary)==manifest['source']['app_sha256'],'binary drift')
    verify.require(verify.sha(build/'producer')==manifest['source']['producer_sha256'],'producer drift')
    for name,digest in manifest['source']['instrumented'].items():verify.require(verify.sha(build/'source'/name)==digest,'instrumented source drift')
    verify.require(type(manifest['repetitions']) is int and manifest['repetitions']>0 and manifest['modes'] and len(manifest['modes'])==len(set(manifest['modes'])) and set(manifest['modes'])<={'sync','async'},'profile matrix')
    expected={(rep,mode) for rep in range(manifest['repetitions']) for mode in manifest['modes']};found=set()
    verify.require(len(manifest['runs'])==len(expected) and len({x['path'] for x in manifest['runs']})==len(expected),'incomplete profile matrix')
    uid=stacks.macho_uuid(binary.read_bytes())
    with (output/'symbols.log').open('xb') as log:subprocess.run(symbols.bundle_command(output,binary),stdout=log,stderr=subprocess.STDOUT,check=True)
    symbol=symbols.symbol_file(output,uid,binary.name)
    results=[]
    for run in manifest['runs']:
        folder=(root/run['path']).resolve();verify.require(folder.is_relative_to(root),'profile path escape');destination=output/run['path'];destination.mkdir();record=json.loads((folder/'record.json').read_text())
        verify.require(verify.sha(folder/'record.json')==run['record_sha256'] and record['diagnostic'] is True and record['error'] is None,'invalid diagnostic record')
        identity=(record['repeat'],record['mode']);verify.require(identity in expected and identity not in found,'duplicate/unexpected profile');found.add(identity)
        verify.require(record['size']==50000 and record['flow']=='shared' and record['count']==30 and record['period_ns']==100_000_000 and record['kind']=='normal','profile workload')
        for name in ['app.json','posts.json','app.log','producer.log','config','ready.json','source-record.json','source-recovery.json']:
            verify.require(verify.sha(folder/name)==record[name+'_sha256'],'raw receipt drift')
        app=json.loads((folder/'app.json').read_text());producer=json.loads((folder/'posts.json').read_text())
        verify.classify(app,producer,record)
        toc=(folder/'toc.xml').read_text();target_identity(toc,record['app_pid'],binary)
        verify.require(record['observer_start']['target_pid']==record['app_pid'] and record['observer_start']['notification_received_ns']<producer['start_ns'],'recording did not precede producer schedule')
        text=(folder/'time-profile.xml').read_text()
        # 원본 trace 재내보내기의 표본 사실을 비교한다. XML 표시 이름이나 ID는 재현 근거가 아니다.
        replay_folder=destination/'sdk-replay';replay_folder.mkdir()
        trace_before=replay.trace_files(folder/'profile.trace')
        for kind,options in [('toc',['--toc']),('profile',['--xpath',replay.XPATH])]:
            with (replay_folder/(kind+'.log')).open('xb') as log:
                subprocess.run(['xcrun','xctrace','export','--input',str(folder/'profile.trace'),*options,'--output',str(replay_folder/(kind+'.xml'))],stdout=log,stderr=subprocess.STDOUT,check=True)
        target_identity((replay_folder/'toc.xml').read_text(),record['app_pid'],binary)
        verify.require(replay.canonical(text)==replay.canonical((replay_folder/'profile.xml').read_text()),'SDK sample replay differs')
        verify.require(replay.image_binding(text,str(binary))==replay.image_binding((replay_folder/'profile.xml').read_text(),str(binary)),'SDK image binding differs')
        verify.require(main_tids(text)==main_tids((replay_folder/'profile.xml').read_text()),'SDK main thread identity differs')
        verify.require(trace_before==replay.trace_files(folder/'profile.trace'),'trace changed during SDK replay')
        resolution=symbols.collect(destination,text,binary,symbol,uid,binary.name)
        (destination/'address-symbols.json').write_text(json.dumps(resolution,indent=2)+'\n')
        checked=symbols.checked(destination,text,binary,symbol,uid,resolution,binary.name)
        result=profile(text,record['app_pid'],checked)
        result.update(path=run['path'],mode=record['mode'],app_sha256=verify.sha(folder/'app.json'),xml_sha256=verify.sha(folder/'time-profile.xml'))
        result['trace_files_sha256']=trace_before
        results.append(result)
    (output/'analysis.json').write_text(json.dumps(dict(schema=1,kind=manifest['kind'],source=str(root),manifest_sha256=verify.sha(root/'manifest.json'),analysis_tools=tool_hashes,binary_sha256=verify.sha(binary),symbol_sha256=verify.sha(symbol),binary_uuid=uid,runs=results),indent=2)+'\n')
    print(output/'analysis.json')


if __name__=='__main__':main()
