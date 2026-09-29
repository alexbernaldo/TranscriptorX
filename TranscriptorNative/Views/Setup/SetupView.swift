import SwiftUI

/// Setup view shown when dependencies are missing
struct SetupView: View {
    @EnvironmentObject var dependencyManager: DependencyManager
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    
    var body: some View {
        ZStack {
            // Background
            Color.bgPrimary
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentPrimary.opacity(0.3), Color.cyan.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)
                        
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.gradientAccent)
                    }
                    
                    Text(localizationManager.text("setup.title", fallback: "Configuración inicial"))
                        .font(.transcriptTitle)
                        .foregroundColor(.textPrimary)
                    
                    Text(localizationManager.text("setup.subtitle", fallback: "TranscriptorX necesita instalar algunas dependencias\npara funcionar correctamente."))
                        .font(.bodyDefault)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                
                // Dependencies list
                VStack(spacing: 12) {
                    ForEach(dependencyManager.dependencies) { dep in
                        DependencyRow(dependency: dep)
                    }
                }
                .padding(20)
                .background(Color.bgSecondary)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.borderSubtle, lineWidth: 1)
                )
                
                // Progress section (when installing)
                if dependencyManager.isInstalling {
                    VStack(spacing: 12) {
                        Text(dependencyManager.currentInstallStep)
                            .font(.labelLarge)
                            .foregroundColor(.textPrimary)
                        
                        ProgressView(value: dependencyManager.installProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: Color.accentPrimary))
                        
                        // Logs
                        ScrollView {
                            ScrollViewReader { proxy in
                                VStack(alignment: .leading, spacing: 4) {
                                    let recentIndices = Array(dependencyManager.installLogs.indices.suffix(10))
                                    ForEach(recentIndices, id: \.self) { index in
                                        Text(dependencyManager.installLogs[index])
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.textMuted)
                                            .id(index)
                                    }
                                }
                                .onChange(of: dependencyManager.installLogs.count) { count in
                                    guard count > 0 else { return }
                                    withAnimation {
                                        proxy.scrollTo(count - 1, anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .frame(height: 80)
                        .padding(10)
                        .background(Color.bgElevated)
                        .cornerRadius(8)
                    }
                    .padding(20)
                    .background(Color.bgSecondary)
                    .cornerRadius(16)
                }
                
                // Button section
                VStack(spacing: 12) {
                    if dependencyManager.isReady {
                        // All ready - show continue button
                        Text("✅ \(localizationManager.text("setup.allInstalled", fallback: "Todas las dependencias están instaladas"))")
                            .font(.labelDefault)
                            .foregroundColor(.success)
                        
                        Button(action: {
                            // Dependencies are ready, this should trigger ContentView via isReady
                            // Force a UI refresh
                            Task {
                                await dependencyManager.checkAll()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(localizationManager.text("setup.continue", fallback: "Continuar"))
                            }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: metrics.setupButtonMaxWidth)
                            .padding(.vertical, 14)
                            .background(Color.success)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Not ready - show install button
                        Button(action: {
                            Task {
                                await dependencyManager.installMissing()
                            }
                        }) {
                            HStack(spacing: 8) {
                                if dependencyManager.isInstalling {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    Text(localizationManager.text("setup.installing", fallback: "Instalando..."))
                                } else if dependencyManager.isChecking {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    Text(localizationManager.text("setup.checking", fallback: "Verificando..."))
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text(localizationManager.text("setup.installDependencies", fallback: "Instalar dependencias"))
                                }
                            }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: metrics.setupButtonMaxWidth)
                            .padding(.vertical, 14)
                            .background(
                                Group {
                                    if dependencyManager.isInstalling || dependencyManager.isChecking {
                                        Color.gray.opacity(0.5)
                                    } else {
                                        Color.accentPrimary
                                    }
                                }
                            )
                            .cornerRadius(12)
                            .shadow(color: Color.accentPrimary.opacity(0.4), radius: 12, y: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(dependencyManager.isInstalling || dependencyManager.isChecking)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: metrics.setupMaxWidth)
        }
        .task {
            if !dependencyManager.isReady {
                await dependencyManager.checkAll()
            }
        }
    }
}

// MARK: - Dependency Row
struct DependencyRow: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let dependency: DependencyManager.Dependency
    
    var body: some View {
        HStack(spacing: 14) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                
                if dependency.isInstalling {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: statusColor))
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(statusColor)
                }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.name)
                    .font(.titleDefault)
                    .foregroundColor(.textPrimary)
                
                Text(localizedDependencyDescription)
                    .font(.bodySmall)
                    .foregroundColor(.textMuted)
            }
            
            Spacer()
            
            // Status badge
            Text(statusText)
                .font(.labelMedium)
                .foregroundColor(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15))
                .cornerRadius(12)
        }
    }
    
    private var statusColor: Color {
        if dependency.isInstalling { return .warning }
        return dependency.isInstalled ? .success : .textMuted
    }
    
    private var statusIcon: String {
        dependency.isInstalled ? "checkmark" : "circle"
    }
    
    private var statusText: String {
        if dependency.isInstalling { return localizationManager.text("setup.status.installing", fallback: "Instalando") }
        return dependency.isInstalled
            ? localizationManager.text("setup.status.installed", fallback: "Instalado")
            : localizationManager.text("setup.status.pending", fallback: "Pendiente")
    }

    private var localizedDependencyDescription: String {
        let isSpanish = localizationManager.appLanguage == .es
        switch dependency.id {
        case "homebrew":
            return isSpanish ? "Gestor de paquetes para macOS" : "Package manager for macOS"
        case "ffmpeg":
            return isSpanish ? "Procesamiento de audio/video" : "Audio/video processing"
        case "whisper-cpp":
            return isSpanish ? "Motor de transcripción nativo con CoreML" : "Native transcription engine with CoreML"
        default:
            return dependency.description
        }
    }
}

#if DEBUG
struct SetupView_Previews: PreviewProvider {
    static var previews: some View {
        SetupView()
            .environmentObject(DependencyManager())
            .environmentObject(LocalizationManager())
            .frame(width: 600, height: 700)
    }
}
#endif
