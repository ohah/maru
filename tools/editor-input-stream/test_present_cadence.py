"""표시 순서를 가정하지 않고 기록된 겹침만 센다."""
import copy
import unittest
import present_cadence_report as report
from test_submit_display import row


def later(offset=10000000):
    value=copy.deepcopy(row())
    for name in ('renderer','commit','returned','kernel_start','kernel_end','gpu_start','gpu_end','scheduled_cb','completed_cb','presented','presented_cb'):
        value[name]+=offset
    value['generation']=3
    return value


class PresentationCadence(unittest.TestCase):
    def test_sparse_single_row_has_no_inferred_period(self):
        rows=report.timeline([row()]);self.assertIsNone(report.summarize(rows)['previous_present_gaps'])
        self.assertEqual(rows[0]['prior_unpresented_at_gpu_end'],0)

    def test_order_is_commit_not_callback_arrival(self):
        a,b=row(),later()
        self.assertEqual(report.timeline([b,a]),report.timeline([a,b]))
        self.assertEqual(report.timeline([b,a])[1]['prior_unpresented_at_gpu_end'],1)

    def test_boundary_presentation_is_not_pending(self):
        a,b=row(),later(18200000)
        self.assertEqual(a['presented'],b['gpu_end'])
        self.assertEqual(report.timeline([a,b])[1]['prior_unpresented_at_gpu_end'],0)

    def test_reversed_and_simultaneous_presentations_preserved(self):
        for stamp,reverse,same in [(29000000,1,0),(30000000,0,1)]:
            a,b=row(),later();b['presented']=stamp
            result=report.summarize(report.timeline([a,b]))
            self.assertEqual(result['reversed_present_pairs'],reverse)
            self.assertEqual(result['simultaneous_present_pairs'],same)

    def test_process_boundaries_do_not_create_a_gap(self):
        rows=report.timeline([row()])+report.timeline([later()])
        self.assertIsNone(report.summarize(rows)['previous_present_gaps'])

    def test_ownership_errors_and_duplicates_rejected(self):
        a,b=row(),later();b['presented_drawable']=99
        for values in ([],[a,a],[a,b]):
            with self.assertRaises(ValueError):report.timeline(values)
