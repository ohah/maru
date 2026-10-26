"""SDK 없이 호출 순서·완료 상태·시간 포함 관계·정확성 모집단을 검사한다."""
import unittest

import contract


def normal(accuracy=0):
    lines = []
    for key in range(20):
        lines += [f'BUDGET_SLICE key={key} slice=0 ns=100 native_ns=60 range_ns=20 done=1',
                  f'BUDGET_EDIT key={key} budget_ns=0 first_ns=100 call_ns=100 max_ns=100 wall_ns=110 resumes=0 changed_all=0 changed_len=0 oracle_nodes={3 if accuracy else 0} color_ns=10 accuracy={accuracy}']
    lines.append('BUDGET_ORACLE normal=1 shifted_rejected=1')
    lines += (['BUDGET_CHAIN stage=0 pending=1', 'BUDGET_CHAIN stage=1 pending=1',
               'BUDGET_CHAIN stage=2 inverse_nodes=3 replacement_nodes=4 latest_equal=1'] if accuracy else ['BUDGET_CHAIN skipped=1'])
    lines.append('All 4 tests passed.')
    return '\n'.join(lines)


class ContractTests(unittest.TestCase):
    def test_complete_timing_and_accuracy_populations_remain_separate(self):
        for accuracy in (0,1):
            self.assertEqual(len(contract.measure(normal(accuracy),0,accuracy)['edits']),20)
        with self.assertRaisesRegex(ValueError,'Wrong run population'):
            contract.measure(normal(1),0,0)

    def test_actual_resumes_are_balanced_without_a_hard_time_threshold(self):
        text = normal().replace('budget_ns=0','budget_ns=4000000')
        text = text.replace('key=0 slice=0 ns=100 native_ns=60 range_ns=20 done=1',
            'key=0 slice=0 ns=100 native_ns=60 range_ns=20 done=0\nBUDGET_SLICE key=0 slice=1 ns=150 native_ns=100 range_ns=0 done=1')
        text = text.replace('key=0 budget_ns=4000000 first_ns=100 call_ns=100 max_ns=100 wall_ns=110 resumes=0',
            'key=0 budget_ns=4000000 first_ns=100 call_ns=250 max_ns=150 wall_ns=270 resumes=1')
        result = contract.measure(text,4000000,0)
        self.assertEqual(result['edits'][0]['call_ns'],250)

    def test_bool_versions_and_noncanonical_integer_fields_are_rejected(self):
        for value in (True,1.0,'1',None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                contract.strict(value,1,'schema')
        for field in ('ns=-1','ns=1.0','ns=01','ns=true','ns='+str(2**64),'ns=1 ns=2'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                contract.fields(field)

    def test_missing_or_reordered_and_extra_completed_slices_are_rejected(self):
        for old,new in [('slice=0','slice=1'),('key=0 slice=0','key=1 slice=0'),
                        ('ns=100 native_ns=60 range_ns=20 done=1','ns=100 native_ns=60 range_ns=20 done=0')]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                contract.measure(normal().replace(old,new,1),0,0)
        text = normal().replace('BUDGET_EDIT key=0', 'BUDGET_SLICE key=0 slice=1 ns=10 native_ns=0 range_ns=0 done=1\nBUDGET_EDIT key=0',1)
        with self.assertRaisesRegex(ValueError,'Slice after completion'):
            contract.measure(text,0,0)

    def test_wrong_sum_max_and_native_range_overlap_are_rejected(self):
        for old,new in [('call_ns=100','call_ns=101'),('max_ns=100','max_ns=99'),
                        ('wall_ns=110','wall_ns=99'),('native_ns=60','native_ns=90')]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                contract.measure(normal().replace(old,new,1),0,0)

    def test_fresh_node_oracle_and_latest_input_chain_cannot_disappear(self):
        for old,new in [('oracle_nodes=3','oracle_nodes=0'),('latest_equal=1','latest_equal=0'),
                        ('shifted_rejected=1','shifted_rejected=0'),('stage=1 pending=1','stage=1 pending=0')]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                contract.measure(normal(1).replace(old,new,1),0,1)

    def test_incomplete_or_duplicated_log_is_not_a_completed_population(self):
        for text in (normal().replace('All 4 tests passed.',''),normal()+'\n'+normal()):
            with self.assertRaises(ValueError): contract.measure(text,0,0)

    def test_state_guards_require_every_observed_contract(self):
        text = 'BUDGET_STATE '+' '.join(key+'=1' for key in sorted(contract.STATE))+'\nAll 2 tests passed.'
        self.assertEqual(len(contract.state(text)),8)
        for key in contract.STATE:
            with self.subTest(key=key), self.assertRaises(ValueError):
                contract.state(text.replace(key+'=1',key+'=0'))

    def test_multiline_semantic_failure_belongs_to_the_intended_test(self):
        text='1/2 a.test.latest...BUDGET_CHAIN stage=0 pending=1\nFAIL (Mismatch)\n2/2 a.test.other...OK\n'
        self.assertTrue(contract.semantic_failure(text,'latest'))
        self.assertFalse(contract.semantic_failure(text,'other'))
        text='1/2 a.test.latest...OK\n2/2 a.test.other...FAIL (Mismatch)\n'
        self.assertFalse(contract.semantic_failure(text,'latest'))


if __name__ == '__main__':
    unittest.main()
