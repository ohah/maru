import copy
import json
import pathlib
import shutil
import tempfile
import unittest
from verify_file_header import verify


class FileHeaderArtifacts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=pathlib.Path(self.temp.name)
        records=[]
        for n in range(1,21):
            folder=self.root/f'round-{n:02d}';folder.mkdir();(folder/'work').mkdir()
            base=0x4648000000000000;svg=n in (4,5,9,10,18)
            fixture=folder/'work'/('sample.svg' if svg else 'sample.md')
            fixture.write_bytes(b'<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><rect width="80" height="80" fill="#579"/></svg>' if svg else b'# Inspector fixture\n\nRead only mode control.\n')
            mode=(1,2,0,1,0,0,1,2,1,0,0,1,2,0,2,1,2,1,0,1)[n-1]
            order=(0,1) if svg else (0,2,1)
            def node(identity,role,x=0,width=3,parent=None):
                box=dict(x=x,y=0,width=width,height=3)
                return dict(source='file_header',id=identity,parent_id=parent,generation=2,role=role,rect=copy.deepcopy(box),visible_rect=copy.deepcopy(box))
            nodes=[node(base,'group',width=len(order)*3)]
            nodes += [node(base+1+tag,'tab',x=index*3,parent=base) for index,tag in enumerate(order)]
            target=next(v for v in nodes if v['id']==base+1+mode)
            expected=next(v for v in nodes if v['id']==base+2) if n==15 else None if n==16 else target
            after=copy.deepcopy(nodes)
            if n==20:
                for entry in after:
                    entry['generation']=3;entry['rect']['y']+=2;entry['visible_rect']['y']+=2
            selected=None if n in (11,12,14,17,20) else expected
            control=copy.deepcopy(nodes)
            for v in control:v['generation']=4
            records.append(dict(round=n,mode='file_header',passed=True,errors=[],file_unchanged=True,root=str(folder),target=target,expected=expected,
                                hover=dict(picking=True,hovered=expected),
                                selected=dict(picking=n==17,hovered=None,selected=selected,nodes=after),
                                sidebar_before=nodes,control=dict(nodes=control) if n==1 else None))
            flags=4 if n==14 else 0;place=(n-1)%5+1;cursor='arrow' if n==16 else 'crosshair'
            report=f'phase=hover cursor={cursor}\nlabel=ready placement={place} target=1 flags=0\nlabel=hovered placement={place} target=1 flags=0\nlabel=selected placement={place} target=1 flags={flags}\n'
            if n==1:report+=f'label=control placement={place} target=1 flags=0\n'
            if n==13:report+='label=pre-pick placement=3 flags=4\n'
            (folder/'report.txt').write_text(report)
            x=-10 if n==16 else target['rect']['x']+3 if n==15 else target['rect']['x']+1.5
            (folder/'point.json').write_text(json.dumps(dict(x=x,y=1.5)))
            width=1800 if 6<=n<=10 else 16
            prefix=f'P6\n{width} 8\n255\n'.encode();pixels=bytearray(width*8*3)
            (folder/'baseline.ppm').write_bytes(prefix+pixels)
            pixels[(expected['rect']['x'] if expected else 0)*3]=255
            (folder/'hover.ppm').write_bytes(prefix+pixels)
            if n in (11,12,14,17):pixels=bytes(width*8*3)
            (folder/'selected.ppm').write_bytes(prefix+pixels)
            (folder/'observations.json').write_text('[{}]')
            if n%5==0:(folder/'detached.png').write_bytes(b'\x89PNG\r\n\x1a\n')
        (self.root/'manifest.json').write_text(json.dumps(dict(rounds=records,passed=True)))

    def test_normal_equivalent_and_restored(self):
        self.assertTrue(verify(self.root)['passed'])
        path=self.root/'manifest.json';data=json.loads(path.read_text())
        path.write_text(json.dumps(data,indent=4,sort_keys=True))
        self.assertTrue(verify(self.root)['passed'])
        path.write_text(json.dumps(data))
        self.assertTrue(verify(self.root)['passed'])

    def test_reject_artifact_defects(self):
        defects=('count','scope','feature','parent','boundary','product-action','cancel-select','pick-retained','resume','pause','initial-pause','reflow','stale-selection','file-bytes','normal-control-hidden','cancel-highlight','hover-highlight','selected-highlight','cursor','scale','detached','product-focus','pinned-focus-proxy')
        for defect in defects:
            with self.subTest(defect=defect),tempfile.TemporaryDirectory() as temp:
                dest=pathlib.Path(temp)/'copy';shutil.copytree(self.root,dest)
                path=dest/'manifest.json';data=json.loads(path.read_text());rows=data['rounds']
                for row in rows:row['root']=str(dest/f"round-{row['round']:02d}")
                if defect=='normal-control-hidden':rows[0]['control']['nodes']=[]
                elif defect=='file-bytes':(dest/'round-01/work/sample.md').write_text('changed')
                elif defect=='count':rows.pop()
                elif defect=='scope':rows[0]['target']['source']='sidebar'
                elif defect=='feature':rows[2]['target']['id']+=1
                elif defect=='parent':rows[0]['sidebar_before'][-1]['parent_id']=999
                elif defect=='boundary':(dest/'round-15/point.json').write_text('{"x":2.5,"y":1.5}')
                elif defect=='product-action':rows[0]['selected']['nodes']=[]
                elif defect=='cancel-select':rows[10]['selected']['selected']=rows[10]['expected']
                elif defect=='pick-retained':rows[11]['selected']['picking']=True
                elif defect in ('resume','pause','initial-pause','cursor','product-focus','pinned-focus-proxy'):
                    n=14 if defect=='pause' else 16 if defect=='cursor' else 13
                    file=dest/f'round-{n:02d}'/'report.txt';text=file.read_text()
                    if defect=='resume':text=text.replace('label=hovered placement=3 target=1 flags=0','label=hovered placement=3 target=1 flags=4')
                    elif defect=='pause':text=text.replace('label=selected placement=4 target=1 flags=4','label=selected placement=4 target=1 flags=0')
                    elif defect=='initial-pause':text=text.replace('label=pre-pick placement=3 flags=4','label=pre-pick placement=3 flags=0')
                    elif defect=='product-focus':text=text.replace('label=selected placement=3 target=1','label=selected placement=3 target=2')
                    elif defect=='pinned-focus-proxy':text=text.replace('label=hovered placement=3 target=1 flags=0','label=hovered placement=3 target=1 flags=2')
                    else:text=text.replace('cursor=arrow','cursor=crosshair')
                    file.write_text(text)
                elif defect=='reflow':
                    for a,b in zip(rows[19]['selected']['nodes'],rows[19]['sidebar_before']):a['rect']=b['rect']
                elif defect=='stale-selection':rows[19]['selected']['selected']=rows[19]['expected']
                elif defect in ('cancel-highlight','hover-highlight','selected-highlight'):
                    n=11 if defect=='cancel-highlight' else 1
                    source='hover' if defect=='cancel-highlight' else 'baseline'
                    target='hover' if defect=='hover-highlight' else 'selected'
                    folder=dest/f'round-{n:02d}';(folder/f'{target}.ppm').write_bytes((folder/f'{source}.ppm').read_bytes())
                elif defect=='scale':
                    for name in ('baseline','hover','selected'):
                        p=dest/f'round-07/{name}.ppm';p.write_bytes(p.read_bytes().replace(b'1800 8',b'8 1800',1))
                elif defect=='detached':(dest/'round-05/detached.png').unlink()
                path.write_text(json.dumps(data))
                with self.assertRaises(AssertionError):verify(dest)
        self.assertTrue(verify(self.root)['passed'])
