import SwiftUI

// MARK: - Recording Floating Panel (Modern Glassmorphism Design)
struct RecordingFloatingPanel: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Binding var isPresented: Bool
    @StateObject private var recorder = SystemAudioRecorder()
    @Environment(\.responsiveMetrics) private var metrics
    var body: some View {
        VStack(spacing: 20) {
            // Header - Simplified
            panelHeader
            
            // Source Selector - Modern capsule style
            ModernSourceSelector(selectedSource: $recorder.selectedSource)
            
            // Microphone selector (only when microphone source is selected)
            if recorder.selectedSource == .microphone && !recorder.availableMicrophones.isEmpty {
                MicrophoneSelector(
                    microphones: recorder.availableMicrophones,
                    selectedMicrophone: Binding(
                        get: { recorder.selectedMicrophone },
                        set: { recorder.selectedMicrophone = $0 }
                    ),
                    onRefresh: { recorder.refreshMicrophoneList() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Audio Visualizer - Larger and dynamic
            AudioVisualizerArea(recorder: recorder)
            
            // Action Button - Accent colored
            ModernActionButton(recorder: recorder) { url in
                transcribeRecording(url)
            } onDiscard: {
                discardRecording()
            }
            
            // Error message (if any)
            if let error = recorder.errorMessage {
                ErrorMessage(message: error)
            }
        }
        .padding(24)
        .frame(width: metrics.recordingPanelWidth)
        .animation(.snappy(duration: 0.2), value: recorder.selectedSource)
        .animation(.snappy(duration: 0.2), value: recorder.hasPermission)
        .background(
            // Glassmorphism background
            ZStack {
                // Base dark translucent layer
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.08).opacity(0.85))
                
                // Gradient overlay for depth
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentPrimary.opacity(0.05),
                                Color.accentSecondary.opacity(0.03),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizationManager.text("recordingPanel.accessibilityLabel", fallback: "Recording panel"))
        .onAppear {
            // Only refresh mic list on appear, permissions checked when recording starts
            if recorder.selectedSource == .microphone {
                recorder.refreshMicrophoneList()
            }
        }
        .environment(\.colorScheme, .dark) // Glassmorphism panel always dark
    }
    
    // MARK: - Header
    private var panelHeader: some View {
        HStack {
            Text(localizationManager.text("recorder.title", fallback: "Record audio"))
                .font(.titleLarge)
                .foregroundColor(.textPrimary)
            
            Spacer()
            
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
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
            .accessibilityLabel(localizationManager.text("common.closePanel", fallback: "Close panel"))
        }
    }
    
    private func discardRecording() {
        if let url = recorder.recordedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder.recordedFileURL = nil
    }
    
    private func transcribeRecording(_ url: URL) {
        // Verify file exists before proceeding
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("ERROR: Recording file does not exist at: \(url.path)")
            return
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        print("DEBUG: Transcribing recording at: \(url.path), size: \(fileSize) bytes")
        
        // Copy URL to ensure it survives panel dismissal
        let fileURL = url
        
        // Close this panel and open NewTranscriptionSheet with the recorded file
        isPresented = false
        
        // Post notification to open NewTranscriptionSheet with the recorded file
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
                name: .openNewTranscriptionWithFile,
                object: nil,
                userInfo: ["fileURL": fileURL]
            )
        }
    }
}

// MARK: - Modern Source Selector (Capsule Style)
private struct ModernSourceSelector: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @Binding var selectedSource: SystemAudioRecorder.AudioSource
    @State private var hoveredSource: SystemAudioRecorder.AudioSource?
    
    var body: some View {
        HStack(spacing: 12) {
            sourceButton(
                source: .system,
                title: localizationManager.text("recorder.source.system", fallback: "System"),
                icon: "display"
            )
            
            sourceButton(
                source: .microphone,
                title: localizationManager.text("recorder.source.mic", fallback: "Microphone"),
                icon: "mic.fill"
            )
        }
    }
    
    private func sourceButton(source: SystemAudioRecorder.AudioSource, title: String, icon: String) -> some View {
        let isSelected = selectedSource == source
        let isHovered = hoveredSource == source
        
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                selectedSource = source
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.labelLarge)
                
                Text(title)
                    .font(.labelLarge)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.white.opacity(isHovered ? 0.08 : 0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .foregroundColor(isSelected ? .white : (isHovered ? .textPrimary : .textSecondary))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredSource = hovering ? source : nil
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(
            isSelected
                ? localizationManager.text("common.selected", fallback: "Selected")
                : localizationManager.text("common.clickToSelect", fallback: "Click to select")
        )
    }
}

// MARK: - Audio Visualizer Area (Large & Dynamic)
private struct AudioVisualizerArea: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject var recorder: SystemAudioRecorder
    
    var body: some View {
        VStack(spacing: 12) {
            if recorder.isRecording {
                // Live waveform - dynamic bars based on actual audio data
                DynamicWaveformBars(
                    waveformData: recorder.waveformData,
                    audioLevel: recorder.audioLevel,
                    isRecording: true
                )
                
                // Time display with pulsing dot
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .modifier(PulsingModifier())
                    
                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .monospacedDigit()
                }
                .accessibilityLabel(
                    String(
                        format: localizationManager.text("recordingPanel.recording.accessibilityLabel", fallback: "Recording: %@"),
                        formatAccessibleDuration(recorder.recordingDuration)
                    )
                )
                
            } else if recorder.recordedFileURL != nil {
                // Recording complete
                ModernCompletedState(duration: recorder.recordingDuration)
                
            } else {
                // Ready state - show idle waveform
                DynamicWaveformBars(
                    waveformData: Array(repeating: Float(0), count: 30),
                    audioLevel: 0,
                    isRecording: false
                )
                
                Text(
                    recorder.selectedSource == .system
                        ? localizationManager.text("recordingPanel.idle.system", fallback: "Capture your Mac audio")
                        : localizationManager.text("recordingPanel.idle.microphone", fallback: "Use your microphone")
                )
                    .font(.bodySmall)
                    .foregroundColor(.textMuted)
            }
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func formatAccessibleDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            if localizationManager.appLanguage == .es {
                return "\(minutes) minutos \(seconds) segundos"
            }
            return "\(minutes) minutes \(seconds) seconds"
        }
        return localizationManager.appLanguage == .es
            ? "\(seconds) segundos"
            : "\(seconds) seconds"
    }
}

// MARK: - Dynamic Waveform Bars (Real-time Audio Visualization)
private struct DynamicWaveformBars: View {
    let waveformData: [Float]
    let audioLevel: Float
    let isRecording: Bool
    
    private let barCount = 30
    private let maxBarHeight: CGFloat = 50
    private let minBarHeight: CGFloat = 4
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                SingleBar(
                    height: barHeight(for: index),
                    isRecording: isRecording,
                    index: index
                )
            }
        }
        .frame(height: maxBarHeight)
        .accessibilityHidden(true)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        guard isRecording else {
            // Idle state: small static bars with gentle wave
            let wave = sin(Double(index) * 0.3) * 0.3 + 0.5
            return minBarHeight + CGFloat(wave) * 6
        }
        
        // Get actual waveform data for this bar
        let dataIndex = min(index, waveformData.count - 1)
        let value = dataIndex >= 0 && dataIndex < waveformData.count ? waveformData[dataIndex] : 0
        
        // Normalize and scale the value
        let normalizedValue = CGFloat(min(max(value, 0), 1))
        
        // Apply curve for more dramatic visualization
        let curvedValue = pow(normalizedValue, 0.7)
        
        // Calculate height with minimum
        let height = minBarHeight + curvedValue * (maxBarHeight - minBarHeight)
        
        return max(minBarHeight, min(maxBarHeight, height))
    }
}

// MARK: - Single Animated Bar
private struct SingleBar: View {
    let height: CGFloat
    let isRecording: Bool
    let index: Int
    
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barGradient)
            .frame(width: 6, height: height)
            .animation(
                .spring(response: 0.15, dampingFraction: 0.6, blendDuration: 0.05),
                value: height
            )
    }
    
    private var barGradient: LinearGradient {
        if isRecording {
            // Gradient from accent to secondary based on position
            return LinearGradient(
                colors: [
                    Color.accentPrimary.opacity(0.9),
                    Color.accentSecondary
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            // Muted gradient for idle state
            return LinearGradient(
                colors: [
                    Color.textMuted.opacity(0.2),
                    Color.textMuted.opacity(0.1)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }
}

// MARK: - Legacy Large Waveform (kept for compatibility)
private struct LargeWaveform: View {
    let level: Float
    let isRecording: Bool
    let barCount = 24
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: isRecording ?
                                [Color.accentPrimary, Color.accentSecondary] :
                                [Color.textMuted.opacity(0.3), Color.textMuted.opacity(0.2)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        
        // Base height with curve toward center
        let base: CGFloat = 8 + (1 - distance) * 12
        
        // Add randomness based on level
        let levelEffect = CGFloat(level) * 20 * (1 - distance * 0.6)
        
        // Add slight random variation for organic feel
        let randomOffset = sin(Double(index) * 0.7 + Double(level) * 10) * 3
        
        return max(6, min(40, base + levelEffect + CGFloat(randomOffset)))
    }
}

// MARK: - Modern Completed State
private struct ModernCompletedState: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let duration: TimeInterval
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.success)
                
                Text(localizationManager.text("recordingPanel.completed.ready", fallback: "Recording ready"))
                    .font(.labelDefault)
                    .foregroundColor(.textSecondary)
            }
            
            Text(formatDuration(duration))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundColor(.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: localizationManager.text("recordingPanel.completed.accessibilityLabel", fallback: "Recording completed: %@"),
                formatAccessibleDuration(duration)
            )
        )
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func formatAccessibleDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            if localizationManager.appLanguage == .es {
                return "\(minutes) minutos \(seconds) segundos"
            }
            return "\(minutes) minutes \(seconds) seconds"
        }
        return localizationManager.appLanguage == .es
            ? "\(seconds) segundos"
            : "\(seconds) seconds"
    }
}

// MARK: - Modern Action Button
private struct ModernActionButton: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject var recorder: SystemAudioRecorder
    let onTranscribe: (URL) -> Void
    let onDiscard: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        if recorder.isRecording {
            // Stop button
            Button {
                Task { let _ = await recorder.stopRecording() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                    
                    Text(localizationManager.text("recorder.stop", fallback: "Stop"))
                        .font(.titleDefault)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.red)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizationManager.text("recorder.stop.accessibilityLabel", fallback: "Stop recording"))
            
        } else if let url = recorder.recordedFileURL {
            // Transcribe / Discard buttons
            HStack(spacing: 10) {
                Button(action: onDiscard) {
                    Text(localizationManager.text("recorder.discard", fallback: "Discard"))
                        .font(.labelLarge)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                
                Button { onTranscribe(url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text(localizationManager.text("recorder.transcribe", fallback: "Transcribe"))
                            .font(.titleSmall)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentPrimary)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            
        } else {
            // Start recording button - Accent colored
            Button {
                Task { await recorder.startRecording() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    
                    Text(localizationManager.text("recorder.record.start", fallback: "Start recording"))
                        .font(.titleDefault)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentPrimary)
                )
                .foregroundColor(.white)
                .scaleEffect(isHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .accessibilityLabel(localizationManager.text("recorder.record.start", fallback: "Start recording"))
        }
    }
}

// MARK: - Error Message
private struct ErrorMessage: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.bodySmall)
                .foregroundColor(.warning)
            
            Text(message)
                .font(.bodySmall)
                .foregroundColor(.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.warning.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.warning.opacity(0.2), lineWidth: 1)
        )
        .accessibilityLabel(String(format: localizationManager.text("common.errorPrefix", fallback: "Error: %@"), message))
    }
}

// MARK: - Pulsing Modifier
private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Microphone Selector
private struct MicrophoneSelector: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let microphones: [SystemAudioRecorder.AudioDevice]
    @Binding var selectedMicrophone: SystemAudioRecorder.AudioDevice?
    let onRefresh: () -> Void
    
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizationManager.text("recordingPanel.inputDevice", fallback: "Input device"))
                    .font(.labelMedium)
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
                .help(localizationManager.text("recordingPanel.refreshMicrophones", fallback: "Refresh microphone list"))
            }
            
            Menu {
                ForEach(microphones) { mic in
                    Button {
                        selectedMicrophone = mic
                    } label: {
                        HStack {
                            if mic.isDefault {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(mic.name)
                            if mic.id == selectedMicrophone?.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.bodySmall)
                        .foregroundColor(.accentPrimary)
                    
                    Text(selectedMicrophone?.name ?? localizationManager.text("common.select", fallback: "Select..."))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.labelSmall)
                        .foregroundColor(.textMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }
}

// MARK: - Permission Warning View
private struct PermissionWarningView: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let source: SystemAudioRecorder.AudioSource
    let onRequestPermission: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.bodyXLarge)
                    .foregroundColor(.warning)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizationManager.text("recordingPanel.permissionRequired", fallback: "Permission required"))
                        .font(.titleSmall)
                        .foregroundColor(.textPrimary)
                    
                    Text(permissionMessage)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }
                
                Spacer()
            }
            
            Button(action: onRequestPermission) {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                        .font(.labelMedium)
                    Text(localizationManager.text("recordingPanel.openSettings", fallback: "Open settings"))
                        .font(.labelBody)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.warning.opacity(isHovered ? 0.25 : 0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.warning.opacity(0.3), lineWidth: 1)
                )
                .foregroundColor(.warning)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.warning.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var permissionMessage: String {
        switch source {
        case .microphone:
            return localizationManager.text("recordingPanel.permission.microphone", fallback: "Enable Microphone access in Privacy & Security.")
        case .system:
            return localizationManager.text("recordingPanel.permission.system", fallback: "Enable Screen Recording in Privacy & Security.")
        }
    }
}

// MARK: - Preview
#if DEBUG
struct RecordingFloatingPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            
            RecordingFloatingPanel(isPresented: .constant(true))
        }
        .frame(width: 500, height: 400)
    }
}
#endif
