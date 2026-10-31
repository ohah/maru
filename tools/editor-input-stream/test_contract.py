"""입력 유실을 평균으로 숨기지 않고 합쳐진 첫 표시를 정확히 배정하는 계약이다."""
import copy
import unittest
import protocol
import verify


def fixture():
    n, start, period = 4, 1_000_000_000, 100_000_000
    meta = {'count': n, 'mode': 'async', 'shared': False, 'period_ns': period, 'lateness_ns': 20_000_000,
            'kind': 'normal', 'app_pid': 200, 'producer_pid': 201, 'fixture_bytes': 100, 'fixture_tail_sha256': 'a'*64}
    events, keys = [], []
    for i in range(n):
        posted = start+i*period+1_000_000
        events.append({'seq': i+1, 'token': protocol.MAGIC|i+1, 'code': protocol.CODES[i], 'ascii': ord(protocol.TEXT[i]),
                       'scheduled_ns': start+i*period, 'post_ns': posted, 'after_post_ns': posted+100_000, 'frontmost_pid': 200, 'source_verified': True})
        shown = start+(2 if i == 1 else i)*period+5_000_000
        gen, prefix = [(11, 1), (12, 3), (12, 3), (13, 4)][i]
        keys.append([i+1, protocol.MAGIC|i+1, posted-1_000, posted+1_000_000, protocol.CODES[i], 0,
                     shown, gen, prefix, 1, 1, 1])
    app = {'schema': 1, 'protocol': protocol.NAME, 'pid': 200, 'mode': 'async', 'shared': False,
           'error': None, 'restored': True, 'foreground': True, 'document_verified': True, 'visible_line': '// abcd',
           'initial_tail_sha256': 'a'*64, 'header': [0, n, n, n, start+306_000_000, 14, n, 1, 0], 'keys': keys,
           'baseline': [10, 0, 0, 1, 1, 100, 3, 0], 'state': [14, n, 0, 1, 1, 104, 3, n],
           'pause_start_ns': 0, 'pause_end_ns': 0, 'suppressed_frames': 0, 'memory': [200, 180], 'baseline_memory': [190, 170]}
    producer = {'schema': 1, 'protocol': protocol.NAME, 'transport': 'CGEventPostToPid', 'pid': 201, 'target_pid': 200,
                'count': n, 'period_ns': period, 'lateness_ns': meta['lateness_ns'], 'start_ns': start, 'error': None,
                'events': events, 'finished_ns': events[-1]['after_post_ns']+100_000}
    return app, producer, meta


class Contract(unittest.TestCase):
    def setUp(self):
        self.app, self.producer, self.meta = fixture()

    def check(self):
        return verify.validate(self.app, self.producer, self.meta)

    def test_control_and_coalescence(self):
        result = self.check()
        self.assertEqual(result['post_to_present_ms'], [4, 104, 4, 4])
        self.assertEqual(result['post_to_native_ms'], [1, 1, 1, 1])
        self.assertEqual(result['first_frames'], 3)
        self.assertEqual(result['coalesced_keys'], 1)

    def test_main_pause_still_has_independent_posts(self):
        self.meta['kind'] = 'main-pause'
        self.app['pause_start_ns'], self.app['pause_end_ns'] = 1_010_000_000, 1_260_000_000
        for i in [1, 2]:
            self.app['keys'][i][3] = 1_260_000_000+i*1_000_000
            self.app['keys'][i][6] = 1_265_000_000
        self.assertEqual(self.check()['pause_posted_count'], 2)

    def test_undeclared_pause(self): self.rejects(lambda a,p,m: a.__setitem__('pause_start_ns',1))
    def test_pause_without_posts(self): self.rejects(lambda a,p,m: m.__setitem__('kind','main-pause'))
    def test_float_period(self): self.rejects(lambda a,p,m: p.__setitem__('period_ns',float(p['period_ns'])))

    def rejects(self, mutate):
        mutate(self.app, self.producer, self.meta)
        with self.assertRaises(ValueError):
            self.check()
        verify.validate(*fixture())

    def test_missing_native(self): self.rejects(lambda a,p,m: a['keys'][1].__setitem__(3,0))
    def test_duplicate_native(self): self.rejects(lambda a,p,m: a['keys'][1].__setitem__(11,2))
    def test_wrong_token(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(1,0))
    def test_wrong_hid_code(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(4,7))
    def test_modifier(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(5,1))
    def test_event_order(self): self.rejects(lambda a,p,m: a['keys'][1].__setitem__(3,a['keys'][0][3]-1))
    def test_missing_present(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(6,0))
    def test_stale_generation(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(7,a['baseline'][0]))
    def test_prefix_missing_key(self): self.rejects(lambda a,p,m: a['keys'][1].__setitem__(8,1))
    def test_prefix_exceeds_text(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(8,5))
    def test_frame_conflict(self): self.rejects(lambda a,p,m: a['keys'][1].__setitem__(6,a['keys'][1][6]+1))
    def test_prefix_group_late(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(8,3))
    def test_text_loss(self): self.rejects(lambda a,p,m: a.__setitem__('visible_line','// abdd'))
    def test_tail_changed(self): self.rejects(lambda a,p,m: a.__setitem__('initial_tail_sha256','b'*64))
    def test_final_document(self): self.rejects(lambda a,p,m: a.__setitem__('document_verified',False))
    def test_bad_mode(self): self.rejects(lambda a,p,m: a['state'].__setitem__(6,1))
    def test_view_count(self): self.rejects(lambda a,p,m: a['state'].__setitem__(4,2))
    def test_source_not_restored(self): self.rejects(lambda a,p,m: a.__setitem__('restored',False))
    def test_foreground_lost(self): self.rejects(lambda a,p,m: a.__setitem__('foreground',False))
    def test_inflight_callback(self): self.rejects(lambda a,p,m: a['header'].__setitem__(8,1))
    def test_final_color_absent(self): self.rejects(lambda a,p,m: a['header'].__setitem__(4,0))
    def test_producer_same_process(self): self.rejects(lambda a,p,m: p.__setitem__('pid',a['pid']))
    def test_target_changed(self): self.rejects(lambda a,p,m: p.__setitem__('target_pid',999))
    def test_producer_error(self): self.rejects(lambda a,p,m: p.__setitem__('error','late'))
    def test_producer_count(self): self.rejects(lambda a,p,m: p['events'].pop())
    def test_schedule_feedback(self): self.rejects(lambda a,p,m: p['events'][1].__setitem__('scheduled_ns',p['events'][1]['scheduled_ns']+10))
    def test_producer_late(self): self.rejects(lambda a,p,m: p['events'][0].__setitem__('post_ns',p['events'][0]['post_ns']+30_000_000))
    def test_foreground_at_post(self): self.rejects(lambda a,p,m: p['events'][0].__setitem__('frontmost_pid',999))
    def test_source_at_post(self): self.rejects(lambda a,p,m: p['events'][0].__setitem__('source_verified',False))
    def test_float_clock(self): self.rejects(lambda a,p,m: a['keys'][0].__setitem__(3,float(a['keys'][0][3])))
    def test_bool_schema(self): self.rejects(lambda a,p,m: a.__setitem__('schema',True))


class NegativeControls(unittest.TestCase):
    def setUp(self):
        self.app, self.producer, self.meta = fixture()
        self.meta.update(app_exit=0, producer_exit=0, disk_unchanged=True)
        self.meta.update(provider_before=dict(a=None,b=None,c=None),provider_after=dict(a=None,b=None,c=None))

    def drop(self):
        self.meta['kind'] = 'drop-present'
        self.app['error'] = 'stream_timeout'
        self.app['header'][3:7] = [0,0,0,0]
        self.app['suppressed_frames'] = 4
        for key in self.app['keys']:
            key[6:11] = [0]*5

    def skip(self):
        self.meta['kind'] = 'skip'
        self.app['error'] = 'observer_error'
        self.app['header'][0] = 18
        self.app['keys'][2] = [3]+[0]*11
        self.app['document_verified'] = False
        self.producer['events'].pop(2)

    def test_drop_has_actual_native_input(self):
        self.drop()
        self.assertEqual(verify.classify(self.app,self.producer,self.meta), {'expected_failure':'missing_presentation'})

    def test_drop_without_suppression_is_rejected(self):
        self.drop();self.app['suppressed_frames'] = 0
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_drop_without_native_input_is_rejected(self):
        self.drop();self.app['keys'][0][3] = 0
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_control_post_lateness_is_rejected(self):
        self.drop();self.producer['events'][0]['post_ns'] += 30_000_000
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_control_post_identity_is_rejected(self):
        self.drop();self.producer['events'][0]['token'] = 0
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_skip_is_expected_failure(self):
        self.skip()
        self.assertEqual(verify.classify(self.app,self.producer,self.meta), {'expected_failure':'missing_input_id'})

    def test_skip_with_unrelated_error_is_rejected(self):
        self.skip();self.app['header'][0] |= 64
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_drop_cannot_join_normal_population(self):
        self.drop();self.meta['kind'] = 'normal'
        with self.assertRaises(ValueError): verify.classify(self.app,self.producer,self.meta)

    def test_external_configuration_change_is_rejected(self):
        self.meta['provider_after']['a'] = 'changed'
        with self.assertRaisesRegex(ValueError,'provider configuration changed'): verify.classify(self.app,self.producer,self.meta)


if __name__ == '__main__': unittest.main()
