"""Synthetic receipt corruptions are separate from actual OS evidence."""
import copy
import unittest
from tab_delivery import validate


def fixture():
    before=(1<<58)+2
    request=dict(id=1,pid=42,keycode=48,flags=0,korean=True,generation=str(before),time=1.0)
    ack=dict(request,passed=True,events=2)
    phases=['app_dispatch','view_received','view_handled','app_dispatch','view_release_received','view_release_handled']
    rows=[dict(phase=p,id=1,pid=42,foreground_pid=42,active=True,key_window=True,event_type=10 if i<3 else 11,field=0 if i<2 else 3,owner=str(before if i<2 else before+1),committed=0,time=1.1+i*.1,event_timestamp=1.05 if i<3 else 1.35) for i,p in enumerate(phases)]
    final=dict(pid=42,field=3,owner=str(before+1),committed=0,marked=0,time=2.0)
    return rows,request,ack,final


class DeliveryTests(unittest.TestCase):
    def test_normal(self):
        self.assertTrue(validate(*fixture())['passed'])

    def test_posting_alone_is_not_delivery(self):
        rows,req,ack,end=fixture()
        with self.assertRaises(ValueError):validate([],req,ack,end)

    def test_short_diagnostic_separation(self):
        from tab_probe import validate_short
        report=dict(mode='diagnostic',window_inventory_validated=False,passed=True,failures=[],step=40,candidate_count=0,target_field=3)
        validate_short(report)
        for change in [dict(mode='live'),dict(window_inventory_validated=True),dict(candidate_count=5),dict(target_field=0),dict(step=22),dict(failures=['failed'])]:
            with self.subTest(change=change),self.assertRaises(ValueError):validate_short(dict(report,**change))

    def test_corruptions(self):
        attacks={
            'boolean_request_id':lambda w,r,a,f:r.update(id=True),
            'boolean_receipt_id':lambda w,r,a,f:w[0].update(id=True),
            'boolean_field':lambda w,r,a,f:w[0].update(field=False),
            'boolean_final':lambda w,r,a,f:f.update(marked=False),
            'nan_final':lambda w,r,a,f:f.update(time=float('nan')),
            'missing':lambda w,r,a,f:w.pop(),
            'duplicate':lambda w,r,a,f:w.append(copy.deepcopy(w[-1])),
            'order':lambda w,r,a,f:w.reverse(),
            'request_id':lambda w,r,a,f:r.update(id=2),
            'non_tab':lambda w,r,a,f:r.update(keycode=36),
            'modified_tab':lambda w,r,a,f:r.update(flags=1),
            'wrong_source':lambda w,r,a,f:r.update(korean=False),
            'rejected_post':lambda w,r,a,f:a.update(passed=False),
            'wrong_ack':lambda w,r,a,f:a.update(id=2),
            'owner_domain':lambda w,r,a,f:r.update(generation='1'),
            'owner_not_advanced':lambda w,r,a,f:w[2].update(owner=r['generation']),
            'wrong_id':lambda w,r,a,f:w[0].update(id=9),
            'wrong_pid':lambda w,r,a,f:w[1].update(pid=43),
            'external_foreground':lambda w,r,a,f:w[1].update(foreground_pid=43),
            'inactive':lambda w,r,a,f:w[1].update(active=False),
            'not_key':lambda w,r,a,f:w[1].update(key_window=False),
            'up_as_down':lambda w,r,a,f:w[1].update(event_type=11),
            'no_field_change':lambda w,r,a,f:w[2].update(field=0),
            'stale_owner':lambda w,r,a,f:w[3].update(owner=r['generation']),
            'text_commit':lambda w,r,a,f:w[2].update(committed=1),
            'nan':lambda w,r,a,f:w[0].update(time=float('nan')),
            'late':lambda w,r,a,f:w[0].update(time=5),
            'before_post':lambda w,r,a,f:w[0].update(time=.9),
            'different_event':lambda w,r,a,f:w[1].update(event_timestamp=1.06),
            'wrong_final':lambda w,r,a,f:f.update(field=0),
            'final_marked':lambda w,r,a,f:f.update(marked=3),
            'early_final':lambda w,r,a,f:f.update(time=1.0),
        }
        for name,attack in attacks.items():
            args=fixture();attack(*args)
            with self.subTest(attack=name),self.assertRaises(ValueError):validate(*args)


if __name__=='__main__':unittest.main()
