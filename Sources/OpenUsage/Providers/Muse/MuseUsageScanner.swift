import Foundation

/// Builds daily token/cost estimates for Muse Code by scanning the CLI's local session logs
/// natively (`<data>/muse/sessions/YYYY/MM/DD/<session-id>/session.jsonl`), replacing any
/// external summarizer. Muse Code publishes no quota or spend API, so this scan is the whole
/// provider: spend tiles and the usage trend below, nothing meter-shaped above.
///
/// Each `model_completed` run event carries that step's token usage (`input_tokens`,
/// `output_tokens`, `cached_tokens` / `cache_read_tokens`, `cache_write_tokens`,
/// `reasoning_tokens`) and its model id. Meta bills reasoning tokens as output, so reasoning
/// folds into the output bucket before pricing. Dollars are estimated through the shared engine
/// from Meta's published Muse Spark rates (see the pricing supplement); steps whose model has
/// no known price are excluded from the totals and surfaced as the tile's unknown-model warning.
///
/// An actor holding the versioned incremental parse cache (keyed path + size + mtime) in memory
/// and Application Support, so refreshes and relaunches parse only changed session files.
actor MuseUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    /// One model step's token usage, normalized from a `model_completed` event.
    struct Entry: Codable, Sendable, Hashable {
        var timestamp: Date
        var model: String
        /// Non-cached input (`input_tokens` minus the cache-read portion).
        var input: Int
        var cacheRead: Int
        var cacheWrite: Int
        /// `output_tokens` plus `reasoning_tokens`, which Meta bills as output.
        var output: Int
        /// Every consumed token, for the tile's token count.
        var reportedTotalTokens: Int
    }

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("muse"),
        persistence: JSONLScanCachePersistence(namespace: "muse", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Scan the last `daysBack` days of Muse session logs. Returns `nil` when the sessions
    /// directory holds no log files at all (the spend tiles then render "No data").
    func scan(
        daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing
    ) async -> LogUsageScan? {
        let directory = MusePaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        var files = JSONLScanning.jsonlFiles(under: URL(fileURLWithPath: directory))
        // Subagent transcripts live under `subagent/` beside (and mirrored into) the parent log —
        // counting both would double-count every delegated step. The parent stream already carries
        // the child's usage, so the nested copies are skipped.
        files.removeAll { $0.path.contains("/subagent/") }
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
    }

    /// Whether any Muse session log exists on disk — the usage half of first-run detection.
    func hasLocalUsage() -> Bool {
        let directory = MusePaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        return !JSONLScanning.jsonlFiles(under: URL(fileURLWithPath: directory)).isEmpty
    }

    // MARK: - Parsing

    /// Parse every `model_completed` event of one session file. Session files mix two line shapes:
    /// retained-frame wrappers (`{"retained_frame":…,"children":[{"record_json":"…"}]}`) and bare
    /// records, so each line is normalized to its record list first. Lines without usage events
    /// (resource samples, tool batches, permission frames) are dropped here.
    static func parseFile(_ data: Data) -> [Entry] {
        // Quoteless on purpose: retained-frame wrappers escape their embedded records
        // (`...completed\"`), so a quoted marker would never match them. Shape validation still
        // happens in `recordEntry`, so a stray mention elsewhere parses to nothing.
        let marker = Data("model_completed".utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let lineData = Data(line)
            guard lineData.range(of: marker) != nil else { continue }
            entries += parseRecords(lineData)
        }
        return entries
    }

    static func parseRecords(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        if let children = object["children"] as? [[String: Any]] {
            return children.compactMap { child in
                guard let raw = child["record_json"] as? String,
                      let record = raw.data(using: .utf8)
                else { return nil }
                return recordEntry(record)
            }
        }
        return recordEntry(data).map { [$0] } ?? []
    }

    /// One `model_completed` record, or nil for any other payload. `recorded_at` is
    /// microseconds since the epoch. Zero-usage completions carry no cost or tokens and are
    /// skipped so they can never fabricate a tile.
    static func recordEntry(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["payload_type"] as? String == "runtime.session",
              let payload = object["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              event["kind"] as? String == "model_completed",
              let recordedMicros = ProviderParse.number(object["recorded_at"]),
              let usage = event["usage"] as? [String: Any],
              let model = (event["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return nil }

        let inputTotal = Int(ProviderParse.number(usage["input_tokens"]) ?? 0)
        let cacheRead = Int(
            ProviderParse.number(usage["cache_read_tokens"])
                ?? ProviderParse.number(usage["cached_tokens"]) ?? 0
        )
        let cacheWrite = Int(ProviderParse.number(usage["cache_write_tokens"]) ?? 0)
        let output = Int(ProviderParse.number(usage["output_tokens"]) ?? 0)
        let reasoning = Int(ProviderParse.number(usage["reasoning_tokens"]) ?? 0)
        guard inputTotal > 0 || output > 0 || reasoning > 0 else { return nil }
        return Entry(
            timestamp: Date(timeIntervalSince1970: recordedMicros / 1_000_000),
            model: model,
            input: max(inputTotal - cacheRead, 0),
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: output + reasoning,
            reportedTotalTokens: inputTotal + output + reasoning
        )
    }

    // MARK: - Dedup and aggregation

    /// Drop exact replays of the same step (mirrored or copied session logs), keeping the first
    /// occurrence. Steps are identified by their timestamp, model, and token buckets.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<Entry> = []
        return entries.filter { seen.insert($0).inserted }
    }

    /// Bucket the entries into local calendar days. Steps whose model has no known price are
    /// excluded from the totals and surfaced as the tile's unknown-model warning, matching the
    /// other log scanners. Cost is estimated through the shared engine (see the source note on
    /// the provider's descriptors).
    static func aggregate(
        entries: [Entry], since: Date, pricing: ModelPricing
    ) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let tokens = TokenBreakdown(
                input: entry.input,
                cacheWrite5m: entry.cacheWrite,
                cacheRead: entry.cacheRead,
                output: entry.output
            )
            guard let cost = pricing.estimatedCostDollars(model: entry.model, tokens: tokens) else {
                if entry.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: entry.model)
                }
                continue
            }
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }
}
