import SwiftUI
import AppKit
import Combine

/// One open document: its editor. Sessions are cached so navigating does not reload or reset
/// anything (spec: no duplicated services, no restarted tasks when navigating).
@MainActor
final class DocumentSession {
    let editor: DocumentEditor
    init(document: Transcription) { editor = DocumentEditor(document: document) }
}

@MainActor
final class DocumentSessions {
    static let shared = DocumentSessions()
    private var sessions: [UUID: DocumentSession] = [:]
    private var order: [UUID] = []
    private var observer: AnyCancellable?

    private init() {
        // Services (AI, translation) write to the store: refresh those fields in open editors.
        observer = LibraryStore.shared.$items
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for (id, session) in self.sessions {
                        if let t = LibraryStore.shared.document(id) { session.editor.refreshFromStore(t) }
                    }
                }
            }
    }

    /// Returns the session for a document, creating it (cheap, synchronous) when needed.
    func session(for id: UUID) -> DocumentSession? {
        if let s = sessions[id] { touch(id); return s }
        guard let document = LibraryStore.shared.document(id) else { return nil }
        let s = DocumentSession(document: document)
        sessions[id] = s
        touch(id)
        return s
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 3 {
            let old = order.removeFirst()
            sessions[old] = nil
        }
    }
}

// MARK: - Document view

struct DocumentView: View {
    let documentId: UUID

    var body: some View {
        if let session = DocumentSessions.shared.session(for: documentId) {
            DocumentContent(editor: session.editor)
        }
    }
}

/// ⇧⌘T from the menu: which segment's time popover to open.
@MainActor
final class AdjustTimesRequest: ObservableObject {
    static let shared = AdjustTimesRequest()
    @Published var segmentId: UUID?
}

private struct PlayingRowFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

struct VisibleRowsKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { a, _ in a })
    }
}

struct DocumentContent: View {
    @ObservedObject var editor: DocumentEditor
    @ObservedObject private var playback = PlaybackController.shared
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCompactHeight) private var compactHeight
    @Environment(\.workAreaWidth) private var workAreaWidth
    @AppStorage("transcriptSize") private var transcriptSizeRaw = TX.TranscriptSize.normal.rawValue
    @State private var viewportHeight: CGFloat = 600
    @State private var scrollFrame: CGRect = .zero
    @State private var playingFrame: CGRect?
    @State private var headerCompact = false
    @State private var scrollMonitor: Any?
    @State private var showTranslation = false
    @State private var restored = false
    @State private var timesPopoverFor: UUID?
    @FocusState private var listFocused: Bool

    private var transcriptSize: TX.TranscriptSize { TX.TranscriptSize(rawValue: transcriptSizeRaw) ?? .normal }
    /// Timestamp moves above the segment when the work area is narrow or the text is Very Large (spec 10.4).
    private var stackedTimestamps: Bool { workAreaWidth < 640 || transcriptSize == .extraLarge }
    private var translationLanguage: String? { editor.document.fullTextTranslations?.keys.sorted().first }

    var body: some View {
        VStack(spacing: 0) {
            if editor.find != nil {
                FindBar(editor: editor)
                TXSeparator()
            }
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            DocumentHeader(editor: editor, showTranslation: $showTranslation, compactHeight: compactHeight)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: HeaderOffsetKey.self, value: geo.frame(in: .named("docScroll")).maxY)
                                })
                            if showTranslation, let lang = translationLanguage, let text = editor.document.fullTextTranslations?[lang] {
                                TranslationReadingView(text: text, language: lang)
                            } else if !editor.hasSegments {
                                PlainTextReadingView(text: editor.document.text)
                            } else if editor.visible.isEmpty {
                                TXEmptyState(systemImage: "star", title: TXL.t("editor.noFavorites", "No hay segmentos favoritos"),
                                             message: TXL.t("editor.noFavorites.text", "Marca segmentos con ⌘D para verlos aquí."))
                                    .padding(.top, 60)
                            } else {
                                segmentList
                            }
                        }
                        .padding(.horizontal, TX.Space.s32)
                        .padding(.bottom, TX.Space.s48)
                        .frame(maxWidth: TX.Size.readingColumn + (stackedTimestamps ? 0 : TX.Size.timestampGutter) + 2 * TX.Space.s32)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "docScroll")
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { viewportHeight = geo.size.height; scrollFrame = geo.frame(in: .global) }
                            .txOnChange(of: geo.size.height) { viewportHeight = $0; scrollFrame = geo.frame(in: .global) }
                    })
                    .onPreferenceChange(PlayingRowFrameKey.self) { playingFrame = $0 }
                    .onPreferenceChange(HeaderOffsetKey.self) { maxY in
                        let compact = maxY < 0
                        if compact != headerCompact { headerCompact = compact }
                    }
                    .onPreferenceChange(VisibleRowsKey.self) { rows in saveTopSegment(rows) }
                    .txOnChange(of: editor.scrollRequest) { request in
                        guard let request else { return }
                        withAnimation(request.animated && !reduceMotion ? TX.Motion.followPlayback : nil) {
                            proxy.scrollTo(request.id, anchor: request.anchor)
                        }
                    }
                    .txOnChange(of: editor.playingSegmentId) { id in followPlayback(id, proxy: proxy) }
                    .onAppear { restore(proxy) }
                    .overlay(alignment: .trailing) { MarkRail(editor: editor) }
                }
                if headerCompact { CompactDocumentBar(editor: editor, showTranslation: $showTranslation) }
                if !editor.followPlayback && playback.isPlaying {
                    VStack {
                        Spacer()
                        Button {
                            editor.resumeFollowing()
                        } label: {
                            Text(TXL.t("editor.backToPlayback", "Volver a la reproducción ⌘L"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillButtonStyle())
                        .padding(.bottom, 12)
                    }
                    .transition(.opacity)
                }
            }
            if playback.hasMedia || playback.missingMediaPath != nil || editor.document.sourceURL != nil {
                PlayerBar(editor: editor)
            }
        }
        .background(TX.Colors.bgWindow)
        .focusable()
            .txCustomFocusRing()
        .focused($listFocused)
        .onKeyDown(active: workspace.sheet == nil && !editor.isEditing) { handleReadingKey($0) }
        .onAppear {
            editor.undoManager = undoManager
            CommandRouter.shared.activeEditor = editor
            loadMedia()
            installScrollMonitor()
            if let query = PendingFind.shared.consume(for: editor.id) {
                editor.openFind(replace: false)
                editor.find?.query = query
                if let m = editor.matches.first { editor.select(m.segmentId); editor.scrollRequest = .init(id: m.segmentId, anchor: .center, animated: false) }
            }
            if DocumentFocus.shared.pendingFocusFirstSegment == editor.id, let first = editor.visible.first {
                DocumentFocus.shared.pendingFocusFirstSegment = nil
                editor.select(first.id)
                listFocused = true
            }
        }
        .onDisappear {
            removeScrollMonitor()
            if CommandRouter.shared.activeEditor === editor { CommandRouter.shared.activeEditor = nil }
        }
        .txOnChange(of: playback.currentTime) { time in savePosition(time) }
        .onReceive(AdjustTimesRequest.shared.$segmentId) { id in
            guard let id, editor.segment(id) != nil else { return }
            timesPopoverFor = id
            AdjustTimesRequest.shared.segmentId = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.document", "Documento"))
    }

    // MARK: Segment list (lazy: only visible rows plus a margin are built, spec 7.14)

    private var segmentList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(editor.visible.enumerated()), id: \.element.id) { index, segment in
                let previous = index > 0 ? editor.visible[index - 1] : nil
                let turn = segment.speaker != nil && segment.speaker != previous?.speaker
                SegmentRow(editor: editor, segment: segment, index: index,
                           showsSpeaker: turn, isFirst: index == 0, stackedTimestamp: stackedTimestamps,
                           style: transcriptSize.style, listFocused: listFocused,
                           timesPopoverFor: $timesPopoverFor)
                    .id(segment.id)
                    .padding(.top, index == 0 ? TX.Space.s16 : (turn ? TX.Space.s20 : TX.Space.s12))
                    .background(GeometryReader { geo in
                        let frame = geo.frame(in: .named("docScroll"))
                        Color.clear
                            .preference(key: PlayingRowFrameKey.self, value: editor.playingSegmentId == segment.id ? frame : nil)
                            .preference(key: VisibleRowsKey.self, value: [segment.id: frame.minY])
                    })
            }
        }
    }

    // MARK: Follow playback (spec 7.7)

    private func followPlayback(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, editor.followPlayback, playback.isPlaying else { return }
        let band = (viewportHeight * 0.20)...(viewportHeight * 0.70)
        if let f = playingFrame, band.contains(f.minY) { return }
        withAnimation(reduceMotion ? nil : TX.Motion.followPlayback) {
            proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
    }

    /// Wheel/trackpad scrolling while audio plays suspends following.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if let window = event.window, window === WindowCoordinator.mainWindow, let content = window.contentView {
                let p = content.convert(event.locationInWindow, from: nil)
                let point = CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
                if scrollFrame.contains(point) { editor.userNavigated() }
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: Keyboard (Reading mode, spec 7.8)

    private func handleReadingKey(_ event: NSEvent) -> Bool {
        guard workspace.currentDocumentId == editor.id else { return false }
        let mods = event.txModifiers
        switch (event.keyCode, mods) {
        case (KeyCode.space, []):
            playback.togglePlayPause()
            if playback.isPlaying { editor.followPlayback = true }
            return true
        case (KeyCode.left, []):
            playback.skip(-5); return true
        case (KeyCode.right, []):
            playback.skip(5); return true
        case (KeyCode.up, []):
            editor.moveSelection(-1, extend: false); listFocused = true; return true
        case (KeyCode.down, []):
            editor.moveSelection(1, extend: false); listFocused = true; return true
        case (KeyCode.up, .shift):
            editor.moveSelection(-1, extend: true); return true
        case (KeyCode.down, .shift):
            editor.moveSelection(1, extend: true); return true
        case (KeyCode.returnKey, []), (KeyCode.enter, []):
            if let id = editor.primarySelection { editor.beginEditing(id); return true }
            return false
        case (KeyCode.escape, []):
            if editor.find != nil { editor.closeFind(); return true }
            if !editor.selection.isEmpty { editor.selection = []; return true }
            return false
        default:
            return false
        }
    }

    // MARK: Media and restoration (spec 4.5)

    private func loadMedia() {
        let position = UserDefaults.standard.double(forKey: "restore.position.\(editor.id.uuidString)")
        PlaybackController.shared.load(documentId: editor.id, url: editor.document.sourceURL,
                                       fallbackDuration: editor.documentDuration, position: position)
    }

    private func restore(_ proxy: ScrollViewProxy) {
        guard !restored else { return }
        restored = true
        if let raw = UserDefaults.standard.string(forKey: "restore.segment.\(editor.id.uuidString)"),
           let id = UUID(uuidString: raw), editor.segment(id) != nil, editor.visible.first?.id != id {
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        }
    }

    @State private var lastPositionSave = Date.distantPast
    private func savePosition(_ time: TimeInterval) {
        guard Date().timeIntervalSince(lastPositionSave) > 2 || !playback.isPlaying else { return }
        lastPositionSave = Date()
        UserDefaults.standard.set(time, forKey: "restore.position.\(editor.id.uuidString)")
    }

    private func saveTopSegment(_ rows: [UUID: CGFloat]) {
        guard let top = rows.filter({ $0.value >= -40 }).min(by: { $0.value < $1.value })?.key else { return }
        UserDefaults.standard.set(top.uuidString, forKey: "restore.segment.\(editor.id.uuidString)")
    }
}

private struct HeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TX.Colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(configuration.isPressed ? TX.Colors.bgControl : TX.Colors.bgElevated))
            .txFloatingShadow(cornerRadius: 14)
            .clipShape(Capsule())
    }
}

// MARK: - Header (spec 7.1)

struct DocumentHeader: View {
    @ObservedObject var editor: DocumentEditor
    @Binding var showTranslation: Bool
    var compactHeight = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                titleView
                if compactHeight {
                    Text(TXFormat.shortDuration(editor.documentDuration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(TX.Colors.textSecondary)
                }
                Spacer(minLength: 12)
                if editor.hasSegments {
                    Toggle(TXL.t("editor.favoritesOnly", "Solo favoritos"), isOn: $editor.favoritesOnly)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12))
                        .help(TXL.t("editor.favoritesOnly.help", "Filtra la vista, no el documento"))
                    Text(TXL.n("editor.segmentCount", "%2$@ segmento", "%2$@ segmentos",
                               (editor.document.segments ?? []).filter { !$0.isDeleted }.count,
                               TXFormat.integer((editor.document.segments ?? []).filter { !$0.isDeleted }.count)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(TX.Colors.textTertiary)
                }
            }
            if !compactHeight {
                Text(metadata)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .tracking(0.2)
                    .foregroundStyle(TX.Colors.textSecondary)
                if !(editor.document.aiTags ?? []).isEmpty || editor.document.fullTextTranslations?.isEmpty == false {
                    HStack(spacing: 8) {
                        if let tags = editor.document.aiTags, !tags.isEmpty { FlowTags(tags: tags) }
                        Spacer(minLength: 0)
                        TranslationToggle(editor: editor, showTranslation: $showTranslation)
                    }
                }
            }
        }
        .padding(.top, compactHeight ? TX.Space.s12 : TX.Space.s24)
        .padding(.bottom, TX.Space.s8)
        .frame(minHeight: compactHeight ? 44 : 96, alignment: .bottomLeading)
        .padding(.leading, 0)
    }

    @ViewBuilder private var titleView: some View {
        if editingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { editor.rename(titleDraft); editingTitle = false }
                .onExitCommand { editingTitle = false }
                .onAppear { titleFocused = true }
                .accessibilityLabel(TXL.t("editor.title.a11y", "Título del documento"))
        } else {
            Text(editor.document.title)
                .font(.system(size: compactHeight ? 15 : 20, weight: .semibold))
                .foregroundStyle(TX.Colors.textPrimary)
                .lineLimit(2)
                .onTapGesture { titleDraft = editor.document.title; editingTitle = true }
                .help(TXL.t("editor.title.help", "Haz clic para cambiar el título"))
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: TXL.t("editor.title.rename", "Cambiar título")) {
                    titleDraft = editor.document.title; editingTitle = true
                }
        }
    }

    /// «12 oct 2026, 10:42 · 42 min 10 s · Español · 3 hablantes» (the model is not stored with
    /// documents, so it is not shown; spec 12.1 #22).
    private var metadata: String {
        var parts = [TXFormat.longDateTime(editor.document.createdAt)]
        if editor.documentDuration > 0 { parts.append(TXFormat.longDuration(editor.documentDuration)) }
        parts.append(TXFormat.languageName(editor.document.language))
        let speakers = editor.speakers.count
        if speakers > 0 { parts.append(TXL.n("history.speakers", "%d hablante", "%d hablantes", speakers)) }
        return parts.joined(separator: " · ")
    }
}

struct TranslationToggle: View {
    @ObservedObject var editor: DocumentEditor
    @Binding var showTranslation: Bool

    var body: some View {
        if let lang = editor.document.fullTextTranslations?.keys.sorted().first {
            Picker("", selection: $showTranslation) {
                Text(TXL.t("editor.original", "Original")).tag(false)
                Text(TXFormat.languageName(lang)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(TXL.t("editor.translationToggle", "Versión del texto"))
        }
    }
}

/// 44 pt sticky bar once the header scrolls away.
struct CompactDocumentBar: View {
    @ObservedObject var editor: DocumentEditor
    @Binding var showTranslation: Bool

    var body: some View {
        HStack {
            Text(editor.document.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TX.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
            TranslationToggle(editor: editor, showTranslation: $showTranslation)
        }
        .padding(.horizontal, TX.Space.s32)
        .frame(height: 44)
        .background(TX.Colors.bgWindow.opacity(0.97))
        .overlay(alignment: .bottom) { TXSeparator() }
    }
}

/// Translation: read-only, copyable (spec 6.19). Stored as full text per language in this version.
struct TranslationReadingView: View {
    let text: String
    let language: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TXL.f("translation.readOnly", "Traducción al %@ · solo lectura", TXFormat.languageName(language).lowercased()))
                .font(.system(size: 12))
                .foregroundStyle(TX.Colors.textSecondary)
            Text(text)
                .txStyle(TX.Typography.transcript)
                .foregroundStyle(TX.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: TX.Size.readingColumn, alignment: .leading)
        }
        .padding(.top, TX.Space.s16)
    }
}

/// Documents without segments (YouTube subtitles, old plain-text imports).
struct PlainTextReadingView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TXL.t("editor.plainText.note", "Este documento no tiene segmentos con tiempo: se muestra como texto continuo."))
                .font(.system(size: 12))
                .foregroundStyle(TX.Colors.textSecondary)
            Text(text)
                .txStyle(TX.Typography.transcript)
                .foregroundStyle(TX.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: TX.Size.readingColumn, alignment: .leading)
        }
        .padding(.top, TX.Space.s16)
    }
}

// MARK: - Scroll rail marks: favourites (4 pt purple.400) and search matches (2 pt amber)

struct MarkRail: View {
    @ObservedObject var editor: DocumentEditor

    var body: some View {
        GeometryReader { geo in
            let count = max(editor.visible.count, 1)
            let index = Dictionary(uniqueKeysWithValues: editor.visible.enumerated().map { ($1.id, $0) })
            ZStack(alignment: .topTrailing) {
                if editor.visible.count > 500 {
                    ForEach(editor.visible.filter(\.isFavorite)) { seg in
                        Circle().fill(TX.Colors.accentText).frame(width: 4, height: 4)
                            .offset(y: geo.size.height * CGFloat(index[seg.id] ?? 0) / CGFloat(count))
                    }
                }
                ForEach(Array(Set(editor.matches.map(\.segmentId))), id: \.self) { id in
                    Rectangle().fill(TX.Colors.searchMatch).frame(width: 8, height: 2)
                        .offset(y: geo.size.height * CGFloat(index[id] ?? 0) / CGFloat(count))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 10)
        .padding(.trailing, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
