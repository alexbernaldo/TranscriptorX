import SwiftUI
import Combine

/// State and operations of the open document (spec 7). One instance per open document,
/// owned by `DocumentSession`; views never create services or reload the document.
@MainActor
final class DocumentEditor: ObservableObject {

    enum Mode: Equatable {
        case reading
        case editing(UUID)
    }

    struct FindState: Equatable {
        var query = ""
        var replacement = ""
        var showReplace = false
        var caseSensitive = false
        var wholeWord = false
        var current = 0
    }

    // MARK: Published state

    @Published private(set) var document: Transcription
    /// Non-deleted segments in order (the editor never shows soft-deleted ones).
    @Published private(set) var visible: [TranscriptionSegment] = []
    @Published private(set) var mode: Mode = .reading
    @Published var selection: Set<UUID> = []
    @Published private(set) var anchor: UUID? {
        // A new anchor starts a new ⇧↑/⇧↓ extension.
        didSet { lastExtended = nil }
    }
    @Published var favoritesOnly = false {
        didSet { rebuildVisible() }
    }
    @Published var find: FindState? {
        didSet { if find?.query != oldValue?.query || find?.caseSensitive != oldValue?.caseSensitive || find?.wholeWord != oldValue?.wholeWord { recomputeMatches() } }
    }
    @Published private(set) var matches: [EditorOperations.Match] = []
    /// Follow playback (on by default). Suspended when the user navigates (spec 7.7).
    @Published var followPlayback = true
    @Published private(set) var playingSegmentId: UUID?
    @Published private(set) var activeWordIndex: Int?
    /// Segments whose start was estimated after a split without word timestamps («≈»).
    @Published private(set) var estimatedStarts: Set<UUID> = []
    /// Segments whose last save failed (error icon in the margin).
    @Published private(set) var failedSaves: Set<UUID> = []
    /// Timestamp that flashes once after applying new times.
    @Published private(set) var flashTimestamp: UUID?
    /// Scroll requests for the view (segment id + anchor).
    @Published var scrollRequest: ScrollRequest?
    @Published private(set) var selectedSpeaker: Int?

    struct ScrollRequest: Equatable {
        let id: UUID
        let anchor: UnitPoint
        let animated: Bool
        let token = UUID()
    }

    weak var undoManager: UndoManager?
    private var cancellables = Set<AnyCancellable>()
    private let storage = TranscriptionStorage.shared
    private let playback = PlaybackController.shared

    var id: UUID { document.id }
    var isEditing: Bool { if case .editing = mode { return true }; return false }
    var editingId: UUID? { if case .editing(let id) = mode { return id }; return nil }
    var hasSegments: Bool { !(document.segments ?? []).isEmpty }
    var hasWordTimestamps: Bool { (document.segments ?? []).contains { $0.words?.isEmpty == false } }

    var speakers: [Int] {
        Array(Set((document.segments ?? []).filter { !$0.isDeleted }.compactMap(\.speaker))).sorted()
    }

    init(document: Transcription) {
        self.document = document
        rebuildVisible()
        playback.$currentTime
            .removeDuplicates()
            .sink { [weak self] in self?.trackPlayback(at: $0) }
            .store(in: &cancellables)
    }

    // MARK: Lookups

    func segment(_ id: UUID) -> TranscriptionSegment? { visible.first { $0.id == id } }
    func index(of id: UUID) -> Int? { visible.firstIndex { $0.id == id } }

    func speakerName(_ index: Int) -> String {
        if let name = document.speakerNames?["\(index)"], !name.isEmpty { return name }
        return TXL.f("speaker.default", "Hablante %d", index + 1)
    }

    func segmentCount(for speaker: Int) -> Int {
        visible.filter { $0.speaker == speaker }.count
    }

    var hasUnnamedSpeakers: Bool {
        speakers.contains { (document.speakerNames?["\($0)"] ?? "").isEmpty }
    }

    private func rebuildVisible() {
        let all = (document.segments ?? []).filter { !$0.isDeleted }
        visible = favoritesOnly ? all.filter(\.isFavorite) : all
        recomputeMatches()
    }

    // MARK: Selection and navigation (Reading mode)

    func select(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            return
        }
        if extend, let anchor, let a = index(of: anchor), let b = index(of: id) {
            selection = Set(visible[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    var primarySelection: UUID? {
        if let editingId { return editingId }
        if let anchor, selection.contains(anchor) { return anchor }
        return visible.first { selection.contains($0.id) }?.id
    }

    /// ↑/↓ and ⇧↑/⇧↓. Moving with arrows suspends playback following when audio plays.
    func moveSelection(_ delta: Int, extend: Bool) {
        guard !visible.isEmpty else { return }
        // ⇧↑/⇧↓ continue from the last extended end, or start at the selection.
        let current = ((extend ? lastExtended : nil) ?? primarySelection).flatMap { index(of: $0) }
        let next = current.map { min(max($0 + delta, 0), visible.count - 1) } ?? (delta > 0 ? 0 : visible.count - 1)
        let id = visible[next].id
        if extend {
            lastExtended = id
            if let anchor, let a = index(of: anchor) {
                selection = Set(visible[min(a, next)...max(a, next)].map(\.id))
            } else {
                select(id)
                lastExtended = id
            }
        } else {
            lastExtended = nil
            select(id)
        }
        userNavigated()
        scrollRequest = ScrollRequest(id: id, anchor: .center, animated: false)
    }
    private var lastExtended: UUID?

    /// The user scrolled or moved with the keyboard while audio plays.
    func userNavigated() {
        if playback.isPlaying { followPlayback = false }
    }

    func resumeFollowing() {
        followPlayback = true
        if let id = playingSegmentId { scrollRequest = ScrollRequest(id: id, anchor: UnitPoint(x: 0.5, y: 0.35), animated: true) }
    }

    /// Click on a word in Reading mode: selects the segment and moves the audio there.
    func clicked(segment id: UUID, wordIndex: Int?) {
        select(id)
        guard let seg = segment(id) else { return }
        if let wordIndex, let words = seg.words, wordIndex < words.count, EditorOperations.wordsMatch(words, text: seg.text) {
            playback.seek(to: words[wordIndex].start)
        } else {
            playback.seek(to: seg.startTime)
        }
    }

    /// Click on a timestamp: moves playback without changing its state; reactivates following.
    func clickedTimestamp(_ id: UUID) {
        guard let seg = segment(id) else { return }
        playback.seek(to: seg.startTime)
        followPlayback = true
    }

    func nextFavorite(_ forward: Bool) {
        let favorites = visible.filter(\.isFavorite)
        guard !favorites.isEmpty else { return }
        let current = primarySelection.flatMap { index(of: $0) } ?? (forward ? -1 : visible.count)
        let target = forward
            ? favorites.first { index(of: $0.id)! > current } ?? favorites.first!
            : favorites.last { index(of: $0.id)! < current } ?? favorites.last!
        select(target.id)
        scrollRequest = ScrollRequest(id: target.id, anchor: .center, animated: false)
    }

    func jumpToSpeaker(_ speaker: Int, forward: Bool) {
        selectedSpeaker = speaker
        let segs = visible.filter { $0.speaker == speaker }
        guard !segs.isEmpty else { return }
        let current = primarySelection.flatMap { index(of: $0) } ?? (forward ? -1 : visible.count)
        let target = forward
            ? segs.first { index(of: $0.id)! > current } ?? segs.first!
            : segs.last { index(of: $0.id)! < current } ?? segs.last!
        select(target.id)
        scrollRequest = ScrollRequest(id: target.id, anchor: .center, animated: false)
    }

    func selectSpeaker(_ speaker: Int?) { selectedSpeaker = speaker }

    // MARK: Editing mode (spec 7.6)

    func beginEditing(_ id: UUID) {
        guard segment(id) != nil else { return }
        if let current = editingId, current != id { return }
        selection = [id]
        anchor = id
        mode = .editing(id)
    }

    /// Ends editing and saves (Esc or click outside). Returns true if text changed.
    @discardableResult
    func commitEditing(_ id: UUID, text: String) -> Bool {
        guard editingId == id else { return false }
        mode = .reading
        guard let idx = documentIndex(of: id) else { return false }
        let old = document.segments![idx]
        let updated = EditorOperations.applyTextEdit(old, newText: text)
        guard updated.text != old.text else { return false }
        mutate(actionName: TXL.t("undo.editText", "Editar texto")) { doc in
            doc.segments![idx] = updated
        }
        return true
    }

    /// ⌘Return: save and open the next segment in editing.
    func commitAndEditNext(_ id: UUID, text: String) {
        guard editingId == id, let i = index(of: id) else { return }
        commitEditing(id, text: text)
        if i + 1 < visible.count {
            let next = visible[i + 1].id
            beginEditing(next)
            scrollRequest = ScrollRequest(id: next, anchor: .center, animated: false)
        }
    }

    /// ⌥↑/⌥↓ at the edge of the segment while editing.
    func commitAndMove(_ id: UUID, text: String, delta: Int) {
        guard editingId == id, let i = index(of: id) else { return }
        commitEditing(id, text: text)
        let target = i + delta
        guard visible.indices.contains(target) else { return }
        beginEditing(visible[target].id)
        scrollRequest = ScrollRequest(id: visible[target].id, anchor: .center, animated: false)
    }

    // MARK: Structure operations

    /// ⌥Return in Editing: splits at the cursor. `utf16Offset` is the NSTextView location
    /// (UTF-16), converted to a character offset so accented text splits where the cursor is.
    func splitEditing(_ id: UUID, text: String, at utf16Offset: Int) {
        guard editingId == id, let idx = documentIndex(of: id) else { return }
        let offset = EditorOperations.characterOffset(utf16Offset: utf16Offset, in: text)
        // Split the text exactly as edited; words survive only if the edit kept them.
        let original = document.segments![idx]
        var source = original.withText(text)
        if let words = original.words, !EditorOperations.wordsMatch(words, text: text) { source.words = nil }
        guard let result = EditorOperations.split(source, atCharacterOffset: offset) else { return }
        mode = .reading
        mutate(actionName: TXL.t("undo.split", "Dividir segmento")) { doc in
            doc.segments![idx] = result.left
            doc.segments!.insert(result.right, at: idx + 1)
        }
        if result.estimated { estimatedStarts.insert(result.right.id) }
        selection = [result.right.id]
        anchor = result.right.id
        let time = TXFormat.timestamp(result.right.startTime, documentDuration: documentDuration)
        WorkspaceState.shared.showToast(ToastItem(icon: .success,
            text: TXL.f("toast.split", "Segmento dividido en %@", time),
            actionTitle: TXL.t("common.undo", "Deshacer"),
            action: { [weak self] in self?.undoManager?.undo() }))
    }

    var canMergeSelection: Bool {
        EditorOperations.areConsecutive(selection, in: visible)
    }

    /// Whether merging needs the different-speakers confirmation.
    var mergeNeedsConfirmation: Bool { EditorOperations.hasMixedSpeakers(selection, in: visible) }

    func mergeSelection() {
        guard canMergeSelection else { return }
        let ordered = visible.filter { selection.contains($0.id) }
        guard let merged = EditorOperations.merge(ordered), let firstIdx = documentIndex(of: ordered[0].id) else { return }
        let removeIds = Set(ordered.dropFirst().map(\.id))
        mutate(actionName: TXL.t("undo.merge", "Unir segmentos")) { doc in
            doc.segments![firstIdx] = merged
            doc.segments!.removeAll { removeIds.contains($0.id) }
        }
        selection = [merged.id]
        anchor = merged.id
    }

    func mergeWithNext(_ id: UUID) {
        guard let i = index(of: id), i + 1 < visible.count else { return }
        selection = [id, visible[i + 1].id]
        mergeSelection()
    }

    func setTimes(_ id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let idx = documentIndex(of: id) else { return }
        mutate(actionName: TXL.t("undo.times", "Ajustar tiempos")) { doc in
            doc.segments![idx].startTime = start
            doc.segments![idx].endTime = end
        }
        estimatedStarts.remove(id)
        flashTimestamp = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if self?.flashTimestamp == id { self?.flashTimestamp = nil }
        }
    }

    func neighbours(of id: UUID) -> (previous: TranscriptionSegment?, next: TranscriptionSegment?) {
        let all = (document.segments ?? []).filter { !$0.isDeleted }
        guard let i = all.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (i > 0 ? all[i - 1] : nil, i + 1 < all.count ? all[i + 1] : nil)
    }

    /// ⌘D: on the edited segment or the selection.
    func toggleFavorite(_ ids: Set<UUID>? = nil) {
        let targets = ids ?? (editingId.map { [$0] } ?? selection)
        guard !targets.isEmpty else { return }
        let allFavorite = visible.filter { targets.contains($0.id) }.allSatisfy(\.isFavorite)
        mutate(actionName: TXL.t("undo.favorite", "Favorito")) { doc in
            for i in doc.segments!.indices where targets.contains(doc.segments![i].id) {
                doc.segments![i].isFavorite = !allFavorite
            }
        }
    }

    func setSpeaker(_ speaker: Int, for ids: Set<UUID>) {
        mutate(actionName: TXL.t("undo.speaker", "Cambiar hablante")) { doc in
            for i in doc.segments!.indices where ids.contains(doc.segments![i].id) {
                doc.segments![i].speaker = speaker
            }
        }
    }

    // MARK: Speakers (spec 6.11)

    func renameSpeaker(_ index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(actionName: TXL.t("undo.renameSpeaker", "Renombrar hablante")) { doc in
            var names = doc.speakerNames ?? [:]
            if trimmed.isEmpty { names.removeValue(forKey: "\(index)") } else { names["\(index)"] = trimmed }
            doc.speakerNames = names.isEmpty ? nil : names
        }
    }

    func mergeSpeaker(_ from: Int, into target: Int) {
        mutate(actionName: TXL.t("undo.mergeSpeaker", "Fusionar hablantes")) { doc in
            let (segs, names) = EditorOperations.mergeSpeaker(from, into: target, segments: doc.segments ?? [], names: doc.speakerNames ?? [:])
            doc.segments = segs
            doc.speakerNames = names.isEmpty ? nil : names
        }
        if selectedSpeaker == from { selectedSpeaker = nil }
    }

    /// Clears the names given in this document (merges can be undone with ⌘Z in the session).
    func restoreSpeakerLabels() {
        mutate(actionName: TXL.t("undo.restoreSpeakers", "Restaurar etiquetas")) { doc in
            doc.speakerNames = nil
        }
    }

    // MARK: Title and AI metadata

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != document.title else { return }
        mutate(actionName: TXL.t("undo.rename", "Cambiar título")) { $0.title = trimmed }
    }

    func setAITags(_ tags: [String]) {
        mutate(actionName: TXL.t("undo.tags", "Guardar etiquetas")) { $0.aiTags = tags }
    }

    /// Keeps an AI suggestion/summary with the document (existing fields aiTitle/aiSummary).
    func storeAIResult(title: String? = nil, summary: String? = nil) {
        if let title { document.aiTitle = title }
        if let summary { document.aiSummary = summary }
        save()
    }

    /// «Restaurar texto original» (kept from the previous editor).
    func restoreOriginalText(_ id: UUID) {
        guard let idx = documentIndex(of: id), let original = document.segments![idx].originalText,
              original != document.segments![idx].text else { return }
        mutate(actionName: TXL.t("undo.restoreOriginal", "Restaurar texto original")) { doc in
            doc.segments![idx] = EditorOperations.applyTextEdit(doc.segments![idx], newText: original)
        }
    }

    /// Stores a translation (full text per language, the existing format).
    func storeTranslation(_ text: String, language: String) {
        var translations = document.fullTextTranslations ?? [:]
        translations[language] = text
        document.fullTextTranslations = translations
        save()
    }

    /// Updates fields written by services (AI summary, translations) without an undo step.
    func refreshFromStore(_ t: Transcription) {
        guard t.id == document.id else { return }
        document.aiTitle = t.aiTitle
        document.aiSummary = t.aiSummary
        document.aiTags = t.aiTags
        document.fullTextTranslations = t.fullTextTranslations
    }

    // MARK: Find and replace (spec 7.9)

    func openFind(replace: Bool) {
        if find == nil { find = FindState() }
        find?.showReplace = replace || (find?.showReplace ?? false)
    }

    func closeFind() {
        if let m = currentMatch { select(m.segmentId) }
        find = nil
    }

    private func recomputeMatches() {
        guard let f = find, !f.query.isEmpty else { matches = []; return }
        matches = EditorOperations.findMatches(f.query, in: visible, caseSensitive: f.caseSensitive, wholeWord: f.wholeWord)
        if let current = find?.current, current >= matches.count { find?.current = 0 }
    }

    var currentMatch: EditorOperations.Match? {
        guard let f = find, matches.indices.contains(f.current) else { return nil }
        return matches[f.current]
    }

    func stepMatch(_ delta: Int) {
        guard !matches.isEmpty, find != nil else { return }
        find!.current = (find!.current + delta + matches.count) % matches.count
        if let m = currentMatch {
            scrollRequest = ScrollRequest(id: m.segmentId, anchor: .center, animated: false)
        }
    }

    func replaceCurrent() {
        guard let f = find, let m = currentMatch, let idx = documentIndex(of: m.segmentId) else { return }
        let seg = document.segments![idx]
        let newText = EditorOperations.replacing([m], in: seg.text, with: f.replacement)
        mutate(actionName: TXL.t("undo.replace", "Reemplazar")) { doc in
            doc.segments![idx] = EditorOperations.applyTextEdit(seg, newText: newText)
        }
    }

    func replaceAll() {
        guard let f = find, !matches.isEmpty else { return }
        let grouped = Dictionary(grouping: matches, by: \.segmentId)
        let count = matches.count
        mutate(actionName: TXL.t("undo.replaceAll", "Reemplazar todo")) { doc in
            for (segId, ms) in grouped {
                guard let idx = doc.segments!.firstIndex(where: { $0.id == segId }) else { continue }
                let seg = doc.segments![idx]
                doc.segments![idx] = EditorOperations.applyTextEdit(seg, newText: EditorOperations.replacing(ms, in: seg.text, with: f.replacement))
            }
        }
        WorkspaceState.shared.showToast(ToastItem(icon: .success,
            text: TXL.f("toast.replaceAll", "%@ en %@", TXL.n("toast.replacements", "%d reemplazo", "%d reemplazos", count),
                        TXL.n("toast.segments", "%d segmento", "%d segmentos", grouped.count)),
            actionTitle: TXL.t("common.undo", "Deshacer"),
            action: { [weak self] in self?.undoManager?.undo() }))
    }

    // MARK: Playback tracking

    var documentDuration: TimeInterval {
        max(document.duration, (document.segments ?? []).last?.endTime ?? 0)
    }

    private func trackPlayback(at time: TimeInterval) {
        guard playback.documentId == document.id else {
            if playingSegmentId != nil { playingSegmentId = nil; activeWordIndex = nil }
            return
        }
        let idx = EditorOperations.segmentIndex(at: time, in: visible)
        let newId = idx.map { visible[$0].id }
        if newId != playingSegmentId { playingSegmentId = newId }
        var word: Int? = nil
        if let idx, let words = visible[idx].words, EditorOperations.wordsMatch(words, text: visible[idx].text) {
            word = EditorOperations.wordIndex(at: time, in: words)
        }
        if word != activeWordIndex { activeWordIndex = word }
    }

    // MARK: Mutation, undo and persistence

    private func documentIndex(of id: UUID) -> Int? {
        document.segments?.firstIndex { $0.id == id }
    }

    /// Applies a change with an undo step (snapshot) and saves in the background.
    private func mutate(actionName: String, _ change: (inout Transcription) -> Void) {
        let before = document
        var after = document
        change(&after)
        apply(after, undoFrom: before, actionName: actionName)
    }

    private func apply(_ new: Transcription, undoFrom old: Transcription, actionName: String) {
        document = recomputedText(new)
        rebuildVisible()
        undoManager?.registerUndo(withTarget: self) { target in
            target.apply(old, undoFrom: target.document, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        save()
    }

    private func recomputedText(_ t: Transcription) -> Transcription {
        var t = t
        if let segs = t.segments {
            t.text = segs.filter { !$0.isDeleted }.map(\.text).joined(separator: " ")
        }
        return t
    }

    private var saveTask: Task<Void, Never>?

    func save() {
        let snapshot = document
        let editedId = selection.first
        LibraryStore.shared.didSave(snapshot)
        saveTask = Task { [weak self] in
            let storage = TranscriptionStorage.shared
            let ok = await Task.detached(priority: .utility) { storage.saveQuietly(snapshot) }.value
            guard let self else { return }
            if ok {
                if !self.failedSaves.isEmpty {
                    self.failedSaves.removeAll()
                    WorkspaceState.shared.dismissBanner(key: "save:\(snapshot.id)")
                }
            } else {
                self.reportSaveFailure(segmentId: editedId)
            }
        }
    }

    private func reportSaveFailure(segmentId: UUID?) {
        if let segmentId { failedSaves.insert(segmentId) }
        let time = segmentId.flatMap { segment($0) }.map { TXFormat.timestamp($0.startTime, documentDuration: documentDuration) } ?? ""
        WorkspaceState.shared.post(BannerItem(
            key: "save:\(document.id)", kind: .error,
            title: TXL.f("banner.saveFailed", "No se pudo guardar el cambio en %@", time),
            actions: [BannerAction(title: TXL.t("common.retry", "Reintentar"), isPrimary: true) { [weak self] in self?.save() }]))
    }
}
