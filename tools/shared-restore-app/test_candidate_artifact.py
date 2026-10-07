import copy
import unittest
from candidate_artifact import validate


def artifact(close=False):
    rows = []
    for index, wid in enumerate((10, 11)):
        window = dict(id=wid, owner=dict(pid=99), layer=20, on_screen=True)
        rows.append(dict(name=('source' if index == 0 else 'peer'), key_code=(124 if index == 0 else 13 if close else 123),
                         source_owner=(2 if index == 0 else 3), target_owner=(3 if index == 0 else 2),
                         window_id=wid, popup_closed=True, before=dict(windows=[]), opened=dict(windows=[window]),
                         closed=dict(windows=[]), app_capture=dict(window_id=wid, capture_basename=f'candidate-{index}-{wid}.png',
                             sha256='a'*64, width=100, height=200, hanja_rows=5)))
    return dict(schema='maru.editor-ime-candidate-handoff.v1', source_id='com.apple.inputmethod.Korean.2SetKorean',app_pid=99,rows=rows)


class CandidateTests(unittest.TestCase):
    def test_switch_and_close_controls(self):
        self.assertEqual(len(validate(artifact(), False)), 2)
        self.assertEqual(len(validate(artifact(True), True)), 2)

    def test_real_hidden_popup_may_reuse_window_id(self):
        data = artifact()
        row = data['rows'][1]
        row['window_id'] = row['app_capture']['window_id'] = row['opened']['windows'][0]['id'] = 10
        row['app_capture']['capture_basename'] = 'candidate-1-10.png'
        self.assertEqual(len(validate(data, False)), 2)

    def test_corruption_rejected(self):
        def change(path, value):
            data = artifact()
            target = data
            for key in path[:-1]: target = target[key]
            target[path[-1]] = value
            return data
        cases = [(['schema'],'wrong'),(['source_id'],'wrong'),(['app_pid'],True),(['rows'],[]),
                 (['rows',0,'name'],'peer'),(['rows',0,'key_code'],13),(['rows',0,'source_owner'],True),
                 (['rows',0,'target_owner'],2),(['rows',1,'target_owner'],4),(['rows',0,'popup_closed'],False),
                 (['rows',0,'app_capture'],None),(['rows',0,'app_capture','window_id'],42),
                 (['rows',0,'app_capture','capture_basename'],'../candidate-0-10.png'),
                 (['rows',0,'app_capture','sha256'],'a'*63),(['rows',0,'app_capture','hanja_rows'],2),
                 (['rows',0,'app_capture','width'],0),(['rows',0,'opened','windows',0,'owner','pid'],88),
                 (['rows',0,'opened','windows',0,'layer'],0),(['rows',0,'opened','windows',0,'on_screen'],False),
                 (['rows',0,'closed','windows'],[dict(id=10)]),(['rows',0,'before','windows'],[dict(id=10)]),
                 (['rows',0,'opened','windows'],[dict(id=10),dict(id=12)]),
                 (['rows',0,'before','windows'],[dict(id=12),dict(id=12)])]
        for path,value in cases:
            with self.subTest(path=path), self.assertRaises((ValueError,KeyError)): validate(change(path,value),False)
        data=artifact();data['rows'].append(copy.deepcopy(data['rows'][1]))
        with self.assertRaises(ValueError): validate(data,False)
        with self.assertRaises(ValueError): validate(artifact(True),False)


if __name__ == '__main__': unittest.main()
