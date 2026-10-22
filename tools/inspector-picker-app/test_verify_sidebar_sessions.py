import copy
import json
import pathlib
import tempfile
import unittest
from verify_sidebar_sessions import BASE, slot, verify


class SidebarSessionArtifacts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=pathlib.Path(self.temp.name);rounds=[]
        for n in range(1,21):
            folder=self.root/f'round-{n:02d}';folder.mkdir();(folder/'work').mkdir()
            (folder/'work/sample.txt').write_bytes(b'picker fixture\n')
            def node(i,role,parent):
                box=dict(x=i*3,y=0,width=3,height=3)
                return dict(source='sidebar',id=BASE+i,parent_id=parent,generation=2,role=role,action_id=BASE+i,enabled=True,cursor='press',rect=box,visible_rect=box)
            before=[node(0,'scroll_view',None),node(1,'tab',BASE),node(3,'button',BASE+1)]
            before += [node(i,'list_item',BASE+1) for i in (5,7,9)]
            target=next(v for v in before if v['id']==BASE+1+slot(n)*2)
            expected=None if n in (15,16) else target
            after=copy.deepcopy(before)
            if n==20:
                after=[v for v in after if v['role']!='list_item']
                for v in after:v['generation']=3
            hover=dict(picking=True,hovered=expected)
            selected=dict(picking=n==17,hovered=None,selected=None if n in (11,12,14,17,20) else expected,nodes=after)
            control=copy.deepcopy(before)
            for v in control:v['generation']=3
            if n==1:control=[v for v in control if v['role']!='list_item']
            rounds.append(dict(round=n,mode='sidebar_sessions',passed=True,errors=[],root=str(folder),target=target,expected=expected,hover=hover,selected=selected,sidebar_before=before,control=dict(nodes=control) if n<4 else None))
            place=(n-1)%5+1;flags=4 if n==14 else 0
            report=f'phase=hover cursor=hand\nphase=hover cursor={"arrow" if n==16 else "crosshair"}\nlabel=ready placement={place} target=3 flags=0\nlabel=hovered placement={place} target=3 flags=0\nlabel=selected placement={place} target=3 flags={flags}\nlabel=control placement={place} target=1 flags=0\n'
            if n==13:report+='label=pre-pick placement=3 flags=4\n'
            (folder/'report.txt').write_text(report)
            (folder/'point.json').write_text(json.dumps(dict(x=-10 if n==16 else target['rect']['x']+3 if n==15 else target['rect']['x']+1,y=1)))
            (folder/'observations.json').write_text(json.dumps([dict(elements=hover),dict(elements=selected)]))
            width=1800 if 6<=n<=10 else 32
            prefix=f'P6\n{width} 8\n255\n'.encode();pixels=bytearray(width*8*3)
            (folder/'baseline.ppm').write_bytes(prefix+pixels)
            if expected:pixels[expected['rect']['x']*3]=255
            (folder/'hover.ppm').write_bytes(prefix+pixels)
            if n in (11,12,14,17):pixels=bytes(width*8*3)
            (folder/'selected.ppm').write_bytes(prefix+pixels)
            if n%5==0:(folder/'detached.png').write_bytes(b'\x89PNG\r\n\x1a\n')
        self.data=dict(rounds=rounds,passed=True);self.save()

    def save(self):
        (self.root/'manifest.json').write_text(json.dumps(self.data))

    def test_normal_equivalent_and_restored(self):
        self.assertTrue(verify(self.root)['passed'])
        (self.root/'manifest.json').write_text(json.dumps(self.data,indent=4,sort_keys=True))
        self.assertTrue(verify(self.root)['passed'])
        self.save();self.assertTrue(verify(self.root)['passed'])

    def test_rejects_twenty_contract_defects(self):
        original=copy.deepcopy(self.data)
        changes=[
            lambda d:d['rounds'].pop(),
            lambda d:d['rounds'][0].update(mode='picker'),
            lambda d:d['rounds'][0]['target'].update(source='file_tree'),
            lambda d:d['rounds'][0]['target'].update(id=0),
            lambda d:d['rounds'][0]['target'].update(parent_id=None),
            lambda d:d['rounds'][0]['target'].update(role='text'),
            lambda d:d['rounds'][0]['target'].update(action_id=None),
            lambda d:d['rounds'][0]['target'].update(cursor='auto'),
            lambda d:d['rounds'][0]['target'].update(enabled=False),
            lambda d:d['rounds'][0]['sidebar_before'][0].update(label='secret'),
            lambda d:d['rounds'][0]['sidebar_before'][0].update(generation=9),
            lambda d:d['rounds'][0]['hover'].update(picking=False),
            lambda d:d['rounds'][0]['hover'].update(hovered=None),
            lambda d:d['rounds'][0]['selected'].update(picking=True),
            lambda d:d['rounds'][0]['selected'].update(selected=None),
            lambda d:d['rounds'][0]['selected']['nodes'].pop(),
            lambda d:d['rounds'][0].update(control=None),
            lambda d:d['rounds'][0]['control'].update(nodes=d['rounds'][0]['sidebar_before']),
            lambda d:d['rounds'][19]['selected'].update(nodes=d['rounds'][19]['sidebar_before']),
            lambda d:d['rounds'][19]['selected'].update(selected=d['rounds'][19]['target']),
        ]
        for i,mutate in enumerate(changes):
            with self.subTest(defect=i):
                self.data=copy.deepcopy(original);mutate(self.data);self.save()
                with self.assertRaises(AssertionError):verify(self.root)
        self.data=original;self.save();self.assertTrue(verify(self.root)['passed'])

    def test_rejects_native_pixel_and_file_defects(self):
        folder=self.root/'round-01'
        for file,replacement in [('report.txt',b'no native events'),('work/sample.txt',b'changed'),('hover.ppm',(folder/'baseline.ppm').read_bytes()),('observations.json',b'[]')]:
            with self.subTest(file=file):
                path=folder/file;original=path.read_bytes();path.write_bytes(replacement)
                with self.assertRaises((AssertionError,KeyError,IndexError)):verify(self.root)
                path.write_bytes(original)
        self.assertTrue(verify(self.root)['passed'])
