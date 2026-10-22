#!/usr/bin/env python3
"""Independent native/CLI/Metal oracle for canonical sidebar session rows."""
import json
import pathlib
import re
import sys

BASE = 0x5342000000000000

def slot(n):
    return 1 if n in (1,4,6,9,11,14,17,20) else 3 if n in (3,8,10,12,18) else 2

def verify(output):
    manifest=json.loads((output/'manifest.json').read_text())
    assert [v['round'] for v in manifest['rounds']]==list(range(1,21))
    samples=changed=0
    for r in manifest['rounds']:
        n=r['round'];folder=output/f'round-{n:02d}'
        target=r['target'];expected=r['expected'];hover=r['hover'];selected=r['selected'];before=r['sidebar_before']
        assert r['mode']=='sidebar_sessions' and r['passed'] and not r['errors']
        assert target['source']=='sidebar' and target['id']==BASE+1+slot(n)*2
        assert target['parent_id']==BASE+1
        assert target['role']==('button' if slot(n)==1 else 'list_item')
        assert target['action_id']==target['id'] and target['enabled'] and target['cursor']=='press'
        assert len({v['id'] for v in before})==len(before)
        assert all(not any(k in v for k in ('label','path','text','value')) for v in before)
        sessions=[v for v in before if v['role']=='list_item']
        assert len(sessions)>=3 and all(v['parent_id']==BASE+1 for v in sessions)
        assert all(v['generation']==target['generation'] for v in before)
        assert hover['picking'] and hover['hovered']==expected
        assert (pathlib.Path(r['root'])/'work/sample.txt').read_bytes()==b'picker fixture\n'
        if n in (11,12,14,20):assert not selected['picking'] and selected['selected'] is None
        elif n==17:assert selected['picking'] and selected['hovered'] is None and selected['selected'] is None
        else:assert not selected['picking'] and selected['selected']==expected
        if n not in (15,16):assert expected==target
        point=json.loads((folder/'point.json').read_text())
        if n==15:
            assert point['x']==target['visible_rect']['x']+target['visible_rect']['width']
            assert expected is None or expected['id']!=target['id']
        if n==16:assert expected is None and point['x']<0
        after=[v for v in selected['nodes'] if v['source']=='sidebar']
        if n==20:
            assert not any(v['role']=='list_item' for v in after)
            assert after and after[0]['generation']!=before[0]['generation']
        else:assert before==after,'Pick executed a normal session action'
        report=(folder/'report.txt').read_text()
        states={label:(int(place),int(flags)) for label,place,flags in re.findall(r'label=([\w-]+) placement=(\d+) [^\n]*?flags=(\d+)',report)}
        targets={label:int(t) for label,t in re.findall(r'label=([\w-]+) [^\n]*?target=(\d+)',report)}
        assert states['hovered'][0]==(n-1)%5+1
        assert states['selected'][1]&2==0 and states['hovered'][1]&2==0
        assert targets['ready']==targets['selected']
        assert bool(states['selected'][1]&4)==(n==14)
        if n==13:assert states['pre-pick'][1]&4
        cursors=re.findall(r'phase=hover cursor=([\w-]+)',report)
        assert cursors[-1]==('arrow' if n==16 else 'crosshair')
        if n not in (15,16):assert cursors[0]=='hand'
        if n in (1,2,3):
            control=r['control'];assert control is not None
            control_nodes=[v for v in control['nodes'] if v['source']=='sidebar']
            assert before!=control_nodes
            if n==1:assert not any(v['role']=='list_item' for v in control_nodes)
            else:assert targets['control']!=targets['selected'],'normal session click did not switch target'
        observations=json.loads((folder/'observations.json').read_text());samples+=len(observations)
        assert any(v['elements']==hover for v in observations)
        assert any(v['elements']==selected for v in observations)
        baseline=(folder/'baseline.ppm').read_bytes().split(b'\n',3)
        highlighted=(folder/'hover.ppm').read_bytes().split(b'\n',3)
        assert baseline[:3]==highlighted[:3]
        width,height=map(int,baseline[1].split())
        assert len(baseline[3])==len(highlighted[3])==width*height*3
        if 6<=n<=10:assert width>=1800
        if n%5==0:assert (folder/'detached.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        if expected:
            box=expected['visible_rect'];x,y,w,h=(int(box[k]) for k in ('x','y','width','height'))
            assert 0<=x<x+w<=width and 0<=y<y+h<=height
            edges=[(yy*width+xx)*3 for yy in range(y,y+h) for xx in range(x,x+w) if xx-x<2 or x+w-xx<=2 or yy-y<2 or y+h-yy<=2]
            count=sum(baseline[3][i:i+3]!=highlighted[3][i:i+3] for i in edges)
            assert count>0,'missing owner highlight';changed+=count
            picked=(folder/'selected.ppm').read_bytes().split(b'\n',3)
            assert picked[:3]==baseline[:3]
            if n in (11,12,14,17):assert all(baseline[3][i:i+3]==picked[3][i:i+3] for i in edges)
            elif n!=20:assert any(baseline[3][i:i+3]!=picked[3][i:i+3] for i in edges)
    return dict(passed=True,rounds=20,cli_samples=samples,changed_edge_pixels=changed)

if __name__=='__main__':
    output=pathlib.Path(sys.argv[1]);result=verify(output)
    (output/'verified.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
