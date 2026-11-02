"""요청한 이름만 믿지 않고 실제 워커 경로와 뷰 재구축을 검사한다."""
import unittest
import bracket_control
import verify


class BracketControl(unittest.TestCase):
    def valid(self,mode,stats):bracket_control.validate({'bracket_stats':stats},{'bracket_control':mode},verify.require)

    def test_baseline(self):self.valid('disabled',[0,0,3,1000,0])
    def test_prepared(self):self.valid('prepared',[3,3,0,0,0])
    def test_no_control_is_unchanged(self):bracket_control.validate({}, {},verify.require)
    def test_wrong_paths(self):
        for mode,stats in [('disabled',[1,0,3,1,0]),('disabled',[0,1,3,1,0]),('disabled',[0,0,0,1,0]),('disabled',[0,0,3,0,0]),('prepared',[0,1,0,0,0]),('prepared',[1,0,0,0,0]),('prepared',[1,1,1,0,0]),('prepared',[1,1,0,1,0])]:
            with self.subTest(mode=mode,stats=stats),self.assertRaises(ValueError):self.valid(mode,stats)

    def test_invalid_shape_types_and_mode(self):
        for mode,stats in [('other',[1,1,0,0,0]),('prepared',[]),('prepared',[True,1,0,0,0]),('prepared',[1.0,1,0,0,0]),('prepared',[-1,1,0,0,0]),('prepared',[2**64,1,0,0,0])]:
            with self.subTest(mode=mode,stats=stats),self.assertRaises(ValueError):self.valid(mode,stats)


if __name__=='__main__':unittest.main()


class SyntaxStages(unittest.TestCase):
    def fixture(self):
        import test_contract
        app,producer,meta=test_contract.fixture();meta['bracket_control']='prepared'
        app['syntax_presentations']=[[k[6],k[7],k[8]] for k in app['keys']]
        app['syntax_presentation']=app['syntax_presentations'][-1][:2]
        return app,producer,meta
    def test_normal_and_missing(self):
        app,p,m=self.fixture()
        self.assertGreater(bracket_control.stages(app,p,m,verify.require)['last_post_to_syntax_present_ms'],0)
        self.assertEqual(bracket_control.stages({}, {}, {},verify.require),{})
        del app['syntax_presentation']
        with self.assertRaises(ValueError):bracket_control.stages(app,p,m,verify.require)
    def test_bad_types_clocks_and_generations(self):
        import copy
        app,p,m=self.fixture();at,gen=app['syntax_presentation']
        for stage in ([True,gen],[at,False],[at,0],[0,gen],[at,gen+100],[at-1,gen],[app['header'][4]+1,gen],[at]):
            broken=copy.deepcopy(app);broken['syntax_presentation']=stage
            with self.subTest(stage=stage),self.assertRaises(ValueError):bracket_control.stages(broken,p,m,verify.require)

    def test_bad_syntax_rows_and_prefix(self):
        import copy
        app,p,m=self.fixture()
        for mutation in ['missing','false','clock','generation','prefix','population']:
            broken=copy.deepcopy(app)
            if mutation=='missing':del broken['syntax_presentations']
            elif mutation=='false':broken['syntax_presentations'][0][0]=True
            elif mutation=='clock':broken['syntax_presentations'][0][0]=1
            elif mutation=='generation':broken['syntax_presentations'][0][1]=100
            elif mutation=='prefix':broken['syntax_presentations'][0][2]=100
            else:broken['syntax_presentations'].pop()
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):bracket_control.stages(broken,p,m,verify.require)
