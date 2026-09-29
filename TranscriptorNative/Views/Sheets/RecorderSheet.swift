import SwiftUI

// MARK: - Recorder Sheet (Modern Design)
struct RecorderSheet: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.responsiveMetrics) private var metrics
    @StateObject private var recorder = SystemAudioRecorder()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(
                title: localizationManager.text("recorder.title", fallback: "Record audio"),
                subtitle: localizationManager.text("recorder.subtitle", fallback: "Capture system audio or microphone")
            ) {
                dismiss()
            }
            
            VStack(spacing: 28) {
                // Source Selector
                RecorderSourceSelector(selectedSource: $recorder.selectedSource)
                
                // Recording Area
                RecordingArea(recorder: recorder)
                
                // Control Button
                ControlButton(recorder: recorder) {
                    transcribeRecording($0)
                } onDiscard: {
                    discardRecording()
                }
                
                // Error message
                if let error = recorder.errorMessage {
                    ErrorBanner(message: error)
                }
            }
            .padding(28)
            
            Spacer()
        }
        .frame(width: metrics.recorderWidth, height: metrics.recorderWidth * 1.18)
        .background(VisualEffectView(material: .popover))
    }
    
    private func discardRecording() {
        if let url = recorder.recordedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder.recordedFileURL = nil
    }
    
    private func transcribeRecording(_ url: URL) {
        viewModel.loadFile(url: url)
        dismiss()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            viewModel.requestTranscription()
        }
    }
}

// MARK: - Source Selector (RecorderSheet)
private struct RecorderSourceSelector: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @Binding var selectedSource: SystemAudioRecorder.AudioSource
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FUENTE DE AUDIO")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.textMuted)
                .tracking(0.8)
            
            HStack(spacing: 12) {
                RecorderSourceCard(
                    title: localizationManager.text("recorder.source.system", fallback: "System"),
                    subtitle: localizationManager.text("recorder.source.system.subtitle", fallback: "Zoom, YouTube, etc."),
                    icon: "speaker.wave.3.fill",
                    isSelected: selectedSource == .system
                ) {
                    withAnimation(.snappy) {
                        selectedSource = .system
                    }
                }
                
                RecorderSourceCard(
                    title: localizationManager.text("recorder.source.mic", fallback: "Microphone"),
                    subtitle: localizationManager.text("recorder.source.mic.subtitle", fallback: "Dictation, meetings"),
                    icon: "mic.fill",
                    isSelected: selectedSource == .microphone
                ) {
                    withAnimation(.snappy) {
                        selectedSource = .microphone
                    }
                }
            }
        }
    }
}

// MARK: - Source Card
private struct RecorderSourceCard: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentSubtle : Color.bgHover)
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .accentPrimary : .textSecondary)
                }
                .accessibilityHidden(true)
                
                VStack(spacing: 3) {
                    Text(title)
                        .font(.labelLarge)
                        .foregroundColor(isSelected ? .textPrimary : .textSecondary)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.bgSelected : (isHovered ? Color.bgHover : Color.bgSecondary))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.accentPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: localizationManager.text("recorder.source.accessibilityLabel", fallback: "%@: %@"),
            title,
            subtitle
        ))
        .accessibilityHint(
            isSelected
                ? localizationManager.text("recorder.source.selectedHint", fallback: "Source selected")
                : localizationManager.text("recorder.source.selectHint", fallback: "Click to select this source")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(subtitle)
    }
}

// MARK: - Recording Area
private struct RecordingArea: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject var recorder: SystemAudioRecorder
    
    var body: some View {
        VStack(spacing: 20) {
            if recorder.isRecording {
                // Recording state
                LiveWaveform(level: recorder.audioLevel)
                
                // Time display
                HStack(spacing: 10) {
                    PulsingDot()
                    
                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .monospacedDigit()
                }
                
                Text(
                    String(
                        format: localizationManager.text("recorder.recording.inProgress", fallback: "Recording %@..."),
                        recorder.selectedSource == .system
                            ? localizationManager.text("recorder.source.systemAudio", fallback: "system audio")
                            : localizationManager.text("recorder.source.microphone", fallback: "microphone")
                    )
                )
                    .font(.bodySmall)
                    .foregroundColor(.textTertiary)
                
            } else if let _ = recorder.recordedFileURL {
                // Recording complete
                CompleteState(duration: recorder.recordingDuration)
                
            } else {
                // Ready state
                ReadyState()
            }
        }
        .frame(minHeight: 200)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Ready State
private struct ReadyState: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.bgSecondary)
                    .frame(width: 80, height: 80)
                
                Image(systemName: "waveform")
                    .font(.system(size: 32))
                    .foregroundColor(.textMuted)
            }
            .accessibilityHidden(true)
            
            Text(localizationManager.text("recorder.ready", fallback: "Ready to record"))
                .font(.bodyMedium)
                .foregroundColor(.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localizationManager.text("recorder.ready", fallback: "Ready to record"))
        .accessibilityHint(localizationManager.text("recorder.ready.hint", fallback: "Click record to start"))
    }
}

// MARK: - Complete State
private struct CompleteState: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let duration: TimeInterval
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.success.opacity(0.15))
                    .frame(width: 72, height: 72)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.success)
            }
            .accessibilityHidden(true)
            
            Text(localizationManager.text("recorder.completed", fallback: "Recording completed"))
                .font(.titleMedium)
                .foregroundColor(.textPrimary)
            
            Text(formatDuration(duration))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: localizationManager.text("recorder.completed.durationLabel", fallback: "Recording completed. Duration: %@"),
            formatAccessibleDuration(duration)
        ))
        .accessibilityHint(localizationManager.text("recorder.completed.hint", fallback: "You can transcribe or discard the recording"))
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
                return "\(minutes) minutos y \(seconds) segundos"
            }
            return "\(minutes) minutes and \(seconds) seconds"
        }
        return localizationManager.appLanguage == .es
            ? "\(seconds) segundos"
            : "\(seconds) seconds"
    }
}

// MARK: - Control Button
private struct ControlButton: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject var recorder: SystemAudioRecorder
    let onTranscribe: (URL) -> Void
    let onDiscard: () -> Void
    
    var body: some View {
        if recorder.isRecording {
            // Stop button
            Button(action: {
                Task { let _ = await recorder.stopRecording() }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(localizationManager.text("recorder.stop", fallback: "Stop"))
                        .font(.titleMedium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.error)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizationManager.text("recorder.stop.accessibilityLabel", fallback: "Stop recording"))
            .accessibilityHint(localizationManager.text("recorder.stop.hint", fallback: "Ends the current recording"))
            .help(localizationManager.text("recorder.stop.accessibilityLabel", fallback: "Stop recording"))
            
        } else if let url = recorder.recordedFileURL {
            // Transcribe/Discard buttons
            HStack(spacing: 12) {
                Button(localizationManager.text("recorder.discard", fallback: "Discard"), action: onDiscard)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(localizationManager.text("recorder.discard.accessibilityLabel", fallback: "Discard recording"))
                    .accessibilityHint(localizationManager.text("recorder.discard.hint", fallback: "Deletes the recording without transcribing"))
                
                Button(action: { onTranscribe(url) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.badge.checkmark")
                        Text(localizationManager.text("recorder.transcribe", fallback: "Transcribe"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel(localizationManager.text("recorder.transcribe.accessibilityLabel", fallback: "Transcribe recording"))
                .accessibilityHint(localizationManager.text("recorder.transcribe.hint", fallback: "Converts recording to text"))
            }
            
        } else {
            // Record button
            Button(action: {
                Task { await recorder.startRecording() }
            }) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(localizationManager.text("recorder.record", fallback: "Record"))
                        .font(.titleMedium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.error)
                )
            }
            .buttonStyle(.plain)
            .shadow(color: Color.error.opacity(0.3), radius: 8, y: 3)
            .accessibilityLabel(localizationManager.text("recorder.record.accessibilityLabel", fallback: "Start recording"))
            .accessibilityHint(localizationManager.text("recorder.record.hint", fallback: "Starts recording audio from the selected source"))
            .help(localizationManager.text("recorder.record.accessibilityLabel", fallback: "Start recording"))
        }
    }
}

// MARK: - Live Waveform
private struct LiveWaveform: View {
    let level: Float
    let barCount = 40
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.error.opacity(0.8))
                    .frame(width: 4, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 48)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let base = sin(Double(index) * 0.4) * 8 + 12
        let levelMultiplier = CGFloat(level) * 30
        return CGFloat(base) + levelMultiplier * CGFloat.random(in: 0.5...1)
    }
}

// MARK: - Pulsing Dot
private struct PulsingDot: View {
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(Color.error)
            .frame(width: 12, height: 12)
            .scaleEffect(isPulsing ? 1.2 : 1)
            .opacity(isPulsing ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Error Banner
private struct ErrorBanner: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.error)
                .accessibilityHidden(true)
            
            Text(message)
                .font(.bodySmall)
                .foregroundColor(.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.tagRed)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.error.opacity(0.3), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: localizationManager.text("common.errorPrefix", fallback: "Error: %@"),
                message
            )
        )
        .accessibilityAddTraits(.isStaticText)
    }
}
