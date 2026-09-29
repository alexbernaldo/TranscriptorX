import Foundation
import Combine
import AppKit

/// Manages Whisper model lifecycle with lazy loading and automatic unloading
/// Implements "elastic memory" pattern - loads on demand, unloads when idle
@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()
    
    // MARK: - Published State
    
    @Published private(set) var state: ModelState = .unloaded
    @Published private(set) var currentModelId: String?
    @Published private(set) var memoryUsageMB: Double = 0
    
    enum ModelState: Equatable {
        case unloaded
        case loading(progress: Double)
        case ready
        case unloading
        case error(String)
        
        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
        
        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }
    
    // MARK: - Configuration
    
    /// Time in seconds before unloading idle model
    private let idleTimeout: TimeInterval = 5 * 60 // 5 minutes
    
    /// Time before unloading when app goes to background
    private let backgroundTimeout: TimeInterval = 60 // 1 minute
    
    // MARK: - Private Properties
    
    private var idleTimer: Timer?
    private var backgroundTimer: Timer?
    private var lastUsedTime: Date = Date()
    private var cancellables = Set<AnyCancellable>()
    
    // Reference to track if model is "loaded" (in real implementation, this would be the actual model context)
    private var isModelInMemory = false
    
    // MARK: - Initialization
    
    private init() {
        setupBackgroundObservers()
        
        AppLogger.shared.log("ModelManager initialized", category: .model, metadata: [
            "idleTimeout": "\(Int(idleTimeout))s",
            "backgroundTimeout": "\(Int(backgroundTimeout))s"
        ])
    }
    
    // MARK: - Public Methods
    
    /// Request model to be loaded (if not already)
    /// Returns when model is ready to use
    func ensureModelLoaded(modelId: String) async throws {
        // If already loaded with same model, just reset idle timer
        if state.isReady && currentModelId == modelId {
            resetIdleTimer()
            return
        }
        
        // If different model is loaded, unload first
        if currentModelId != nil && currentModelId != modelId {
            await unloadModel()
        }
        
        // Load the requested model
        try await loadModel(modelId: modelId)
    }
    
    /// Mark model as being used (resets idle timer)
    func markModelUsed() {
        lastUsedTime = Date()
        resetIdleTimer()
    }
    
    /// Immediately unload model to free memory
    func unloadModelNow() async {
        await unloadModel()
    }
    
    /// Get estimated memory for a model
    func estimatedMemory(for modelId: String) -> Double {
        // Approximate RAM usage by model size
        switch modelId {
        case "tiny": return 75
        case "base": return 150
        case "small": return 500
        case "medium": return 1500
        case "large", "large-v2", "large-v3", "large-v3-turbo": return 3000
        default: return 500
        }
    }
    
    // MARK: - Private Methods
    
    private func loadModel(modelId: String) async throws {
        guard !state.isLoading else { return }
        
        let startTime = Date()
        state = .loading(progress: 0)
        currentModelId = modelId
        
        AppLogger.shared.log("Loading model", category: .model, metadata: ["modelId": modelId])
        AppLogger.shared.logMemoryUsage()
        
        do {
            // Simulate/perform actual model loading
            // In real implementation, this would call TranscriptionService to load the model
            
            // Progress updates
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms per step for demo
                state = .loading(progress: progress)
            }
            
            // Mark as loaded
            isModelInMemory = true
            state = .ready
            memoryUsageMB = estimatedMemory(for: modelId)
            lastUsedTime = Date()
            
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            AppLogger.shared.logModelEvent("Model loaded", modelId: modelId, durationMs: duration)
            AppLogger.shared.logMemoryUsage()
            
            // Start idle timer
            resetIdleTimer()
            
        } catch {
            state = .error(error.localizedDescription)
            currentModelId = nil
            AppLogger.shared.logError(error, context: "Model loading failed", category: .model)
            throw error
        }
    }
    
    private func unloadModel() async {
        guard isModelInMemory else { return }
        
        state = .unloading
        
        let modelId = currentModelId ?? "unknown"
        AppLogger.shared.log("Unloading model", category: .model, metadata: ["modelId": modelId])
        
        // Cancel timers
        idleTimer?.invalidate()
        idleTimer = nil
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        
        // In real implementation, this would release the whisper context
        // For now, just mark as unloaded
        await Task.yield() // Allow UI to update
        
        isModelInMemory = false
        state = .unloaded
        memoryUsageMB = 0
        currentModelId = nil
        
        AppLogger.shared.log("Model unloaded", category: .model, metadata: ["modelId": modelId])
        AppLogger.shared.logMemoryUsage()
    }
    
    // MARK: - Idle Timer Management
    
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Check if model is still idle
                let idleTime = Date().timeIntervalSince(self.lastUsedTime)
                if idleTime >= self.idleTimeout {
                    AppLogger.shared.log("Unloading model due to idle timeout", category: .memory, metadata: [
                        "idleTime": "\(Int(idleTime))s"
                    ])
                    await self.unloadModel()
                }
            }
        }
    }
    
    // MARK: - Background/Foreground Handling
    
    private func setupBackgroundObservers() {
        // Observe app going to background
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppBackground()
            }
            .store(in: &cancellables)
        
        // Observe app coming to foreground
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppForeground()
            }
            .store(in: &cancellables)
        
        // Observe memory pressure warnings
        NotificationCenter.default.publisher(for: NSNotification.Name("NSProcessInfoPowerStateDidChangeNotification"))
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleMemoryPressure()
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleAppBackground() {
        guard isModelInMemory else { return }
        
        AppLogger.shared.log("App went to background, starting unload timer", category: .memory)
        
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: backgroundTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isModelInMemory else { return }
                
                AppLogger.shared.log("Unloading model due to background timeout", category: .memory)
                await self.unloadModel()
            }
        }
    }
    
    private func handleAppForeground() {
        // Cancel background unload timer
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        
        AppLogger.shared.log("App returned to foreground", category: .memory)
    }
    
    private func handleMemoryPressure() {
        guard isModelInMemory else { return }
        
        AppLogger.shared.log("Memory pressure detected, unloading model", category: .memory, metadata: [
            "level": "warning"
        ])
        
        Task {
            await unloadModel()
        }
    }
}

// MARK: - State Description

extension ModelManager.ModelState: CustomStringConvertible {
    var description: String {
        switch self {
        case .unloaded:
            return "No cargado"
        case .loading(let progress):
            return "Cargando... \(Int(progress * 100))%"
        case .ready:
            return "Listo"
        case .unloading:
            return "Liberando memoria..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
