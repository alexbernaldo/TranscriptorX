import Foundation
import Combine

/// Lightweight row model for the history list (no segments).
struct HistoryItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var speakerCount: Int
    var hasFavorites: Bool
    var isLink: Bool
    var language: String

    init(_ t: Transcription) {
        id = t.id
        title = t.title
        createdAt = t.createdAt
        duration = t.duration
        let segments = t.segments ?? []
        speakerCount = Set(segments.filter { !$0.isDeleted }.compactMap(\.speaker)).count
        hasFavorites = t.isFavorite || segments.contains { $0.isFavorite && !$0.isDeleted }
        if let url = t.sourceURL { isLink = !url.isFileURL } else { isLink = false }
        language = t.language
    }

    /// «12 oct · 42 min · 3 hablantes»
    var metadataLine: String {
        var parts = [TXFormat.shortDate(createdAt)]
        if duration > 0 { parts.append(TXFormat.shortDuration(duration)) }
        if speakerCount > 0 {
            parts.append(TXL.n("history.speakers", "%d hablante", "%d hablantes", speakerCount))
        }
        return parts.joined(separator: " · ")
    }

    /// «Entrevista con Marta, 12 de octubre, 42 minutos, 3 hablantes»
    var accessibilityLabel: String {
        var parts = [title, TXFormat.spokenDate(createdAt)]
        if duration > 0 { parts.append(TXFormat.spokenDuration(duration)) }
        if speakerCount > 0 { parts.append(TXL.n("history.speakers", "%d hablante", "%d hablantes", speakerCount)) }
        return parts.joined(separator: ", ")
    }
}

struct HistorySection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [HistoryItem]
}

struct SearchHit: Identifiable, Equatable {
    let id: UUID
    let item: HistoryItem
    /// Two-line excerpt and the ranges of the matches inside it.
    let snippet: String
    let matchRanges: [Range<String.Index>]
    let matchCount: Int
}

struct SearchResults: Equatable {
    let query: String
    let hits: [SearchHit]
    var totalMatches: Int { hits.reduce(0) { $0 + $1.matchCount } }
}

struct TrashItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let deletedAt: Date
    let retentionDays: Int

    var daysLeft: Int {
        let purgeDate = deletedAt.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
        return max(0, Int(ceil(purgeDate.timeIntervalSinceNow / 86_400)))
    }
}

/// History, search and Recently Deleted. Loads off the main thread (spec: never block the UI).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    enum LoadState: Equatable {
        case loading
        /// First launch after updating from a version with transcriptions.json.
        case migrating
        case ready
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var sections: [HistorySection] = []
    @Published private(set) var trash: [TrashItem] = []
    @Published private(set) var searchResults: SearchResults?
    @Published private(set) var isSearching = false
    @Published var query: String = "" {
        didSet { scheduleSearch() }
    }
    /// Set once per launch when the legacy JSON was migrated (or failed to).
    @Published private(set) var migrationOutcome: TranscriptionDatabase.MigrationOutcome = .none

    private var documents: [UUID: Transcription] = [:]
    private var searchTask: Task<Void, Never>?
    private var observer: Any?
    private let storage = TranscriptionStorage.shared

    private init() {
        if TranscriptionDatabase.needsLegacyMigration { state = .migrating }
        observer = NotificationCenter.default.addObserver(forName: .transcriptionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    // MARK: Loading

    func reload() {
        let storage = self.storage
        Task.detached(priority: .userInitiated) {
            let all = storage.loadTranscriptions()
            let trash = storage.loadTrashEntries()
            let outcome = storage.migrationOutcome
            await MainActor.run {
                self.apply(all: all, trash: trash)
                if self.state != .ready {
                    self.state = .ready
                    self.migrationOutcome = outcome
                }
            }
        }
    }

    func retryMigration() {
        state = TranscriptionDatabase.needsLegacyMigration ? .migrating : .loading
        reload()
    }

    private func apply(all: [Transcription], trash entries: [(transcription: Transcription, deletedAt: Date)]) {
        documents = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        items = all.map(HistoryItem.init)
        sections = Self.group(items)
        let retention = UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int ?? 30
        trash = entries.map { TrashItem(id: $0.transcription.id, title: $0.transcription.title, deletedAt: $0.deletedAt, retentionDays: retention) }
        if !query.isEmpty { scheduleSearch(immediate: true) }
    }

    /// Hoy, Ayer, Últimos 7 días, then month and year (spec 4.2).
    static func group(_ items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current) -> [HistorySection] {
        var buckets: [(key: String, title: String, items: [HistoryItem])] = []
        func append(_ key: String, _ title: String, _ item: HistoryItem) {
            if let i = buckets.firstIndex(where: { $0.key == key }) { buckets[i].items.append(item) }
            else { buckets.append((key, title, [item])) }
        }
        let startToday = calendar.startOfDay(for: now)
        let startYesterday = calendar.date(byAdding: .day, value: -1, to: startToday)!
        let startWeek = calendar.date(byAdding: .day, value: -7, to: startToday)!
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            if item.createdAt >= startToday {
                append("today", TXL.t("history.group.today", "Hoy"), item)
            } else if item.createdAt >= startYesterday {
                append("yesterday", TXL.t("history.group.yesterday", "Ayer"), item)
            } else if item.createdAt >= startWeek {
                append("week", TXL.t("history.group.week", "Últimos 7 días"), item)
            } else {
                let comps = calendar.dateComponents([.year, .month], from: item.createdAt)
                append("m\(comps.year ?? 0)-\(comps.month ?? 0)", TXFormat.monthYear(item.createdAt), item)
            }
        }
        return buckets.map { HistorySection(id: $0.key, title: $0.title, items: $0.items) }
    }

    // MARK: Documents

    func document(_ id: UUID) -> Transcription? { documents[id] }

    func item(_ id: UUID) -> HistoryItem? { items.first { $0.id == id } }

    /// Editor saves update the in-memory list without reloading everything.
    func didSave(_ t: Transcription) {
        documents[t.id] = t
        if let i = items.firstIndex(where: { $0.id == t.id }) {
            items[i] = HistoryItem(t)
        } else {
            items.insert(HistoryItem(t), at: 0)
        }
        sections = Self.group(items)
    }

    // MARK: Recently Deleted

    func moveToTrash(_ ids: [UUID]) {
        let storage = self.storage
        Task.detached { ids.forEach { storage.deleteTranscription(id: $0) } }
    }

    func restore(_ ids: [UUID]) {
        let storage = self.storage
        Task.detached { ids.forEach { storage.restoreTranscription(id: $0) } }
    }

    // MARK: Search (FTS5 with the same look for the fallback, spec 6.13)

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        isSearching = true
        let storage = self.storage
        let known = items
        searchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let hits: [SearchHit] = await Task.detached(priority: .userInitiated) {
                let found = storage.searchTranscriptions(matching: q)
                return found.map { t in
                    let item = known.first { $0.id == t.id } ?? HistoryItem(t)
                    let (snippet, ranges, count) = LibraryStore.excerpt(text: t.text, title: t.title, query: q)
                    return SearchHit(id: t.id, item: item, snippet: snippet, matchRanges: ranges, matchCount: count)
                }
                .sorted { $0.matchCount > $1.matchCount }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searchResults = SearchResults(query: q, hits: hits)
            self.isSearching = false
        }
    }

    /// Excerpt around the first match (≈ two lines) and the number of matches in title + text.
    nonisolated static func excerpt(text: String, title: String, query: String) -> (String, [Range<String.Index>], Int) {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func count(in s: String) -> Int {
            var n = 0
            var range = s.startIndex..<s.endIndex
            while let r = s.range(of: query, options: options, range: range) {
                n += 1
                range = r.upperBound..<s.endIndex
            }
            return n
        }
        let total = count(in: text) + count(in: title)
        guard let first = text.range(of: query, options: options) else {
            return (String(text.prefix(140)), [], max(total, 1))
        }
        let start = text.index(first.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: 110, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        var ranges: [Range<String.Index>] = []
        var range = snippet.startIndex..<snippet.endIndex
        while let r = snippet.range(of: query, options: options, range: range) {
            ranges.append(r)
            range = r.upperBound..<snippet.endIndex
        }
        return (snippet, ranges, max(total, 1))
    }
}
