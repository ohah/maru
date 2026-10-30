#!/usr/bin/env python3
"""외부 측정 기록을 시간·판·프레임·foreground·완전한 쌍의 경계로 검증한다."""
import argparse, hashlib, json, math, pathlib, statistics

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def require(ok,reason):
 if not ok:raise ValueError(reason)
def integer(v):return type(v) is int and v>=0
def validate(value,run,events):
 require(type(value['schema']) is int and value['schema']==1 and value['error'] is None and value['restored'] is True,'run failure')
 require(integer(value['pid']) and value['pid']==run['pid'],'process identity')
 require(value['mode']==run['mode'] and value['flow']==run['flow'],'identity')
 require(len(value['rows'])==events,'missing event')
 require(all(integer(x) and x>0 for x in value['memory']+value['baseline_memory']),'memory counter')
 require(value['memory'][0]>=value['baseline_memory'][0],'peak counter reversed')
 for i,row in enumerate(value['rows']):
  require(type(row['seq']) is int and row['seq']==i+1,'event sequence')
  require(row['foreground'] is True and row['text_verified'] is True,'foreground/text')
  prefix=('가나 '*(i//5)+['ㄱ','가','간','가나','가나 '][i%5]) if run['flow']=='ime' else 'x'*(i+1)
  require(row['visible_line']=='// '+prefix,'visible input mismatch')
  t,b,a=row['timing'],row['before'],row['after']
  require(len(t)==11 and len(b)==len(a)==7 and all(integer(x) for x in t+b+a),'record types')
  require(t[0]==i+1 and 0<t[1]<=t[3]<=t[5],'presentation order')
  if i<events-1:require(max(t[5],t[6],t[9])<value['rows'][i+1]['timing'][1],'receipt after superseding input')
  require((t[6]==0 or t[5]<=t[6]) and (t[9]==0 or t[6]>0 and t[6]<=t[9]),'color presentation order')
  require(i<events-1 or t[9]>0,'last input color incomplete')
  require(0<t[2]<=t[3],'event clock domain')
  require(t[4]==([15,40,1,40,49][i%5] if run['flow']=='ime' else 7),'wrong HID key')
  require(b[0]<t[7]<=a[0] and (not t[6] or t[7]<=t[8]<=a[0]) and (not t[9] or t[8]<=t[10]<=a[0]),'stale frame generation')
  require(a[1]>=b[1] and (a[1]>b[1] or a[2]!=b[2]),'unmodified input')
  require((a[6]>>1)==(1 if run['mode']=='async' else 0) and (b[6]>>1)==(a[6]>>1),'actual parse mode')
  require((i<events-1 or a[3]==1 and (a[6]&1)==1) and a[4]==(2 if run['flow']=='shared' else 1),'syntax/view not ready')
 return value

def percentile(xs,p):return sorted(xs)[math.ceil(len(xs)*p)-1]
def verify(root):
 manifest=json.loads((root/'manifest.json').read_text());require(not manifest.get('diagnostic',False),'diagnostic timing')
 require(manifest['source'].get('optimize')=='ReleaseFast','unoptimized measurement');require(not manifest['source'].get('continuation_fix',False),'experimental product change');events=manifest['events'];runs=manifest['runs']
 expected={(size,flow,rep,mode) for size in manifest['sizes'] for flow in manifest['flows'] for rep in range(manifest['repetitions']) for mode in ['sync','async']}
 require(len(runs)==len(expected) and {(r['size'],r['flow'],r['repeat'],r['mode']) for r in runs}==expected,'missing paired run')
 require(len({r['path'] for r in runs})==len(runs),'reused process')
 require(manifest['app_sha256']==manifest['source']['app_sha256'] and sha(pathlib.Path(manifest['build'])/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app')==manifest['app_sha256'],'binary identity')
 groups={}
 previous_end=0
 for r in runs:
  path=(root/r['path']/'result.json').resolve();require(path.is_relative_to(root),'path escapes output')
  require(r['exit']==0 and r['disk_unchanged'] is True and sha(path)==r['result_sha256'],'process/receipt')
  require(sha(root/r['path']/'document.zig')==r['fixture_sha256'],'disk fixture drift')
  require(sha(root/r['path']/'app.log')==r['app_log_sha256'],'log drift')
  require(sha(root/('flat-'+str(r['size'])+'.zig'))==r['fixture_sha256'],'fixture drift')
  v=validate(json.loads(path.read_text()),r,events)
  require(v['rows'][0]['timing'][1]>previous_end,'overlapping/replayed process');previous_end=v['rows'][-1]['timing'][9]
  rows=v['rows'][5:];require(bool(rows),'not enough post-warmup events')
  fields={'post_to_present_ms':[ (x['timing'][5]-x['timing'][1])/1e6 for x in rows],
    'queue_ms':[(x['timing'][3]-x['timing'][1])/1e6 for x in rows]}
  result={'run':r['path'],'events':len(rows),'gap_samples':len(rows)-1,'syntax_observed_in_gap':sum(x['timing'][6]>0 for x in rows[:-1]),'full_color_observed_in_gap':sum(x['timing'][9]>0 for x in rows[:-1]),'last_syntax_ms':(rows[-1]['timing'][6]-rows[-1]['timing'][1])/1e6,'last_full_color_ms':(rows[-1]['timing'][9]-rows[-1]['timing'][1])/1e6,'peak_rss_mib':v['memory'][0]/1048576,'settled_rss_mib':v['memory'][1]/1048576,
    'baseline_rss_mib':v['baseline_memory'][1]/1048576, **{k:{'median':statistics.median(xs),'p95':percentile(xs,.95),'max':max(xs)} for k,xs in fields.items()}}
  groups.setdefault((r['size'],r['flow'],r['mode']),[]).append(result)
 return {str(k):v for k,v in groups.items()}
def main():
 p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);a=p.parse_args();r=verify(a.root.resolve());print(json.dumps(r,indent=2))
if __name__=='__main__':main()
