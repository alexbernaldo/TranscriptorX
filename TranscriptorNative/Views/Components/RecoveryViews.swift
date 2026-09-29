import SwiftUI

// MARK: - Recovery Manager View
/// Shows recovered recordings and transcriptions after a crash or interruption
struct RecoveryManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.responsiveMetrics) private var metrics
    @State private var recoveredItems: [RecoveryManager.RecoveredItem] = []
    @State private var isLoading = true
    @State private var selectedItem: RecoveryManager.RecoveredItem?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
                .background(Color.borderSubtle)
            
            // Content
            if isLoading {
                loadingView
            } else if recoveredItems.isEmpty {
                emptyView
            } else {
                itemsList
            }
        }
        .frame(width: metrics.recoveryWidth, height: metrics.recoveryHeight)
        .background(Color.bgPrimary)
        .task {
            await loadRecoveredItems()
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recuperación de sesión")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Archivos recuperados de sesiones anteriores")
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.borderSubtle))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
            .accessibilityHint("Cierra el panel de recuperación")
        }
        .padding(20)
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
                .tint(.accentPrimary)
            Text("Buscando archivos recuperables...")
                .font(.bodyDefault)
                .foregroundColor(.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty View
    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("¡Todo en orden!")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            
            Text("No hay sesiones interrumpidas que recuperar")
                .font(.bodyDefault)
                .foregroundColor(.textSecondary)
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Text("Cerrar")
                    .font(.labelDefault)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.accentPrimary)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Items List
    private var itemsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(recoveredItems) { item in
                    RecoveredItemRow(item: item) {
                        // Handle recovery
                        Task {
                            await recoverItem(item)
                        }
                    } onDelete: {
                        // Handle deletion (with confirmation)
                        itemPendingDeletion = item
                        showDeleteConfirmation = true
                    }
                }
            }
            .padding(16)
        }
        .alert("¿Eliminar archivo recuperado?", isPresented: $showDeleteConfirmation) {
            Button("Cancelar", role: .cancel) {
                itemPendingDeletion = nil
            }
            Button("Eliminar", role: .destructive) {
                if let item = itemPendingDeletion {
                    Task {
                        await deleteItem(item)
                        itemPendingDeletion = nil
                    }
                }
            }
        } message: {
            Text("Este archivo se eliminará de forma permanente.")
        }
    }
    
    @State private var showDeleteConfirmation = false
    @State private var itemPendingDeletion: RecoveryManager.RecoveredItem?
    
    // MARK: - Actions
    private func loadRecoveredItems() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            recoveredItems = try await RecoveryManager.shared.getRecoveredItems()
        } catch {
            AppLogger.shared.log("Failed to load recovered items: \(error)", level: .error, category: .recovery)
            recoveredItems = []
        }
    }
    
    private func recoverItem(_ item: RecoveryManager.RecoveredItem) async {
        AppLogger.shared.log("Recovering item: \(item.id)", level: .info, category: .recovery)
        
        switch item.type {
        case .audio:
            // Open the recovered audio file for transcription
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openNewTranscriptionWithFile,
                    object: nil,
                    userInfo: ["fileURL": item.fileURL]
                )
                dismiss()
            }
        case .transcription:
            // Copy partial transcription text to clipboard
            if let text = item.partialText ?? (try? String(contentsOf: item.fileURL, encoding: .utf8)) {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
    
    private func deleteItem(_ item: RecoveryManager.RecoveredItem) async {
        do {
            try await RecoveryManager.shared.deleteRecoveredItem(item.id)
            await loadRecoveredItems()
        } catch {
            AppLogger.shared.log("Failed to delete item: \(error)", level: .error, category: .recovery)
        }
    }
}

// MARK: - Recovered Item Row
struct RecoveredItemRow: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let item: RecoveryManager.RecoveredItem
    let onRecover: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: item.type == .audio ? "waveform.circle.fill" : "doc.text.fill")
                .font(.system(size: 24))
                .foregroundColor(item.type == .audio ? .orange : .accentPrimary)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    item.type == .audio
                        ? localizationManager.text("recovery.item.audio", fallback: "Recording")
                        : localizationManager.text("recovery.item.transcription", fallback: "Transcription")
                )
                    .font(.labelDefault)
                    .foregroundColor(.white)
                
                HStack(spacing: 8) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.bodySmall)
                        .foregroundColor(.textSecondary)
                    
                    if let duration = item.duration {
                        Text("·")
                            .foregroundColor(.textMuted)
                        Text(formatDuration(duration))
                            .font(.bodySmall)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            
            Spacer()
            
            // Actions (always reachable for keyboard/AT, visually emphasized on hover)
            HStack(spacing: 8) {
                Button(action: onRecover) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Recuperar")
                .accessibilityLabel("Recuperar")
                .accessibilityHint("Recupera este archivo")
                
                Button(action: onDelete) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Eliminar")
                .accessibilityLabel("Eliminar")
                .accessibilityHint("Elimina este archivo recuperado")
            }
            .opacity(isHovered ? 1 : 0.5)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.bgHover.opacity(0.8) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHovered ? 0.1 : 0.05), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Recovery Banner
/// A small banner that appears at the top when recovered items are found
struct RecoveryBanner: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let items: [RecoveryManager.RecoveredItem]
    let onDismiss: () -> Void
    let onViewItems: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.bodyXLarge)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Sesiones recuperables encontradas")
                    .font(.labelLarge)
                    .foregroundColor(.white)
                
                Text(String(
                    format: localizationManager.text("recovery.banner.recoverableCount", fallback: "%d file(s) can be recovered"),
                    items.count
                ))
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            Button(action: onViewItems) {
                Text("Ver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
            
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.15, green: 0.12, blue: 0.1).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 10)
        .padding(.horizontal, 40)
    }
}

// MARK: - Preview
#if DEBUG
struct RecoveryManagerView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryManagerView()
            .frame(width: 500, height: 400)
    }
}
#endif
