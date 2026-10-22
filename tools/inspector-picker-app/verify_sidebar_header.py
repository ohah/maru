#!/usr/bin/env python3
"""Independent painted file-header-details native/CLI/Metal artifact verifier."""
import json
import pathlib
import re
import sys


def verify(output):
    m=json.loads((output/'manifest.json').read_text())
    assert [r['round'] for r in m['rounds']]==list(range(1,21))
    samples=changed=0
    for r in m['rounds']:
        n=r['round'];folder=output/f'round-{n:02d}'
        assert r['mode']=='sidebar_header' and r['passed'] and not r['errors']
        expected=r['expected'];hover=r['hover'];selected=r['selected']
        assert r['target']['source']=='sidebar_header' and hover['picking']
        assert hover['hovered']==expected
        if n==16:
            assert expected is None and json.loads((folder/'point.json').read_text())['x']<0
        elif n!=15:
            assert expected['source']=='sidebar_header'
        if n in (11,12,14,20):assert not selected['picking'] and selected['selected'] is None
        elif n==17:assert selected['picking'] and selected['hovered'] is None and selected['selected'] is None
        else:assert not selected['picking'] and selected['selected']==expected
        target=r['target']
        if n not in (15,16):assert expected==target, 'hover missed the intended mode'
        root_id=0x5348000000000000
        part=(3,1,2,4,0,3,4,3,4,4,2,4,0,1,2,0,3,0,4,3)[n-1]
        assert target['id']==root_id+1+part and target['parent_id']==root_id
        assert target['role']==('text' if part==0 else 'button')
        assert target['action_id']==target['id'] and target['enabled']
        assert target['cursor']==('text' if part==0 else 'press')
        fixture=pathlib.Path(r['root'])/'work'/'sample.txt'
        assert fixture.read_bytes()==b'picker fixture\n', 'Pick changed file bytes'
        before_nodes=r['sidebar_before']
        order=(3,4) if 6<=n<=10 else tuple(range(5))
        assert len(before_nodes)==len(order)+1
        assert len({v['id'] for v in before_nodes})==len(before_nodes)
        roots=[v for v in before_nodes if v['parent_id'] is None]
        assert len(roots)==1 and roots[0]['id']==root_id
        assert {v['id'] for v in before_nodes}=={root_id}|{root_id+1+i for i in order}
        assert all(not any(k in v for k in ('label','text','path','value')) for v in before_nodes)
        assert all(v['parent_id']==root_id and v['generation']==roots[0]['generation'] for v in before_nodes[1:])
        after_nodes=[v for v in selected['nodes'] if v['source']=='sidebar_header']
        if n==20:
            assert selected['selected'] is None
            assert {v['id'] for v in after_nodes}=={root_id,root_id+4,root_id+5}
            assert before_nodes[0]['generation']!=after_nodes[0]['generation']
            old=next(v for v in before_nodes if v['id']==root_id+4)
            new=next(v for v in after_nodes if v['id']==root_id+4)
            assert old['rect']!=new['rect'], 'collapse did not change geometry'
        else:assert before_nodes==after_nodes,'Pick executed a product action'
        if n==1:
            assert r['control'] is not None
            control=[v for v in r['control']['nodes'] if v['source']=='sidebar_header']
            assert {v['id'] for v in control}=={root_id,root_id+4,root_id+5}
            assert before_nodes[0]['generation']!=control[0]['generation']
        if n==15:
            point=json.loads((folder/'point.json').read_text())
            assert point['x']==target['visible_rect']['x']+target['visible_rect']['width']
            assert expected is None or expected['id']!=target['id']
        report=(folder/'report.txt').read_text()
        if n not in (15,16):assert re.findall(r'phase=hover cursor=([\w-]+)',report)[0]==('ibeam' if part==0 else 'hand'), 'normal control cursor mismatch'
        cursor='arrow' if n==16 else 'crosshair'
        assert f'phase=hover cursor={cursor}' in report
        state={label:(int(place),int(flags)) for label,place,flags in re.findall(r'label=([\w-]+) placement=(\d+) [^\n]*?flags=(\d+)',report)}
        assert state['hovered'][0]==(n-1)%5+1 and state['hovered'][1]&4==0
        targets={label:int(target) for label,target in re.findall(r'label=([\w-]+) [^\n]*?target=(\d+)',report)}
        assert state['hovered'][1]&2==0 and state['selected'][1]&2==0, 'focus control must remain Follow'
        assert targets['ready']==targets['selected'], 'Pick changed the active pane/Term'
        assert bool(state['selected'][1]&4)==(n==14)
        if n==13:assert state['pre-pick'][1]&4
        before=(folder/'baseline.ppm').read_bytes().split(b'\n',3)
        highlight=(folder/'hover.ppm').read_bytes().split(b'\n',3)
        assert before[:3]==highlight[:3]
        width,height=map(int,before[1].split())
        assert len(before[3])==len(highlight[3])==width*height*3
        if 6<=n<=10:assert width>=1800
        if n%5==0:
            assert (folder/'detached.png').exists()
            assert (folder/'detached.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        if expected:
            box=expected['visible_rect'];x,y,w,h=(int(box[k]) for k in ('x','y','width','height'))
            assert 0<=x<x+w<=width and 0<=y<y+h<=height
            edge=[(yy*width+xx)*3 for yy in range(y,y+h) for xx in range(x,x+w) if xx-x<2 or x+w-xx<=2 or yy-y<2 or y+h-yy<=2]
            pixels=sum(before[3][i:i+3]!=highlight[3][i:i+3] for i in edge)
            assert pixels>0,'missing painted owner boundary'
            changed+=pixels
            if n in (11,12,14,17):
                cancelled=(folder/'selected.ppm').read_bytes().split(b'\n',3)
                assert cancelled[:3]==before[:3] and len(cancelled[3])==len(before[3])
                assert all(before[3][i:i+3]==cancelled[3][i:i+3] for i in edge),'cancelled highlight remained'
            elif n!=20:
                picked=(folder/'selected.ppm').read_bytes().split(b'\n',3)
                assert picked[:3]==before[:3] and len(picked[3])==len(before[3])
                assert any(before[3][i:i+3]!=picked[3][i:i+3] for i in edge),'selected owner boundary disappeared'
        samples+=len(json.loads((folder/'observations.json').read_text()))
    return dict(passed=True,rounds=20,cli_samples=samples,changed_edge_pixels=changed)


if __name__=='__main__':
    output=pathlib.Path(sys.argv[1]);v=verify(output)
    (output/'verified.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
