import SwiftUI
import AppKit

/// One segment (spec 7.4, 7.5): 88 pt timestamp gutter with favourite star, speaker label on
/// turn changes, text column. Selection is a block background, playback a 2 pt bar, the active
/// word a word background, search matches amber: the four signals coexist without hiding each other.
struct SegmentRow: View {
    @ObservedObject var editor: DocumentEditor
    let segment: TranscriptionSegment
    let index: Int
    let showsSpeaker: Bool
    let isFirst: Bool
    let stackedTimestamp: Bool
    let style: TX.TextStyle
    let listFocused: Bool
    @Binding var timesPopoverFor: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var caret: Int?

    private var isSelected: Bool { editor.selection.contains(segment.id) && !isEditing }
    private var isEditing: Bool { editor.editingId == segment.id }
    private var isPlaying: Bool { editor.playingSegmentId == segment.id }
    private var duration: TimeInterval { editor.documentDuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsSpeaker || stackedTimestamp {
                HStack(spacing: 8) {
                    if !stackedTimestamp { Color.clear.frame(width: TX.Size.timestampGutter) }
                    if let speaker = segment.speaker, showsSpeaker {
                        SpeakerLabel(editor: editor, speaker: speaker)
                    }
                    if stackedTimestamp { timestampButton }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                if !stackedTimestamp { gutter }
                textColumn
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { SegmentMenu(editor: editor, segment: segment, timesPopoverFor: $timesPopoverFor) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: TXL.t("segment.a11y.playFrom", "Reproducir desde aquí")) {
            PlaybackController.shared.seek(to: segment.startTime)
            PlaybackController.shared.play()
        }
        .accessibilityAction(named: TXL.t("segment.edit", "Editar")) { editor.beginEditing(segment.id) }
        .accessibilityAction(named: TXL.t("segment.mergeNext", "Unir con el siguiente")) { editor.mergeWithNext(segment.id) }
        .accessibilityAction(named: TXL.t("segment.favorite", "Favorito")) { editor.toggleFavorite([segment.id]) }
        .accessibilityAction(named: TXL.t("segment.adjustTimes", "Ajustar tiempos…")) { timesPopoverFor = segment.id }
    }

    // MARK: Gutter (88 pt): timestamp, star, save error

    /// The star sits under the timestamp without adding height: it overlays the 12 pt gap,
    /// keeping a 28 × 28 pt hit area (spec 10.6).
    private var gutter: some View {
        timestampButton
            .frame(width: TX.Size.timestampGutter, alignment: .leading)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2) {
                    starButton
                    if editor.failedSaves.contains(segment.id) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TX.Colors.error)
                        .help(TXL.t("segment.saveFailed", "No se pudo guardar este cambio"))
                        .accessibilityLabel(TXL.t("segment.saveFailed", "No se pudo guardar este cambio"))
                    }
                }
                .offset(x: -8, y: style.lineHeight - 8)
            }
            .padding(.top, isEditing ? 8 : 0)
    }

    private var timestampButton: some View {
        Button { editor.clickedTimestamp(segment.id) } label: {
            Text((editor.estimatedStarts.contains(segment.id) ? "≈" : "") + TXFormat.timestamp(segment.startTime, documentDuration: duration))
                .txStyle(TX.Typography.timestamp)
                .foregroundStyle(timestampColor)
                .frame(minHeight: style.lineHeight, alignment: .center)
        }
        .buttonStyle(.plain)
        .help("\(TXFormat.precise(segment.startTime)) – \(TXFormat.precise(segment.endTime))")
        .popover(isPresented: Binding(get: { timesPopoverFor == segment.id }, set: { if !$0 { timesPopoverFor = nil } }),
                 arrowEdge: .trailing) {
            AdjustTimesPopover(editor: editor, segment: segment) { timesPopoverFor = nil }
        }
        .accessibilityLabel(TXL.f("segment.timestamp.a11y", "Ir a %@", TXFormat.spokenDuration(segment.startTime)))
    }

    private var timestampColor: Color {
        if editor.flashTimestamp == segment.id { return TX.Colors.accentText }
        if isPlaying { return TX.Colors.accentText }
        if isSelected { return TX.Colors.textSecondary }
        return TX.Colors.textTertiary
    }

    @ViewBuilder private var starButton: some View {
        if segment.isFavorite || hovering {
            Button { editor.toggleFavorite([segment.id]) } label: {
                Image(systemName: segment.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(segment.isFavorite ? TX.Colors.accentText : TX.Colors.textTertiary)
                    .frame(width: TX.Size.minHit, height: TX.Size.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(segment.isFavorite ? TXL.t("segment.unfavorite", "Quitar de favoritos ⌘D") : TXL.t("segment.favorite.help", "Marcar como favorito ⌘D"))
            .accessibilityLabel(segment.isFavorite ? TXL.t("segment.unfavorite.a11y", "Quitar de favoritos") : TXL.t("segment.favorite", "Favorito"))
        } else {
            Color.clear.frame(width: TX.Size.minHit, height: TX.Size.minHit)
        }
    }

    // MARK: Text column

    private var textColumn: some View {
        ZStack(alignment: .topTrailing) {
            SegmentTextView(
                text: segment.text,
                style: style,
                isEditing: isEditing,
                highlights: highlights,
                reduceMotion: reduceMotion,
                accessibilityLabel: accessibilityLabel,
                onClick: { word in
                    editor.clicked(segment: segment.id, wordIndex: word)
                },
                onDoubleClick: { char in
                    caret = char
                    editor.beginEditing(segment.id)
                },
                onCommit: { text in editor.commitEditing(segment.id, text: text) },
                onCommitNext: { text in editor.commitAndEditNext(segment.id, text: text) },
                onSplit: { text, offset in editor.splitEditing(segment.id, text: text, at: offset) },
                onMoveEdge: { text, delta in editor.commitAndMove(segment.id, text: text, delta: delta) },
                initialCaret: caret
            )
            .frame(maxWidth: TX.Size.readingColumn, alignment: .leading)
            .padding(.vertical, isEditing ? 8 : 0)
            .padding(.horizontal, isEditing ? 12 : 0)

            if hovering && !isEditing {
                Menu {
                    SegmentMenu(editor: editor, segment: segment, timesPopoverFor: $timesPopoverFor)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TX.Colors.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: TX.Size.minHit, height: TX.Size.minHit)
                .offset(x: 4, y: -4)
                .help(TXL.t("segment.menu", "Acciones del segmento"))
                .accessibilityLabel(TXL.t("segment.menu", "Acciones del segmento"))
            }
        }
        .background(background)
        .overlay(alignment: .leading) {
            if isPlaying {
                Rectangle().fill(TX.Colors.purpleX).frame(width: 2)
                    .offset(x: -8)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            // Segments are custom views: 2 pt purple ring at 2 pt distance when focused by keyboard (spec 10.1).
            if listFocused && isSelected && editor.selection.count == 1 {
                RoundedRectangle(cornerRadius: TX.Radius.row + 2, style: .continuous)
                    .strokeBorder(TX.Colors.purpleX, lineWidth: 2)
                    .padding(-10)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var background: some View {
        if isEditing {
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(TX.Colors.bgSurface)
                .overlay(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                    .strokeBorder(TX.Colors.purpleX.opacity(0.6), lineWidth: 1))
        } else if isSelected {
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(listFocused ? TX.Colors.selectionRow : TX.Colors.selectionRowInactive)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        } else if hovering {
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(TX.Colors.bgHover)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        }
    }

    private var highlights: SegmentTextView.Highlights {
        var h = SegmentTextView.Highlights()
        // The word highlight hides in the segment being edited (nothing moves under the caret).
        if isPlaying, !isEditing { h.activeWord = editor.activeWordIndex }
        let matches = editor.matches.filter { $0.segmentId == segment.id }
        h.matches = matches.map { NSRange($0.range, in: segment.text) }
        if let current = editor.currentMatch, current.segmentId == segment.id {
            h.currentMatch = NSRange(current.range, in: segment.text)
        }
        return h
    }

    /// «Marta, 1 minuto 12 segundos, favorito: texto del segmento»
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let s = segment.speaker { parts.append(editor.speakerName(s)) }
        parts.append(TXFormat.spokenDuration(segment.startTime))
        if segment.isFavorite { parts.append(TXL.t("segment.a11y.favorite", "favorito")) }
        return parts.joined(separator: ", ") + ": " + segment.text
    }
}

// MARK: - Speaker label (shape + small caps name in the speaker colour)

struct SpeakerLabel: View {
    @ObservedObject var editor: DocumentEditor
    let speaker: Int
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            SpeakerMark(index: speaker)
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit { editor.renameSpeaker(speaker, to: draft); renaming = false }
                    .onExitCommand { renaming = false }
                    .onAppear { focused = true }
            } else {
                Menu {
                    Button(TXL.f("speaker.rename", "Renombrar %@…", editor.speakerName(speaker))) {
                        draft = editor.speakerName(speaker); renaming = true
                    }
                    Menu(TXL.f("speaker.mergeInto", "Fusionar %@ con…", editor.speakerName(speaker))) {
                        ForEach(editor.speakers.filter { $0 != speaker }, id: \.self) { other in
                            Button(editor.speakerName(other)) { SpeakerActions.confirmMerge(editor: editor, from: speaker, into: other) }
                        }
                    }
                    Button(TXL.t("speaker.showInInspector", "Mostrar en el inspector")) {
                        editor.selectSpeaker(speaker)
                        WorkspaceState.shared.showInspector(tab: .speakers)
                    }
                } label: {
                    Text(speakerTitle)
                        .font(.system(size: 12, weight: editor.selectedSpeaker == speaker ? .bold : .semibold))
                        .tracking(0.4)
                        .foregroundStyle(TX.Speakers.color(speaker))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var speakerTitle: String {
        let name = editor.speakerName(speaker).uppercased()
        return TX.Speakers.needsNumber(speaker) ? "H\(speaker + 1) · \(name)" : name
    }
}

@MainActor
enum SpeakerActions {
    /// «¿Fusionar Hablante 3 con Marta? Sus 8 segmentos pasarán a Marta.»
    static func confirmMerge(editor: DocumentEditor, from: Int, into: Int) {
        let alert = NSAlert()
        alert.messageText = TXL.f("speaker.merge.title", "¿Fusionar %@ con %@?", editor.speakerName(from), editor.speakerName(into))
        alert.informativeText = TXL.f("speaker.merge.text", "Sus %d segmentos pasarán a %@.", editor.segmentCount(for: from), editor.speakerName(into))
        alert.addButton(withTitle: TXL.t("speaker.merge.confirm", "Fusionar"))
        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn { editor.mergeSpeaker(from, into: into) }
    }

    static func confirmRestore(editor: DocumentEditor) {
        let alert = NSAlert()
        alert.messageText = TXL.t("speaker.restore.title", "¿Restaurar las etiquetas originales?")
        alert.informativeText = TXL.t("speaker.restore.text", "Se perderán los nombres de este documento. Las fusiones se deshacen con ⌘Z mientras el documento siga abierto.")
        alert.addButton(withTitle: TXL.t("speaker.restore.confirm", "Restaurar"))
        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn { editor.restoreSpeakerLabels() }
    }

    /// Merge confirmation when the selected segments belong to different speakers (spec 7.10).
    static func mergeSegments(editor: DocumentEditor) {
        guard editor.canMergeSelection else { return }
        if editor.mergeNeedsConfirmation {
            let first = editor.visible.first { editor.selection.contains($0.id) }
            let name = first?.speaker.map { editor.speakerName($0) } ?? TXL.t("speaker.none", "sin hablante")
            let alert = NSAlert()
            alert.messageText = TXL.t("merge.mixed.title", "Los segmentos son de hablantes distintos.")
            alert.informativeText = TXL.f("merge.mixed.text", "El resultado será de %@.", name)
            alert.addButton(withTitle: TXL.t("merge.confirm", "Unir"))
            alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        editor.mergeSelection()
    }
}

// MARK: - Segment menu (button ··· and secondary click, spec 7.4)

struct SegmentMenu: View {
    @ObservedObject var editor: DocumentEditor
    let segment: TranscriptionSegment
    @Binding var timesPopoverFor: UUID?

    var body: some View {
        Button(TXL.t("segment.edit", "Editar")) { editor.beginEditing(segment.id) }
        Button(TXL.t("segment.split", "Dividir en el cursor")) {}
            .disabled(true)
            .help(TXL.t("segment.split.help", "Entra en Edición y pulsa ⌥Retorno donde quieras dividir"))
        Button(editor.selection.count > 1 && editor.selection.contains(segment.id)
               ? TXL.f("segment.mergeMany", "Unir %d segmentos", editor.selection.count)
               : TXL.t("segment.mergeNext", "Unir con el siguiente")) {
            if editor.selection.count > 1 && editor.selection.contains(segment.id) {
                SpeakerActions.mergeSegments(editor: editor)
            } else {
                editor.selection = [segment.id]
                if let i = editor.index(of: segment.id), i + 1 < editor.visible.count {
                    editor.selection.insert(editor.visible[i + 1].id)
                    SpeakerActions.mergeSegments(editor: editor)
                }
            }
        }
        .disabled(editor.selection.count > 1 && editor.selection.contains(segment.id) ? !editor.canMergeSelection : editor.index(of: segment.id) == editor.visible.count - 1)
        Button(TXL.t("segment.adjustTimes", "Ajustar tiempos…")) { timesPopoverFor = segment.id }
        Button(segment.isFavorite ? TXL.t("segment.unfavorite.a11y", "Quitar de favoritos") : TXL.t("segment.favorite", "Favorito")) {
            editor.toggleFavorite([segment.id])
        }
        if !editor.speakers.isEmpty {
            Menu(TXL.t("segment.speaker", "Hablante")) {
                ForEach(editor.speakers, id: \.self) { s in
                    Button(editor.speakerName(s)) { editor.setSpeaker(s, for: [segment.id]) }
                }
                Divider()
                if let s = segment.speaker {
                    Button(TXL.f("speaker.rename", "Renombrar %@…", editor.speakerName(s))) {
                        editor.selectSpeaker(s)
                        WorkspaceState.shared.showInspector(tab: .speakers)
                    }
                    Menu(TXL.t("speaker.mergeWith", "Fusionar con…")) {
                        ForEach(editor.speakers.filter { $0 != s }, id: \.self) { other in
                            Button(editor.speakerName(other)) { SpeakerActions.confirmMerge(editor: editor, from: s, into: other) }
                        }
                    }
                }
                Button(TXL.t("speaker.showInInspector", "Mostrar en el inspector")) {
                    editor.selectSpeaker(segment.speaker)
                    WorkspaceState.shared.showInspector(tab: .speakers)
                }
            }
        }
        if let original = segment.originalText, original != segment.text {
            Button(TXL.t("segment.restoreOriginal", "Restaurar texto original")) { editor.restoreOriginalText(segment.id) }
        }
        Divider()
        Button(TXL.t("segment.copyText", "Copiar texto")) { copy(segment.text) }
        Button(TXL.t("segment.copyWithTime", "Copiar con timestamp")) {
            copy("[\(TXFormat.timestamp(segment.startTime, documentDuration: editor.documentDuration))] \(segment.text)")
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Adjust timestamps (280 pt popover, spec 7.11)

struct AdjustTimesPopover: View {
    @ObservedObject var editor: DocumentEditor
    let segment: TranscriptionSegment
    let close: () -> Void
    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focusedField: String?

    var body: some View {
        let neighbours = editor.neighbours(of: segment.id)
        let validation = EditorOperations.validate(start: start, end: end, previous: neighbours.previous, next: neighbours.next)
        VStack(alignment: .leading, spacing: 12) {
            Text(TXL.t("times.title", "Ajustar tiempos"))
                .txStyle(TX.Typography.sectionTitle)
            timeField(TXL.t("times.start", "Inicio"), value: $start, text: $startText)
            timeField(TXL.t("times.end", "Fin"), value: $end, text: $endText)
            switch validation {
            case .ok:
                EmptyView()
            case .startNotBeforeEnd:
                validationText(TXL.t("times.error.order", "El inicio debe ser anterior al fin"))
            case .overlapsPrevious(let previousEnd):
                validationText(TXL.f("times.error.previous", "Se solapa con el segmento anterior, que termina en %@", TXFormat.precise(previousEnd)))
            case .overlapsNext(let nextStart):
                validationText(TXL.f("times.error.next", "Se solapa con el segmento siguiente, que empieza en %@", TXFormat.precise(nextStart)))
            }
            HStack {
                Spacer()
                Button(TXL.t("common.cancel", "Cancelar"), action: close)
                    .buttonStyle(TXSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(TXL.t("times.apply", "Aplicar")) {
                    editor.setTimes(segment.id, start: start, end: end)
                    close()
                }
                .buttonStyle(TXPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(validation != .ok)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            start = segment.startTime; end = segment.endTime
            startText = TXFormat.precise(start); endText = TXFormat.precise(end)
        }
    }

    private func validationText(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// SF Mono field «00:01:12,400» with stepper (↑/↓ ±0,1 s; ⇧ ±1 s) and «Usar posición actual».
    private func timeField(_ label: String, value: Binding<TimeInterval>, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            HStack(spacing: 6) {
                TextField("", text: text)
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .txField()
                    .focused($focusedField, equals: label)
                    .onSubmit { commit(text.wrappedValue, into: value, text: text) }
                    .onKeyDown(active: focusedField == label, allowTextInput: true) { event in
                        switch event.keyCode {
                        case KeyCode.up: step(value, text: text, by: 1); return true
                        case KeyCode.down: step(value, text: text, by: -1); return true
                        default: return false
                        }
                    }
                    .accessibilityLabel(label)
                Stepper("", onIncrement: { step(value, text: text, by: 1) }, onDecrement: { step(value, text: text, by: -1) })
                    .labelsHidden()
                    .accessibilityLabel(label)
            }
            Button(TXL.t("times.useCurrent", "Usar posición actual")) {
                value.wrappedValue = PlaybackController.shared.currentTime
                text.wrappedValue = TXFormat.precise(value.wrappedValue)
            }
            .buttonStyle(TXBorderlessButtonStyle())
        }
        .txOnChange(of: text.wrappedValue) { newValue in
            if let parsed = EditorOperations.parseTime(newValue) { value.wrappedValue = parsed }
        }
    }

    private func step(_ value: Binding<TimeInterval>, text: Binding<String>, by direction: Double) {
        let amount = NSEvent.modifierFlags.contains(.shift) ? 1.0 : 0.1
        value.wrappedValue = max(0, value.wrappedValue + direction * amount)
        text.wrappedValue = TXFormat.precise(value.wrappedValue)
    }

    private func commit(_ raw: String, into value: Binding<TimeInterval>, text: Binding<String>) {
        if let parsed = EditorOperations.parseTime(raw) { value.wrappedValue = parsed }
        text.wrappedValue = TXFormat.precise(value.wrappedValue)
    }
}
