import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine
import CoreAudio

/// Records system audio using ScreenCaptureKit (macOS 13+)
/// No external drivers needed - captures any audio playing on the Mac
/// Integrates with RecoveryManager for crash-proof recordings
/// Supports microphone selection and optimized 16kHz mono output for Whisper
@MainActor
class SystemAudioRecorder: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0 // 0.0 to 1.0 for visualizer
    @Published var waveformData: [Float] = Array(repeating: 0, count: 50) // For waveform viz
    @Published var errorMessage: String?
    @Published var hasPermission: Bool = false
    @Published var recordedFileURL: URL?
    @Published var recordingState: RecordingState = .idle
    @Published var isNormalizing: Bool = false
    
    // MARK: - Available Microphones
    
    struct AudioDevice: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }
    
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice?
    
    // MARK: - Recovery State
    
    /// Current recovery session ID (nil if not recording)
    private var currentSessionId: UUID?
    /// Timer for periodic recovery manifest updates
    private var recoveryHeartbeatTimer: Timer?
    /// Last duration we sent to recovery manager (avoid duplicate writes)
    private var lastRecoveryDuration: TimeInterval = 0
    /// Interval between recovery heartbeats (seconds)
    private let recoveryHeartbeatInterval: TimeInterval = 5.0
    
    // MARK: - Audio Sources
    
    enum AudioSource: String, CaseIterable, Identifiable {
        case system = "system"
        case microphone = "microphone"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .system: return "Audio del Sistema"
            case .microphone: return "Micrófono"
            }
        }
        
        var icon: String {
            switch self {
            case .system: return "speaker.wave.3.fill"
            case .microphone: return "mic.fill"
            }
        }
        
        var description: String {
            switch self {
            case .system: return "Zoom, YouTube, Spotify, etc."
            case .microphone: return "Dictado, reuniones presenciales"
            }
        }
    }
    
    @Published var selectedSource: AudioSource = .microphone {
        didSet {
            // When source changes, just refresh microphone list if needed
            // Permissions are checked when user starts recording
            if selectedSource == .microphone {
                refreshMicrophoneList()
            }
        }
    }
    
    // MARK: - Private Properties
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var durationTimer: Timer?
    private var flushTimer: Timer?
    private var startTime: Date?
    
    /// Target sample rate for Whisper (16kHz is optimal)
    private let targetSampleRate: Double = 16000
    /// Target channels (mono for speech recognition)
    private let targetChannels: UInt32 = 1
    
    private var tempOutputURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(UUID().uuidString).wav")
    }

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        Task {
            await checkPermission()
            refreshMicrophoneList()
        }
    }
    
    // MARK: - Microphone Enumeration
    
    /// Refresh the list of available microphones
    func refreshMicrophoneList() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        
        guard status == noErr else {
            AppLogger.shared.log("Failed to get audio devices size: \(status)", level: .error, category: .recording)
            return
        }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        
        guard status == noErr else {
            AppLogger.shared.log("Failed to get audio devices: \(status)", level: .error, category: .recording)
            return
        }
        
        // Get default input device
        var defaultInputID: AudioDeviceID = 0
        var defaultPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultPropertyAddress,
            0,
            nil,
            &defaultSize,
            &defaultInputID
        )
        
        var microphones: [AudioDevice] = []
        
        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputPropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var inputSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputPropertyAddress, 0, nil, &inputSize)
            
            guard status == noErr, inputSize > 0 else { continue }
            
            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
            
            status = AudioObjectGetPropertyData(deviceID, &inputPropertyAddress, 0, nil, &inputSize, bufferListPointer)
            guard status == noErr else { continue }
            
            var inputChannels: UInt32 = 0
            
            // Use UnsafeMutableAudioBufferListPointer for safe iteration
            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            for buffer in ablPointer {
                inputChannels += buffer.mNumberChannels
            }
            
            guard inputChannels > 0 else { continue }
            
            // Get device name
            var namePropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            
            // Fix unsafe/dangling pointer warning using usage block
            status = withUnsafeMutablePointer(to: &name) { namePtr in
                AudioObjectGetPropertyData(deviceID, &namePropertyAddress, 0, nil, &nameSize, namePtr)
            }
            
            guard status == noErr else { continue }
            
            let deviceName = name as String
            let isDefault = deviceID == defaultInputID
            
            microphones.append(AudioDevice(id: deviceID, name: deviceName, isDefault: isDefault))
        }
        
        // Sort: default first, then alphabetically
        microphones.sort { 
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name < $1.name
        }
        
        availableMicrophones = microphones
        
        // Select default if none selected
        if selectedMicrophone == nil, let defaultMic = microphones.first(where: { $0.isDefault }) ?? microphones.first {
            selectedMicrophone = defaultMic
        }
        
        AppLogger.shared.log("Found \(microphones.count) microphones. Default: \(microphones.first(where: { $0.isDefault })?.name ?? "none")", level: .info, category: .recording)
    }
    
    // MARK: - Permissions
    
    @Published var hasMicrophonePermission: Bool = false
    @Published var hasScreenCapturePermission: Bool = false
    
    func checkPermission() async {
        // Only check permission for the selected source
        switch selectedSource {
        case .microphone:
            await checkMicrophonePermission()
        case .system:
            await checkScreenCapturePermission()
        }
        
        updatePermissionStatus()
    }
    
    private func updatePermissionStatus() {
        switch selectedSource {
        case .microphone:
            hasPermission = hasMicrophonePermission
        case .system:
            hasPermission = hasScreenCapturePermission
        }
    }
    
    /// Check microphone permission (for microphone recording)
    private func checkMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            // Request permission
            hasMicrophonePermission = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            hasMicrophonePermission = false
        @unknown default:
            hasMicrophonePermission = false
        }
        
        AppLogger.shared.log("Microphone permission: \(hasMicrophonePermission)", level: .info, category: .recording)
    }
    
    /// Check screen capture permission (for system audio)
    private func checkScreenCapturePermission() async {
        do {
            // This will trigger the permission dialog if not granted
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            hasScreenCapturePermission = true
        } catch {
            hasScreenCapturePermission = false
            AppLogger.shared.log("ScreenCaptureKit permission check failed: \(error)", level: .warning, category: .recording)
        }
    }
    
    func requestPermission() async {
        switch selectedSource {
        case .microphone:
            await requestMicrophonePermission()
        case .system:
            await requestScreenCapturePermission()
        }
    }
    
    private func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        hasMicrophonePermission = granted
        
        if !granted {
            // Open System Preferences to microphone settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
        
        updatePermissionStatus()
    }
    
    private func requestScreenCapturePermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            hasScreenCapturePermission = true
        } catch {
            hasScreenCapturePermission = false
            // Open System Preferences to screen recording settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        
        updatePermissionStatus()
    }
    
    // MARK: - Recording Control
    
    func startRecording() async {
        guard !isRecording else { return }
        
        errorMessage = nil
        recordedFileURL = nil
        recordingState = .preparingAudio
        
        // Check and request permission based on source
        await checkPermission()
        
        if !hasPermission {
            // Request permission and show error
            await requestPermission()
            
            if !hasPermission {
                switch selectedSource {
                case .microphone:
                    errorMessage = localized(
                        "Se requiere permiso de micrófono. Actívalo en Configuración del Sistema → Privacidad y Seguridad → Micrófono.",
                        "Microphone permission is required. Enable it in System Settings → Privacy & Security → Microphone."
                    )
                case .system:
                    errorMessage = localized(
                        "Se requiere permiso de Grabación de Pantalla. Actívalo en Configuración del Sistema → Privacidad y Seguridad → Grabación de Pantalla.",
                        "Screen Recording permission is required. Enable it in System Settings → Privacy & Security → Screen Recording."
                    )
                }
                recordingState = .failed(error: .permissionDenied)
                AppLogger.shared.log("Permission denied for \(selectedSource.rawValue)", level: .warning, category: .recording)
                return
            }
        }
        
        AppLogger.shared.log("Starting recording with source: \(selectedSource.rawValue)", category: .recording)
        
        do {
            // Start recovery session first (write-ahead logging)
            recordingState = .initializingCapture
            let (sessionId, audioURL) = try await RecoveryManager.shared.beginRecordingSession(
                source: selectedSource.rawValue
            )
            currentSessionId = sessionId
            AppLogger.shared.log("Recovery session started: \(sessionId)", category: .recording)
            
            switch selectedSource {
            case .system:
                try await startSystemAudioCapture(outputURL: audioURL)
            case .microphone:
                try await startMicrophoneCapture(outputURL: audioURL)
            }
            
            isRecording = true
            isPaused = false
            startTime = Date()
            recordingState = .recording(duration: 0)
            startDurationTimer()
            startRecoveryHeartbeat()
            
            AppLogger.shared.log("Recording started successfully", category: .recording)
            
        } catch let error as RecordingError {
            recordingState = .failed(error: error)
            errorMessage = localized(
                "Error al iniciar grabación: \(error.localizedDescription)",
                "Error starting recording: \(error.localizedDescription)"
            )
            AppLogger.shared.logError(error, context: "Recording start failed", category: .recording)
            
            // Cancel recovery session if we started one
            if let sessionId = currentSessionId {
                try? await RecoveryManager.shared.cancelRecordingSession(sessionId: sessionId)
                currentSessionId = nil
            }
        } catch {
            let recordingError = RecordingError.writerError(error.localizedDescription)
            recordingState = .failed(error: recordingError)
            errorMessage = localized(
                "Error al iniciar grabación: \(error.localizedDescription)",
                "Error starting recording: \(error.localizedDescription)"
            )
            AppLogger.shared.logError(error, context: "Recording start failed", category: .recording)
            
            // Cancel recovery session if we started one
            if let sessionId = currentSessionId {
                try? await RecoveryManager.shared.cancelRecordingSession(sessionId: sessionId)
                currentSessionId = nil
            }
        }
    }
    
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        
        recordingState = .stopping
        AppLogger.shared.log("Stopping recording", category: .recording)
        
        stopDurationTimer()
        stopRecoveryHeartbeat()
        
        switch selectedSource {
        case .system:
            await stopSystemAudioCapture()
        case .microphone:
            await stopMicrophoneCapture()
        }
        
        isRecording = false
        isPaused = false
        audioLevel = 0
        
        // Complete recovery session
        if let sessionId = currentSessionId, let fileURL = recordedFileURL {
            recordingState = .saving
            let finalDuration = recordingDuration
            do {
                try await RecoveryManager.shared.completeRecordingSession(
                    sessionId: sessionId,
                    finalURL: fileURL
                )
                AppLogger.shared.log("Recording completed and recovery session closed", category: .recording)
                recordingState = .completed(url: fileURL, duration: finalDuration)
            } catch {
                AppLogger.shared.logError(error, context: "Failed to complete recovery session", category: .recording)
                // Still mark as completed since the recording file exists
                recordingState = .completed(url: fileURL, duration: finalDuration)
            }
            currentSessionId = nil
        }
        
        return recordedFileURL
    }
    
    /// Cancel an in-progress recording without saving
    func cancelRecording() async {
        guard isRecording else { return }
        
        recordingState = .stopping
        AppLogger.shared.log("Cancelling recording", category: .recording)
        
        stopDurationTimer()
        stopRecoveryHeartbeat()
        
        switch selectedSource {
        case .system:
            await stopSystemAudioCapture()
        case .microphone:
            await stopMicrophoneCapture()
        }
        
        isRecording = false
        isPaused = false
        audioLevel = 0
        recordingDuration = 0
        
        // Cancel recovery session and delete temp file
        if let sessionId = currentSessionId {
            try? await RecoveryManager.shared.cancelRecordingSession(sessionId: sessionId)
            AppLogger.shared.log("Recording cancelled and recovery session deleted", category: .recording)
            currentSessionId = nil
        }
        
        // Delete temp file if exists
        if let url = recordedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedFileURL = nil
        recordingState = .idle
    }
    
    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        stopDurationTimer()
        // Note: SCStream doesn't support pause, we just stop the timer
    }
    
    func resumeRecording() {
        guard isRecording, isPaused else { return }
        isPaused = false
        startDurationTimer()
    }
    
    // MARK: - System Audio Capture (ScreenCaptureKit)
    
    private func startSystemAudioCapture(outputURL: URL) async throws {
        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        // Get the main display for audio capture
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }
        
        // Create filter - we want system audio from the whole display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Configure stream for audio only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // Don't capture our own app's audio
        config.sampleRate = 16000 // Whisper works best with 16kHz
        config.channelCount = 1   // Mono for transcription
        
        // We still need to configure video even if we don't use it
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        config.showsCursor = false
        
        // Setup asset writer with recovery-managed URL
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
            assetWriter?.add(audioInput)
        }
        
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: .zero)
        
        // Create stream output handler
        streamOutput = AudioStreamOutput { [weak self] sampleBuffer in
            self?.handleAudioSample(sampleBuffer)
        }
        
        // Create and start stream
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        
        try await stream?.startCapture()
        
        recordedFileURL = outputURL
        AppLogger.shared.log("System audio capture started, output: \(outputURL.path)", category: .recording)
    }
    
    private func stopSystemAudioCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            AppLogger.shared.log("Error stopping stream: \(error)", level: .warning, category: .recording)
        }
        
        stream = nil
        streamOutput = nil
        
        // Finalize asset writer
        audioInput?.markAsFinished()
        
        if let writer = assetWriter {
            await writer.finishWriting()
            
            if writer.status == .completed {
                AppLogger.shared.log("System audio asset writer completed successfully", level: .info, category: .recording)
            } else if writer.status == .failed {
                let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
                AppLogger.shared.log("System audio asset writer failed: \(errorMsg)", level: .error, category: .recording)
                errorMessage = localized(
                    "Error al guardar la grabación: \(errorMsg)",
                    "Error saving recording: \(errorMsg)"
                )
            }
        }
        
        assetWriter = nil
        audioInput = nil
        
        AppLogger.shared.log("System audio capture stopped", category: .recording)
    }
    
    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard !isPaused else { return }
        
        // Write to file
        if audioInput?.isReadyForMoreMediaData == true {
            audioInput?.append(sampleBuffer)
        }
        
        // Calculate audio level and waveform for visualizer
        updateAudioLevel(from: sampleBuffer)
        updateWaveform(from: sampleBuffer)
    }
    
    // MARK: - Microphone Capture (AVAudioEngine) - Optimized for Whisper
    
    private func startMicrophoneCapture(outputURL: URL) async throws {
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            throw RecordingError.audioEngineFailure(
                localized("No se pudo inicializar AVAudioEngine", "Could not initialize AVAudioEngine")
            )
        }
        
        // Set selected microphone if available
        if let selectedMic = selectedMicrophone {
            try setInputDevice(deviceID: selectedMic.id)
            AppLogger.shared.log("Using microphone: \(selectedMic.name)", level: .info, category: .recording)
        }
        
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        
        AppLogger.shared.log("Native mic format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount) channels", level: .info, category: .recording)
        
        // Create target format for Whisper: 16kHz, Mono, Int16 (PCM)
        // Using Int16 for better compatibility with AVAssetWriter
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: true
        ) else {
            throw RecordingError.audioEngineFailure(
                localized(
                    "No se pudo crear el formato de audio objetivo",
                    "Could not create target audio format"
                )
            )
        }
        
        // Create converter from native to target format
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            // Fallback: use native format if conversion fails
            AppLogger.shared.log("Could not create converter, using native format", level: .warning, category: .recording)
            try await startMicrophoneCaptureNative(outputURL: outputURL, audioEngine: audioEngine, inputNode: inputNode, format: nativeFormat)
            return
        }
        audioConverter = converter
        
        // Change extension to .wav for Linear PCM
        let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
        
        // Setup asset writer with 16kHz mono Linear PCM - optimal for Whisper
        assetWriter = try AVAssetWriter(outputURL: wavURL, fileType: .wav)
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
            assetWriter?.add(audioInput)
        }
        
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: .zero)
        
        // Install tap on input node with native format, convert in callback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, time in
            self?.handleMicrophoneBufferWithConversion(buffer, time: time, converter: converter, targetFormat: targetFormat)
        }
        
        try audioEngine.start()
        
        // Start flush timer for extra safety
        startFlushTimer()
        
        recordedFileURL = wavURL
        AppLogger.shared.log("Microphone capture started at \(targetSampleRate)Hz mono, output: \(wavURL.path)", level: .info, category: .recording)
    }
    
    /// Fallback: capture with native format when conversion fails
    private func startMicrophoneCaptureNative(outputURL: URL, audioEngine: AVAudioEngine, inputNode: AVAudioInputNode, format: AVAudioFormat) async throws {
        // Change extension to .wav for Linear PCM
        let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
        
        assetWriter = try AVAssetWriter(outputURL: wavURL, fileType: .wav)
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
            assetWriter?.add(audioInput)
        }
        
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: .zero)
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handleMicrophoneBuffer(buffer, time: time)
        }
        
        try audioEngine.start()
        startFlushTimer()
        
        recordedFileURL = wavURL
    }
    
    /// Set the audio input device by ID
    private func setInputDevice(deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        
        if status != noErr {
            AppLogger.shared.log("Warning: Could not set input device (status: \(status))", level: .warning, category: .recording)
        }
    }
    
    /// Handle microphone buffer with conversion to 16kHz mono
    private func handleMicrophoneBufferWithConversion(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        guard !isPaused else { return }
        
        // Calculate output frame capacity based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            AppLogger.shared.log("Audio conversion error: \(error)", level: .warning, category: .recording)
            return
        }
        
        // Convert to CMSampleBuffer and write
        if let sampleBuffer = convertedBuffer.toCMSampleBuffer(presentationTime: time) {
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        }
        
        // Update audio level and waveform
        updateAudioLevelFromBuffer(convertedBuffer)
        updateWaveformFromBuffer(convertedBuffer)
    }
    
    private func stopMicrophoneCapture() async {
        stopFlushTimer()
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        
        audioInput?.markAsFinished()
        
        // Await async finish and verify success
        if let writer = assetWriter {
            await writer.finishWriting()
            
            if writer.status == .completed {
                AppLogger.shared.log("Asset writer completed successfully", level: .info, category: .recording)
            } else if writer.status == .failed {
                let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
                AppLogger.shared.log("Asset writer failed: \(errorMsg)", level: .error, category: .recording)
                errorMessage = localized(
                    "Error al guardar la grabación: \(errorMsg)",
                    "Error saving recording: \(errorMsg)"
                )
            }
        }
        
        assetWriter = nil
        audioInput = nil
        
        AppLogger.shared.log("Microphone capture stopped", category: .recording)
    }
    
    private func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard !isPaused else { return }
        
        // Convert buffer to CMSampleBuffer for asset writer
        if let sampleBuffer = buffer.toCMSampleBuffer(presentationTime: time) {
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        }
        
        // Update audio level and waveform
        updateAudioLevelFromBuffer(buffer)
        updateWaveformFromBuffer(buffer)
    }
    
    // MARK: - Audio Level Visualization
    
    private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let data = dataPointer else { return }
        
        // Calculate RMS level
        var sum: Float = 0
        let samples = length / 2 // 16-bit samples
        
        data.withMemoryRebound(to: Int16.self, capacity: samples) { ptr in
            for i in 0..<samples {
                let sample = Float(ptr[i]) / Float(Int16.max)
                sum += sample * sample
            }
        }
        
        let rms = sqrt(sum / Float(max(samples, 1)))
        let level = min(1.0, rms * 3) // Amplify for visibility
        
        DispatchQueue.main.async {
            self.audioLevel = level
        }
    }
    
    /// Update waveform data from CMSampleBuffer (for system audio)
    private func updateWaveform(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let data = dataPointer else { return }
        
        let samples = length / 2 // 16-bit samples
        let samplesPerPoint = max(1, samples / 30)
        var newWaveform: [Float] = []
        
        data.withMemoryRebound(to: Int16.self, capacity: samples) { ptr in
            for i in stride(from: 0, to: min(samples, 30 * samplesPerPoint), by: samplesPerPoint) {
                var sum: Float = 0
                let count = min(samplesPerPoint, samples - i)
                for j in 0..<count {
                    let sample = abs(Float(ptr[i + j]) / Float(Int16.max))
                    sum += sample
                }
                let avg = sum / Float(count)
                newWaveform.append(min(1.0, avg * 4)) // Amplify for visibility
            }
        }
        
        DispatchQueue.main.async {
            // Smooth transition
            for i in 0..<min(newWaveform.count, self.waveformData.count) {
                self.waveformData[i] = self.waveformData[i] * 0.3 + newWaveform[i] * 0.7
            }
        }
    }
    
    private func updateAudioLevelFromBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        
        // Handle Int16 format
        if buffer.format.commonFormat == .pcmFormatInt16, let int16Data = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                let sample = Float(int16Data[i]) / Float(Int16.max)
                sum += sample * sample
            }
        }
        // Handle Float32 format  
        else if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
        } else {
            return
        }
        
        let rms = sqrt(sum / Float(max(frameLength, 1)))
        let level = min(1.0, rms * 3)
        
        DispatchQueue.main.async {
            self.audioLevel = level
        }
    }
    
    /// Update waveform data for visualization
    private func updateWaveformFromBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let samplesPerPoint = max(1, frameLength / 50)
        var newWaveform: [Float] = []
        
        // Handle Int16 format
        if buffer.format.commonFormat == .pcmFormatInt16, let int16Data = buffer.int16ChannelData?[0] {
            for i in stride(from: 0, to: min(frameLength, 50 * samplesPerPoint), by: samplesPerPoint) {
                var sum: Float = 0
                let count = min(samplesPerPoint, frameLength - i)
                for j in 0..<count {
                    let sample = abs(Float(int16Data[i + j]) / Float(Int16.max))
                    sum += sample
                }
                let avg = sum / Float(count)
                newWaveform.append(min(1.0, avg * 4)) // Amplify for visibility
            }
        }
        // Handle Float32 format
        else if let channelData = buffer.floatChannelData?[0] {
            for i in stride(from: 0, to: min(frameLength, 50 * samplesPerPoint), by: samplesPerPoint) {
                var sum: Float = 0
                let count = min(samplesPerPoint, frameLength - i)
                for j in 0..<count {
                    let sample = abs(channelData[i + j])
                    sum += sample
                }
                let avg = sum / Float(count)
                newWaveform.append(min(1.0, avg * 4)) // Amplify for visibility
            }
        } else {
            return
        }
        
        DispatchQueue.main.async {
            // Smooth transition
            for i in 0..<min(newWaveform.count, self.waveformData.count) {
                self.waveformData[i] = self.waveformData[i] * 0.3 + newWaveform[i] * 0.7
            }
        }
    }
    
    // MARK: - Flush Timer (Extra Safety)
    
    /// Periodically flush audio data to disk for crash protection
    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // The AVAssetWriter handles flushing internally
            // This timer just logs for debugging - actual flush happens automatically
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.assetWriter?.status == .writing {
                    // Writer is active and writing - data is being persisted
                    AppLogger.shared.log("🔄 Audio flush check: Writer active", level: .debug, category: .recording)
                }
            }
        }
    }
    
    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }
    
    // MARK: - Post-Processing (Normalization)
    
    /// Normalize audio volume using ffmpeg before sending to Whisper
    /// This improves transcription accuracy for quiet recordings
    func normalizeAudio(inputURL: URL) async -> URL? {
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            AppLogger.shared.log("⚠️ ffmpeg not found, skipping normalization", level: .warning, category: .recording)
            return inputURL // Return original if ffmpeg not available
        }
        
        await MainActor.run {
            self.isNormalizing = true
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("normalized_\(UUID().uuidString).wav")
        
        AppLogger.shared.log("🎚️ Normalizing audio: \(inputURL.lastPathComponent)", level: .info, category: .recording)
        
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-i", inputURL.path,
                "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",  // EBU R128 loudness normalization
                "-ar", "16000",  // Ensure 16kHz
                "-ac", "1",      // Ensure mono
                "-y",            // Overwrite output
                outputURL.path
            ]
            
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            
            do {
                try process.run()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    
                    Task { @MainActor in
                        self.isNormalizing = false
                    }
                    
                    if process.terminationStatus == 0 {
                        AppLogger.shared.log("✅ Audio normalized successfully", level: .info, category: .recording)
                        // Delete original, return normalized
                        try? FileManager.default.removeItem(at: inputURL)
                        continuation.resume(returning: outputURL)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        AppLogger.shared.log("❌ ffmpeg failed: \(errorString)", level: .error, category: .recording)
                        continuation.resume(returning: inputURL) // Return original on failure
                    }
                }
            } catch {
                Task { @MainActor in
                    self.isNormalizing = false
                }
                AppLogger.shared.log("❌ Failed to start ffmpeg: \(error)", level: .error, category: .recording)
                continuation.resume(returning: inputURL)
            }
        }
    }
    
    // MARK: - Timer
    
    private func startDurationTimer() {
        let capturedStartTime = self.startTime
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = capturedStartTime else { return }
            Task { @MainActor in
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
    
    // MARK: - Recovery Heartbeat
    
    /// Start periodic updates to recovery manifest
    private func startRecoveryHeartbeat() {
        lastRecoveryDuration = 0
        recoveryHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: recoveryHeartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.sendRecoveryHeartbeat()
            }
        }
    }
    
    /// Stop recovery heartbeat timer
    private func stopRecoveryHeartbeat() {
        recoveryHeartbeatTimer?.invalidate()
        recoveryHeartbeatTimer = nil
    }
    
    /// Send current progress to recovery manager
    private func sendRecoveryHeartbeat() async {
        guard let sessionId = currentSessionId else { return }
        
        // Only update if duration has changed meaningfully (> 1 second)
        let currentDuration = recordingDuration
        guard currentDuration - lastRecoveryDuration >= 1.0 else { return }
        
        do {
            try await RecoveryManager.shared.updateRecordingProgress(
                sessionId: sessionId,
                duration: currentDuration
            )
            lastRecoveryDuration = currentDuration
        } catch {
            AppLogger.shared.logError(error, context: "Recovery heartbeat failed", category: .recording)
        }
    }
}

// MARK: - SCStream Output Handler

private class AudioStreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}

// MARK: - AVAudioPCMBuffer Extension

extension AVAudioPCMBuffer {
    func toCMSampleBuffer(presentationTime: AVAudioTime) -> CMSampleBuffer? {
        let format = self.format
        
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMAudioFormatDescription?
        
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let formatDesc = formatDescription else { return nil }
        
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: presentationTime.audioTimeStamp.mSampleTime / format.sampleRate, preferredTimescale: 1000000),
            decodeTimeStamp: .invalid
        )
        
        guard let blockBuffer = self.toBlockBuffer() else { return nil }
        
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer
    }
    
    private func toBlockBuffer() -> CMBlockBuffer? {
        // Handle Int16 format (interleaved)
        if format.commonFormat == .pcmFormatInt16, let int16Data = self.int16ChannelData {
            let dataSize = Int(self.frameLength) * MemoryLayout<Int16>.size * Int(self.format.channelCount)
            var blockBuffer: CMBlockBuffer?
            
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            
            guard let buffer = blockBuffer else { return nil }
            
            CMBlockBufferReplaceDataBytes(
                with: int16Data[0],
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
            
            return buffer
        }
        
        // Handle Float32 format (non-interleaved)
        guard let channelData = self.floatChannelData else { return nil }
        
        let dataSize = Int(self.frameLength) * MemoryLayout<Float>.size * Int(self.format.channelCount)
        var blockBuffer: CMBlockBuffer?
        
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard let buffer = blockBuffer else { return nil }
        
        CMBlockBufferReplaceDataBytes(
            with: channelData[0],
            blockBuffer: buffer,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        
        return buffer
    }
}
