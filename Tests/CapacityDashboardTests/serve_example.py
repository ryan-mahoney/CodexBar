"""Serve public documentation fixtures without reading credentials or calling providers."""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from ai_capacity.server import DashboardServer, Handler, Snapshot, STATIC, normalize_report


def example_report():
    now = datetime.now(timezone.utc)
    def window(name, used, minutes, hours):
        return {'name': name, 'usedPercent': used, 'windowMinutes': minutes,
                'resetsAt': (now + timedelta(hours=hours)).isoformat() if hours is not None else None}
    rows = [
        {'provider':'codex', 'windows':[window('Weekly', 36, 10080, 112), window('Example weekly pool', 20, 10080, 112)]},
        {'provider':'claude', 'windows':[window('Session', 18, 300, 2), window('Weekly', 24, 10080, 18)]},
        {'provider':'qwencloud', 'windows':[window('Weekly', 45, 10080, 4)]},
        {'provider':'zai', 'windows':[window('5-hour', 8, 300, None), window('Weekly', 12, 10080, 68)]},
    ]
    for row in rows:
        row.update(account='Example account', kind='subscription', balances=[])
    for provider, amount in [('deepseek',42.80), ('openrouter',18.25)]:
        rows.append({'provider':provider, 'account':'Example account', 'kind':'balance', 'windows':[],
                     'balances':[{'amount':amount,'currency':'USD'}]})
    return normalize_report({'checkedAt':now.isoformat(),'accounts':rows})


class ExampleHandler(Handler):
    def do_GET(self):
        if self.path == '/' and self.allowed_request():
            html = (STATIC / 'index.html').read_text().replace(
                '</h1>', '</h1><p class="text-xs muted mt-2">Example data · Documentation preview</p>', 1)
            return self.respond(200, html.encode(), 'text/html; charset=utf-8')
        return super().do_GET()


if __name__ == '__main__':
    snapshot = Snapshot(example_report)
    server = DashboardServer(('127.0.0.1', 8788), snapshot)
    server.RequestHandlerClass = ExampleHandler
    snapshot.start()
    print('Example dashboard: http://localhost:8788/ (no provider access)', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        snapshot.stop()
