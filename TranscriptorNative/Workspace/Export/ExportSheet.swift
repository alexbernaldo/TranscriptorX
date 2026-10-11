import SwiftUI
import AppKit

/// Exportar (spec 6.16, 6.17): formats on the left (220 pt), options of the chosen format on
/// the right (only the ones it supports), name and folder below. Batch mode exports one file
/// per transcription with progress, «Detener» and a result summary.
struct ExportSheet: View {
    let request: ExportRequest
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.lastFormat") private var lastFormat = ExportKind.srt.rawValue
    @State private var kind: ExportKind = .srt
    @State private var options = ExportKindOptions()
    @State private var name = ""
    @State private var folder = ExportFolders.defaultFolder
    @State private var error: String?
    @State private var batch: BatchState?
    @State private var batchTask: Task<Void, Never>?
    @FocusState private var formatsFocused: Bool

    struct BatchState {
        var done = 0
        var total = 0
        var failures: [(String, String)] = []
        var finished = false
        var stopped = false
    }

    private var documents: [Transcription] { request.documentIds.compactMap { LibraryStore.shared.document($0) } }
    private var single: Transcription? { request.isBatch ? nil : documents.first }

    var body: some View {
        VStack(spacing: 0) {
            Text(request.isBatch
                 ? TXL.n("export.title.batch", "Exportar %d transcripción", "Exportar %d transcripciones", documents.count)
                 : TXL.t("export.title", "Exportar"))
                .txStyle(TX.Typography.sectionTitle)
                .foregroundStyle(TX.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            TXSeparator()
            HStack(spacing: 0) {
                formatList
                    .frame(width: 220)
                TXSeparator(vertical: true)
                optionsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            TXSeparator()
            footer
                .padding(20)
        }
        .frame(width: 760, height: 560)
        .background(TX.Colors.bgElevated)
        .onAppear {
            kind = ExportKind(rawValue: lastFormat) ?? .srt
            options = ExportKindOptions.load(kind)
            name = single?.title ?? ""
            formatsFocused = true
        }
        .txOnChange(of: kind) { k in
            lastFormat = k.rawValue
            options = ExportKindOptions.load(k)
            error = nil
        }
        .txOnChange(of: options) { $0.save(kind) }
    }

    // MARK: Formats

    private var formatList: some View {
        List(selection: Binding(get: { kind }, set: { if let k = $0 { kind = k } })) {
            ForEach(ExportKind.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(group.kinds) { k in
                        HStack(spacing: 6) {
                            Text(k.name).font(.system(size: 13))
                            Text(k.extensionLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TX.Colors.textSecondary)
                        }
                        .tag(k)
                        .accessibilityLabel("\(k.name), \(k.extensionLabel)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($formatsFocused)
        .disabled(batch != nil && !(batch?.finished ?? true))
        .accessibilityLabel(TXL.t("export.formats.a11y", "Formatos"))
    }

    // MARK: Options (only those the format supports)

    @ViewBuilder private var optionsPanel: some View {
        if let batch {
            batchProgress(batch)
                .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let available = ExportKindOptions.available(for: kind)
                    if kind == .project {
                        Text(TXL.t("export.project.text", "Guarda la transcripción con su audio para abrirla en otro Mac con Transcriptor X. Para usar el texto en otras apps, elige otro formato."))
                            .font(.system(size: 13))
                            .foregroundStyle(TX.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if available.contains(.style) {
                        labeledPicker(TXL.t("export.opt.style", "Estilo"), selection: $options.style, values: ExportStyle.allCases) { styleName($0) }
                    }
                    if available.contains(.grouping) {
                        labeledPicker(TXL.t("export.opt.grouping", "Agrupar"), selection: $options.grouping, values: ExportGroupingPreference.allCases) { groupingName($0) }
                    }
                    if available.contains(.speakerNames) {
                        Toggle(TXL.t("export.opt.speakerNames", "Mostrar nombre del hablante"), isOn: $options.showSpeakerNames)
                    }
                    if available.contains(.favoritesOnly) {
                        Toggle(TXL.t("export.opt.favoritesOnly", "Solo favoritos"), isOn: $options.favoritesOnly)
                    }
                    if available.contains(.timestamps) {
                        Toggle(TXL.t("export.opt.timestamps", "Incluir timestamps"), isOn: $options.includeTimestamps)
                        if options.includeTimestamps {
                            VStack(alignment: .leading, spacing: 8) {
                                if available.contains(.milliseconds) {
                                    Toggle(TXL.t("export.opt.milliseconds", "Milisegundos"), isOn: $options.useMilliseconds)
                                }
                                if available.contains(.endTimestamp) {
                                    Toggle(TXL.t("export.opt.endTime", "Incluir el fin de cada segmento"), isOn: $options.showEndTimestamp)
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }
                    if available.contains(.fps) {
                        labeledPicker(TXL.t("export.opt.fps", "Fotogramas por segundo"), selection: $options.fps, values: [25, 30]) { "\($0)" }
                    }
                    if showsUnnamedSpeakersNote {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "info.circle").foregroundStyle(TX.Colors.info).accessibilityHidden(true)
                            Text(TXL.t("export.unnamedSpeakers", "Se exportará Hablante 1, Hablante 2… Ponles nombre en el inspector."))
                                .font(.system(size: 12))
                                .foregroundStyle(TX.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "xmark.octagon").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
                                Text(error).font(.system(size: 13)).foregroundStyle(TX.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button(TXL.t("export.chooseOther", "Elegir otra carpeta…")) {
                                if let url = ExportFolders.choose() { folder = url; self.error = nil }
                            }
                            .buttonStyle(TXBorderlessButtonStyle())
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .padding(20)
            }
        }
    }

    private var showsUnnamedSpeakersNote: Bool {
        guard ExportKindOptions.available(for: kind).contains(.speakerNames) || [.docx, .html, .json, .csv, .pdf].contains(kind) else { return false }
        if ExportKindOptions.available(for: kind).contains(.speakerNames), !options.showSpeakerNames { return false }
        return documents.contains { t in
            let speakers = Set((t.segments ?? []).compactMap(\.speaker))
            return speakers.contains { (t.speakerNames?["\($0)"] ?? "").isEmpty }
        }
    }

    private func labeledPicker<V: Hashable>(_ label: String, selection: Binding<V>, values: [V], title: @escaping (V) -> String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func styleName(_ s: ExportStyle) -> String {
        switch s {
        case .segments: return TXL.t("export.style.segments", "Por segmentos")
        case .fullTranscript: return TXL.t("export.style.full", "Texto continuo")
        case .subtitles: return TXL.t("export.style.subtitles", "Bloques de subtítulo")
        case .whisper: return TXL.t("export.style.whisper", "JSON de whisper")
        }
    }

    private func groupingName(_ g: ExportGroupingPreference) -> String {
        switch g {
        case .none: return TXL.t("export.grouping.none", "Sin agrupar")
        case .people: return TXL.t("export.grouping.people", "Por hablante")
        case .sentences: return TXL.t("export.grouping.sentences", "Por frases")
        case .words: return TXL.t("export.grouping.words", "Por palabras")
        }
    }

    // MARK: Batch progress

    private func batchProgress(_ b: BatchState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !b.finished {
                Text(TXL.f("export.batch.progress", "Exportando %d de %d", b.done, b.total))
                    .font(.system(size: 13).monospacedDigit())
                TXProgressLine(kind: .determinate(b.total > 0 ? Double(b.done) / Double(b.total) : 0))
            } else if b.failures.isEmpty {
                Text(TXL.n("export.batch.done", "%d archivo exportado", "%d archivos exportados", b.done))
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(TXL.f("export.batch.partial", "%d exportados, %d con errores", b.done - b.failures.count, b.failures.count))
                    .font(.system(size: 13, weight: .medium))
                DisclosureGroup(TXL.t("export.batch.failures", "Archivos con errores")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(b.failures.enumerated()), id: \.offset) { _, f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.0).font(.system(size: 12, weight: .medium))
                                    Text(f.1).font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            if b.stopped {
                Text(TXL.t("export.batch.stopped", "Exportación detenida. Lo ya exportado se conserva."))
                    .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if request.isBatch {
                    Text(TXL.t("export.batch.names", "Cada archivo usa el título de su transcripción"))
                        .font(.system(size: 13)).foregroundStyle(TX.Colors.textSecondary)
                } else {
                    Text(TXL.t("export.name", "Nombre")).font(.system(size: 13))
                    TextField("", text: $name).txField().frame(maxWidth: 260)
                        .accessibilityLabel(TXL.t("export.name", "Nombre"))
                }
                Spacer()
                Text(TXL.t("export.folder", "Carpeta")).font(.system(size: 13))
                Menu(ExportFolders.displayName(folder)) {
                    ForEach(([ExportFolders.downloads] + ExportFolders.recents).uniqued(), id: \.self) { url in
                        Button(ExportFolders.displayName(url)) { folder = url }
                    }
                    Divider()
                    Button(TXL.t("export.folder.other", "Otra…")) { if let url = ExportFolders.choose() { folder = url } }
                }
                .fixedSize()
                .accessibilityLabel(TXL.f("export.folder.a11y", "Carpeta, %@", ExportFolders.displayName(folder)))
            }
            HStack {
                Text(TXL.t("export.remembered", "Las opciones se recuerdan para cada formato"))
                    .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                Spacer()
                if let batch, !batch.finished {
                    Button(TXL.t("export.stop", "Detener")) { batchTask?.cancel() }
                        .buttonStyle(TXSecondaryButtonStyle())
                } else if let batch, batch.finished {
                    Button(TXL.t("common.showInFinder", "Mostrar en Finder")) { NSWorkspace.shared.open(folder) }
                        .buttonStyle(TXSecondaryButtonStyle())
                    Button(TXL.t("common.done", "Hecho")) { dismiss() }
                        .buttonStyle(TXPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(TXL.t("common.cancel", "Cancelar")) { dismiss() }
                        .buttonStyle(TXSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(TXL.t("export.button", "Exportar")) { export() }
                        .buttonStyle(TXPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(documents.isEmpty || (!request.isBatch && name.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    // MARK: Export

    private func export() {
        error = nil
        let kind = self.kind, options = self.options, folder = self.folder
        if let t = single {
            let baseName = name.trimmingCharacters(in: .whitespaces)
            Task {
                do {
                    let url = try await ExportEngine.write(t, kind: kind, options: options, folder: folder, baseName: baseName)
                    ExportFolders.remember(folder)
                    dismiss()
                    workspace.showToast(ToastItem(icon: .success,
                        text: TXL.f("export.done", "Exportado en %@", ExportFolders.displayName(folder)),
                        actionTitle: TXL.t("common.showInFinder", "Mostrar en Finder"),
                        action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }
        // Batch: never includes Recently Deleted (documents come from the active history).
        let docs = documents
        batch = BatchState(total: docs.count)
        batchTask = Task {
            for t in docs {
                if Task.isCancelled { batch?.stopped = true; break }
                do {
                    _ = try await ExportEngine.write(t, kind: kind, options: options, folder: folder, baseName: t.title)
                } catch {
                    batch?.failures.append((t.title, error.localizedDescription))
                }
                batch?.done += 1
            }
            ExportFolders.remember(folder)
            batch?.finished = true
            AccessibilityAnnouncer.announce(TXL.n("export.batch.done", "%d archivo exportado", "%d archivos exportados", batch?.done ?? 0))
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
