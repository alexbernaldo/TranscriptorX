import SwiftUI
import AppKit

/// Ajustes › Modelos (rediseño completo según especificación 6.2).
/// Tres bloques: Modelo por tarea, Catálogo y Avanzado.
struct ModelsSettingsDetailView: View {
    @ObservedObject private var prefs = TaskModelPreferences.shared
    @ObservedObject private var storage = ModelStorageService.shared
    @ObservedObject private var jobs = JobManager.shared
    @ObservedObject private var defaults = DefaultsModel.shared

    @State private var advancedExpanded = false
    @State private var modelToDelete: ModelDescriptor?
    @State private var showingDeleteAlert = false
    @State private var integrityMessage: String?
    @State private var showingIntegrityAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 0. Banner de aviso único sobre nombres nuevos (6.5)
                if let renameNotice = prefs.renameNoticeText {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(TX.Colors.purpleX)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(renameNotice)
                                .font(.system(size: 12))
                                .foregroundStyle(TX.Colors.textPrimary)
                        }
                        Spacer()
                        Button(TXL.t("common.understood", "Entendido")) {
                            prefs.dismissRenameNotice()
                        }
                        .buttonStyle(TXSecondaryButtonStyle())
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: TX.Radius.row).fill(TX.Colors.purpleX.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: TX.Radius.row).strokeBorder(TX.Colors.purpleX.opacity(0.2), lineWidth: 1))
                }

                // BLOQUE 1: Modelo por tarea (cuatro filas con selector y sublínea)
                taskModelsBlock

                // BLOQUE 2: Catálogo completo agrupado
                catalogBlock

                // BLOQUE 3: Opciones avanzadas (plegable, cerrado por defecto)
                advancedBlock
            }
            .padding(.bottom, 24)
        }
        .alert(TXL.f("models.delete.confirm", "¿Eliminar %@?", modelToDelete?.displayName ?? ""),
               isPresented: $showingDeleteAlert) {
            Button(TXL.t("common.cancel", "Cancelar"), role: .cancel) {}
            Button(TXL.t("common.delete", "Eliminar"), role: .destructive) {
                if let id = modelToDelete?.id {
                    try? storage.deleteModel(id: id)
                }
            }
        } message: {
            Text(TXL.t("models.delete.message", "Los archivos del modelo se eliminarán del disco. Podrás volver a descargarlo en cualquier momento."))
        }
        .alert(TXL.t("models.integrity.title", "Comprobación de integridad"),
               isPresented: $showingIntegrityAlert) {
            Button(TXL.t("common.ok", "Aceptar"), role: .cancel) {}
        } message: {
            Text(integrityMessage ?? "")
        }
    }

    // MARK: - Bloque 1: Modelo por tarea

    private var taskModelsBlock: some View {
        SettingsGroup(title: TXL.t("models.tasks.title", "Modelo por tarea")) {
            taskRow(
                task: .files,
                title: TXL.t("models.task.files", "Archivos"),
                assignment: $prefs.filesAssignment
            )
            TXSeparator()
            taskRow(
                task: .recording,
                title: TXL.t("models.task.recording", "Grabación"),
                assignment: $prefs.recordingAssignment
            )
            TXSeparator()
            taskRow(
                task: .liveCaptions,
                title: TXL.t("models.task.liveCaptions", "Subtítulos en vivo"),
                assignment: $prefs.liveCaptionsAssignment
            )
            TXSeparator()
            taskRow(
                task: .dictation,
                title: TXL.t("models.task.dictation", "Dictado"),
                assignment: $prefs.dictationAssignment
            )
        }
    }

    private func taskRow(task: ModelTask, title: String, assignment: Binding<ModelAssignment>) -> some View {
        let resolution = prefs.resolve(task: task)
        let resolvedDesc = resolution.model
        let resolvedName = resolvedDesc.map { ModelCatalog.formattedName(for: $0.id, showTechnical: prefs.showTechnicalNames) } ?? "—"
        let engineBadge = resolvedDesc?.engine.badge ?? "Whisper"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TX.Colors.textPrimary)
                Spacer()
                ModelPickerView(
                    task: task,
                    assignment: assignment
                )
            }
            if assignment.wrappedValue == .automatic {
                Text(TXL.f("models.auto.resolved", "Ahora: %@ · %@", resolvedName, engineBadge))
                    .font(.system(size: 11))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bloque 2: Catálogo

    private var catalogBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TXL.t("models.catalog.title", "Catálogo de modelos"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TX.Colors.textPrimary)

            let visibleGroups: [ModelGroup] = prefs.showExperimental
                ? [.recommended, .advanced, .experimental]
                : [.recommended, .advanced]

            ForEach(visibleGroups, id: \.self) { group in
                catalogGroupSection(group)
            }
        }
    }

    @ViewBuilder
    private func catalogGroupSection(_ group: ModelGroup) -> some View {
        let groupTitle: String = {
            switch group {
            case .recommended: return TXL.t("models.group.recommended", "Recomendados")
            case .advanced: return TXL.t("models.group.advanced", "Avanzados")
            case .experimental: return TXL.t("models.group.experimental", "Experimentales")
            }
        }()

        let models = ModelCatalog.visible(showExperimental: prefs.showExperimental)
            .filter { $0.group == group }

        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(groupTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, m in
                        if index > 0 { TXSeparator() }
                        catalogModelRow(m)
                    }
                }
                .background(RoundedRectangle(cornerRadius: TX.Radius.row).fill(TX.Colors.bgSurface))
                .overlay(RoundedRectangle(cornerRadius: TX.Radius.row).strokeBorder(TX.Colors.separator, lineWidth: 1))
            }
        }
    }

    private func catalogModelRow(_ m: ModelDescriptor) -> some View {
        let isDownloaded = storage.isDownloaded(m.id)
        let inMemory = jobs.modelInUse == m.id
        let sizeText = storage.displaySize(for: m.id)
        let name = ModelCatalog.formattedName(for: m.id, showTechnical: prefs.showTechnicalNames)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TX.Colors.textPrimary)

                    // Insignia de motor (pequeña)
                    Text(m.engine.badge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(TX.Colors.bgHover))
                        .foregroundStyle(TX.Colors.textSecondary)

                    // Insignia de capacidad
                    if let capBadge = m.capabilityBadgeDefault {
                        Text(capBadge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TX.Colors.purpleX.opacity(0.12)))
                            .foregroundStyle(TX.Colors.purpleX)
                    }

                    if inMemory {
                        Text(TXL.t("models.inMemory", "En memoria"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(Color.green)
                    }
                }

                Text(m.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .lineLimit(1)

                // Escalas relativas y soporte de idiomas
                HStack(spacing: 16) {
                    RatingScaleView(label: TXL.t("models.scale.speed", "Velocidad"), score: m.scales.speed)
                    RatingScaleView(label: TXL.t("models.scale.accuracy", "Precisión"), score: m.scales.accuracy)

                    languagesLabel(for: m)
                }
                .padding(.top, 2)
            }

            Spacer()

            // Tamaño y acción
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(TX.Colors.textSecondary)

                modelActionView(m, isDownloaded: isDownloaded)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func languagesLabel(for m: ModelDescriptor) -> some View {
        switch m.languages {
        case .any:
            Text(TXL.t("models.lang.multilingual", "Multilingüe (99+ idiomas)"))
                .font(.system(size: 10))
                .foregroundStyle(TX.Colors.textTertiary)
        case .only(let langs):
            if langs == ["en"] {
                Text(TXL.t("models.lang.englishOnly", "Solo inglés"))
                    .font(.system(size: 10))
                    .foregroundStyle(TX.Colors.textTertiary)
            } else {
                Text(TXL.f("models.lang.count", "%d idiomas", langs.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TX.Colors.purpleX)
                    .help(langs.sorted().joined(separator: ", "))
            }
        }
    }

    @ViewBuilder
    private func modelActionView(_ m: ModelDescriptor, isDownloaded: Bool) -> some View {
        let downloadState = ModelDownloadCenter.shared.state(for: m.id)

        switch downloadState {
        case .downloading(let received, let total):
            HStack(spacing: 4) {
                let frac = total > 0 ? Double(received) / Double(total) : 0
                ProgressView(value: frac)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Button(TXL.t("common.cancel", "Cancelar")) {
                    ModelDownloadCenter.shared.cancel(m.id)
                }
                .buttonStyle(TXBorderlessButtonStyle())
                .controlSize(.small)
            }
        default:
            if isDownloaded {
                Menu {
                    Button(TXL.t("common.showInFinder", "Mostrar en Finder")) {
                        storage.revealInFinder(for: m.id)
                    }
                    Divider()
                    Button(role: .destructive) {
                        modelToDelete = m
                        showingDeleteAlert = true
                    } label: {
                        Text(TXL.t("common.delete", "Eliminar"))
                    }
                } label: {
                    Text(TXL.t("models.downloaded", "Descargado"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            } else {
                Button(TXL.t("common.download", "Descargar")) {
                    ModelDownloadCenter.shared.download(m.id)
                }
                .buttonStyle(TXSecondaryButtonStyle())
                .controlSize(.small)
            }
        }
    }

    // MARK: - Bloque 3: Avanzado

    private var advancedBlock: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsGroup {
                    SettingsRow(
                        label: TXL.t("models.adv.technicalNames", "Mostrar nombres técnicos en toda la app"),
                        help: TXL.t("models.adv.technicalNames.help", "Muestra el ID técnico junto al nombre visible en selectores y cabeceras.")
                    ) {
                        Toggle("", isOn: $prefs.showTechnicalNames).toggleStyle(.switch).labelsHidden()
                    }
                    TXSeparator()
                    SettingsRow(
                        label: TXL.t("models.adv.experimental", "Mostrar modelos experimentales"),
                        help: TXL.t("models.adv.experimental.help", "Habilita modelos como Mini (Parakeet Redux) y Cohere Transcribe.")
                    ) {
                        Toggle("", isOn: $prefs.showExperimental).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: "Whisper") {
                    SettingsRow(
                        label: TXL.t("models.whisper.neuralEngine", "Usar acelerador CoreML (Neural Engine) si existe"),
                        help: TXL.t("models.whisper.neuralEngine.help", "Usa el encoder compilado en Neural Engine si está disponible.")
                    ) {
                        Toggle("", isOn: $defaults.settings.useCoreML).toggleStyle(.switch).labelsHidden()
                    }
                    TXSeparator()
                    SettingsRow(
                        label: TXL.t("models.whisper.vad", "Detección de voz (Silero VAD)"),
                        help: TXL.t("models.whisper.vad.help", "Filtra silencios con Silero VAD antes de transcribir.")
                    ) {
                        Toggle("", isOn: $defaults.settings.useVAD).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: TXL.t("models.memory.title", "Memoria")) {
                    let inUse = jobs.modelInUse
                    let inUseDesc = inUse.flatMap { ModelCatalog.descriptor(id: $0) }
                    let inUseName = inUseDesc?.displayName ?? (inUse ?? TXL.t("models.memory.none", "Ningún modelo en memoria"))
                    let engine = inUseDesc?.engine.badge ?? "Whisper"
                    let compute = inUseDesc?.capabilities.computeUnits == .neuralEngine ? "Neural Engine" : "CPU"

                    SettingsRow(
                        label: inUse != nil ? "\(inUseName) · \(engine) (\(compute))" : TXL.t("models.memory.none", "Ningún modelo en memoria"),
                        help: TXL.t("models.memory.help", "whisper corre en subproceso por trabajo; los modelos FluidAudio se descargan automáticamente tras inactividad.")
                    ) {
                        if inUse != nil {
                            Button(TXL.t("models.memory.freeNow", "Liberar ahora")) {
                                Task {
                                    await ModelMemoryManager.shared.unloadAll()
                                }
                                if let activeId = JobManager.shared.jobs.first(where: { $0.status == .processing })?.id {
                                    _ = JobManager.shared.cancel(jobId: activeId)
                                }
                            }
                            .buttonStyle(TXSecondaryButtonStyle())
                            .controlSize(.small)
                        } else {
                            EmptyView()
                        }
                    }
                }

                SettingsGroup(title: TXL.t("models.storage.title", "Almacenamiento")) {
                    SettingsRow(
                        label: TXL.f("models.storage.total", "Espacio total usado: %@", storage.formattedTotalStorageUsed()),
                        help: TXL.t("models.storage.help", "Carpeta local con los archivos binarios y modelos compilados.")
                    ) {
                        HStack(spacing: 8) {
                            Button(TXL.t("common.showInFinder", "Mostrar en Finder")) {
                                storage.revealInFinder(for: "base")
                            }
                            .buttonStyle(TXSecondaryButtonStyle())
                            .controlSize(.small)

                            Button(TXL.t("models.storage.checkIntegrity", "Comprobar integridad")) {
                                checkAllIntegrity()
                            }
                            .buttonStyle(TXSecondaryButtonStyle())
                            .controlSize(.small)
                        }
                    }
                }

                SettingsGroup(title: TXL.t("models.licenses.title", "Licencias de los modelos")) {
                    VStack(alignment: .leading, spacing: 8) {
                        licenseRow("Whisper (tiny, base, small, medium, large)", license: "MIT", author: "OpenAI / ggerganov")
                        licenseRow("Parakeet TDT (v3, v2, Ultra, Redux)", license: "CC-BY-4.0", author: "NVIDIA / FluidInference / moondream")
                        licenseRow("Nemotron Streaming (multilingüe y EN)", license: "NVIDIA Open Model License", author: "NVIDIA / FluidInference")
                        licenseRow("Silero VAD", license: "MIT", author: "Silero Team")
                        licenseRow("pyannote audio (diarización)", license: "CC-BY-4.0", author: "pyannote / FluidAudio")
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(TXL.t("models.advanced.toggle", "Opciones avanzadas"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TX.Colors.textPrimary)
        }
    }

    private func licenseRow(_ name: String, license: String, author: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(TX.Colors.textPrimary)
            Spacer()
            Text("\(license) · \(author)").font(.system(size: 10)).foregroundStyle(TX.Colors.textSecondary)
        }
    }

    private func checkAllIntegrity() {
        let downloaded = storage.installedModelIds()
        var allOK = true
        for id in downloaded {
            if !storage.checkIntegrity(for: id) {
                allOK = false
            }
        }
        if downloaded.isEmpty {
            integrityMessage = TXL.t("models.integrity.none", "No hay modelos descargados en este Mac.")
        } else if allOK {
            integrityMessage = TXL.f("models.integrity.ok", "Todos los modelos (%d) están íntegros y listos para usar.", downloaded.count)
        } else {
            integrityMessage = TXL.t("models.integrity.corrupt", "Se han detectado archivos potencialmente incompletos o corruptos.")
        }
        showingIntegrityAlert = true
    }
}

/// Control de escala relativa 1…5 con VoiceOver explícito (sección 4 y 10).
struct RatingScaleView: View {
    let label: String
    let score: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(label + ":")
                .font(.system(size: 10))
                .foregroundStyle(TX.Colors.textTertiary)
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= score ? TX.Colors.textSecondary : TX.Colors.border)
                    .frame(width: 4, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TXL.f("models.a11y.scale", "%@: %d de 5", label, score))
    }
}
