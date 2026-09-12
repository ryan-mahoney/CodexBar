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
The `--json` flag prints the same data as JSON.
The report preserves currencies. It does not convert token credits or budget remainders into money.
Missing quota data and failed requests appear as unavailable, not as zero.

Exit status `0` means complete. Status `1` means at least one requested reading is unavailable.
Status `64` means invalid arguments. The default timeout is 60 seconds per account.

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
