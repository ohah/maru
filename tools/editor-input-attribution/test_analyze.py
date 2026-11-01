"""표시 이름 대신 검증한 주소를 쓰고, 빠진 스택·재귀를 숨기지 않는지 확인한다."""
import copy
import unittest
import xml.etree.ElementTree as E
import analyze
from test_stacks import fixture,resolution


class Analyze(unittest.TestCase):
    def setUp(self):
        self.root=fixture();self.root.find('.//thread').set('fmt','Main Thread 0x7 (fixture)')
        self.addresses=resolution()

    def parse(self):return analyze.profile(E.tostring(self.root,encoding='unicode'),42,self.addresses)

    def reject(self,edit):
        edit()
        with self.assertRaises(ValueError):self.parse()

    def test_control(self):
        r=self.parse();self.assertEqual(r['counts']['main_rows'],3)
        self.assertEqual(sum(r['self_weight_ns'].values()),3_000_000)
        self.assertEqual(r['self_weight_ns']['[missing-stack]'],1_000_000)

    def test_recursion_is_not_added_twice(self):
        self.root.find('.//backtrace').append(E.Element('frame',ref='11'))
        r=self.parse();self.assertEqual(r['inclusive_weight_ns']['ts_parser_parse_with_options'],2_000_000)

    def test_xml_names_do_not_determine_cost(self):
        old=self.parse();self.root.find('.//frame').set('name','misleading-label');self.assertEqual(self.parse(),old)

    def test_unresolved_is_retained(self):
        self.addresses['names']['0x10']=None
        self.assertEqual(self.parse()['self_weight_ns']['[unresolved-target]'],2_000_000)

    def test_foreign_pid(self):self.reject(lambda:self.root.find('.//pid').__setattr__('text','43'))
    def test_bad_weight(self):self.reject(lambda:self.root.find('.//weight').__setattr__('text','-1'))
    def test_zero_weight(self):self.reject(lambda:self.root.find('.//weight').__setattr__('text','0'))
    def test_bad_core(self):self.reject(lambda:self.root.find('.//core').__setattr__('text','-1'))
    def test_waiting_state(self):self.reject(lambda:self.root.find('.//thread-state').__setattr__('text','Waiting'))
    def test_no_main_thread(self):self.reject(lambda:self.root.find('.//thread').set('fmt','Worker'))
    def test_missing_main_label(self):self.reject(lambda:self.root.find('.//thread').attrib.pop('fmt'))
    def test_missing_address(self):self.reject(lambda:self.addresses['names'].pop('0x10'))
    def test_bad_address(self):self.reject(lambda:self.root.find('.//frame').set('addr','bogus'))
    def test_missing_reference(self):self.reject(lambda:self.root.find('.//thread[@ref]').set('ref','999'))
    def test_wrong_reference_type(self):self.reject(lambda:self.root.find('.//thread[@ref]').set('ref','4'))
    def test_duplicate_identifier(self):self.reject(lambda:self.root.find('.//core').set('id','1'))
    def test_reordered_sample(self):self.reject(lambda:self.root.find('.//sample-time[@id="15"]').__setattr__('text','50'))
    def test_duplicate_sample(self):self.reject(lambda:self.root.find('.//sample-time[@id="14"]').__setattr__('text','100'))
    def test_unknown_column(self):self.reject(lambda:self.root.find('.//mnemonic').__setattr__('text','other'))
    def test_wrong_row_tag(self):self.reject(lambda:self.root.find('.//core').__setattr__('tag','other'))
    def test_invalid_sentinel(self):self.reject(lambda:self.root.find('.//sentinel').set('invented','1'))
    def test_empty_stack(self):self.reject(lambda:self.root.find('.//backtrace').clear())
    def test_unknown_frame_tag(self):self.reject(lambda:self.root.find('.//frame').__setattr__('tag','other'))
    def test_multiple_main_threads(self):
        row=self.root[0].findall('row')[1];row.remove(row[1]);t=E.Element('thread',fmt='Main Thread 0x8')
        E.SubElement(t,'tid').text='8';E.SubElement(t,'process',ref='4');row.insert(1,t)
        with self.assertRaises(ValueError):self.parse()


if __name__=='__main__':unittest.main()
