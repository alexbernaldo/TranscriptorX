import SwiftUI

/// Selector de modelos para Quick settings, popover de grabación y ajustes (sección 6.1).
/// Menú agrupado en Automático / Recomendados / Avanzados (y Experimentales).
struct ModelPickerView: View {
    let task: ModelTask
    var currentLanguage: String? = nil
    var translate: Bool = false
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

            Divider()
            Button(TXL.t("models.manage", "Gestionar modelos…")) {
                SettingsNavigator.open(.models)
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

        if let reason = incomp {
            // Desactivado con motivo secundario
            Button {} label: {
                Text("\(name) · \(reason.reason)")
            }
            .disabled(true)
        } else {
            Button {
                assignment = .model(m.id)
            } label: {
                let fullTitle = "\(name) · \(m.engine.badge) · \(stateText)"
                if isSelected {
                    Label(fullTitle, systemImage: "checkmark")
                } else {
                    Text(fullTitle)
                }
            }
        }
    }
}
