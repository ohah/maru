#!/usr/bin/env python3
"""실제 worker/helper의 첫 출력·취소·수거·부분 결과를 독립 fixture로 측정한다."""
import argparse,json,subprocess,tempfile,time,os,shutil,hashlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--worker',type=Path,required=True);p.add_argument('--rg',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();base=a.output.resolve();base.mkdir(parents=True,exist_ok=True);out=Path(tempfile.mkdtemp(prefix='run-',dir=base))
worker=a.worker.resolve();rg=a.rg.resolve();cases=[]
def run(name,root,query,cancel=-1,budget=8*1024*1024,occupied=()):
    started=time.monotonic()
    result=subprocess.run([str(worker),str(rg),str(root),query,str(cancel),str(budget),*occupied],capture_output=True,timeout=15)
    (out/(name+'.stdout')).write_bytes(result.stdout);(out/(name+'.stderr')).write_bytes(result.stderr)
    assert result.returncode==0,(name,result.stderr.decode(errors='replace'))
    lines=[json.loads(line) for line in result.stdout.splitlines()];summary=lines[-1]
    pid=summary['stats']['child_pid']
    if pid is not None:
        assert summary['stats']['reaped'], (name,'helper not reaped')
        try: os.kill(pid,0)
        except ProcessLookupError: pass
        else: raise AssertionError((name,'helper still alive'))
    cases.append(dict(name=name,summary=summary,wall_ms=round((time.monotonic()-started)*1000)))
    return lines[:-1],summary
report={'status':'running','cases':cases,'worker_sha256':hashlib.sha256(worker.read_bytes()).hexdigest(),'rg_sha256':hashlib.sha256(rg.read_bytes()).hexdigest()}
try:
    root=out/'files';root.mkdir();(root/'a.txt').write_text('foo\nfoo\n');(root/'b.txt').write_text('foo\n')
    ownership=subprocess.run([str(worker),'--audit-ownership',str(rg),str(root)],capture_output=True,timeout=30)
    (out/'ownership.stdout').write_bytes(ownership.stdout);(out/'ownership.stderr').write_bytes(ownership.stderr)
    assert ownership.returncode==0,ownership.stderr.decode(errors='replace')
    report['ownership_audit']='passed'
    rows,s=run('normal',root,'foo');assert s['status']=='complete' and s['matches']==3
    rows,s=run('occupied-zero',root,'foo',occupied=('a.txt',));assert s['matches']==1 and all(row['path'].removeprefix('./')!='a.txt' for row in rows)
    rows,s=run('budget',root,'foo',budget=0);assert s['status']=='partial' and s['matches']==0
    rows,s=run('pre-cancel',root,'foo',cancel=0);assert s['status']=='cancelled' and s['matches']==0
    rows,s=run('normalized-open-model-zero',root,'foo',occupied=('--model','././a.txt','absent'))
    assert s['status']=='complete' and s['matches']==1 and all(row['path'].removeprefix('./')!='a.txt' for row in rows)
    rows,s=run('model-zero-overrides-disk',root,'foo',occupied=('--model','a.txt','absent'))
    assert s['matches']==1 and all(row['path'].removeprefix('./')!='a.txt' for row in rows)
    rows,s=run('independent-models-same-path',root,'foo',occupied=('--model','a.txt','foo foo','--model','a.txt','foo'))
    assert s['matches']==4
    rows,s=run('model-unicode-coordinates',root,'foo',occupied=('--model','a.txt','😀가foo\r\nfoo'))
    assert s['matches']==3
    model_rows=[r for r in rows if r['path']=='a.txt']
    assert [(r['ranges'][0]['start']['line'],r['ranges'][0]['start']['byte']) for r in model_rows]==[(0,7),(1,0)]
    assert model_rows[0]['text_start']=={'line':0,'byte':7}
    rows,s=run('shared-model-once',root,'foo',occupied=('--shared','a.txt','foo','--shared','a.txt','foo'))
    assert s['matches']==2
    vcs=out/'.git'/'objects';vcs.mkdir(parents=True);(vcs/'a.txt').write_text('foo\n')
    rows,s=run('vcs-root-rejected',vcs,'foo',occupied=('--model','a.txt','foo'));assert s['status']=='failed' and s['failure']=='VcsRoot' and not rows
    alias=out/'vcs-alias';alias.mkdir();(alias/'.git').symlink_to(root,target_is_directory=True)
    rows,s=run('vcs-logical-root-alias-rejected',alias/'.git','foo');assert s['status']=='failed' and s['failure']=='VcsRoot'

    rows,s=run('model-fold',root,'σ',occupied=('--fold','--model','a.txt','Σσς'))
    assert s['matches']==3
    rows,s=run('model-word-policy',root,'foo',occupied=('--word','--model','a.txt','foo$bar foo😀bar foo_bar foo'))
    assert len([r for r in rows if r['path']=='a.txt'])==2
    rows,s=run('model-full-document-regex',root,r'foo\r?\nbar',occupied=('--regex','--model','a.txt','foo\r\nbar'))
    assert s['matches']==1 and rows[0]['ranges'][0]['end']=={'line':1,'byte':3}
    rows,s=run('model-empty-first-alternative',root,r'^|foo',occupied=('--regex','--model','a.txt','foo'))
    assert [(r['ranges'][0]['start']['byte'],r['ranges'][0]['end']['byte']) for r in rows if r['path']=='a.txt']==[(0,0)]
    rows,s=run('empty-model-regex-EOF',root,'^$',occupied=('--regex','--model','a.txt',''))
    assert s['status']=='complete' and s['matches']==1 and rows[0]['ranges'][0]=={'start':{'line':0,'byte':0},'end':{'line':0,'byte':0}}
    rows,s=run('immutable-model-after-edit',root,'changed-after-capture',occupied=('--mutate','--model','a.txt','foo'))
    assert s['status']=='complete' and s['matches']==0
    scope=out/'scope';scope.mkdir()
    names=['src/a.zig','src/deep/b.zig','other/c.zig','src/a.txt','src/b.txt','src/c.txt','top.zig','a.zig/inside.txt','a[0].txt','axb.txt','src/a/deep/b.txt','a.txt','b.txt','n.txt','t.txt','f.txt','r.txt','v.txt','dir/a.txt','deep/dir/a.txt','汉.txt','😀.txt','a/b/c.txt','a].txt',r'\.txt',r'\a].txt','-.txt','].txt']
    for name in names:
        file=scope/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_text('foo\n')
    glob_cases=[['--include','**b.txt'],['--include','src/**b.txt'],['--include','**/b.txt'],['--include','{src,other}/**/*.zig'],['--include','**/*.{zig,txt}'],['--include','**/{a,b}.txt'],['--include','[^a]*.txt'],['--include','src/[!c].txt'],['--include','[[]*.txt'],['--include',r'\axb.txt'],['--include','src/a**b.txt'],['--include','src/*.zig'],['--include','src'],['--include','**/*.zig'],['--include','src/{a,b}.txt'],['--include','src/[ab].txt'],['--exclude','src/**'],['--include','src/**','--exclude','src/deep/**'],['--include',r'a\[0\].txt'],['--include','SRC/*.ZIG','--glob-case']]
    glob_cases += [['--include',pattern] for pattern in [r'[\a].txt',r'[\b].txt',r'[\n].txt',r'[\t].txt',r'[\f].txt',r'[\r].txt',r'[\v].txt','{**/a.txt,b.txt}','**/{**/a.txt,b.txt}','[😀汉].txt','**/?.txt']]
    glob_cases += [['--include',pattern] for pattern in ['**/{a/**,dir/**}','{,dir/}a.txt',r'[\-a].txt',r'[\]a].txt','{a.txt,}','{,}','{**/a.txt,{,dir/**}}']]
    for n,flags in enumerate(glob_cases):
        disk,ds=run(f'glob-disk-{n}',scope,'foo',occupied=flags)
        models=[]
        for name in names:models+=['--model',name,'foo\n']
        opened,ms=run(f'glob-model-{n}',scope,'foo',occupied=flags+models)
        assert ds['status']==ms['status']=='complete'
        assert sorted(r['path'].removeprefix('./') for r in disk)==sorted(r['path'].removeprefix('./') for r in opened),(flags,disk,opened)
    ignored=out/'ignored-open';ignored.mkdir();(ignored/'.gitignore').write_text('a.txt\n');(ignored/'a.txt').write_text('foo\n')
    rows,s=run('ignored-open-model',ignored,'foo',occupied=('--model','a.txt','foo'))
    assert s['matches']==1 and rows[0]['path']=='a.txt'
    dense=out/'dense';dense.mkdir();(dense/'dense.txt').write_bytes(b'foo\n'*1000000)
    rows,s=run('result-cap',dense,'foo');assert s['status']=='partial' and s['matches']<=20000
    rows,s=run('stale-root-generation',dense,'foo',occupied=('--stale',));assert s['status']=='cancelled' and not rows

    large=out/'large';large.mkdir()
    with (large/'long.txt').open('wb') as f:
        for _ in range(128):f.write(b'a'*1024*1024)
    rows,s=run('large-cancel',large,'missing',cancel=1);assert s['status']=='cancelled' and s['cancel_latency_ms']<1000
    cycle=out/'cycle';cycle.mkdir();(cycle/'a.txt').write_text('foo\n');(cycle/'loop').symlink_to(cycle,target_is_directory=True)
    rows,s=run('symlink-cycle',cycle,'foo');assert s['status']=='partial'
    fifo=out/'fifo';fifo.mkdir();os.mkfifo(fifo/'pipe');(fifo/'a.txt').write_text('foo\n')
    rows,s=run('fifo-skipped',fifo,'foo');assert s['status']=='complete' and s['matches']==1
    # 제품의 고정 번들 locator는 PATH의 rg와 별개로 같은 공식 사본을 선택한다.
    original_worker,original_rg=worker,rg
    bundle=out/'Maru.app'/'Contents';(bundle/'MacOS').mkdir(parents=True);(bundle/'Helpers').mkdir()
    shutil.copy2(worker,bundle/'MacOS'/'probe');shutil.copy2(rg,bundle/'Helpers'/'rg')
    worker=bundle/'MacOS'/'probe';rg=Path('@bundle')
    rows,s=run('bundle-helper',root,'foo');assert s['status']=='complete' and s['matches']==3
    worker,rg=original_worker,original_rg
    # callback 오류가 난 직후에도 child를 죽이고 수거해야 한다.
    fake=out/'malformed-helper';fake.write_text('#!/usr/bin/python3\nimport sys,time\nprint(\'{"type":"unexpected"}\',flush=True)\ntime.sleep(5)\n');fake.chmod(0o755)
    rg=fake
    rows,s=run('malformed-helper-reaped',root,'foo');assert s['status']=='failed' and s['failure']=='UnknownEvent'
    oversized=out/'oversized-helper';oversized.write_text('#!/usr/bin/python3\nimport json,time\nprint(json.dumps({"type":"summary","data":{"stats":{"matches":0}},"extra":"a"*(5*1024*1024)}),flush=True)\ntime.sleep(5)\n');oversized.chmod(0o755)
    rg=oversized
    rows,s=run('oversized-event-partial-reaped',root,'foo');assert s['status']=='partial' and s['failure']=='EventTooLarge' and not rows
    replaced=out/'root-replaced';replaced.mkdir()
    changer=out/'root-change-helper';changer.write_text('#!/usr/bin/python3\nimport os,json\np=os.getcwd()\nos.rename(p,p+".old")\nos.mkdir(p)\nprint(json.dumps({"type":"summary","data":{"stats":{"matches":0}}}),flush=True)\n');changer.chmod(0o755)
    rg=changer
    rows,s=run('root-replaced-rejected',replaced,'foo');assert s['status']=='failed' and s['failure']=='RootChanged'
    mismatch=out/'mismatch-helper';mismatch.write_text('#!/usr/bin/python3\nimport json,time\nprint(json.dumps({"type":"summary","data":{"stats":{"matches":1}}}),flush=True)\ntime.sleep(5)\n');mismatch.chmod(0o755)
    rg=mismatch
    rows,s=run('summary-count-mismatch-reaped',root,'foo');assert s['status']=='failed' and s['failure']=='SummaryMismatch'
    summary_line=json.dumps({'type':'summary','data':{'stats':{'matches':0}}})
    hostile=[
        ('duplicate-summary',f'print({summary_line!r},flush=True)\nprint({summary_line!r},flush=True)\ntime.sleep(5)', 'failed','EventAfterSummary'),
        ('truncated-json','sys.stdout.write(\'{"type":"summary"\');sys.stdout.flush()\ntime.sleep(5)', 'cancelled',None),
        ('signal-after-summary',f'print({summary_line!r},flush=True)\nos.kill(os.getpid(),9)', 'failed','HelperTerminated'),
        ('error-exit-after-summary',f'print({summary_line!r},flush=True)\nsys.exit(2)', 'partial',None),
        ('closed-stdout-live-child',f'print({summary_line!r},flush=True)\nos.close(1)\ntime.sleep(5)', 'cancelled',None),
    ]
    for name,body,status,failure in hostile:
        fake=out/(name+'-helper');fake.write_text('#!/usr/bin/python3\nimport sys,time,os\n'+body+'\n');fake.chmod(0o755);rg=fake
        rows,s=run(name,root,'foo',cancel=100 if status=='cancelled' else -1)
        assert s['status']==status and s['failure']==failure,(name,s)
    rg=Path('/usr/bin/true')
    rows,s=run('empty-success-output-rejected',root,'foo');assert s['status']=='failed' and s['failure']=='IncompleteOutput'
    sleepy=out/'deadline-helper';sleepy.write_text('#!/usr/bin/python3\nimport json,time\nprint('+repr(summary_line)+',flush=True)\ntime.sleep(5)\n');sleepy.chmod(0o755);rg=sleepy
    rows,s=run('execution-deadline',root,'foo',occupied=('--execution-ms','100'))
    assert s['status']=='partial' and s['failure'] is None and s['stats']['elapsed_ms']<1000
    hostile_more=[
        ('empty-exit-one','sys.exit(1)',-1,'failed','IncompleteOutput'),
        ('truncated-eof','sys.stdout.write(\'{"type":"summary"\');sys.stdout.flush()',-1,'failed','IncompleteEvent'),
        ('stderr-flood',f'os.write(2,b"x"*1048576)\nprint({summary_line!r},flush=True)',-1,'complete',None),
        ('continuous-stdout','while True: os.write(1,b\'{"type":"begin"}\\n\'*100)',100,'cancelled',None),
    ]
    for name,body,cancel,status,failure in hostile_more:
        fake=out/(name+'-helper');fake.write_text('#!/usr/bin/python3\nimport sys,time,os\n'+body+'\n');fake.chmod(0o755);rg=fake
        rows,s=run(name,root,'foo',cancel=cancel)
        assert s['status']==status and s['failure']==failure,(name,s)
    rg=original_rg
    report['status']='passed'  
except Exception as e:
    report['status']='failed';report['error']=repr(e);raise
finally:
    (out/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    (base/'latest.json').write_text(json.dumps({'status':report['status'],'report':str((out/'verification.json').relative_to(base))})+'\n')
    print(out/'verification.json')
