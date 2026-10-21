#!/usr/bin/env python3
"""Independent pane-tab native/CLI/Metal artifact verifier."""
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
        assert r['mode']=='pane_tabs' and r['passed'] and not r['errors']
        expected=r['expected'];hover=r['hover'];selected=r['selected']
        assert r['target']['source']=='pane_tabs' and hover['picking']
        assert hover['hovered']==expected
        if n==16:
            assert expected is None and json.loads((folder/'point.json').read_text())['x']<0
        else:
            assert expected['source']=='pane_tabs'
        if n in (11,12,14,20):assert not selected['picking'] and selected['selected'] is None
        elif n==17:assert selected['picking'] and selected['hovered'] is None and selected['selected'] is None
        else:assert not selected['picking'] and selected['selected']==expected
        feature=('tab','close','plus','left','right','tab','close','plus','left','right','tab','close','plus','left','close','tab','close','plus','left','plus')[n-1]
        target=r['target'];low=target['id']&0xffffffff
        if feature=='tab':assert target['role']=='tab'
        elif feature=='close':assert target['role']=='button' and 0<low<0xfffffffc
        else:assert target['role']=='button' and low=={'plus':0xfffffffc,'left':0xfffffffd,'right':0xfffffffe}[feature]
        before_nodes=r['sidebar_before']
        identities={node['id']:node for node in before_nodes}
        assert len(identities)==len(before_nodes)
        roots=[node for node in before_nodes if node['parent_id'] is None]
        assert len(roots)==(2 if 6<=n<=10 else 1)
        for node in before_nodes:
            assert node['generation']==before_nodes[0]['generation']
            if node['parent_id'] is not None:assert node['parent_id'] in identities
        if n in (9,10):assert target['parent_id']==roots[1]['id']
        after_nodes=[v for v in selected['nodes'] if v['source']=='pane_tabs']
        if n==20:
            normalize=lambda rows:[{k:v for k,v in node.items() if k not in ('generation','rect','visible_rect')} for node in rows]
            assert normalize(before_nodes)==normalize(after_nodes)
            assert before_nodes[0]['generation']!=after_nodes[0]['generation']
            assert any(a['rect']!=b['rect'] for a,b in zip(before_nodes,after_nodes))
        else:assert before_nodes==after_nodes,'product action changed tabs'
        if n in (1,3):
            assert r['control'] is not None
            assert before_nodes!=[v for v in r['control']['nodes'] if v['source']=='pane_tabs']
        if n==15:
            p=json.loads((folder/'point.json').read_text());target=r['target']
            assert p['x']==target['visible_rect']['x']+target['visible_rect']['width']
            assert expected['role']=='tab' and expected['id']!=target['parent_id']
            assert expected['rect']['x']==p['x'],'exclusive close edge did not enter the adjacent tab'
        report=(folder/'report.txt').read_text()
        cursor='arrow' if n==16 else 'crosshair'
        assert f'phase=hover cursor={cursor}' in report
        state={label:(int(place),int(flags)) for label,place,flags in re.findall(r'label=([\w-]+) placement=(\d+) [^\n]*?flags=(\d+)',report)}
        assert state['hovered'][0]==(n-1)%5+1 and state['hovered'][1]&4==0
        targets={label:int(target) for label,target in re.findall(r'label=([\w-]+) [^\n]*?target=(\d+)',report)}
        assert state['hovered'][1]&2==0 and state['selected'][1]&2==0, 'focus control must remain Follow'
        assert targets['ready']==targets['selected'], 'Pick changed the active pane/Term'
        if n in (1,3):assert targets['control']!=targets['ready'], 'normal focus/create control did not execute' 
        assert bool(state['selected'][1]&4)==(n==14)
        if n==13:assert state['pre-pick'][1]&4
        before=(folder/'baseline.ppm').read_bytes().split(b'\n',3)
        highlight=(folder/'hover.ppm').read_bytes().split(b'\n',3)
        assert before[:3]==highlight[:3]
        width,height=map(int,before[1].split())
        assert len(before[3])==len(highlight[3])==width*height*3
        if 6<=n<=10 or n==13:assert width>=1800
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
