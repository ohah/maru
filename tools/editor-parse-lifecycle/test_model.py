"""설계 모델의 입력 순서와 자원 반환 불변식 대조. 제품 검증으로 세지 않는다."""
from dataclasses import replace
from itertools import permutations
import unittest
from model import Key, Model

BASE = Key(1, 2, 3, 4, 5, 6)


def mismatch_case(fault=None, field='generation'):
    model = Model(fault)
    serial = model.input(BASE)
    model.start()
    model.finish()
    # 작업 완료 뒤 메인 전달 전에 입력 판만 달라진 경우를 분리한다.
    model.desired = replace(BASE, **{field: getattr(BASE, field) + 1})
    accepted = model.deliver(serial)
    assert not accepted
    model.check()
    model.drain()


def failed_prepare_case(fault=None):
    model = Model(fault)
    serial = model.input(BASE)
    model.start()
    model.finish()
    latest = replace(BASE, revision=BASE.revision + 1, serial=BASE.serial + 1)
    model.input(latest, prepared=False)
    assert model.desired == latest
    assert not model.deliver(serial)
    model.drain()


def running_close_case(fault=None):
    model = Model(fault)
    serial = model.input(BASE)
    model.start()
    model.close()
    assert model.jobs[serial].snapshot_returns == 0
    model.check()
    model.finish()
    assert not model.deliver(serial)
    model.drain()


def shared_reader_case(fault=None):
    model = Model(fault)
    serial = model.input(BASE)
    model.start()
    model.finish()
    assert model.deliver(serial, ('left', 'right'))
    model.input(replace(BASE, revision=5, serial=7))
    assert not model.retire(serial)
    model.return_view(serial, 'left')
    assert not model.retire(serial)
    model.return_view(serial, 'right')
    assert model.retire(serial)
    model.drain()


class Contracts(unittest.TestCase):
    def test_identity_fields_and_positive_control(self):
        for field in Key.__dataclass_fields__:
            with self.subTest(field=field): mismatch_case(field=field)
        model = Model()
        serial = model.input(BASE); model.start(); model.finish()
        self.assertTrue(model.deliver(serial))
        model.check(); model.drain()

    def test_failed_preparation_invalidates_previous_result(self):
        failed_prepare_case()

    def test_close_waits_for_actual_return(self):
        running_close_case()

    def test_shared_readers_block_final_release(self):
        shared_reader_case()

    def test_queue_replacement_and_failure_completion(self):
        model = Model()
        first = model.input(BASE)
        second = model.input(replace(BASE, serial=7))
        self.assertEqual(model.jobs[first].snapshot_returns, 1)
        self.assertEqual(model.start(), second)
        model.finish(success=False)
        self.assertFalse(model.deliver(second))
        model.drain()

    def test_slot_reuse_during_old_work(self):
        model = Model()
        old = model.input(BASE); model.start(); model.close()
        new = model.input(replace(BASE, generation=4, serial=7))
        model.finish()
        self.assertFalse(model.deliver(old))
        self.assertEqual(model.start(), new)
        model.finish(); self.assertTrue(model.deliver(new))
        model.drain()

    def test_duplicate_delivery_and_retirement_rejected(self):
        model = Model()
        serial = model.input(BASE); model.start(); model.finish()
        self.assertTrue(model.deliver(serial))
        with self.assertRaises(AssertionError): model.deliver(serial)
        model.close(); self.assertTrue(model.retire(serial))
        with self.assertRaises(AssertionError): model.retire(serial)
        model.check()

    def test_completion_and_delivery_orderings(self):
        count = 0
        events = ('submit_b', 'finish_a', 'deliver_a', 'start_b', 'finish_b', 'deliver_b')
        for order in permutations(events):
            pos = {name: order.index(name) for name in events}
            if not (pos['submit_b'] < pos['start_b'] < pos['finish_b'] < pos['deliver_b'] and
                    pos['finish_a'] < pos['start_b'] and pos['finish_a'] < pos['deliver_a']): continue
            for close_at in range(8):
                model = Model(); a = model.input(BASE); model.start(); b = None
                closed = False
                for index, event in enumerate(order):
                    if close_at == index:
                        model.close(); closed = True
                    if event == 'submit_b' and not closed:
                        b = model.input(replace(BASE, revision=5, serial=7))
                    elif event == 'finish_a': model.finish()
                    elif event == 'deliver_a':
                        accepted = model.deliver(a)
                        self.assertEqual(accepted, not closed and pos['deliver_a'] < pos['submit_b'])
                    elif event == 'start_b' and b is not None and model.queued is not None: model.start()
                    elif event == 'finish_b' and model.running is not None: model.finish()
                    elif event == 'deliver_b' and b is not None and model.jobs[b].phase == 'completed':
                        self.assertEqual(model.deliver(b), not closed)
                    model.check()
                if close_at == len(order): model.close()
                model.drain(); count += 1
        self.assertEqual(count, 72)

    def test_semantic_faults_are_detected(self):
        cases = [('generation', lambda f=None: mismatch_case(f, 'generation')),
                 ('serial', lambda f=None: mismatch_case(f, 'serial')),
                 ('failed_prepare_keeps_old', failed_prepare_case),
                 ('free_running', running_close_case),
                 ('free_with_reader', shared_reader_case)]
        for fault, case in cases:
            with self.subTest(fault=fault):
                case()
                with self.assertRaises(AssertionError): case(fault)


if __name__ == '__main__': unittest.main()
