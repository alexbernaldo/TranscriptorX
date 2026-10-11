import SwiftUI

/// Inspector (spec 4.2): Hablantes, IA, Traducción, Detalles. Remembers the tab per document.
/// Tab changes are not animated (spec 9.5).
struct InspectorView: View {
    @ObservedObject var editor: DocumentEditor
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        let tab = workspace.inspectorTab(for: editor.id)
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { workspace.setInspectorTab($0, for: editor.id) })) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(TX.Space.s16)
            .accessibilityLabel(TXL.t("inspector.tabs.a11y", "Pestañas del inspector"))
            TXSeparator()
            Group {
                switch tab {
                case .speakers: SpeakersTab(editor: editor)
                case .ai: AITab(editor: editor)
                case .translation: TranslationTab(editor: editor)
                case .details: DetailsTab(editor: editor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(TX.Colors.bgWindow)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.inspector", "Inspector"))
    }
}

// MARK: - Hablantes (spec 6.11)

struct SpeakersTab: View {
    @ObservedObject var editor: DocumentEditor
    @State private var renaming: Int?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if editor.speakers.isEmpty {
            ScrollView {
                TXEmptyState(systemImage: "person.2",
                             title: TXL.t("speakers.empty.title", "Esta transcripción no tiene hablantes identificados"),
                             message: TXL.t("speakers.empty.text", "Activa «Quién habla» en Opciones, en Inicio, antes de transcribir."))
                    .padding(TX.Space.s16)
                    .padding(.top, TX.Space.s24)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.speakers, id: \.self) { speaker in row(speaker) }
                    if let selected = editor.selectedSpeaker {
                        HStack(spacing: 8) {
                            Button(TXL.t("speakers.previous", "Anterior")) { editor.jumpToSpeaker(selected, forward: false) }
                                .buttonStyle(TXSecondaryButtonStyle(size: .small))
                            Button(TXL.t("speakers.next", "Siguiente")) { editor.jumpToSpeaker(selected, forward: true) }
                                .buttonStyle(TXSecondaryButtonStyle(size: .small))
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                    }
                    Button(TXL.t("speakers.restore", "Restaurar etiquetas originales")) {
                        SpeakerActions.confirmRestore(editor: editor)
                    }
                    .buttonStyle(TXBorderlessButtonStyle())
                    .padding(.top, 12)
                    .disabled(editor.document.speakerNames?.isEmpty ?? true)
                }
                .padding(TX.Space.s8)
            }
        }
    }

    private func row(_ speaker: Int) -> some View {
        let selected = editor.selectedSpeaker == speaker
        return HStack(spacing: 8) {
            SpeakerMark(index: speaker, size: 10)
            if renaming == speaker {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit { editor.renameSpeaker(speaker, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
                    .onAppear { fieldFocused = true }
            } else {
                Text(editor.speakerName(speaker))
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(TX.Colors.textPrimary)
                    .lineLimit(1)
                if TX.Speakers.needsNumber(speaker) {
                    Text("H\(speaker + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(TX.Colors.textSecondary)
                }
            }
            Spacer()
            Text(TXL.n("speakers.segments", "%d segmento", "%d segmentos", editor.segmentCount(for: speaker)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(TX.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).fill(selected ? TX.Colors.selectionRow : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = editor.speakerName(speaker); renaming = speaker }
        .onTapGesture { editor.selectSpeaker(selected ? nil : speaker) }
        .contextMenu {
            Button(TXL.f("speaker.rename", "Renombrar %@…", editor.speakerName(speaker))) {
                draft = editor.speakerName(speaker); renaming = speaker
            }
            Menu(TXL.t("speaker.mergeWith", "Fusionar con…")) {
                ForEach(editor.speakers.filter { $0 != speaker }, id: \.self) { other in
                    Button(editor.speakerName(other)) { SpeakerActions.confirmMerge(editor: editor, from: speaker, into: other) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TXL.f("speakers.row.a11y", "%@, hablante %d, %@", editor.speakerName(speaker), speaker + 1,
                                  TXL.n("speakers.segments", "%d segmento", "%d segmentos", editor.segmentCount(for: speaker))))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { editor.selectSpeaker(selected ? nil : speaker) }
        .accessibilityAction(named: TXL.t("speakers.rename.a11y", "Renombrar")) { draft = editor.speakerName(speaker); renaming = speaker }
        .accessibilityAction(named: TXL.t("speaker.mergeWith", "Fusionar con…")) {
            if let other = editor.speakers.first(where: { $0 != speaker }) {
                SpeakerActions.confirmMerge(editor: editor, from: speaker, into: other)
            }
        }
    }
}

// MARK: - IA (spec 6.18)

struct AITab: View {
    @ObservedObject var editor: DocumentEditor
    @ObservedObject private var ai = AIController.shared
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    private var id: UUID { editor.id }
    private var enabled: Bool { ai.availability == .available && !editor.document.text.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerHeader
                    TXSeparator()
                    titleBlock
                    summaryBlock
                    tagsBlock
                }
                .padding(TX.Space.s16)
            }
            .frame(maxHeight: .infinity)
            TXSeparator()
            chat
                .frame(maxHeight: .infinity)
            Text(TXL.f("ai.footer", "Se procesa con %@ en este Mac.", ai.providerName))
                .font(.system(size: 11))
                .foregroundStyle(TX.Colors.textSecondary)
                .padding(.horizontal, TX.Space.s16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if ai.availability == .checking { ai.check() } }
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { ai.provider }, set: { ai.provider = $0 })) {
                Text(verbatim: "Apple Foundation Models").tag(AIProviderKind.appleFoundation)
                Text(verbatim: "Ollama").tag(AIProviderKind.ollama)
                Text(verbatim: "LM Studio").tag(AIProviderKind.lmstudio)
            }
            .labelsHidden()
            .accessibilityLabel(TXL.t("ai.provider", "Proveedor"))
            if !AIController.appleModelsSupported && ai.provider == .appleFoundation {
                EmptyView()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch ai.availability {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text(TXL.t("ai.checking", "Comprobando…")).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                case .available:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TX.Colors.success).accessibilityHidden(true)
                    Text(TXL.t("ai.available", "Disponible")).font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                case .unavailable(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TX.Colors.warning).accessibilityHidden(true)
                    Text(reason).font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if ai.provider != .appleFoundation, !ai.models.isEmpty {
                Picker("", selection: Binding(get: { ai.selectedModel ?? "" }, set: { ai.setModel($0) })) {
                    ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel(TXL.t("ai.model", "Modelo"))
            }
            Button(TXL.t("ai.recheck", "Volver a comprobar")) { ai.check() }
                .buttonStyle(TXBorderlessButtonStyle())
        }
    }

    // MARK: Blocks (pending vs finished)

    private func actionRow(_ title: String, task: AIController.AITask) -> some View {
        HStack {
            if ai.running[id] == task {
                Button(TXL.t("ai.stop", "Detener")) { ai.cancel(task, document: id) }
                    .buttonStyle(TXSecondaryButtonStyle(size: .small))
            } else {
                Button(title) { ai.run(task, editor: editor) }
                    .buttonStyle(TXSecondaryButtonStyle(size: .small))
                    .disabled(!enabled || ai.running[id] != nil)
            }
            Spacer()
        }
    }

    private func pending(_ task: AIController.AITask) -> some View {
        Group {
            if ai.running[id] == task {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TXL.f("ai.generating", "Generando con %@…", ai.providerName))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                    TXProgressLine(kind: .indeterminate)
                }
            } else if let error = ai.failures[id]?[task] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
                    Text(TXL.f("ai.incomplete", "Respuesta incompleta · %@", error))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(TXL.t("ai.tryAgain", "Volver a intentar")) { ai.run(task, editor: editor) }
                    .buttonStyle(TXBorderlessButtonStyle())
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow(TXL.t("ai.suggestTitle", "Sugerir título"), task: .title)
            pending(.title)
            if let suggestion = ai.titleSuggestion[id] ?? editor.document.aiTitle, ai.running[id] != .title,
               suggestion != editor.document.title {
                Text(suggestion)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TX.Colors.textPrimary)
                    .textSelection(.enabled)
                HStack {
                    Button(TXL.t("ai.useTitle", "Usar este título")) { editor.rename(suggestion); ai.dismissTitle(id) }
                        .buttonStyle(TXSecondaryButtonStyle(size: .small))
                    Button(TXL.t("ai.discard", "Descartar")) { ai.dismissTitle(id); editor.storeAIResult(title: "") }
                        .buttonStyle(TXBorderlessButtonStyle())
                }
            }
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow(TXL.t("ai.summarize", "Resumir"), task: .summary)
            pending(.summary)
            if let summary = editor.document.aiSummary, !summary.isEmpty, ai.running[id] != .summary {
                Text(summary)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .foregroundStyle(TX.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(TXL.t("common.copy", "Copiar")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    .buttonStyle(TXSecondaryButtonStyle(size: .small))
                    Button(TXL.t("ai.regenerate", "Volver a generar")) { ai.run(.summary, editor: editor) }
                        .buttonStyle(TXBorderlessButtonStyle())
                        .disabled(!enabled)
                }
            }
        }
    }

    private var tagsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow(TXL.t("ai.suggestTags", "Sugerir etiquetas"), task: .tags)
            pending(.tags)
            if let tags = ai.tagSuggestion[id], !tags.isEmpty, ai.running[id] != .tags {
                FlowTags(tags: tags)
                HStack {
                    Button(TXL.t("ai.saveTags", "Guardar etiquetas")) { editor.setAITags(tags); ai.dismissTags(id) }
                        .buttonStyle(TXSecondaryButtonStyle(size: .small))
                    Button(TXL.t("ai.discard", "Descartar")) { ai.dismissTags(id) }
                        .buttonStyle(TXBorderlessButtonStyle())
                }
            }
        }
    }

    // MARK: Chat (blocks without bubbles)

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(ai.chats[id] ?? []) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.author)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(TX.Colors.textSecondary)
                                if message.text.isEmpty && ai.chatRunning.contains(id) {
                                    WaitingFragments()
                                } else {
                                    Text(message.text)
                                        .font(.system(size: 13))
                                        .lineSpacing(5)
                                        .foregroundStyle(TX.Colors.textPrimary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if message.incomplete {
                                    HStack(spacing: 6) {
                                        Text(TXL.t("ai.chat.incomplete", "Respuesta incompleta"))
                                            .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                                        Button(TXL.t("ai.tryAgain", "Volver a intentar")) { ai.retryLast(editor) }
                                            .buttonStyle(TXBorderlessButtonStyle())
                                    }
                                }
                            }
                            .id(message.id)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(TX.Space.s16)
                }
                .txOnChange(of: ai.chats[id]?.count ?? 0) { _ in
                    if let last = ai.chats[id]?.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ChatField(text: $question, placeholder: TXL.t("ai.chat.placeholder", "Pregunta algo sobre esta transcripción")) {
                    ai.send(question, editor: editor); question = ""
                }
                .disabled(!enabled)
                if ai.chatRunning.contains(id) {
                    Button { ai.stopChat(id) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(TXIconButtonStyle())
                        .help(TXL.t("ai.stop", "Detener"))
                        .accessibilityLabel(TXL.t("ai.stop", "Detener"))
                }
            }
            .padding(TX.Space.s12)
        }
    }
}

/// 2 to 6 lines; Return sends, ⇧Return inserts a line break.
struct ChatField: View {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(2...6)
            .font(.system(size: 13))
            .txField(height: nil)
            .padding(.vertical, 0)
            .focused($focused)
            .onKeyDown(active: focused, allowTextInput: true) { event in
                guard event.keyCode == KeyCode.returnKey else { return false }
                if event.modifierFlags.contains(.shift) {
                    text += "\n"
                    return true
                }
                onSend()
                return true
            }
            .accessibilityLabel(placeholder)
    }
}

// MARK: - Detalles

struct DetailsTab: View {
    @ObservedObject var editor: DocumentEditor

    var body: some View {
        let doc = editor.document
        let segments = (doc.segments ?? []).filter { !$0.isDeleted }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                detail(TXL.t("details.created", "Creada"), TXFormat.longDateTime(doc.createdAt))
                detail(TXL.t("details.duration", "Duración"), TXFormat.longDuration(editor.documentDuration))
                detail(TXL.t("details.language", "Idioma"), TXFormat.languageName(doc.language))
                detail(TXL.t("details.segments", "Segmentos"), TXFormat.integer(segments.count))
                detail(TXL.t("details.words", "Palabras"), TXFormat.integer(doc.text.split(whereSeparator: { $0.isWhitespace }).count))
                detail(TXL.t("details.favorites", "Favoritos"), TXFormat.integer(segments.filter(\.isFavorite).count))
                detail(TXL.t("details.wordTimestamps", "Timestamps por palabra"),
                       editor.hasWordTimestamps ? TXL.t("common.yes", "Sí") : TXL.t("common.no", "No"))
                if let url = doc.sourceURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.isFileURL ? TXL.t("details.audio", "Audio guardado") : TXL.t("details.link", "Enlace"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(TX.Colors.textSecondary)
                        Text(url.isFileURL ? TXFormat.displayPath(url.path) : url.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(TX.Colors.textPrimary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                            Button(TXL.t("common.showInFinder", "Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(TXBorderlessButtonStyle())
                        }
                    }
                }
            }
            .padding(TX.Space.s16)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(TX.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
