import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location('health', Path(__file__).with_name('backend_health.py'))
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)
CONFIG = {'supabase_url': 'https://test.supabase.co', 'supabase_publishable_key': 'public-test-key', 'sender_email': 'sender@example.com', 'recipient': 'owner@example.com'}

class Checks(unittest.TestCase):
    def test_database_retries_and_reads_only_public_rpc(self):
        calls = []
        def opener(request, timeout):
            calls.append(request)
            if len(calls) == 1:
                raise urllib.error.URLError('temporary')
            return io.BytesIO(b'[]')
        with contextlib.redirect_stdout(io.StringIO()):
            health.check_database(CONFIG, opener, lambda _: None)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].full_url, 'https://test.supabase.co/rest/v1/rpc/leaderboard')
        self.assertEqual(json.loads(calls[0].data), {'kind': 'single'})
        self.assertEqual(calls[0].get_header('Apikey'), 'public-test-key')
        self.assertIsNone(calls[0].get_header('Authorization'))

    def test_email_uses_tls_one_fixed_recipient_and_no_postal_address(self):
        events = []
        class SMTP:
            def __init__(self, host, port, timeout):
                self.tls = False
                events.append((host, port))
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def ehlo(self): pass
            def starttls(self, context): self.tls = True
            def login(self, login, key):
                self_outer.assertTrue(self.tls)
                self_outer.assertEqual((login, key), ('login', 'key'))
            def send_message(self, message, from_addr, to_addrs):
                events.append((message, from_addr, to_addrs))
                return {}
        self_outer = self
        with contextlib.redirect_stdout(io.StringIO()):
            health.send_email(CONFIG, {'SMTP_LOGIN': 'login', 'SMTP_KEY': 'key', 'MAIL_TO': 'other@example.com'}, SMTP)
        self.assertEqual(len(events), 2)
        self.assertEqual(events[1][2], ['owner@example.com'])
        self.assertEqual(events[1][0]['Subject'], 'FTOers monthly email check')
        self.assertNotIn('key', events[1][0].as_string().split('Subject:')[0])
        self.assertNotIn('9208', events[1][0].as_string())

    def test_missing_secret_does_not_connect(self):
        with self.assertRaises(ValueError):
            health.send_email(CONFIG, {}, lambda *_: self.fail('SMTP must not connect'))

if __name__ == '__main__':
    unittest.main()
