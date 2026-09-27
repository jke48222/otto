//
//  UsageLedger.swift
//  Otto
//
//  Keeps what each reply of this session cost (for the footers) and per-day, per-model totals (for the
//  menu and Settings). Only numbers and model ids are stored, never prompts, replies or times finer
//  than a day. The totals live in `usage-ledger.json` at the root of Otto's data folder, written with
//  `SecureFile` at most once a second off the main thread; demo replies are never counted.
//

import Darwin
import Foundation
import Observation
import os

@MainActor @Observable final class UsageLedger: UsageRecording {
    /// Day buckets older than this many days (today included) are folded into the archive.
    static let retentionDays = 400
    static let fileName = "usage-ledger.json"
    static let fileVersion = 1
    /// How long changes wait before they are written, so a burst of requests costs one write.
    static let writeDelay: Duration = .seconds(1)

    /// This session's replies (not persisted).
    private(set) var answers: [UUID: AnswerUsage]
    /// "yyyy-MM-dd" (local day at record time) → model id → totals.
    private(set) var days: [String: [String: UsageTotals]]

    /// Totals of days past the retention window, per model (they keep "All time" right).
    @ObservationIgnored private var archive: [String: UsageTotals]
    /// Newest day key folded into `archive`.
    @ObservationIgnored private var archivedThrough: String?
    /// Replies already counted, so a second `finishAnswer` for the same message counts nothing.
    @ObservationIgnored private var finishedAnswers: Set<UUID> = []

    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    /// nil while the ledger is in memory only (no file, or the file was unsafe to use).
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "com.jalenedusei.otto.usage-ledger",
                                                               qos: .utility)
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false

    private nonisolated static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Usage")

    /// `fileURL` nil keeps everything in memory (snapshots, tests, demo mode).
    init(fileURL: URL?, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
        self.fileURL = fileURL
        answers = [:]
        days = [:]
        archive = [:]
        archivedThrough = nil
        if let fileURL { load(from: fileURL) }
        if foldExpiredDays() { scheduleWrite() }
    }

    /// `~/Library/Application Support/Otto/usage-ledger.json` (…/Otto/Demo/ with `--demo`), or nil when Otto's
    /// data folder can't be used safely.
    static func defaultFileURL() -> URL? {
        do {
            return try AppSupport.rootURL().appendingPathComponent(fileName, isDirectory: false)
        } catch {
            logger.error("Usage totals stay in memory: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    // MARK: - Recording

    func record(usage: JSONValue?, requestedModel: String, servedModel: String?, stopReason: String?,
                isPartial: Bool, messageID: UUID, at date: Date) {
        let isDemo = ModelPricing.isDemo(requestedModel) || servedModel.map(ModelPricing.isDemo) == true
        guard let request = RequestUsage.parse(usage: usage, requestedModel: requestedModel, servedModel: servedModel,
                                               stopReason: stopReason, isPartial: isPartial, isDemo: isDemo) else {
            Self.logger.debug("No usage to record for \(messageID.uuidString, privacy: .public)")
            return
        }

        var answer = answers[messageID] ?? AnswerUsage(messageID: messageID)
        answer.add(request)
        answer.isDemo = answer.isDemo || isDemo
        answer.fellBack = answer.fellBack || RequestUsage.containsFallback(usage)
            || Self.isFallback(requestedModel: requestedModel, servedModel: servedModel)
        answers[messageID] = answer

        guard !isDemo else { return }
        let key = dayKey(for: date)
        var bucket = days[key] ?? [:]
        for line in request.lines where !line.usage.isEmpty || (line.costNanos ?? 0) != 0 {
            let model = Self.ledgerModelID(line.model)
            bucket[model] = (bucket[model] ?? UsageTotals()) + UsageTotals(line: line)
        }
        days[key] = bucket
        foldExpiredDays()
        scheduleWrite()
    }

    func finishAnswer(messageID: UUID) {
        guard let answer = answers[messageID], let served = answer.servedModel,
              !answer.isDemo, !finishedAnswers.contains(messageID) else { return }
        finishedAnswers.insert(messageID)
        let key = dayKey(for: now())
        let model = Self.ledgerModelID(served)
        var bucket = days[key] ?? [:]
        bucket[model, default: UsageTotals()].replies += 1
        days[key] = bucket
        foldExpiredDays()
        scheduleWrite()
    }

    // MARK: - Queries

    func answer(for id: UUID) -> AnswerUsage? {
        answers[id]
    }

    /// Totals of every day that overlaps `start..<end` (whole days; the archive counts when the range reaches
    /// back past the retention window).
    func totals(from start: Date, to end: Date) -> UsageTotals {
        totalsByModel(from: start, to: end).reduce(UsageTotals()) { $0 + $1.totals }
    }

    /// Per-model totals of `start..<end`, most expensive first (then by token count, then by id).
    func totalsByModel(from start: Date, to end: Date) -> [(model: String, totals: UsageTotals)] {
        var byModel: [String: UsageTotals] = [:]
        for (key, models) in days where overlaps(dayKey: key, start: start, end: end) {
            for (model, totals) in models { byModel[model] = (byModel[model] ?? UsageTotals()) + totals }
        }
        if let archivedThrough, dayKey(for: start) <= archivedThrough {
            for (model, totals) in archive { byModel[model] = (byModel[model] ?? UsageTotals()) + totals }
        }
        return byModel
            .map { (model: $0.key, totals: $0.value) }
            .sorted { lhs, rhs in
                if lhs.totals.costNanos != rhs.totals.costNanos { return lhs.totals.costNanos > rhs.totals.costNanos }
                if lhs.totals.usage.totalTokens != rhs.totals.usage.totalTokens {
                    return lhs.totals.usage.totalTokens > rhs.totals.usage.totalTokens
                }
                return lhs.model < rhs.model
            }
    }

    var today: UsageTotals {
        let start = calendar.startOfDay(for: now())
        return totals(from: start, to: calendar.date(byAdding: .day, value: 1, to: start) ?? now())
    }

    var thisMonth: UsageTotals {
        guard let month = calendar.dateInterval(of: .month, for: now()) else { return today }
        return totals(from: month.start, to: month.end)
    }

    // MARK: - Maintenance

    /// Deletes every stored total (this session's reply footers stay) and rewrites the file.
    func reset() {
        days = [:]
        archive = [:]
        archivedThrough = nil
        Self.logger.notice("Usage totals reset")
        scheduleWrite()
        flush()
    }

    /// Writes pending changes now and waits for them (`applicationWillTerminate`).
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard isDirty, let data = encodedFile(), let fileURL else { return }
        isDirty = false
        writeQueue.sync { Self.write(data, to: fileURL) }
    }

    /// Replaces the session's answers and the day buckets (snapshots, promo, previews). Nothing is written.
    func debugSeed(answers: [AnswerUsage], days: [String: [String: UsageTotals]]) {
        self.answers = Dictionary(answers.map { ($0.messageID, $0) }, uniquingKeysWith: { _, latest in latest })
        self.days = days
        archive = [:]
        archivedThrough = nil
        finishedAnswers = []
    }

    // MARK: - Private: days

    private func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Self.dayKey(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    private static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Start of the local day a key names, or nil for a malformed key.
    private func date(forDayKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // Rejects keys like "2026-02-30" that the calendar would roll over into another day.
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private func overlaps(dayKey key: String, start: Date, end: Date) -> Bool {
        guard let dayStart = date(forDayKey: key),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        // An empty range (start == end) still selects the day it falls on.
        return dayStart < max(end, start.addingTimeInterval(1)) && dayEnd > start
    }

    /// Folds day buckets older than the retention window into the archive. True when anything moved.
    @discardableResult private func foldExpiredDays() -> Bool {
        let today = calendar.startOfDay(for: now())
        guard let oldestKept = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today) else {
            return false
        }
        let cutoff = dayKey(for: oldestKept)
        let expired = days.keys.filter { $0 < cutoff }
        guard !expired.isEmpty else { return false }
        for key in expired {
            for (model, totals) in days[key] ?? [:] {
                archive[model] = (archive[model] ?? UsageTotals()) + totals
            }
            days[key] = nil
            archivedThrough = max(archivedThrough ?? key, key)
        }
        Self.logger.info("Archived \(expired.count, privacy: .public) days of usage")
        return true
    }

    /// The model id used as a ledger key: the pricing table's id when priced (dated snapshots merge), else the
    /// reported id, cleaned.
    private static func ledgerModelID(_ model: String) -> String {
        ModelPricing.canonicalID(for: model)
            ?? DisplayText.sanitized(ModelPricing.strippingDemoSuffix(model), maxLength: 64)
    }

    /// The server answered with another model than the one Otto asked for (a dated snapshot of it is the same).
    private static func isFallback(requestedModel: String, servedModel: String?) -> Bool {
        guard let servedModel else { return false }
        let requested = ModelPricing.strippingDemoSuffix(requestedModel)
        let served = ModelPricing.strippingDemoSuffix(servedModel)
        return served != requested && !served.hasPrefix(requested + "-")
    }

    // MARK: - Private: file

    /// On-disk format: `{"version":1,"days":{…},"archive":{…},"archivedThrough":"…"}`, sorted keys.
    private struct LedgerFile: Codable {
        var version: Int
        var days: [String: [String: UsageTotals]]
        var archive: [String: UsageTotals]?
        var archivedThrough: String?
    }

    private func load(from url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno != ENOENT {
                Self.logger.error("Couldn't read the usage ledger: errno \(errno, privacy: .public)")
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            Self.logger.fault("Refused the usage ledger file: not a regular file owned by this user")
            fileURL = nil
            return
        }
        do {
            let file = try JSONDecoder().decode(LedgerFile.self, from: Data(contentsOf: url))
            guard file.version == Self.fileVersion else {
                quarantine(url, reason: "unknown version \(file.version)")
                return
            }
            let valid = file.days.filter { date(forDayKey: $0.key) != nil }
            if valid.count != file.days.count {
                Self.logger.notice("Dropped \(file.days.count - valid.count, privacy: .public) malformed usage days")
            }
            days = valid
            archive = file.archive ?? [:]
            archivedThrough = file.archive == nil ? nil : file.archivedThrough
        } catch {
            quarantine(url, reason: "unreadable")
        }
    }

    /// Moves a damaged ledger aside as `usage-ledger.corrupt-<timestamp>.json` and starts empty.
    private func quarantine(_ url: URL, reason: String) {
        let stamp = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now())
        let base = String(format: "usage-ledger.corrupt-%04d%02d%02d-%02d%02d%02d", stamp.year ?? 0, stamp.month ?? 0,
                          stamp.day ?? 0, stamp.hour ?? 0, stamp.minute ?? 0, stamp.second ?? 0)
        let directory = url.deletingLastPathComponent()
        var destination = directory.appendingPathComponent(base + ".json")
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(attempt).json")
            attempt += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            Self.logger.error("Usage ledger was \(reason, privacy: .public); moved it aside and started empty")
        } catch {
            Self.logger.error("Usage ledger was \(reason, privacy: .public) and couldn't be moved aside; not saving")
            fileURL = nil
        }
    }

    private func scheduleWrite() {
        guard fileURL != nil else { return }
        isDirty = true
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    /// Encodes on the main actor (tiny) and writes off it.
    private func writePending() {
        pendingWrite = nil
        guard isDirty, let data = encodedFile(), let fileURL else { return }
        isDirty = false
        writeQueue.async { Self.write(data, to: fileURL) }
    }

    private func encodedFile() -> Data? {
        let file = LedgerFile(version: Self.fileVersion, days: days, archive: archive.isEmpty ? nil : archive,
                              archivedThrough: archive.isEmpty ? nil : archivedThrough)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(file)
        } catch {
            Self.logger.error("Couldn't encode the usage ledger: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Re-checks the folder (no symlink, owned by this user, 0700) before every write.
    private nonisolated static func write(_ data: Data, to url: URL) {
        do {
            _ = try AppSupport.secureDirectory(url.deletingLastPathComponent())
            try SecureFile.write(data, to: url)
        } catch {
            logger.error("Couldn't save usage totals: \(String(describing: error), privacy: .private)")
        }
    }
}
