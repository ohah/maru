"""요청한 이름만 믿지 않고 실제 워커 경로와 뷰 재구축을 검사한다."""
import unittest
import summary_control
import verify


class SummaryControl(unittest.TestCase):
    def valid(self,mode,stats):summary_control.validate({'summary_stats':stats},{'summary_control':mode},verify.require)

    def test_baseline(self):self.valid('disabled',[0,0,3,1000,0])
    def test_prepared(self):self.valid('prepared',[3,3,0,0,0])
    def test_no_control_is_unchanged(self):summary_control.validate({}, {},verify.require)
    def test_wrong_paths(self):
        for mode,stats in [('disabled',[1,0,3,1,0]),('disabled',[0,1,3,1,0]),('disabled',[0,0,0,1,0]),('disabled',[0,0,3,0,0]),('prepared',[0,1,0,0,0]),('prepared',[1,0,0,0,0]),('prepared',[1,1,1,0,0]),('prepared',[1,1,0,1,0])]:
            with self.subTest(mode=mode,stats=stats),self.assertRaises(ValueError):self.valid(mode,stats)

    def test_invalid_shape_types_and_mode(self):
        for mode,stats in [('other',[1,1,0,0,0]),('prepared',[]),('prepared',[True,1,0,0,0]),('prepared',[1.0,1,0,0,0]),('prepared',[-1,1,0,0,0]),('prepared',[2**64,1,0,0,0])]:
            with self.subTest(mode=mode,stats=stats),self.assertRaises(ValueError):self.valid(mode,stats)


if __name__=='__main__':unittest.main()
