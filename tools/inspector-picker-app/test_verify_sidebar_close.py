import copy
import json
import unittest
import test_verify_sidebar_sessions as fixtures
from verify_sidebar_close import BASE, slot, verify


class SidebarCloseArtifacts(unittest.TestCase):
    def setUp(self):
        case=fixtures.SidebarSessionArtifacts();case.setUp();self.addCleanup(case.doCleanups)
        self.root=case.root;self.data=case.data
        for r in self.data['rounds']:
            n=r['round'];folder=self.root/f'round-{n:02d}'
            count=4 if 6<=n<=10 else 3
            def node(i,role,parent,x=0,y=0,width=32):
                box=dict(x=x,y=y,width=width,height=3)
                return dict(source='sidebar',id=BASE+i,parent_id=parent,generation=2,role=role,action_id=BASE+i,enabled=True,cursor='press',rect=box,visible_rect=box)
            before=[node(0,'scroll_view',None,width=0),node(1,'tab',BASE),node(3,'button',BASE+1,y=4)]
            for i in range(count):
                before += [node(5+2*i,'list_item',BASE+1,y=8+4*i),node(6+2*i,'button',BASE+5+2*i,x=20,y=8+4*i,width=3)]
            target=next(v for v in before if v['id']==BASE+2+slot(n)*2)
            expected=None if n==16 else next(v for v in before if v['id']==target['parent_id']) if n==15 else target
            after=copy.deepcopy(before)
            if n==20:
                after=[v for v in after if v['id']<BASE+5+2*(count-1)]
                for v in after:v['generation']=3
            hover=dict(picking=True,hovered=expected)
            selected=dict(picking=n==17,hovered=None,selected=None if n in (11,12,14,17,20) else expected,nodes=after)
            control=[copy.deepcopy(v) for v in before if v['id']<BASE+5+2*(count-1)]
            for v in control:v['generation']=3
            ids=list(range(1,count+1));closed=ids[slot(n)-2];remaining=[v for v in ids if v!=closed]
            confirmation=dict(picking=False,nodes=[]) if n==3 else None
            r.update(mode='sidebar_close',target=target,expected=expected,hover=hover,selected=selected,sidebar_before=before,control=dict(nodes=control) if n<5 else None,
                     surface_ids_before=ids,surface_ids_selected=remaining if n==20 else ids,surface_ids_control=remaining if n<5 else None,target_surface_id=closed,confirmation=confirmation)
            place=(n-1)%5+1;flags=4 if n==14 else 0;active=count
            report=f'phase=hover cursor=hand\nphase=hover cursor={"arrow" if n==16 else "crosshair"}\nlabel=ready placement={place} target={active} flags=0\nlabel=hovered placement={place} target={active} flags=0\nlabel=selected placement={place} target={active} flags={flags}\nlabel=control placement={place} target={active-1 if n==2 else active} flags=0\n'
            if n==13:report+='label=pre-pick placement=3 flags=4\n'
            if n==3:(folder/'inventory-before.txt').write_text('[1] terminal at_prompt=false\n[3] terminal *focused* at_prompt=true\n')
            if n==4:(folder/'inventory-before.txt').write_text('[1] terminal at_prompt=true\n[3] terminal *focused* at_prompt=false\n')
            if n==3:report+='label=close-confirm placement=3 target=3 flags=0\n'
            (folder/'report.txt').write_text(report)
            (folder/'point.json').write_text(json.dumps(dict(x=-10 if n==16 else target['rect']['x']+3 if n==15 else target['rect']['x']+1,y=target['rect']['y']+1)))
            observations=[dict(elements=hover),dict(elements=selected)]
            if n==3:observations.append(dict(elements=confirmation))
            (folder/'observations.json').write_text(json.dumps(observations))
            width=1800 if 6<=n<=10 else 32
            prefix=f'P6\n{width} 32\n255\n'.encode();pixels=bytearray(width*32*3)
            (folder/'baseline.ppm').write_bytes(prefix+pixels)
            if expected:
                offset=(expected['rect']['y']*width+expected['rect']['x'])*3
                pixels[offset:offset+3]=bytes((230,160,80))
            (folder/'hover.ppm').write_bytes(prefix+pixels)
            (folder/'selected.ppm').write_bytes(prefix+(bytes(width*32*3) if n in (11,12,14,17) else pixels))
            if n==3:
                (folder/'confirm.ppm').write_bytes(prefix+bytes([90])*(width*32*3))
                (folder/'confirm.png').write_bytes(b'\x89PNG\r\n\x1a\n')
        self.save()

    def save(self):
        (self.root/'manifest.json').write_text(json.dumps(self.data))

    def test_normal_equivalent_and_restored(self):
        self.assertTrue(verify(self.root)['passed'])
        (self.root/'manifest.json').write_text(json.dumps(self.data,sort_keys=True,indent=4))
        self.assertTrue(verify(self.root)['passed']);self.save();self.assertTrue(verify(self.root)['passed'])

    def test_rejects_close_specific_defects(self):
        original=copy.deepcopy(self.data)
        variants=[
            lambda d:d['rounds'].pop(),
            lambda d:d['rounds'][0].update(mode='sidebar_sessions'),
            lambda d:d['rounds'][0]['target'].update(source='pane_tabs'),
            lambda d:d['rounds'][0]['target'].update(id=0),
            lambda d:d['rounds'][0]['target'].update(parent_id=BASE+1),
            lambda d:d['rounds'][0]['target'].update(role='list_item'),
            lambda d:d['rounds'][0]['target'].update(action_id=None),
            lambda d:d['rounds'][0]['target'].update(cursor='auto'),
            lambda d:d['rounds'][0]['target'].update(enabled=False),
            lambda d:d['rounds'][0]['sidebar_before'][0].update(label='private'),
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
            lambda d:d['rounds'][0].update(surface_ids_selected=[2,3]),
            lambda d:d['rounds'][1].update(surface_ids_control=[1,3]),
            lambda d:d['rounds'][0].update(target_surface_id=2),
            lambda d:d['rounds'][2].update(confirmation=None),
            lambda d:d['rounds'][0]['target']['rect'].update(width=99),
            lambda d:d['rounds'][0]['sidebar_before'].pop(),
        ]
        for i,mutate in enumerate(variants):
            with self.subTest(defect=i):
                self.data=copy.deepcopy(original);mutate(self.data);self.save()
                with self.assertRaises(AssertionError):verify(self.root)
        self.data=original;self.save();self.assertTrue(verify(self.root)['passed'])

    def test_rejects_native_pixels_files_and_false_row_hover(self):
        folder=self.root/'round-01'
        for file,replacement in [('report.txt',b'no events'),('work/sample.txt',b'changed'),('hover.ppm',(folder/'baseline.ppm').read_bytes()),('observations.json',b'[]')]:
            with self.subTest(file=file):
                p=folder/file;old=p.read_bytes();p.write_bytes(replacement)
                with self.assertRaises((AssertionError,KeyError,IndexError)):verify(self.root)
                p.write_bytes(old)
        p=folder/'hover.ppm';old=p.read_bytes();parts=old.split(b'\n',3)
        p.write_bytes(b'\n'.join(parts[:3])+b'\n'+bytes([110])*len(parts[3]))
        with self.assertRaises(AssertionError):verify(self.root)
        p.write_bytes(old)
        p=self.root/'round-03/inventory-before.txt';old=p.read_bytes()
        p.write_text('[1] terminal at_prompt=true\n[3] terminal *focused* at_prompt=true\n')
        with self.assertRaises(AssertionError):verify(self.root)
        p.write_bytes(old);self.assertTrue(verify(self.root)['passed'])
