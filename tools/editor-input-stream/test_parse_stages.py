"""기존 입력 판정과 별도로 같은 요청의 단계를 잘못 연결하지 않는지 검사한다."""
import copy
from pathlib import Path
import unittest
from unittest.mock import patch
import parse_stage_report as report
import parse_stages
from test_prepare import prepare


def fixture(shared=False):
    rows = [[stage, 1000+stage*100, 7, 8, 9, 31, 10, 0, 20 if stage in (2, 3, 4) else 11] for stage in range(1, 6)]
    for i in range(2 if shared else 1):
        for stage in (6, 7, 8):
            rows.append([stage, 1600+i*300+(stage-6)*100, 7, 8, 9, 31, 10, i+1 if stage == 8 else 0, 11])
    app = dict(baseline=[0, 1], parse_stages=rows, parse_stage_header=[len(rows), 0], syntax_presentations=[[3000, 2, 30]])
    return app, {'events': [{'post_ns': 1000}]}, dict(diagnostic=True, count=30, shared=shared)


class Stages(unittest.TestCase):
    def analyze(self, values):
        # 입력/문서 판정은 기존 reader가 소유한다. 여기서는 새 단계 판정만 격리한다.
        with patch.object(report.verify, 'classify'):
            return report.analyze(*values)

    def test_normal_single_and_shared(self):
        for shared in (False, True):
            self.assertEqual(self.analyze(fixture(shared))['views'], 2 if shared else 1)

    def test_independent_corruptions(self):
        faults = [
            lambda a,p,m:m.update(diagnostic=False),
            lambda a,p,m:a.update(parse_stage_header=[8, 1]),
            lambda a,p,m:a.update(parse_stage_header=[7, 0]),
            lambda a,p,m:a.update(parse_stages=[]),
            lambda a,p,m:a['parse_stages'][0].pop(),
            lambda a,p,m:a['parse_stages'][0].__setitem__(0, True),
            lambda a,p,m:a['parse_stages'][0].__setitem__(0, 9),
            lambda a,p,m:a['parse_stages'][0].__setitem__(1, 0),
            lambda a,p,m:a['parse_stages'][0].__setitem__(2, -1),
            lambda a,p,m:a['parse_stages'][0].__setitem__(6, 2**64),
            lambda a,p,m:a['parse_stages'][0].__setitem__(8, 0),
            lambda a,p,m:a['parse_stages'][1].__setitem__(1, 1),
            lambda a,p,m:a['baseline'].__setitem__(1, 2),
            lambda a,p,m:a['parse_stages'][4].__setitem__(0, 1),
            lambda a,p,m:a['parse_stages'][0].__setitem__(2, 99),
            lambda a,p,m:a['parse_stages'][0].__setitem__(6, 99),
            lambda a,p,m:m.update(shared=True),
            lambda a,p,m:a['parse_stages'][7].__setitem__(7, 0),
            lambda a,p,m:a['parse_stages'][4].__setitem__(8, 99),
            lambda a,p,m:a['parse_stages'][1].__setitem__(8, 11),
            lambda a,p,m:a['parse_stages'][2].__setitem__(7, 1),
            lambda a,p,m:p['events'][0].update(post_ns=1200),
            lambda a,p,m:a['parse_stages'][5].__setitem__(0, 7),
            lambda a,p,m:a['syntax_presentations'][0].__setitem__(0, 1700),
        ]
        for index, mutate in enumerate(faults):
            values = copy.deepcopy(fixture())
            mutate(*values)
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.analyze(values)

    def test_private_transformers_keep_product_anchors(self):
        root = Path(__file__).resolve().parents[2]/'src/platform/macos/app_session/editor/parse'
        for name in ('worker', 'runtime', 'view'):
            original = (root/(name+'.zig')).read_text()
            result = getattr(parse_stages, name)(original, prepare.once)
            self.assertIn('streamStage', result)
            with self.assertRaises(ValueError):
                getattr(parse_stages, name)(original+original, prepare.once)


if __name__ == '__main__':
    unittest.main()
