"""Loopback-only dashboard. Provider reports never go to disk."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time
import webbrowser
from urllib.parse import urlsplit
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from . import __version__

REFRESH_SECONDS = 15 * 60
SUBSCRIPTIONS = ('codex', 'claude', 'zai', 'qwencloud')
BALANCES = ('deepseek', 'openrouter')
STATIC = Path(__file__).with_name('static')


def iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat()


def valid_date(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed.isoformat() if parsed.tzinfo is not None else None
    except ValueError:
        return None


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def label(value, fallback=''):
    return ''.join(c for c in value if c.isprintable())[:160] if isinstance(value, str) else fallback


def normalize_report(raw):
    """Keep report fields only. Missing/invalid values never become zero."""
    if not isinstance(raw, dict) or not valid_date(raw.get('checkedAt')) or not isinstance(raw.get('accounts'), list):
        raise ValueError('Invalid report envelope')
    rows = []
    for row in raw['accounts']:
        if not isinstance(row, dict):
            raise ValueError('Invalid account')
        provider, kind = row.get('provider'), row.get('kind')
        if (kind == 'subscription' and provider not in SUBSCRIPTIONS) or (kind == 'balance' and provider not in BALANCES):
            continue
        if kind not in ('subscription', 'balance'):
            continue
        windows, balances = [], []
        for window in row.get('windows') or []:
            if not isinstance(window, dict):
                raise ValueError('Invalid window')
            used = number(window.get('usedPercent'))
            minutes = number(window.get('windowMinutes'))
            windows.append({
                'name': label(window.get('name'), 'Allowance'),
                'usedPercent': used if used is not None and used >= 0 else None,
                'windowMinutes': minutes if minutes is not None and minutes > 0 else None,
                'resetsAt': valid_date(window.get('resetsAt')),
            })
        for balance in row.get('balances') or []:
            if not isinstance(balance, dict):
                raise ValueError('Invalid balance')
            amount, currency = number(balance.get('amount')), balance.get('currency')
            if amount is not None and isinstance(currency, str) and len(currency) == 3 and currency.isascii() and currency.isalpha():
                balances.append({'amount': amount, 'currency': currency.upper()})
        unavailable = bool(row.get('unavailable')) or (not windows if kind == 'subscription' else not balances)
        if kind == 'subscription' and any(w['usedPercent'] is None for w in windows):
            unavailable = True
        rows.append({'provider': provider, 'kind': kind, 'account': label(row.get('account'), 'current'),
                     'windows': windows if kind == 'subscription' else [],
                     'balances': balances if kind == 'balance' else [],
                     'unavailable': 'Some data is unavailable. Check account access and the provider service.' if unavailable else None})
    for kind, providers in [('subscription', SUBSCRIPTIONS), ('balance', BALANCES)]:
        for provider in providers:
            if not any(row['provider'] == provider and row['kind'] == kind for row in rows):
                rows.append({'provider': provider, 'kind': kind, 'account': 'current', 'windows': [], 'balances': [],
                             'unavailable': 'The provider returned no account data.'})
    return {'checkedAt': valid_date(raw['checkedAt']), 'accounts': rows}


def report_environment(auth_path: Path | None):
    """Reuse supported OpenCode API keys in memory only."""
    env = os.environ.copy()
    if auth_path is None:
        return env
    try:
        auth = json.loads(auth_path.read_text())
    except (OSError, ValueError):
        return env
    if not isinstance(auth, dict):
        return env
    for provider, variable in [('zai-coding-plan', 'Z_AI_API_KEY'), ('deepseek', 'DEEPSEEK_API_KEY'), ('openrouter', 'OPENROUTER_API_KEY')]:
        entry = auth.get(provider)
        if isinstance(entry, dict) and entry.get('type') == 'api' and isinstance(entry.get('key'), str):
            if entry['key'].strip() and not env.get(variable):
                env[variable] = entry['key']
    return env


class ReportError(Exception):
    """Safe message for the browser; never include subprocess diagnostics."""


class Collector:
    def __init__(self, binary: Path, auth_path: Path | None, timeout=120):
        self.binary, self.auth_path, self.timeout = binary, auth_path, timeout

    def __call__(self):
        report = self.codexbar_report()
        report['accounts'] = [row for row in report['accounts'] if row['provider'] != 'openrouter']
        report['accounts'].append(self.openrouter_balance())
        return report

    def openrouter_balance(self):
        row = {'provider': 'openrouter', 'account': 'current', 'kind': 'balance', 'windows': [], 'balances': [], 'unavailable': None}
        env = report_environment(self.auth_path)
        key = env.get('OPENROUTER_MANAGEMENT_API_KEY') or env.get('OPENROUTER_API_KEY')
        if not key:
            row['unavailable'] = 'No OpenRouter key configured.'
            return row
        request = Request('https://openrouter.ai/api/v1/credits', headers={'Authorization': 'Bearer ' + key, 'Accept': 'application/json'})
        try:
            with urlopen(request, timeout=15) as response:
                raw = json.loads(response.read(1_000_000))
            data = raw.get('data', {})
            total, used = number(data.get('total_credits')), number(data.get('total_usage'))
            if total is None or used is None or total < 0 or used < 0:
                raise ValueError('Invalid credits')
            row['balances'] = [{'amount': total - used, 'currency': 'USD'}]
        except HTTPError as error:
            row['unavailable'] = ('OpenRouter requires a valid key with account-credit access. Set OPENROUTER_MANAGEMENT_API_KEY.'
                                  if error.code in (401, 403) else 'OpenRouter did not return a balance. Retry the report.')
        except (OSError, URLError, ValueError, TypeError, AttributeError):
            row['unavailable'] = 'OpenRouter did not return a valid balance. Retry the report.'
        return row

    def codexbar_report(self):
        command = [str(self.binary), 'report', '--subscriptions', ','.join(SUBSCRIPTIONS),
                   '--balances', 'deepseek', '--json', '--timeout', '45']
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       stdin=subprocess.DEVNULL, env=report_environment(self.auth_path), start_new_session=True)
        except OSError:
            raise ReportError('The report command could not start. Check the --codexbar path and its permissions.') from None
        try:
            stdout, _ = process.communicate(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise ReportError('The report timed out. Check the provider connections, then refresh the report.') from None
        if process.returncode not in (0, 1) or len(stdout) > 2_000_000:
            raise ReportError('The report command failed. Check the CodexBar configuration, then refresh the report.')
        try:
            return normalize_report(json.loads(stdout))
        except (ValueError, TypeError, OverflowError):
            raise ReportError('The report response was invalid. Check the CodexBar build, then refresh the report.') from None


class Snapshot:
    """One worker, one memory snapshot, independent of connected browser tabs."""
    def __init__(self, collect, interval=REFRESH_SECONDS, clock=time.monotonic, wall=time.time):
        self.collect, self.interval, self.clock, self.wall = collect, interval, clock, wall
        self.condition = threading.Condition()
        self.report = None
        self.error = None
        self.refreshing = False
        self.started_at = None
        self.finished_at = None
        self.next_due = clock()
        self.last_start = -math.inf
        self.stopped = False
        self.revision = 0
        self.thread = threading.Thread(target=self.run, daemon=True, name='capacity-report')

    def start(self):
        self.thread.start()

    def stop(self):
        with self.condition:
            self.stopped = True
            self.condition.notify_all()
        self.thread.join(timeout=125)

    def request_refresh(self):
        with self.condition:
            if self.refreshing or self.clock() - self.last_start < 5:
                return False
            self.next_due = self.clock()
            self.condition.notify_all()
            return True

    def payload(self):
        with self.condition:
            now = self.wall()
            checked = datetime.fromisoformat(self.report['checkedAt']).timestamp() if self.report else None
            return {
                'report': self.report, 'error': self.error, 'refreshing': self.refreshing,
                'revision': self.revision, 'refreshIntervalSeconds': self.interval,
                'serverTime': iso(now), 'startedAt': self.started_at, 'finishedAt': self.finished_at,
                'nextRefreshAt': iso(now + max(0, self.next_due - self.clock())),
                'stale': bool(self.report and (self.error or now - checked > self.interval + 120)),
            }

    def run(self):
        while True:
            with self.condition:
                while not self.stopped and self.next_due > self.clock():
                    self.condition.wait(timeout=self.next_due - self.clock())
                if self.stopped:
                    return
                self.last_start = self.clock()
                self.next_due = self.last_start + self.interval
                self.started_at = iso(self.wall())
                self.refreshing = True
            try:
                report, error = self.collect(), None
            except ReportError as exc:
                report, error = None, str(exc)
            except Exception:
                report, error = None, 'The report failed. Refresh the report to retry.'
            with self.condition:
                if report is not None:
                    self.report = report
                self.error = error
                self.finished_at = iso(self.wall())
                self.refreshing = False
                self.revision += 1
                self.condition.notify_all()


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, snapshot):
        self.snapshot = snapshot
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # No account data or request logs retained.

    def allowed_request(self):
        port = self.server.server_port
        hosts = {f'localhost:{port}', f'127.0.0.1:{port}'}
        host = self.headers.get('Host', '')
        origin = self.headers.get('Origin')
        return host in hosts and (origin is None or origin == f'http://{host}') and self.headers.get('Sec-Fetch-Site') != 'cross-site'

    def respond(self, status, body, content_type='application/json; charset=utf-8'):
        if not isinstance(body, bytes):
            body = json.dumps(body, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if not self.allowed_request():
            return self.respond(403, {'error': 'Local same-origin requests only.'})
        path = urlsplit(self.path).path
        if path == '/api/report':
            return self.respond(200, self.server.snapshot.payload())
        assets = {'/': ('index.html', 'text/html; charset=utf-8'),
                  '/app.css': ('app.css', 'text/css; charset=utf-8'),
                  '/app.js': ('app.js', 'text/javascript; charset=utf-8')}
        if path in assets:
            name, content_type = assets[path]
            return self.respond(200, (STATIC / name).read_bytes(), content_type)
        self.respond(404, {'error': 'Not found.'})

    def do_POST(self):
        if not self.allowed_request():
            return self.respond(403, {'error': 'Local same-origin requests only.'})
        if self.path != '/api/refresh':
            return self.respond(404, {'error': 'Not found.'})
        accepted = self.server.snapshot.request_refresh()
        self.respond(202, {'accepted': accepted, **self.server.snapshot.payload()})


def default_binary():
    root = Path(__file__).resolve().parents[1]
    candidates = (root / 'report-cli/codexbar', root / '.build/debug/CodexBarCLI',
                  root / '.build/report-current/report-cli/codexbar')
    return os.environ.get('CODEXBAR_BIN') or next((str(path) for path in candidates if path.is_file()), None) or shutil.which('codexbar')


def main():
    parser = argparse.ArgumentParser(description='Local capacity dashboard. Refreshes provider data every 15 minutes.')
    parser.add_argument('--version', action='version', version=f'ai-capacity {__version__}')
    parser.add_argument('--no-open', action='store_true', help='Do not open the dashboard in a browser')
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--codexbar', type=Path, default=default_binary(), help='Path to the CodexBar build with the report command')
    parser.add_argument('--no-opencode', action='store_true', help='Do not read Z.ai, DeepSeek, or OpenRouter keys from OpenCode')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('--port must be between 1 and 65535')
    if args.codexbar is None or not args.codexbar.is_file() or not os.access(args.codexbar, os.X_OK):
        parser.error('Set --codexbar to an executable build with the report command.')
    auth = None if args.no_opencode else Path.home() / '.local/share/opencode/auth.json'
    snapshot = Snapshot(Collector(args.codexbar.resolve(), auth))
    try:
        server = DashboardServer(('127.0.0.1', args.port), snapshot)
    except OSError:
        parser.error('The server could not bind this port. Choose another --port.')
    snapshot.start()
    url = f'http://localhost:{args.port}/'
    print(f'AI capacity: {url} — refresh every 15 minutes. Ctrl+C stops the server.', flush=True)
    try:
        if not args.no_open:
            try:
                webbrowser.open(url)
            except webbrowser.Error:
                print(f'Open {url} in your browser.', flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        snapshot.stop()


if __name__ == '__main__':
    main()
