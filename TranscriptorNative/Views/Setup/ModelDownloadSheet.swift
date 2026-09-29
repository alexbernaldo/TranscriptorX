import SwiftUI

/// Sheet shown when a model needs to be downloaded
struct ModelDownloadSheet: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    let modelId: String
    let modelName: String
    let onComplete: () -> Void
    let onCancel: () -> Void
    
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var error: String?
    
    private let service = TranscriptionService.shared
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentPrimary.opacity(0.2))
                        .frame(width: 72, height: 72)
                    
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.gradientAccent)
                }
                
                Text("Descargar modelo")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
            }
            
            // Model info
            VStack(spacing: 8) {
                HStack {
                    Text("Modelo:")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(modelName)
                        .fontWeight(.semibold)
                        .foregroundColor(.textPrimary)
                }
                
                HStack {
                    Text("Tamaño:")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(modelSize(for: modelId))
                        .fontWeight(.semibold)
                        .foregroundColor(.textPrimary)
                }
            }
            .font(.bodyDefault)
            .padding(16)
            .background(Color.bgTertiary)
            .cornerRadius(12)
            
            // Progress (if downloading)
            if isDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: Color.accentPrimary))
                    
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.labelLarge)
                        .foregroundColor(.textSecondary)
                }
            }
            
            // Error
            if let error = error {
                Text(error)
                    .font(.bodyMedium)
                    .foregroundColor(.error)
                    .padding(12)
                    .background(Color.error.opacity(0.1))
                    .cornerRadius(8)
            }
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancelar") {
                    onCancel()
                }
                .buttonStyle(SecondaryButtonStyle())
                
                Button {
                    startDownload()
                } label: {
                    if isDownloading {
                        Text(localizationManager.appLanguage == .es ? "Descargando..." : "Downloading...")
                    } else {
                        Text(localizationManager.appLanguage == .es ? "Descargar" : "Download")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isDownloading)
            }
        }
        .padding(28)
        .frame(width: metrics.modelDownloadWidth)
        .background(Color.bgSecondary)
    }
    
    private func modelSize(for modelId: String) -> String {
        if let size = TranscriptionService.availableModels.first(where: { $0.id == modelId })?.size {
            return size
        }
        return localizationManager.appLanguage == .es ? "Desconocido" : "Unknown"
    }
    
    private func startDownload() {
        isDownloading = true
        error = nil
        downloadProgress = 0
        
        Task {
            do {
                try await service.downloadModel(modelId) { progress in
                    // Progress updates are already dispatched to main thread by the service
                    // Use Task to avoid layout recursion
                    Task { @MainActor in
                        self.downloadProgress = progress
                    }
                }
                await MainActor.run {
                    onComplete()
                }
            } catch let downloadError {
                await MainActor.run {
                    self.error = downloadError.localizedDescription
                    self.isDownloading = false
                }
            }
        }
    }
}

// Note: Button styles (PrimaryButtonStyle, SecondaryButtonStyle) are defined in Theme.swift

#if DEBUG
struct ModelDownloadSheet_Previews: PreviewProvider {
    static var previews: some View {
        ModelDownloadSheet(
            modelId: "base",
            modelName: "Base (Rápido)",
            onComplete: {},
            onCancel: {}
        )
    }
}
#endif
