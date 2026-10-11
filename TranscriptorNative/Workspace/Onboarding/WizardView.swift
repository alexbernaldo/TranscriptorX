import SwiftUI
import AppKit

@MainActor
final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()

    enum Step: Int, CaseIterable {
        case welcome, tools, model, ready
        var title: String {
            switch self {
            case .welcome: return TXL.t("wizard.step.welcome", "Bienvenida")
            case .tools: return TXL.t("wizard.step.tools", "Herramientas")
            case .model: return TXL.t("wizard.step.model", "Modelo")
            case .ready: return TXL.t("wizard.step.ready", "Listo")
            }
        }
    }

    @Published var isShowingWizard: Bool
    @Published var step: Step = .welcome

    private init() {
        let completed = UserDefaults.standard.bool(forKey: "onboarding.completed")
        // People who already have transcriptions never see the wizard.
        let hasHistory = UserDefaults.standard.bool(forKey: "onboarding.hasHistory")
        isShowingWizard = !completed && !hasHistory
    }

    /// Called once the history is known: existing users skip the wizard.
    func historyLoaded(count: Int) {
        guard isShowingWizard, count > 0 else { return }
        complete()
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        isShowingWizard = false
        WorkspaceState.shared.columnVisibility = .all
    }
}

/// First launch (spec 6.1) inside the main window at its initial size, sidebar hidden,
/// centred 640 pt column, four-step indicator, buttons bottom right. Asks for no permission.
struct WizardView: View {
    @ObservedObject private var state = OnboardingState.shared
    @ObservedObject private var tools = ToolsCheck.shared
    @ObservedObject private var downloads = ModelDownloadCenter.shared
    @State private var selectedModel = "base"
    @State private var showTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            indicator
                .padding(.top, TX.Space.s32)
            Spacer(minLength: TX.Space.s24)
            Group {
                switch state.step {
                case .welcome: welcome
                case .tools: ToolsList(showsInstall: true)
                case .model: modelStep
                case .ready: ready
                }
            }
            .frame(width: 640, alignment: .leading)
            Spacer(minLength: TX.Space.s24)
            buttons
                .frame(width: 640)
                .padding(.bottom, TX.Space.s32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            tools.check()
            if let downloaded = ModelCapabilities.catalogue.first(where: { downloads.isDownloaded($0.id) }) {
                selectedModel = downloaded.id
            }
        }
        .onKeyDown(active: true) { event in
            if event.keyCode == 33, event.txModifiers == .command { back(); return true }   // ⌘[
            if event.keyCode == 15, event.txModifiers == .command, state.step == .tools { tools.check(); return true } // ⌘R
            return false
        }
    }

    // MARK: Indicator (dot + name, current in purple.400)

    private var indicator: some View {
        HStack(spacing: 20) {
            ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(step == state.step ? TX.Colors.accentText : (step.rawValue < state.step.rawValue ? TX.Colors.textSecondary : TX.Colors.border))
                        .frame(width: 6, height: 6)
                    Text(step.title)
                        .font(.system(size: 12, weight: step == state.step ? .semibold : .regular))
                        .foregroundStyle(step == state.step ? TX.Colors.accentText : TX.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(step == state.step ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.f("wizard.step.a11y", "Paso %d de 4", state.step.rawValue + 1))
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeSymbol()
            VStack(alignment: .leading, spacing: 12) {
                Text(TXL.t("wizard.welcome.title", "Transcribe audio y vídeo en este Mac"))
                    .txStyle(TX.Typography.display)
                    .foregroundStyle(TX.Colors.textPrimary)
                Text(TXL.t("wizard.welcome.text", "Todo el procesamiento ocurre en tu Mac. No hay cuentas, telemetría ni analíticas. La app solo se conecta a internet cuando descargas un enlace o un modelo, y una vez por semana para buscar actualizaciones."))
                    .txStyle(TX.Typography.ui)
                    .foregroundStyle(TX.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(showTitle ? 1 : 0)
        }
        .onAppear {
            // The title appears between 900 and 1200 ms (spec 9.4).
            if reduceMotion { showTitle = true } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeOut(duration: 0.3)) { showTitle = true }
                }
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TXL.t("wizard.model.title", "Elige un modelo"))
                .txStyle(TX.Typography.sectionTitle)
            ModelTable(defaultModel: $selectedModel, compact: true)
                .frame(height: 280)
            if case .downloading(let received, let total) = downloads.state(for: selectedModel) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(total > 0 ? TXL.f("wizard.model.progress", "%@ de %@", TXFormat.bytes(received), TXFormat.bytes(total)) : TXL.t("wizard.model.starting", "Iniciando la descarga…"))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(TX.Colors.textSecondary)
                    TXProgressLine(kind: total > 0 ? .determinate(Double(received) / Double(total)) : .indeterminate)
                }
            } else if case .failed(let message) = downloads.state(for: selectedModel) {
                Text(TXL.f("model.downloadFailed.title", "No se pudo descargar %@", selectedModel) + " · " + message)
                    .font(.system(size: 12)).foregroundStyle(TX.Colors.error)
            }
        }
        .txOnChange(of: downloads.revision) { _ in
            if downloads.isDownloaded(selectedModel), state.step == .model { advance() }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(TXL.t("wizard.ready.title", "Todo listo"))
                .txStyle(TX.Typography.display)
            VStack(alignment: .leading, spacing: 12) {
                line("tray.and.arrow.down", TXL.t("wizard.ready.drag", "Arrastra audio o vídeo a la ventana"))
                line("keyboard", TXL.t("wizard.ready.dictation", "Activa el dictado en Ajustes y pulsa ⌃⌥Espacio en cualquier app para dictar"))
                line("menubar.rectangle", TXL.t("wizard.ready.menubar", "Transcriptor X sigue disponible en la barra de menús"))
            }
        }
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(TX.Colors.textSecondary).frame(width: 24).accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(TX.Colors.textPrimary)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 12) {
            if state.step == .tools {
                Button(TXL.t("tools.recheck", "Comprobar de nuevo")) { tools.check() }
                    .buttonStyle(TXBorderlessButtonStyle())
                    .help(TXL.t("tools.recheck.help", "Comprobar de nuevo ⌘R"))
            }
            if state.step == .model {
                Button(TXL.t("wizard.model.later", "Elegir más tarde")) { advance() }
                    .buttonStyle(TXBorderlessButtonStyle())
            }
            Spacer()
            if state.step != .welcome {
                Button(TXL.t("common.back", "Atrás")) { back() }
                    .buttonStyle(TXSecondaryButtonStyle(size: .large))
                    .help(TXL.t("common.back.help", "Atrás ⌘["))
            }
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch state.step {
        case .welcome:
            Button(TXL.t("wizard.start", "Empezar")) { advance() }
                .buttonStyle(TXPrimaryButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
        case .tools:
            if tools.onlyLinksMissing {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(TXL.t("tools.continueWithoutLinks", "Continuar sin enlaces")) { advance() }
                        .buttonStyle(TXPrimaryButtonStyle(size: .large))
                        .keyboardShortcut(.defaultAction)
                    Text(TXL.t("tools.continueWithoutLinks.note", "Podrás transcribir archivos. Los enlaces necesitarán yt-dlp."))
                        .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                }
            } else {
                Button(TXL.t("common.continue", "Continuar")) { advance() }
                    .buttonStyle(TXPrimaryButtonStyle(size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(tools.blockingMissing || tools.isChecking)
            }
        case .model:
            if downloads.isDownloaded(selectedModel) {
                Button(TXL.t("common.continue", "Continuar")) { advance() }
                    .buttonStyle(TXPrimaryButtonStyle(size: .large))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(TXL.t("wizard.model.download", "Descargar y continuar")) {
                    setDefaultModel(selectedModel)
                    downloads.download(selectedModel)
                }
                .buttonStyle(TXPrimaryButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
                .disabled(isDownloading(selectedModel))
            }
        case .ready:
            Button(TXL.t("wizard.finish", "Empezar a transcribir")) { state.complete() }
                .buttonStyle(TXPrimaryButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func isDownloading(_ id: String) -> Bool {
        switch downloads.state(for: id) {
        case .downloading, .pending: return true
        default: return false
        }
    }

    private func setDefaultModel(_ id: String) {
        var settings = QuickSettingsModel.defaultSettings()
        settings.selectedModelId = id
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "transcription_settings") }
    }

    private func advance() {
        if state.step == .model, downloads.isDownloaded(selectedModel) { setDefaultModel(selectedModel) }
        if let next = OnboardingState.Step(rawValue: state.step.rawValue + 1) { state.step = next }
    }

    private func back() {
        if let previous = OnboardingState.Step(rawValue: state.step.rawValue - 1) { state.step = previous }
    }
}

// MARK: - Tools list (wizard step 2 and Diagnóstico)

struct ToolsList: View {
    var showsInstall: Bool
    @ObservedObject private var tools = ToolsCheck.shared
    @StateObject private var installer = DependencyManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ToolsCheck.Tool.allCases) { tool in
                row(tool)
                if tool != ToolsCheck.Tool.allCases.last { TXSeparator() }
            }
            if installer.isInstalling {
                VStack(alignment: .leading, spacing: 6) {
                    Text(installer.currentInstallStep).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                    TXProgressLine(kind: .determinate(installer.installProgress))
                }
                .padding(.top, 12)
            }
        }
    }

    private func row(_ tool: ToolsCheck.Tool) -> some View {
        HStack(spacing: 12) {
            statusIcon(tool).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.system(size: 13, weight: .medium)).foregroundStyle(TX.Colors.textPrimary)
                Text(tool.purpose).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            }
            Spacer()
            switch tools.status(tool) {
            case .found(let version):
                Text(version ?? TXL.t("tools.found", "Encontrado"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .lineLimit(1)
            case .missing:
                Text(TXL.t("tools.notFound", "No encontrado")).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                CopyCommandButton(command: tool.installCommand)
                if tool == .homebrew {
                    Link(TXL.t("tools.brew.instructions", "Ver instrucciones en brew.sh"), destination: URL(string: "https://brew.sh")!)
                        .font(.system(size: 12))
                }
                if showsInstall, tool.canInstallInApp {
                    Button(TXL.t("tools.install", "Instalar")) {
                        Task { await installer.installMissing(); tools.check() }
                    }
                    .buttonStyle(TXBorderlessButtonStyle())
                    .disabled(installer.isInstalling)
                    .help(TXL.t("tools.install.help", "Instala las herramientas que faltan desde la app"))
                }
            case .checking:
                EmptyView()
            case .failed(let details):
                Text(TXL.t("tools.error", "Error al comprobar")).font(.system(size: 12)).foregroundStyle(TX.Colors.error)
                    .help(details)
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func statusIcon(_ tool: ToolsCheck.Tool) -> some View {
        switch tools.status(tool) {
        case .checking: ProgressView().controlSize(.small)
        case .found: Image(systemName: "checkmark.circle.fill").foregroundStyle(TX.Colors.success).accessibilityLabel(TXL.t("tools.found", "Encontrado"))
        case .missing: Image(systemName: "circle").foregroundStyle(TX.Colors.warning).accessibilityLabel(TXL.t("tools.notFound", "No encontrado"))
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(TX.Colors.error).accessibilityLabel(TXL.t("tools.error", "Error al comprobar"))
        }
    }
}

// MARK: - Diagnóstico (spec 6.27): 560 pt sheet, nothing is sent

struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tools = ToolsCheck.shared
    @ObservedObject private var jobs = JobManager.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TXL.t("diagnostics.title", "Diagnóstico"))
                .txStyle(TX.Typography.sectionTitle)
            ToolsList(showsInstall: true)
            TXSeparator()
            VStack(alignment: .leading, spacing: 6) {
                info(TXL.t("diagnostics.cli", "Herramienta tx"), CLIInstall.isInstalled ? TXFormat.displayPath(CLIInstall.path) : TXL.t("cli.notInstalled", "No instalada"))
                info(TXL.t("diagnostics.model", "Modelo en memoria"), jobs.modelInUse ?? TXL.t("diagnostics.noModel", "Ninguno"))
                info("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
            }
            HStack {
                Button(TXL.t("tools.recheck", "Comprobar de nuevo")) { tools.check() }
                    .buttonStyle(TXBorderlessButtonStyle())
                    .keyboardShortcut("r")
                Spacer()
                Button(copied ? TXL.t("common.copied", "Copiado") : TXL.t("diagnostics.copy", "Copiar informe")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tools.report(), forType: .string)
                    copied = true
                }
                .buttonStyle(TXSecondaryButtonStyle())
                Button(TXL.t("common.done", "Hecho")) { dismiss() }
                    .buttonStyle(TXPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { tools.check() }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(TX.Colors.textPrimary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Accessibility permission (spec 8.5): explained in the window, macOS shows its own dialog

struct AccessibilityPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TXL.t("ax.title", "Permiso para pegar"))
                .txStyle(TX.Typography.sectionTitle)
            Text(TXL.t("ax.text", "Para pegar lo que dictas en otras apps, macOS necesita que actives Transcriptor X en Accesibilidad."))
                .font(.system(size: 13))
                .foregroundStyle(TX.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(TXL.t("common.cancel", "Cancelar")) { dismiss() }
                    .buttonStyle(TXSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(TXL.t("permission.openSettings", "Abrir Ajustes del Sistema")) {
                    DictationManager.shared.promptAccessibilityIfNeeded()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .buttonStyle(TXPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
