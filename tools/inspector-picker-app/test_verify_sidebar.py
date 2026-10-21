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

    def test_extra_cancellation_pause_and_exclusive_edge_controls(self):
        from verify_sidebar import verify_extra
        import shutil
        for r in self.manifest['rounds']:
            old = r['round']
            n = old + 10
            r['round'] = n
            r['expected']['id'] = 100+n
            r['expected']['role'] = {11:'tab',12:'tree_item',13:'tree_item',14:'button',15:'tab'}[n]
            if n in (11,12,14):r['selected']['selected'] = None
            folder = self.root/f'round-{n:02d}'
            (self.root/f'round-{old:02d}').rename(folder)
            flags = 4 if n == 14 else 0
            report = f'phase=hover cursor=crosshair\nlabel=hovered placement={old} flags=0\nlabel=selected placement={old} flags={flags}\n'
            if n == 13:
                report += 'label=pre-pick placement=3 flags=4\n'
                prefix = b'P6\n1800 5\n255\n'
                (folder/'baseline.ppm').write_bytes(prefix+bytes(1800*5*3))
                (folder/'hover.ppm').write_bytes(prefix+b'\xff'+bytes(1800*5*3-1))
            if n == 15:
                r['target'] = dict(role='button',parent_id=115,visible_rect=dict(x=2,y=0,width=1,height=3))
                (folder/'point.json').write_text('{"x":3,"y":1.5}')
            (folder/'report.txt').write_text(report)
            (folder/'selected.ppm').write_bytes((folder/'baseline.ppm').read_bytes())
        self.save()
        self.assertTrue(verify_extra(self.root)['passed'])
        for defect in ('cancel-select','pick-retained','resume','pause','initial-pause','exclusive-edge','readonly','pixels','cursor','case-count','cancel-highlight'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temp:
                dest = pathlib.Path(temp)/'copy'
                shutil.copytree(self.root,dest)
                m = json.loads((dest/'manifest.json').read_text())
                if defect == 'cancel-select':m['rounds'][0]['selected']['selected'] = m['rounds'][0]['expected']
                elif defect == 'pick-retained':m['rounds'][1]['selected']['picking'] = True
                elif defect in ('resume','initial-pause','pause','cursor'):
                    n = 14 if defect == 'pause' else 13
                    p = dest/f'round-{n:02d}'/'report.txt'
                    text = p.read_text()
                    if defect == 'resume':text = text.replace('label=hovered placement=3 flags=0','label=hovered placement=3 flags=4')
                    elif defect == 'initial-pause':text = text.replace('label=pre-pick placement=3 flags=4','label=pre-pick placement=3 flags=0')
                    elif defect == 'pause':text = text.replace('label=selected placement=4 flags=4','label=selected placement=4 flags=0')
                    else:text = text.replace('cursor=crosshair','cursor=arrow')
                    p.write_text(text)
                elif defect == 'exclusive-edge':(dest/'round-15/point.json').write_text('{"x":2.5,"y":1.5}')
                elif defect == 'readonly':m['rounds'][0]['selected']['nodes'] = []
                elif defect == 'case-count':m['rounds'].pop()
                elif defect == 'cancel-highlight':(dest/'round-11/selected.ppm').write_bytes((dest/'round-11/hover.ppm').read_bytes())
                elif defect == 'pixels':(dest/'round-11/hover.ppm').write_bytes((dest/'round-11/baseline.ppm').read_bytes())
                (dest/'manifest.json').write_text(json.dumps(m))
                with self.assertRaises(AssertionError):verify_extra(dest)
        self.assertTrue(verify_extra(self.root)['passed'])
