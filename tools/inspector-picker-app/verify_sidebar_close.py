#!/usr/bin/env python3
"""Independent native/CLI/Metal oracle for published sidebar session close buttons."""
import json
import pathlib
import re
import sys

BASE = 0x5342000000000000

def slot(n):
    return 2 if n in (3,20) else 4 if n==2 else 2+(n-1)%3

def orange(data, indices):
    # Fixed default-dark product accent. Count the actual orange outline, so
    # ordinary gray row hover cannot produce a false positive in this small ROI.
    return sum(data[i]>data[i+1]+20 and data[i+1]>data[i+2]+20 and data[i]>120 for i in indices)

def verify(output):
    manifest=json.loads((output/'manifest.json').read_text())
    assert [v['round'] for v in manifest['rounds']]==list(range(1,21))
    samples=changed=0
    for r in manifest['rounds']:
        n=r['round'];folder=output/f'round-{n:02d}'
        target=r['target'];expected=r['expected'];hover=r['hover'];selected=r['selected'];before=r['sidebar_before']
        assert r['mode']=='sidebar_close' and r['passed'] and not r['errors']
        assert target['source']=='sidebar' and target['id']==BASE+2+slot(n)*2
        assert target['parent_id']==BASE+1+slot(n)*2
        assert target['role']=='button'
        assert target['action_id']==target['id'] and target['enabled'] and target['cursor']=='press'
        assert len({v['id'] for v in before})==len(before)
        assert all(not any(k in v for k in ('label','path','text','value')) for v in before)
        sessions=[v for v in before if v['role']=='list_item']
        assert len(sessions)>=3 and all(v['parent_id']==BASE+1 for v in sessions)
        assert all(v['generation']==target['generation'] for v in before)
        for row in sessions:
            buttons=[v for v in before if v['parent_id']==row['id'] and v['role']=='button']
            assert len(buttons)==1 and buttons[0]['id']==row['id']+1
            assert buttons[0]['action_id']==buttons[0]['id'] and buttons[0]['enabled'] and buttons[0]['cursor']=='press'
            button=buttons[0];a=button['rect'];b=row['rect']
            assert a['y']==b['y'] and a['height']==b['height']
            assert b['x']<=a['x']<a['x']+a['width']<=b['x']+b['width']
        ids=r['surface_ids_before'];closed=r['target_surface_id']
        assert ids==list(range(1,5 if 6<=n<=10 else 4)) and closed==ids[slot(n)-2]
        assert len(sessions)==len(ids)
        expected_ids=[v for v in ids if v!=closed]
        assert r['surface_ids_selected']==(expected_ids if n==20 else ids), 'Pick closed a real session'

        assert hover['picking'] and hover['hovered']==expected
        assert (pathlib.Path(r['root'])/'work/sample.txt').read_bytes()==b'picker fixture\n'
        if n in (11,12,14,20):assert not selected['picking'] and selected['selected'] is None
        elif n==17:assert selected['picking'] and selected['hovered'] is None and selected['selected'] is None
        else:assert not selected['picking'] and selected['selected']==expected
        if n not in (15,16):assert expected==target
        point=json.loads((folder/'point.json').read_text())
        if n==15:
            assert point['x']==target['visible_rect']['x']+target['visible_rect']['width']
            assert expected is not None and expected['id']==target['parent_id'] and expected['role']=='list_item'
        if n==16:assert expected is None and point['x']<0
        after=[v for v in selected['nodes'] if v['source']=='sidebar']
        if n==20:
            assert len([v for v in after if v['role']=='list_item'])==len(sessions)-1
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
        if n in (1,2,3,4):
            control=r['control'];assert control is not None
            control_nodes=[v for v in control['nodes'] if v['source']=='sidebar']
            assert before!=control_nodes
            assert len([v for v in control_nodes if v['role']=='list_item'])==len(sessions)-1
            assert r['surface_ids_control']==expected_ids, 'normal click closed the wrong Term'
            assert (targets['control']!=targets['selected'])==(n==2)
            if n==3:
                inventory=(folder/'inventory-before.txt').read_text()
                lines=inventory.splitlines()
                assert any(line.startswith('[1]') and 'at_prompt=false' in line for line in lines)
                assert any('*focused*' in line and 'at_prompt=true' in line for line in lines)
                assert r['confirmation'] is not None and r['confirmation']['nodes']==[]
                assert 'label=close-confirm' in report
                assert (folder/'confirm.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                assert (folder/'confirm.ppm').read_bytes()!=(folder/'baseline.ppm').read_bytes()

        if n==4:
            inventory=(folder/'inventory-before.txt').read_text().splitlines()
            assert any(line.startswith('[1]') and 'at_prompt=true' in line for line in inventory)
            assert any('*focused*' in line and 'at_prompt=false' in line for line in inventory)
        observations=json.loads((folder/'observations.json').read_text());samples+=len(observations)
        assert any(v['elements']==hover for v in observations)
        assert any(v['elements']==selected for v in observations)
        if n==3:assert any(v['elements']==r['confirmation'] for v in observations)
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
            normal=orange(baseline[3],edges)
            assert orange(highlighted[3],edges)>normal, 'row hover alone is not Inspector evidence'
            if n in (11,12,14,17):assert orange(picked[3],edges)<=normal, 'cancelled outline remained'
            elif n!=20:assert orange(picked[3],edges)>normal, 'selected outline disappeared'

    return dict(passed=True,rounds=20,cli_samples=samples,changed_edge_pixels=changed)

if __name__=='__main__':
    output=pathlib.Path(sys.argv[1]);result=verify(output)
    (output/'verified.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
