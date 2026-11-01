"""붙인 대상과 종료, 환경 목록의 안전 경계를 검사한다. 환경 값은 오류에도 싣지 않는다."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as E
import analyze
from test_target import fixture,BINARY


class Attached(unittest.TestCase):
    def setUp(self):
        self.root=fixture();self.root.find('.//target/process').set('type','attached')
        env=self.root.find('.//environment');env.clear();E.SubElement(env,'item',key='HOME',value='/fixture')

    def parse(self):analyze.target_identity(E.tostring(self.root,encoding='unicode'),42,Path(BINARY))

    def reject(self,edit):
        edit()
        with self.assertRaises(ValueError):self.parse()

    def test_control(self):self.parse()
    def test_wrong_pid(self):self.reject(lambda:self.root.find('.//target/process').set('pid','43'))
    def test_failed_exit(self):self.reject(lambda:self.root.find('.//target/process').set('return-exit-status','1'))
    def test_wrong_exit_reason(self):self.reject(lambda:self.root.find('.//target/process').set('termination-reason','signal(9)'))
    def test_wrong_path(self):self.reject(lambda:self.root.find('.//processes/process').set('path','/wrong'))
    def test_wrong_template(self):self.reject(lambda:self.root.find('.//template-name').__setattr__('text','Other'))
    def test_early_end(self):self.reject(lambda:self.root.find('.//end-reason').__setattr__('text','Time limit reached'))
    def test_waiting_threads(self):self.reject(lambda:self.root.find('.//table').set('record-waiting-threads','1'))
    def test_secret_key(self):self.reject(lambda:E.SubElement(self.root.find('.//environment'),'item',key='CARGO_REGISTRY_TOKEN',value='fixture'))
    def test_unexpected_secret_key(self):self.reject(lambda:E.SubElement(self.root.find('.//environment'),'item',key='UNKNOWN_VALUE',value='fixture'))
    def test_duplicate_environment(self):self.reject(lambda:E.SubElement(self.root.find('.//environment'),'item',key='HOME',value='/fixture'))
    def test_second_run(self):self.reject(lambda:self.root.append(E.Element('run',number='2')))


if __name__=='__main__':unittest.main()
