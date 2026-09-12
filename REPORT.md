# Current capacity report

This fork adds one command to CodexBar. The command prints current subscription usage, reset times, and monetary balances.
It uses the existing provider integrations and authentication configuration.

```bash
codexbar report --subscriptions codex,claude,zai,qwencloud --balances deepseek
codexbar report --subscriptions alibaba-token-plan --json
```

The first command uses Qwen Cloud. The second uses the separate Alibaba Token Plan integration.
The exact provider depends on the subscription product.

The command includes all configured token accounts and visible Codex accounts.
Without configured accounts, it uses the current account.
For one provider, `--account <label>` selects a configured token account.
The command does not change the active account.

## Output

The text report contains an observation timestamp and one line per quota window or monetary balance.
Reset times use your local timezone and include time remaining, such as `today at 1:39 PM EDT (in 2h 48m)`.
Past reset times show `ago`. They remain visible until the provider returns a new reset time.
The `--json` flag prints the same data as JSON.
JSON timestamps remain machine-readable. The text-only setup instructions do not change the JSON fields.
The report preserves currencies. It does not convert token credits or budget remainders into money.
Missing quota data and failed requests appear as unavailable, not as zero.

Exit status `0` means complete. Status `1` means at least one requested reading is unavailable.
Status `64` means invalid arguments. The default timeout is 60 seconds per account.

## Make your sign-in available to the report

A failed request does not prove that you are signed out.
Chrome sign-in alone does not guarantee that this executable can read Chrome's encrypted cookies.
The text report includes provider-specific links and credential handoff instructions when a reading is unavailable.
These instructions do not open a browser, read the clipboard, or change credentials until you run the commands yourself.

### Z.ai: save an API key once

1. Open the [Z.ai API keys page](https://z.ai/manage-apikey/apikey-list).
2. Copy the key for the account that you want to check.
3. Run the matching command with your report executable:

```bash
pbpaste | codexbar config set-api-key --provider zai --stdin
```

Replace `codexbar` with your executable path if it is not on PATH.
The failure instructions already include the executable path that you used.
This command saves a credential in your local CodexBar configuration. It does not save report data.
The keys do not appear in command arguments or shell history. Do not paste keys into chat.
For a saved token account, update that account's key instead of the provider-wide key.

Z.ai needs a key from the account with your Coding Plan. A browser session alone does not supply this key.

### DeepSeek: supply an API key

1. Open the [DeepSeek API keys page](https://platform.deepseek.com/api_keys).
2. Copy the key for the account that you want to check.
3. Run this command:

```bash
export DEEPSEEK_API_KEY="$(pbpaste)"
```

4. Run the report again in this terminal.

A DeepSeek API key is enough for the balance report. It does not need access to your Chrome session.
The exported key stays in this shell until you unset it or close the terminal. Repeat the export in a new terminal.
For persistent storage, use DeepSeek's **API tokens** section in CodexBar settings.
The upstream `config set-api-key` command does not support DeepSeek. Do not use that command for this provider.
To remove the exported key, run `unset DEEPSEEK_API_KEY`. Do not paste keys into chat.

### Qwen Cloud and Alibaba Token Plan: copy a browser session

1. Open the subscription dashboard in your signed-in Chrome profile:
   - [Qwen Cloud](https://home.qwencloud.com/billing/subscription/token-plan-individual)
   - [Alibaba international](https://modelstudio.console.alibabacloud.com/)
   - [Alibaba mainland](https://bailian.console.aliyun.com/)
2. Open Chrome DevTools and select **Network**.
3. Reload the dashboard.
4. Select its quota or usage request, not an image, script, or analytics request.
5. Under **Headers > Request Headers**, copy only the **Cookie** value.
6. Run the matching command in the terminal where you run the report:

```bash
export QWEN_CLOUD_COOKIE="$(pbpaste)"
export ALIBABA_TOKEN_PLAN_COOKIE="$(pbpaste)"
```

Copy each site's cookie separately before its command. Do not run both commands with the same clipboard contents.
For Qwen Cloud, use the quota request to `cs-data.qwencloud.com`.
For Alibaba Personal/Solo, use the `tokenplan/personal/api/v2/usage` request.
The Alibaba region must match your account and plan. The report shows the configured region and its dashboard link.
In the CodexBar configuration, the `alibabatokenplan` provider's `region` accepts `intl`, `cn`, `intl-personal`, or `cn-personal`.
The first two values select Team plans. The last two select Personal/Solo plans.
The default is `cn`. See the [upstream setup notes](docs/alibaba-token-plan.md) for more details.

7. Run the report again in this terminal.

The exported cookie stays in this shell and its child processes until you unset it or close the terminal.
It is a credential. Do not paste it into chat or commit it to a repository.
Repeat the handoff when the browser session expires. Clear the clipboard after the handoff.
To remove the exported cookies, run `unset QWEN_CLOUD_COOKIE ALIBABA_TOKEN_PLAN_COOKIE`.
If a valid credential still fails, the selected plan, region, network, or provider response can be the cause.

## Retention

The command does not create report files, a usage database, or a background process.
It does not read local conversation logs for cost estimates or fetch provider status pages.
The report path disables HTTP response caches and persistent dashboard snapshots.
Z.ai history requests and Claude quota-backoff persistence are disabled for this command.

Existing authentication behavior remains in place, including credential refresh and credential caches.
The no-retention rule applies to report data, not to the credentials needed for future requests.
The report does not prompt for Keychain access. A provider can report unavailable until its authentication is configured.

## Build and check

The build requires the upstream Swift toolchain, version 6.2 or later.

```bash
swift build --product CodexBarCLI
swift test --filter CapacityReport
.build/debug/CodexBarCLI report --help
```

The fork's `Capacity report` workflow builds the macOS CLI and runs offline checks.
The workflow artifact includes the executable and its required resource bundle.
The resource bundle must remain beside the executable.

The offline tests use synthetic responses. They do not read account credentials or contact providers.
The other CodexBar commands and application features remain available.
