import unittest
from ime_handoffs import analyze

POST = '[IME_FOCUS] post code=124 owner=2 t=1.0\n'
OBSERVED = '[IME_FOCUS] observed owner=3 t=2.0\n'
KEY = '[IME] keyDown owner=3 t=3.0\n'


class HandoffTests(unittest.TestCase):
    def callback(self, owner, time):
        return f'[IME] callback_arrival insertText accepted=true t={time} gen=3 captured=none owner={owner} discard=false\n'

    def test_no_callback_is_not_late_callback_proof(self):
        result = analyze(POST+OBSERVED+KEY)
        self.assertEqual(result[0]['new_owner_arrivals'], [])

    def test_callback_before_driver_observation_is_visible(self):
        result = analyze(POST+self.callback(3,1.5)+OBSERVED+KEY)
        self.assertEqual(len(result[0]['new_owner_arrivals']), 1)
        self.assertEqual(result[0]['after_observed_arrivals'], [])

    def test_after_observation_and_old_owner_are_separate(self):
        result = analyze(POST+self.callback(2,1.5)+OBSERVED+self.callback(3,2.5)+KEY)
        self.assertEqual(len(result[0]['callbacks']), 2)
        self.assertEqual(len(result[0]['new_owner_arrivals']), 1)
        self.assertEqual(len(result[0]['after_observed_arrivals']), 1)

    def test_following_key_callbacks_do_not_count_as_handoff(self):
        result = analyze(POST+OBSERVED+KEY+self.callback(3,3.1))
        self.assertEqual(result[0]['callbacks'], [])

    def test_missing_changed_owner_and_inverted_time_are_rejected(self):
        for text in (POST, OBSERVED, POST+POST, POST+OBSERVED.replace('owner=3','owner=2'),
                     POST+OBSERVED.replace('t=2.0','t=0.5'), POST+self.callback(3,.5)+OBSERVED):
            with self.subTest(text=text), self.assertRaises(ValueError): analyze(text)


if __name__ == '__main__': unittest.main()
