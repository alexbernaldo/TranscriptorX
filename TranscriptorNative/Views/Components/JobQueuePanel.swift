import SwiftUI

// MARK: - Job Queue Drawer (matches LibraryDrawerView format)

struct JobQueuePanel: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject var jobManager: JobManager
    @Binding var isPresented: Bool
    @Environment(\.responsiveMetrics) private var metrics
    var onSelectJob: (TranscriptionJob) -> Void
    
    // Init with default isPresented for backward compatibility
    init(jobManager: JobManager, isPresented: Binding<Bool> = .constant(true), onSelectJob: @escaping (TranscriptionJob) -> Void) {
        self.jobManager = jobManager
        self._isPresented = isPresented
        self.onSelectJob = onSelectJob
    }
    
    @State private var hoveredId: UUID?
    @State private var selectedSection: QueueSection = .active
    @State private var showClearConfirmation = false
    
    enum QueueSection: CaseIterable {
        case active
        case completed
    }
    
    private var filteredJobs: [TranscriptionJob] {
        switch selectedSection {
        case .active:
            return jobManager.jobs.filter { !$0.status.isFinished }
        case .completed:
            return jobManager.jobs.filter { $0.status.isFinished }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            drawerHeader
            
            Divider()
                .background(Color.borderSubtle)
            
            // Section picker
            sectionPicker
            
            // Content
            if filteredJobs.isEmpty {
                emptyState
            } else {
                jobList
            }
            
            // Footer
            if !jobManager.completedJobs.isEmpty || !jobManager.failedJobs.isEmpty {
                footer
            }
        }
        .frame(width: metrics.drawerWidth)
        .background(
            Color.bgSecondary
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: -10, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
    
    // MARK: - Header
    
    private var drawerHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.titleDefault)
                    .foregroundColor(.accentPrimary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cola de trabajos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    
                    Text(queueSummary)
                        .font(.caption)
                        .foregroundColor(.textMuted)
                }
            }
            
            Spacer()
            
            if jobManager.isProcessing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
            }
            
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.labelBody)
                    .foregroundColor(.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.bgHover)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar cola de trabajos")
        }
        .padding(16)
    }
    
    // MARK: - Section Picker
    
    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(QueueSection.allCases, id: \.self) { section in
                let isSelected = selectedSection == section
                let count = section == .active 
                    ? jobManager.jobs.filter { !$0.status.isFinished }.count
                    : jobManager.jobs.filter { $0.status.isFinished }.count
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(localizedSectionTitle(section))
                            .font(.labelBody)
                        
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(isSelected ? .white : .textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.accentPrimary : Color.borderSubtle)
                                )
                        }
                    }
                    .foregroundColor(isSelected ? .accentPrimary : .textMuted)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentPrimary.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.bgTertiary.opacity(0.5))
    }
    
    // MARK: - Job List
    
    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredJobs) { job in
                    jobRow(job)
                }
            }
            .padding(12)
        }
    }
    
    private func jobRow(_ job: TranscriptionJob) -> some View {
        Button {
            onSelectJob(job)
        } label: {
            HStack(spacing: 12) {
                // Status icon (40x40 matching history format)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(statusColor(job).opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    if job.status == .processing {
                        // Progress ring
                        ZStack {
                            Circle()
                                .stroke(Color.borderSubtle, lineWidth: 2.5)
                                .frame(width: 26, height: 26)
                            
                            Circle()
                                .trim(from: 0, to: CGFloat(job.progress) / 100)
                                .stroke(statusColor(job), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .frame(width: 26, height: 26)
                                .rotationEffect(.degrees(-90))
                            
                            Text("\(job.progress)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(statusColor(job))
                        }
                    } else {
                        Image(systemName: job.status.icon)
                            .font(.bodyDefault)
                            .foregroundColor(statusColor(job))
                    }
                }
                
                // File info
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.fileName)
                        .font(.labelDefault)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        if job.status == .processing {
                            Text(localizedProcessingMessage(job.statusMessage))
                                .lineLimit(1)
                        } else {
                            Text(localizedStatusName(job.status))
                        }
                        
                        if let _ = job.fileDuration {
                            Text("•")
                            Label(job.formattedDuration, systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.textMuted)
                }
                
                Spacer()
                
                // Action buttons
                actionButtons(for: job)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hoveredId == job.id ? Color.bgHover.opacity(0.8) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredId = isHovered ? job.id : nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: localizationManager.text("queue.job.accessibilityLabel", fallback: "%@, %@"),
            job.fileName,
            localizedStatusName(job.status)
        ))
        .accessibilityHint(job.status == .completed ? localizationManager.text("queue.job.completedHint", fallback: "Click to view transcript") : "")
    }
    
    @ViewBuilder
    private func actionButtons(for job: TranscriptionJob) -> some View {
        if job.canCancel && (hoveredId == job.id || job.status == .processing) {
            Button {
                jobManager.cancel(jobId: job.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textMuted)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.borderSubtle))
            }
            .buttonStyle(.plain)
            .help("Cancelar")
            .accessibilityLabel("Cancelar trabajo")
        } else if job.canRetry && hoveredId == job.id {
            Button {
                jobManager.retry(jobId: job.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentPrimary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentPrimary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help("Reintentar")
            .accessibilityLabel("Reintentar trabajo")
        } else if job.status == .completed {
            Image(systemName: "chevron.right")
                .font(.labelBody)
                .foregroundColor(.textMuted)
                .opacity(hoveredId == job.id ? 1 : 0.5)
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: selectedSection == .active ? "tray" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.textMuted)
            
            VStack(spacing: 4) {
                Text(
                    selectedSection == .active
                        ? localizationManager.text("queue.empty.active.title", fallback: "No active jobs")
                        : localizationManager.text("queue.empty.completed.title", fallback: "No completed jobs")
                )
                    .font(.titleMedium)
                    .foregroundColor(.textSecondary)
                
                Text(
                    selectedSection == .active
                        ? localizationManager.text("queue.empty.active.subtitle", fallback: "Drag files to transcribe")
                        : localizationManager.text("queue.empty.completed.subtitle", fallback: "Completed jobs will appear here")
                )
                    .font(.bodyMedium)
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.borderSubtle)
            
            Button {
                showClearConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.caption)
                    Text("Limpiar completados")
                        .font(.bodySmall)
                }
                .foregroundColor(.textMuted)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Limpiar trabajos completados")
            .accessibilityHint("Elimina todos los trabajos finalizados de la cola")
            .background(Color.bgTertiary.opacity(0.3))
            .alert("¿Limpiar completados?", isPresented: $showClearConfirmation) {
                Button("Limpiar", role: .destructive) {
                    jobManager.clearFinished()
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se eliminarán todos los trabajos finalizados de la cola.")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func statusColor(_ job: TranscriptionJob) -> Color {
        switch job.status {
        case .queued: return .textMuted
        case .processing: return .accentPrimary
        case .completed: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .failed: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .cancelled: return .textMuted
        }
    }

    private func localizedSectionTitle(_ section: QueueSection) -> String {
        switch section {
        case .active:
            return localizationManager.text("queue.section.active", fallback: "Active")
        case .completed:
            return localizationManager.text("queue.section.completed", fallback: "Completed")
        }
    }

    private func localizedStatusName(_ status: JobStatus) -> String {
        switch status {
        case .queued:
            return localizationManager.text("queue.status.queued", fallback: "Queued")
        case .processing:
            return localizationManager.text("queue.status.processing", fallback: "Processing")
        case .completed:
            return localizationManager.text("queue.status.completed", fallback: "Completed")
        case .failed:
            return localizationManager.text("queue.status.failed", fallback: "Error")
        case .cancelled:
            return localizationManager.text("queue.status.cancelled", fallback: "Cancelled")
        }
    }

    private var queueSummary: String {
        let stats = jobManager.stats
        if stats.processing > 0 {
            return String(
                format: localizationManager.text("queue.summary.processing", fallback: "Processing %d, %d queued"),
                stats.processing,
                stats.queued
            )
        }

        if stats.queued > 0 {
            return String(
                format: localizationManager.text("queue.summary.queuedOnly", fallback: "%d queued"),
                stats.queued
            )
        }

        if stats.completed > 0 {
            return String(
                format: localizationManager.text("queue.summary.completedOnly", fallback: "%d completed"),
                stats.completed
            )
        }

        return localizationManager.text("queue.summary.empty", fallback: "No jobs")
    }

    private func localizedProcessingMessage(_ rawMessage: String) -> String {
        guard !rawMessage.isEmpty else {
            return localizationManager.text("queue.status.processing", fallback: "Processing")
        }

        let lower = rawMessage.lowercased()
        if lower.contains("transcrib") || lower.contains("whisper") {
            return localizationManager.text("queue.status.processing", fallback: "Processing")
        }
        if lower.contains("iniciando") || lower.contains("starting") {
            return localizationManager.appLanguage == .es ? "Iniciando transcripción..." : "Starting transcription..."
        }
        if lower.contains("detectando idioma") || lower.contains("detecting language") {
            return localizationManager.appLanguage == .es ? "Detectando idioma..." : "Detecting language..."
        }
        if lower.contains("cancelad") || lower.contains("cancel") {
            return localizationManager.text("queue.status.cancelled", fallback: "Cancelled")
        }

        return rawMessage
    }
}

// MARK: - Preview

#if DEBUG
struct JobQueuePanel_Previews: PreviewProvider {
    static var previews: some View {
        JobQueuePanel(jobManager: JobManager.shared, isPresented: .constant(true)) { _ in }
            .frame(height: 500)
    }
}
#endif
