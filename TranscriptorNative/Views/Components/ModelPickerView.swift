import SwiftUI

/// Selector de modelos para Quick settings, popover de grabación y ajustes (sección 6.1).
/// Menú agrupado en Automático / Recomendados / Avanzados (y Experimentales).
struct ModelPickerView: View {
    let task: ModelTask
    var currentLanguage: String? = nil
    var translate: Bool = false
    /// «Gestionar modelos…» no se ofrece dentro de Ajustes › Modelos.
    var showsManage: Bool = true
    @Binding var assignment: ModelAssignment

    @ObservedObject private var prefs = TaskModelPreferences.shared
    @ObservedObject private var storage = ModelStorageService.shared
    @ObservedObject private var downloads = ModelDownloadCenter.shared

    private var resolverContext: ModelResolverContext {
        ModelResolverContext(
            installed: storage.installedModelIds(),
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            showExperimental: prefs.showExperimental,
            language: currentLanguage,
            translateToEnglish: translate
        )
    }

    private var resolvedTarget: ModelDescriptor? {
        ModelResolver.resolve(
            task: task,
            assignment: .automatic,
            filesAssignment: prefs.filesAssignment,
            in: resolverContext
        ).model ?? ModelResolver.automaticTarget(task: task, in: resolverContext)
    }

    private var buttonLabelText: String {
        switch assignment {
        case .automatic:
            let targetName = resolvedTarget.map { ModelCatalog.formattedName(for: $0.id, showTechnical: prefs.showTechnicalNames) } ?? "—"
            return TXL.f("models.auto.label", "Automático · %@", targetName)
        case .model(let id):
            return ModelCatalog.formattedName(for: id, showTechnical: prefs.showTechnicalNames)
        }
    }

    var body: some View {
        Menu {
            // 1. Automático
            let autoResolvedName = resolvedTarget.map { ModelCatalog.formattedName(for: $0.id, showTechnical: prefs.showTechnicalNames) } ?? "—"
            Button {
                assignment = .automatic
            } label: {
                let autoTitle = TXL.f("models.auto.menuItem", "Automático · ahora: %@", autoResolvedName)
                if assignment == .automatic {
                    Label(autoTitle, systemImage: "checkmark")
                } else {
                    Text(autoTitle)
                }
            }

            Divider()

            // 2. Recomendados
            let recommended = eligibleModels(group: .recommended)
            if !recommended.isEmpty {
                Section(TXL.t("models.group.recommended", "Recomendados")) {
                    ForEach(recommended) { modelRow($0) }
                }
            }

            // 3. Avanzados
            let advanced = eligibleModels(group: .advanced)
            if !advanced.isEmpty {
                Section(TXL.t("models.group.advanced", "Avanzados")) {
                    ForEach(advanced) { modelRow($0) }
                }
            }

            // 4. Experimentales (si están activados)
            if prefs.showExperimental {
                let experimental = eligibleModels(group: .experimental)
                if !experimental.isEmpty {
                    Section(TXL.t("models.group.experimental", "Experimentales")) {
                        ForEach(experimental) { modelRow($0) }
                    }
                }
            }

            if showsManage {
                Divider()
                Button(TXL.t("models.manage", "Gestionar modelos…")) {
                    SettingsNavigator.open(.models)
                }
            }
        } label: {
            Text(buttonLabelText)
        }
        .fixedSize()
        .help(TXL.t("models.help", "Modelo de transcripción"))
        .accessibilityLabel(TXL.f("models.a11y", "Modelo: %@", buttonLabelText))
    }

    private func eligibleModels(group: ModelGroup) -> [ModelDescriptor] {
        ModelCatalog.eligible(for: task, showExperimental: prefs.showExperimental)
            .filter { $0.group == group }
    }

    @ViewBuilder
    private func modelRow(_ m: ModelDescriptor) -> some View {
        let isSelected = assignment == .model(m.id)
        let incomp = ModelResolver.incompatibility(of: m, task: task, in: resolverContext)
        let isDownloaded = storage.isDownloaded(m.id)
        let sizeText = storage.displaySize(for: m.id)
        let stateText = isDownloaded ? TXL.t("models.state.downloaded", "Descargado") : TXL.f("models.state.download", "Descargar · %@", sizeText)
        let name = ModelCatalog.formattedName(for: m.id, showTechnical: prefs.showTechnicalNames)

        let badge = m.capabilityBadgeKey.flatMap { k in m.capabilityBadgeDefault.map { TXL.t(k, $0) } }
        let tech = prefs.showTechnicalNames ? "" : m.id

        if let reason = incomp {
            // Desactivado, con el motivo en el propio texto (no depende del color).
            Button {} label: {
                Text("\(name) · \(reason.reason)")
            }
            .disabled(true)
            .help(tech.isEmpty ? m.subtitle : "\(m.subtitle) (\(tech))")
            .accessibilityLabel("\(name), \(m.engine.badge). \(reason.reason)")
        } else {
            Button {
                assignment = .model(m.id)
            } label: {
                let fullTitle = ([name, m.engine.badge, badge, stateText].compactMap { $0 }).joined(separator: " · ")
                if isSelected {
                    Label(fullTitle, systemImage: "checkmark")
                } else {
                    Text(fullTitle)
                }
            }
            .help(tech.isEmpty ? m.subtitle : "\(m.subtitle) (\(tech))")
            .accessibilityLabel("\(name), \(m.engine.badge). \(m.subtitle). \(stateText)\(isSelected ? ", " + TXL.t("a11y.selected", "seleccionado") : "")")
        }
    }
}

/// «Modelo en uso» compacto: nombre (o nombre e ID con «Mostrar nombres técnicos») y motor.
/// El ID técnico va siempre en el tooltip.
struct ModelInUseChip: View {
    let modelId: String
    var prefix: String? = nil
    @ObservedObject private var prefs = TaskModelPreferences.shared

    var body: some View {
        let d = ModelCatalog.descriptor(id: modelId)
        let name = ModelCatalog.formattedName(for: modelId, showTechnical: prefs.showTechnicalNames)
        let engine = d?.engine.badge
        let text = [name, engine].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 10)).accessibilityHidden(true)
            Text(prefix.map { "\($0) \(text)" } ?? text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TX.Colors.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: TX.Radius.tag, style: .continuous).fill(TX.Colors.bgControl))
        .help(modelId)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TXL.f("models.inUse.a11y", "Modelo en uso: %@", text))
    }
}
