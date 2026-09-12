"""Bounded checks for report collection, scheduling, and the local HTTP boundary."""
import copy
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, Mock

from ai_capacity.server import (
    Collector, DashboardServer, REFRESH_SECONDS, ReportError, Snapshot,
    normalize_report, report_environment, default_binary,
)


def sample():
    return {'checkedAt': datetime.now(timezone.utc).isoformat(), 'accounts': [
        {'provider': 'claude', 'account': 'test account', 'kind': 'subscription',
         'windows': [{'name': 'Session', 'usedPercent': 0, 'windowMinutes': 300},
                     {'name': 'Weekly', 'usedPercent': 100, 'windowMinutes': 10080}], 'balances': []},
        {'provider': 'deepseek', 'account': 'test account', 'kind': 'balance', 'windows': [],
         'balances': [{'amount': 0, 'currency': 'USD'}]},
    ]}


def wait_for(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.005)
    raise AssertionError('Timed out')


class ReportTests(unittest.TestCase):
    def test_binary_discovery_uses_this_checkout_and_respects_override(self):
        with patch.dict(os.environ, {'CODEXBAR_BIN':'/explicit/codexbar'}, clear=True):
            self.assertEqual(default_binary(), '/explicit/codexbar')
        with patch.dict(os.environ, {}, clear=True), patch('ai_capacity.server.Path.is_file', return_value=True):
            self.assertEqual(Path(default_binary()), Path(__file__).resolve().parents[2] / '.build/debug/CodexBarCLI')

    def test_zero_is_data_and_missing_is_unknown(self):
        report = normalize_report(sample())
        claude = report['accounts'][0]
        self.assertEqual(claude['windows'][0]['usedPercent'], 0)
        self.assertEqual(claude['windows'][1]['usedPercent'], 100)
        self.assertIsNone(claude['unavailable'])
        self.assertEqual(report['accounts'][1]['balances'][0]['amount'], 0)
        self.assertIsNone(report['accounts'][1]['unavailable'])
        self.assertEqual(len(report['accounts']), 6)
        self.assertTrue(next(row for row in report['accounts'] if row['provider'] == 'qwencloud')['unavailable'])

    def test_invalid_values_and_raw_diagnostics_do_not_reach_browser(self):
        raw = sample()
        raw['accounts'][0]['windows'][0]['usedPercent'] = float('nan')
        raw['accounts'][0]['unavailable'] = 'secret response body'
        raw['apiKey'] = 'secret top-level key'
        report = normalize_report(raw)
        self.assertIsNone(report['accounts'][0]['windows'][0]['usedPercent'])
        self.assertNotIn('secret', json.dumps(report))
        for invalid in [None, {}, {'checkedAt': '2026-09-12', 'accounts': []}]:
            with self.assertRaises(ValueError):
                normalize_report(invalid)

    def test_multi_account_rows_and_additional_windows_are_preserved(self):
        raw = sample()
        extra = copy.deepcopy(raw['accounts'][0])
        extra['account'] = 'other account'
        extra['windows'].append({'name': 'Model-specific', 'usedPercent': 105, 'windowMinutes': 10080})
        raw['accounts'].append(extra)
        rows = normalize_report(raw)['accounts']
        self.assertEqual(len([row for row in rows if row['provider'] == 'claude']), 2)
        self.assertEqual(next(row for row in rows if row['account'] == 'other account')['windows'][-1]['usedPercent'], 105)

    def test_opencode_keys_are_scoped_and_explicit_environment_wins(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'Z_AI_API_KEY': 'explicit'}, clear=True):
            path = Path(directory) / 'auth.json'
            path.write_text(json.dumps({'zai-coding-plan': {'type': 'api', 'key': 'fallback'},
                                        'deepseek': {'type': 'api', 'key': 'balance-key'},
                                        'unrelated': {'type': 'api', 'key': 'do-not-read'}}))
            environment = report_environment(path)
            self.assertEqual(environment, {'Z_AI_API_KEY': 'explicit', 'DEEPSEEK_API_KEY': 'balance-key'})
            self.assertEqual(report_environment(None), {'Z_AI_API_KEY': 'explicit'})
            path.write_text('broken JSON')
            self.assertEqual(report_environment(path), {'Z_AI_API_KEY': 'explicit'})

    def test_collector_accepts_partial_exit_and_rejects_bad_output(self):
        process = Mock(returncode=1)
        process.communicate.return_value = (json.dumps(sample()).encode(), None)
        with patch('ai_capacity.server.subprocess.Popen', return_value=process) as start:
            report = Collector(Path('/fake/codexbar'), None).codexbar_report()
            self.assertEqual(len(report['accounts']), 6)
            self.assertIn('--json', start.call_args.args[0])
            arguments = start.call_args.args[0]
            self.assertEqual(arguments[arguments.index('--subscriptions') + 1], 'codex,claude,zai,qwencloud')
            self.assertEqual(arguments[arguments.index('--balances') + 1], 'deepseek')
            self.assertEqual(start.call_args.kwargs['stderr'], subprocess.DEVNULL)
            self.assertNotIn('--allow-keychain-prompt', start.call_args.args[0])
            process.communicate.return_value = (b'secret broken diagnostic', None)
            with self.assertRaises(ReportError) as caught:
                Collector(Path('/fake/codexbar'), None).codexbar_report()
            self.assertNotIn('secret', str(caught.exception))

    def test_collector_timeout_kills_process_group(self):
        process = Mock(pid=12345)
        process.communicate.side_effect = [subprocess.TimeoutExpired('report', 1), (b'', None)]
        with patch('ai_capacity.server.subprocess.Popen', return_value=process), patch('ai_capacity.server.os.killpg') as kill:
            with self.assertRaises(ReportError):
                Collector(Path('/fake/codexbar'), None, timeout=1).codexbar_report()
            kill.assert_called_once()

    def test_openrouter_uses_account_credits_not_key_spend_limit(self):
        collector = Collector(Path('/fake/codexbar'), None)
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b'{"data":{"total_credits":20,"total_usage":5.5,"limit_remaining":99}}'
        with patch.dict(os.environ, {'OPENROUTER_API_KEY':'fixture-key'}, clear=True), patch('ai_capacity.server.urlopen', return_value=response) as request:
            row = collector.openrouter_balance()
            self.assertEqual(row['balances'], [{'amount':14.5,'currency':'USD'}])
            self.assertIsNone(row['unavailable'])
            self.assertEqual(request.call_args.args[0].full_url, 'https://openrouter.ai/api/v1/credits')
            response.read.return_value = b'{"data":{"total_credits":null,"total_usage":0}}'
            self.assertTrue(collector.openrouter_balance()['unavailable'])
        with patch.dict(os.environ, {}, clear=True), patch('ai_capacity.server.urlopen') as request:
            self.assertTrue(collector.openrouter_balance()['unavailable'])
            request.assert_not_called()

    def test_openrouter_failure_does_not_discard_other_providers(self):
        collector = Collector(Path('/fake/codexbar'), None)
        with patch.object(collector, 'codexbar_report', return_value=normalize_report(sample())), patch.object(collector, 'openrouter_balance', return_value={
            'provider':'openrouter', 'kind':'balance', 'account':'current', 'windows':[], 'balances':[], 'unavailable':'No key.'
        }):
            report = collector()
            self.assertEqual(len(report['accounts']), 6)
            self.assertEqual(report['accounts'][0]['provider'], 'claude')
            self.assertEqual(report['accounts'][-1]['unavailable'], 'No key.')


class SchedulerTests(unittest.TestCase):
    def test_real_worker_fires_at_900_seconds_without_a_browser(self):
        clock = [0.0]
        calls = []
        def collect():
            calls.append(clock[0])
            if len(calls) == 2:
                raise ReportError('A safe simulated failure.')
            return normalize_report(sample())
        state = Snapshot(collect, clock=lambda: clock[0])
        state.start()
        try:
            wait_for(lambda: state.revision == 1)
            first = state.payload()['report']
            self.assertEqual(state.interval, 900)
            self.assertEqual(REFRESH_SECONDS, 900)
            def advance(value):
                with state.condition:
                    clock[0] = value
                    state.condition.notify_all()
            advance(899)
            time.sleep(.03)
            self.assertEqual(calls, [0])
            advance(900)
            wait_for(lambda: state.revision == 2)
            self.assertEqual(calls, [0, 900])
            self.assertEqual(state.payload()['report'], first)
            self.assertTrue(state.payload()['stale'])
            advance(1800)
            wait_for(lambda: state.revision == 3)
            self.assertIsNone(state.payload()['error'])
            self.assertFalse(state.payload()['stale'])
            self.assertEqual(calls, [0, 900, 1800])
        finally:
            state.stop()

    def test_overlapping_refresh_requests_do_not_spawn_more_collectors(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def collect():
            calls.append(1)
            entered.set()
            release.wait(2)
            return normalize_report(sample())
        state = Snapshot(collect)
        state.start()
        try:
            self.assertTrue(entered.wait(1))
            self.assertTrue(state.payload()['refreshing'])
            for _ in range(10):
                self.assertFalse(state.request_refresh())
            self.assertEqual(len(calls), 1)
        finally:
            release.set()
            state.stop()


class HTTPTests(unittest.TestCase):
    def test_assets_report_manual_refresh_and_local_boundary(self):
        state = Snapshot(lambda: normalize_report(sample()))
        server = DashboardServer(('127.0.0.1', 0), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        state.start()
        wait_for(lambda: state.revision == 1)
        def request(path, method='GET', headers=None):
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port)
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            result = (response.status, dict(response.getheaders()), response.read())
            connection.close()
            return result
        try:
            for asset, content_type in [('/', 'text/html'), ('/app.css', 'text/css'), ('/app.js', 'text/javascript')]:
                status, headers, body = request(asset)
                self.assertEqual(status, 200)
                self.assertIn(content_type, headers['Content-Type'])
                self.assertEqual(headers['Cache-Control'], 'no-store')
                self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
                self.assertTrue(body)
            payload = json.loads(request('/api/report')[2])
            self.assertEqual(payload['refreshIntervalSeconds'], 900)
            self.assertEqual(len(payload['report']['accounts']), 6)
            request('/api/report')
            self.assertEqual(state.revision, 1)
            self.assertEqual(request('/api/refresh', 'POST')[0], 202)
            for headers in [{'Host': 'evil.example'}, {'Origin': 'https://evil.example'}, {'Sec-Fetch-Site': 'cross-site'}]:
                self.assertEqual(request('/api/report', headers=headers)[0], 403)
                self.assertEqual(request('/api/refresh', 'POST', headers=headers)[0], 403)
            self.assertEqual(request('/../server.py')[0], 404)
            self.assertEqual(request('/api/refresh')[0], 404)
        finally:
            server.shutdown()
            server.server_close()
            state.stop()


if __name__ == '__main__':
    unittest.main()
