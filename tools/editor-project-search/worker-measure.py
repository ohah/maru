#!/usr/bin/env python3
"""합성 파일에서 worker 프로브의 첫 실제 일치·종료·프로세스 peak RSS를 측정한다(앱 RSS 아님)."""
import argparse,json,re,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--worker',type=Path,required=True);p.add_argument('--rg',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True);out=Path(tempfile.mkdtemp(prefix='measure-',dir=a.output));root=out/'root';root.mkdir();(root/'disk.txt').write_text('foo\n')
records=[]
for size in [1024*1024,16*1024*1024,32*1024*1024]:
    native=out/f'model-{size}.txt';native.write_bytes(b'a'*(size-4)+b'foo\n')
    for cancel in [-1,1]:
        name=f'{size}-cancel-{cancel}'
        cmd=['/usr/bin/time','-l',str(a.worker.resolve()),str(a.rg.resolve()),str(root.resolve()),'foo',str(cancel),str(8*1024*1024),'--model-file','model.txt',str(native.resolve())]
        started=time.monotonic();proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        first=None;summary=None;lines=[]
        for line in proc.stdout:
            lines.append(line);event=json.loads(line)
            if 'ranges' in event and first is None:first=round((time.monotonic()-started)*1000,2)
            if 'status' in event:summary=event
        stderr=proc.stderr.read();assert proc.wait(timeout=15)==0
        (out/(name+'.stdout')).write_text(''.join(lines));(out/(name+'.stderr')).write_text(stderr)
        rss=re.search(r'(\d+)\s+maximum resident set size',stderr);assert rss
        records.append(dict(model_bytes=size,cancel_after_ms=cancel,first_match_wall_ms=first,wall_ms=round((time.monotonic()-started)*1000,2),peak_probe_rss_bytes=int(rss.group(1)),summary=summary))
report=dict(scope='standalone actual backend; includes native file initialization, not Maru GUI RSS or all filesystem cancellation guarantee',records=records)
(out/'measurement.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(out/'measurement.json')
