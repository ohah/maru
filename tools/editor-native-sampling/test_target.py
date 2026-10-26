"""외부 프로파일러의 종료 코드와 실제 대상·종료 원인이 다를 때를 검사한다."""
import unittest
import xml.etree.ElementTree as ET

import stacks

BINARY = '/tmp/archived-test'
ENV = dict(MARU_EW2_FILE='/tmp/input.zig', MARU_EW2_WORKLOAD='typing', MARU_EW2_VERIFY_EACH_EDIT='0')


def fixture():
    values = ''.join('<item key="' + key + '" value="' + value + '"/>' for key, value in ENV.items())
    return ET.fromstring('''<trace-toc><run number="1"><info><target>
<process type="launched" name="archived-test" pid="42" arguments="--maru-expect-tests=5 --maru-expect-passed=5"
 return-exit-status="0" termination-reason="exit(0)"/><environment>''' + values + '''</environment></target>
<summary><end-reason>Target app exited</end-reason><template-name>Time Profiler</template-name>
<instruments-version>26.0</instruments-version></summary></info>
<processes><process name="archived-test" pid="42" path="/tmp/archived-test"/></processes>
<data><table schema="time-profile" target-pid="SINGLE" record-waiting-threads="0"/></data>
</run></trace-toc>''')


def parse(root):
    return stacks.target(ET.tostring(root, encoding='unicode'), BINARY, ENV)


class TargetTests(unittest.TestCase):
    def test_normal_launch_identity_is_retained(self):
        self.assertEqual(parse(fixture()), dict(pid=42, instruments_version='26.0'))

    def test_recorder_window_ending_is_not_normal_target_completion(self):
        root = fixture()
        root.find('.//end-reason').text = 'Time limit reached'
        with self.assertRaisesRegex(ValueError, 'Recording ended before target completion'):
            parse(root)

    def test_failure_exit_and_wrong_test_selection_are_rejected(self):
        for key, value in [('return-exit-status', '1'), ('termination-reason', 'signal(9)'),
                           ('arguments', '--maru-expect-tests=0 --maru-expect-passed=0')]:
            with self.subTest(key=key):
                root = fixture()
                root.find('.//target/process').set(key, value)
                with self.assertRaises(ValueError):
                    parse(root)

    def test_wrong_executable_path_is_not_another_copy_of_the_target(self):
        root = fixture()
        root.find('.//processes/process').set('path', '/tmp/other/archived-test')
        with self.assertRaisesRegex(ValueError, 'Wrong target executable path'):
            parse(root)

    def test_duplicate_or_mismatched_environment_is_rejected(self):
        root = fixture()
        root.find('.//environment').append(ET.Element('item', key='MARU_EW2_WORKLOAD', value='typing'))
        with self.assertRaisesRegex(ValueError, 'Wrong target environment'):
            parse(root)
        root = fixture()
        root.find('.//item[@key="MARU_EW2_FILE"]').set('value', '/tmp/stale.zig')
        with self.assertRaisesRegex(ValueError, 'Wrong target environment'):
            parse(root)

    def test_waiting_threads_configuration_and_ambiguous_run_are_rejected(self):
        root = fixture()
        root.find('.//table').set('record-waiting-threads', '1')
        with self.assertRaisesRegex(ValueError, 'Wrong profiling table configuration'):
            parse(root)
        root = fixture()
        root.append(ET.Element('run', number='2'))
        with self.assertRaisesRegex(ValueError, 'Expected one trace run'):
            parse(root)


if __name__ == '__main__':
    unittest.main()
