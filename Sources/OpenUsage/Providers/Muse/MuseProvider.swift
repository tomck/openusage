import Foundation

/// Tracks Muse Code usage from the CLI's session logs already on this Mac: per-day spend tiles
/// and a usage trend. Muse Code publishes no quota or spend API, so there is deliberately no
/// usage client — the local scan is the whole provider — and no quota meters, only the
/// trend and the Today / Yesterday / Last 30 Days tiles every local-scanner provider ships.
///
/// No quick links: the provider ships none rather than guessing at Status / Dashboard URLs.
@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(
        id: "muse",
        displayName: "Muse Code",
        icon: .providerMark("muse")
    )

    let authStore: MuseAuthStore
    let usageScanner: MuseUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Names the local source on hover. Dollars are estimated from Meta's published Muse Spark
    /// rates (not measured), so the estimate marker applies — unlike OpenCode's carried costs.
    private let sourceNote = "From your Muse logs (estimated)"

    /// Edge-triggers the auth-read-failure log so persistently unreadable storage warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageScanner: MuseUsageScanner = MuseUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: an exported `META_API_KEY`, the local `auth.json`, or any
        // Muse session log already on disk. Local-only, off the main actor. Unreadable storage is
        // itself a Muse footprint — enable the provider so `refresh()` can surface the error.
        do {
            if try await loadOffMainActor({ [authStore] in try authStore.credential() }) != nil {
                return true
            }
        } catch {
            return true
        }
        return await usageScanner.hasLocalUsage()
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        var credential: MuseCredential?
        var authReadError: MuseUsageError?
        do {
            credential = try await loadOffMainActor { [authStore] in try authStore.credential() }
            loggedAuthReadFailure = false
        } catch let error as MuseUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("muse"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        let scan = await usageScanner.scan(now: refreshedAt, pricing: await pricing())

        var lines: [MetricLine] = []
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                estimated: true,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        if lines.isEmpty {
            if credential != nil {
                // Logged in but nothing in the window: honest "No data", not an error.
                MetricLine.appendNoDataIfNeeded(&lines)
            } else {
                return ProviderSnapshot.error(
                    provider: provider, error: authReadError ?? MuseUsageError.notLoggedIn
                )
            }
        }

        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.series,
                    modelUsage: $0.modelUsage,
                    unknownModelsByDay: $0.unknownModelsByDay
                )
            }
        )
    }
}
