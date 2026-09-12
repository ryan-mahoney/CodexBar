import CodexBarCore
import Commander
import Foundation

struct ReportOptions: CommanderParsable {
    @Option(name: .long("subscriptions"), help: "Comma-separated subscription providers")
    var subscriptions: String?

    @Option(name: .long("balances"), help: "Comma-separated balance providers")
    var balances: String?

    @Option(name: .long("account"), help: "Configured account label (requires one provider)")
    var account: String?

    @Option(name: .long("timeout"), help: "Per-account timeout in seconds (default 60)")
    var timeout: Double?

    @Flag(name: .long("json"), help: "Print the report as JSON")
    var json: Bool = false
}

/// Uses existing provider integrations, but never the dashboard, cost-history, or usage-rendering paths.
struct ReportCollector: Sendable {
    typealias Fetch = @Sendable (ReportRequest) async -> [ReportRow]
    let fetch: Fetch

    func collect(_ requests: [ReportRequest], now: @Sendable () -> Date = { Date() }) async -> CapacityReport {
        let rows = await withTaskGroup(of: (Int, [ReportRow]).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { await (index, self.fetch(request)) }
            }
            var results: [(Int, [ReportRow])] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return CapacityReport(checkedAt: now(), accounts: rows)
    }
}

struct ReportReadDependencies: Sendable {
    let environment: [String: String]
    let fetch: @Sendable (UsageProvider, ProviderFetchContext) async -> ProviderFetchOutcome

    static var live: Self {
        Self(environment: ProcessInfo.processInfo.environment, fetch: { provider, context in
            await CodexBarCLI.fetchProviderUsage(provider: provider, context: context)
        })
    }
}

extension CodexBarCLI {
    // These integrations were inspected for the one-shot, no-response-retention path.
    static let reportSubscriptions: Set<UsageProvider> = [.codex, .claude, .zai, .qwencloud, .alibabatokenplan]
    static let reportBalances: Set<UsageProvider> = [.deepseek]

    static func reportRequests(subscriptions: String?, balances: String?) throws -> [ReportRequest] {
        var requests: [ReportRequest] = []
        for (raw, kind, supported) in [
            (subscriptions, ReportKind.subscription, Self.reportSubscriptions),
            (balances, ReportKind.balance, Self.reportBalances),
        ] {
            guard let raw else { continue }
            for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
                let name = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let selection = ProviderSelection(argument: name), selection.asList.count == 1,
                      let provider = selection.asList.first, supported.contains(provider)
                else { throw CLIArgumentError("Unsupported \(kind.rawValue) provider '\(name)'. See report --help.") }
                let request = ReportRequest(provider: provider, kind: kind)
                if !requests.contains(request) { requests.append(request) }
            }
        }
        guard !requests.isEmpty else {
            throw CLIArgumentError("Specify --subscriptions or --balances. See report --help.")
        }
        return requests
    }

    static func runReport(_ values: ParsedValues) async {
        let requests: [ReportRequest]
        let timeout: TimeInterval
        do {
            requests = try self.reportRequests(
                subscriptions: values.options["subscriptions"]?.last,
                balances: values.options["balances"]?.last)
            timeout = Double(values.options["timeout"]?.last ?? "60") ?? .nan
            guard timeout.isFinite, timeout > 0, timeout <= 300 else {
                throw CLIArgumentError("--timeout must be more than 0 and at most 300 seconds.")
            }
            if values.options["account"] != nil, requests.count != 1 {
                throw CLIArgumentError("--account requires one provider.")
            }
            if let label = values.options["account"]?.last,
               label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw CLIArgumentError("--account requires a non-empty label.")
            }
        } catch {
            self.exit(code: .usage, message: error.localizedDescription, kind: .args)
        }
        let config: CodexBarConfig
        do {
            config = try CodexBarConfigStore().load() ?? CodexBarConfig.makeDefault()
        } catch {
            self.exit(code: .failure, message: "Could not read the CodexBar configuration.", kind: .config)
        }
        let label = values.options["account"]?.last
        let signalMonitor = CLITerminationSignalMonitor { signalNumber in
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
        }
        defer { signalMonitor.cancel() }
        let report = await ProviderReportMode.$isActive.withValue(true) {
            await ProviderInteractionContext.$current.withValue(.background) {
                await ReportCollector(fetch: { request in
                    await self.reportRows(request: request, config: config, label: label, timeout: timeout)
                }).collect(requests)
            }
        }
        await ProviderCLISessionLifecycle.shutdownPersistentSessions()
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
        if values.flags.contains("json") {
            self.printJSON(report, pretty: true)
        } else {
            print(report.text())
        }
        self.platformExit(report.isComplete ? 0 : 1)
    }

    static func reportRows(
        request: ReportRequest,
        config: CodexBarConfig,
        label: String?,
        timeout: TimeInterval,
        dependencies: ReportReadDependencies = .live) async -> [ReportRow]
    {
        do {
            let configured = config.providerConfig(for: request.provider.instanceID)?.tokenAccounts?.accounts ?? []
            let context = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(
                    label: label,
                    index: nil,
                    allAccounts: label == nil && !configured.isEmpty),
                config: config,
                verbose: false,
                baseEnvironment: dependencies.environment)
            let accounts = try context.resolvedAccounts(for: request.provider)
            let visible = request.provider == .codex && label == nil
                ? context.visibleCodexAccounts().visibleAccounts : []
            let selections: [(ProviderTokenAccount?, CodexVisibleAccount?)] = if !visible.isEmpty {
                visible.map { (nil, Optional($0)) }
            } else if accounts.isEmpty {
                [(nil, nil)]
            } else {
                accounts.map { (Optional($0), nil) }
            }
            var rows: [ReportRow] = []
            for (account, visibleAccount) in selections {
                let name = account?.label ?? visibleAccount?.menuDisplayName ?? "current"
                let task = Task<ReportRow, Error> {
                    await self.reportFetch(
                        request: request,
                        selection: (account, visibleAccount),
                        context: context,
                        timeout: timeout,
                        dependencies: dependencies)
                }
                let join = BoundedTaskJoin<ReportRow>(sourceTask: task)
                switch await join.value(joinGrace: .seconds(timeout)) {
                case let .value(row): rows.append(row)
                case .failure: rows.append(.failure(request, account: name, reason: "fetch failed"))
                case .timedOut:
                    task.cancel()
                    rows.append(.failure(request, account: name, reason: "timeout"))
                }
            }
            return rows
        } catch {
            return [.failure(request, account: label ?? "current", reason: "account not configured")]
        }
    }

    private static func reportFetch(
        request: ReportRequest,
        selection: (account: ProviderTokenAccount?, visibleAccount: CodexVisibleAccount?),
        context: TokenAccountCLIContext,
        timeout: TimeInterval,
        dependencies: ReportReadDependencies) async -> ReportRow
    {
        let (account, visibleAccount) = selection
        let provider = request.provider
        let environment = context.environment(
            base: dependencies.environment,
            provider: provider,
            account: account,
            codexActiveSourceOverride: visibleAccount?.selectionSource)
        let name = account?.label ?? visibleAccount?.menuDisplayName ?? "current"
        let detection = BrowserDetection()
        let base = context.preferredSourceMode(for: provider)
        let source = context.effectiveSourceMode(base: base, provider: provider, account: account)
        let fetcher = UsageFetcher(environment: environment)
        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: source,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: timeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: context.settingsSnapshot(
                for: provider,
                account: account,
                codexActiveSourceOverride: visibleAccount?.selectionSource),
            fetcher: context.fetcher(base: fetcher, provider: provider, env: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: context.tokenUpdater(for: account),
            providerManualTokenUpdater: context.manualTokenUpdater())
        let outcome = await dependencies.fetch(provider, fetchContext)
        switch outcome.result {
        case let .success(result):
            return .project(result, request: request, account: name)
        case .failure:
            // Raw provider diagnostics can contain response bodies or account credentials.
            return .failure(request, account: name, reason: "fetch failed; check provider sign-in")
        }
    }

    static func reportHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar report --subscriptions codex,claude,zai,qwencloud --balances deepseek
          codexbar report --subscriptions alibaba-token-plan --json

        Print current subscription quotas and monetary balances, then exit.
        Subscription providers: codex, claude, zai, qwencloud, alibaba-token-plan.
        Balance providers: deepseek.
        All configured token accounts are included. Otherwise, the current account is used.
        --account <label> selects one configured account for one provider.
        --timeout <seconds> limits each account fetch (default 60, maximum 300).
        --json prints the same report as JSON.
        Exit 0 means complete. Exit 1 means unavailable data. Exit 64 means invalid arguments.
        No report files, usage history, response caches, or background polling.
        Existing authentication configuration and credential refresh remain in use.
        """
    }
}
