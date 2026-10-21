import copy
import json
import pathlib
import tempfile
import unittest
from verify_sidebar import verify


class SidebarArtifacts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.manifest = dict(passed=True, rounds=[])
        for n in range(1, 6):
            node = dict(source='sidebar', role={1:'tab',2:'tree_item',3:'tree_item',4:'button',5:'button'}[n], visible_rect=dict(x=0,y=0,width=3,height=3))
            self.manifest['rounds'].append(dict(round=n,mode='sidebar',passed=True,errors=[],expected=node,
                hover=dict(picking=True,hovered=node),selected=dict(picking=False,selected=node,nodes=[node]),sidebar_before=[node],control=dict(nodes=[])))
            folder = self.root / f'round-{n:02d}'
            folder.mkdir()
            (folder/'report.txt').write_text(f'phase=hover cursor=crosshair placement={n}')
            width = 1800 if n == 5 else 5
            prefix = f'P6\n{width} 5\n255\n'.encode()
            pixels = bytes(width*5*3)
            (folder/'baseline.ppm').write_bytes(prefix+pixels)
            (folder/'hover.ppm').write_bytes(prefix+b'\xff'+pixels[1:])
            (folder/'observations.json').write_text('[{}]')
            if n == 5:(folder/'detached.png').write_bytes(b'\x89PNG\r\n\x1a\n')
        self.save()

    def save(self):
        (self.root/'manifest.json').write_text(json.dumps(self.manifest))

    def test_normal_and_restored(self):
        original = copy.deepcopy(self.manifest)
        self.assertTrue(verify(self.root)['passed'])
        self.manifest['rounds'][0]['selected']['picking'] = True
        self.save()
        with self.assertRaises(AssertionError):verify(self.root)
        self.manifest = original
        self.save()
        self.assertTrue(verify(self.root)['passed'])

    def test_reject_behavior_defects(self):
        original = copy.deepcopy(self.manifest)
        for defect in ('count','role','source','hover','selected','action','cursor'):
            with self.subTest(defect=defect):
                self.manifest = copy.deepcopy(original)
                r = self.manifest['rounds'][0]
                if defect == 'count':self.manifest['rounds'].pop()
                elif defect in ('role','source'):r['expected'][defect] = 'wrong'
                elif defect == 'hover':r['hover']['hovered'] = None
                elif defect == 'selected':r['selected']['selected'] = None
                elif defect == 'action':r['selected']['nodes'] = []
                elif defect == 'cursor':(self.root/'round-01/report.txt').write_text('placement=1 cursor=arrow')
                self.save()
                with self.assertRaises(AssertionError):verify(self.root)
                (self.root/'round-01/report.txt').write_text('phase=hover cursor=crosshair placement=1')

    def test_reject_missing_painted_boundary(self):
        folder = self.root/'round-01'
        (folder/'hover.ppm').write_bytes((folder/'baseline.ppm').read_bytes())
        with self.assertRaises(AssertionError):verify(self.root)
