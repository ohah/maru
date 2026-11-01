"""기록 시작의 유효 토큰과 비밀값 없는 환경 전달을 검사한다."""
import unittest
from observer import diagnostic_environment,notification_token


class Observer(unittest.TestCase):
    def test_network_order_notification(self):
        notification_token(b'\0\0\0\3',3)

    def test_wrong_or_truncated_token(self):
        for raw in [b'',b'\0\3',b'\3\0\0\0',b'\0\0\0\4',b'\0\0\0\3extra']:
            with self.subTest(raw=raw),self.assertRaises(ValueError):notification_token(raw,3)

    def test_environment_allowlist_preserves_existing_homes(self):
        source=dict(PATH='/bin',HOME='/original',CODEX_HOME='/original-codex',CLAUDE_CONFIG_DIR='/original-claude',TMPDIR='/tmp',LANG='ko_KR.UTF-8')
        self.assertEqual(diagnostic_environment(source),source)

    def test_secrets_are_not_inherited_by_name_guessing(self):
        source=dict(PATH='/bin',CARGO_REGISTRY_TOKEN='fixture',UNEXPECTED_SECRET='fixture',AWS_SESSION_TOKEN='fixture',MARU_OLD='fixture')
        self.assertEqual(diagnostic_environment(source),dict(PATH='/bin'))


if __name__=='__main__':unittest.main()
