# Current AI Provider Capacity

This local dashboard displays the JSON report from the CodexBar fork and the OpenRouter credit balance.
It fetches a report at startup and every 15 minutes.

The server keeps one snapshot in memory. It does not store reports, usage history, credentials, or request logs.
The CodexBar command still uses its existing authentication storage and credential refresh.

## Start

For the Homebrew installation, run these commands from any directory:

```bash
brew install ryan-mahoney/tap/ai-capacity
ai-capacity
```

Homebrew supplies Python and the prebuilt report executable. The command opens the dashboard in your browser.
This package requires an Apple Silicon Mac and macOS 14 or later.
Use `ai-capacity --no-open` to leave the browser closed.
Keep the terminal open. Press Ctrl+C to stop the server.

To update, run `brew update`, then `brew upgrade ai-capacity`. Restart the dashboard after the update.

### Source checkout

From this repository, run:

```bash
python3 -m ai_capacity
```

The command opens [http://localhost:8787/](http://localhost:8787/).

The command uses Python 3.11 or later. It requires no Python packages or frontend build.
The stylesheet contains compiled Tailwind CSS and the Roboto font. The browser requires no external assets.

For a source build, run:

```bash
swift build --product CodexBarCLI
```

The build requires Swift 6.2 or later. The dashboard first searches for `.build/debug/CodexBarCLI` in this checkout.
It also accepts the local artifact layout:

```text
.build/report-current/report-cli/codexbar
```

If the executable is elsewhere, specify its path:

```bash
python3 -m ai_capacity --codexbar /absolute/path/to/report-cli/codexbar --port 8787
```

`CODEXBAR_BIN` also selects the executable. Without a local build or this variable, the command searches `PATH`.
The executable must support `report --json`. Keep its resource bundle beside the executable.

Press Ctrl+C to stop the server. A report in progress can take about two minutes to stop.
The server does not start automatically after a reboot.

## Authentication

CodexBar supplies the account configuration, browser-cookie access, and existing sign-ins.
This server never requests a macOS Keychain prompt.

For Z.ai, DeepSeek, and OpenRouter, the server also reads three entries from `~/.local/share/opencode/auth.json`:

- `zai-coding-plan` supplies `Z_AI_API_KEY`.
- `deepseek` supplies `DEEPSEEK_API_KEY`.
- `openrouter` supplies `OPENROUTER_API_KEY`.

Explicit environment variables take precedence. The server reads the file again for each report.
Z.ai and DeepSeek keys supply the child process. The OpenRouter key supplies its credit request.
The server does not send keys to the browser or copy them into another credential store.

OpenRouter uses `GET https://openrouter.ai/api/v1/credits`. The balance is `total_credits - total_usage`, in USD.
This is the account credit balance, not an individual API key limit.
`OPENROUTER_MANAGEMENT_API_KEY` takes precedence over `OPENROUTER_API_KEY` for this request.
If the provider rejects credit access, use a management key. See the [OpenRouter credit API](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits).

To disable this fallback, run:

```bash
ai-capacity --no-opencode
```

An unavailable reading does not mean zero usage or an expired sign-in. Provider outages, account regions, or cookie permissions can also cause unavailable readings.
The page includes account-specific access instructions for failed reports.

If Qwen needs a new cookie import, run this command in a terminal:

```bash
ai-capacity-report cookie refresh --provider qwencloud --allow-keychain-prompt
```

Complete the macOS prompt. Then select **Refresh report** in the dashboard.
For a source checkout, use `python3 -m ai_capacity` and `.build/debug/CodexBarCLI` in place of the installed commands.

## Refresh behavior

One worker fetches configured accounts for Codex, Claude, Z.ai, Qwen Cloud, and DeepSeek through CodexBar.
It also fetches the OpenRouter account balance. Alibaba Token Plan is not requested.
It starts each scheduled fetch 900 seconds after the previous fetch started. This schedule does not depend on an open browser tab.
After sleep, the worker fetches once when its timer is due. It does not replay missed intervals.

Browser tabs read the memory snapshot every five seconds, or every second during a fetch.
These browser requests do not fetch provider data. Hidden tabs refresh the view when they become visible.

**Refresh report** requests an earlier fetch and restarts the 15-minute schedule. Concurrent requests share the same worker.
A five-second minimum between manual requests limits repeated fetches.

The dashboard preserves the previous snapshot during a fetch. A command failure keeps that snapshot with an out-of-date warning.
A successful partial report replaces the snapshot and labels unavailable accounts. It does not substitute older values for failed accounts.
The page does not infer new allowances after a reset time passes.

The reset column displays weekly resets. Short-window reset times share the line with the window duration.
Additional limits display their own resets. Amber marks available weekly allowances that reset within six hours.
Short-window allowances and their reset times do not receive reset color cues.
A quieter amber marks resets within 24 hours. The legend and reset times provide the same information without color.
Stale or failed reports do not receive these cues. A reset time is not a claim that prepaid cash expires.

## Local access

The server binds only to `127.0.0.1`. It rejects foreign Host and Origin headers and cross-site browser requests.
The HTTP service exposes three static assets, the memory report, and a manual refresh endpoint. It does not serve repository files.
Other programs and users on this computer can access the local port. Do not expose this port through a public proxy.

## Checks

```bash
python3 -m unittest discover -s Tests/CapacityDashboardTests -p 'test_*.py' -v
node --check ai_capacity/static/app.js
```

The scheduler check advances an injected clock through two 900-second intervals. It also checks stale-data recovery and concurrent refresh requests.
The HTTP checks use synthetic data. They do not read credentials or fetch live providers.

## README screenshot

The repository screenshot uses example data, not account credentials or personal balances.
Start its local fixture server with:

```bash
python3 Tests/CapacityDashboardTests/serve_example.py
```

Open `http://localhost:8788/`. This server uses the dashboard assets but never contacts a provider.
The example page adds an example-data label to distinguish it from the live dashboard.
