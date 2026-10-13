import Foundation
import AppKit

/// Gestor de memoria elástico para modelos locales en el proceso de la app (Parakeet y Nemotron).
///
/// Reglas de la especificación:
/// - Descarga tras 5 min de inactividad o 60 s en segundo plano.
/// - Notificaciones `NSApplication.willResignActiveNotification` y `didBecomeActiveNotification`.
/// - Permite liberar la memoria inmediatamente a petición del usuario («Liberar ahora»).
@MainActor
final class ModelMemoryManager: ObservableObject {
    static let shared = ModelMemoryManager()

    @Published private(set) var activeModelId: String?
    @Published private(set) var lastActivity: Date?

    private var idleTimer: Task<Void, Never>?
    private var backgroundTimer: Task<Void, Never>?

    private let idleTimeout: TimeInterval = 300 // 5 minutos
    private let backgroundTimeout: TimeInterval = 60 // 60 segundos

    private var unregisterHooks: [() -> Void] = []
    private var unloadHandlers: [() async -> Void] = []

    private init() {
        let center = NotificationCenter.default
        let resignObserver = center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillResignActive()
        }

        let activeObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidBecomeActive()
        }

        unregisterHooks = [
            { center.removeObserver(resignObserver) },
            { center.removeObserver(activeObserver) }
        ]
    }

    deinit {
        unregisterHooks.forEach { $0() }
    }

    func registerUnloadHandler(_ handler: @escaping () async -> Void) {
        unloadHandlers.append(handler)
    }

    func notifyModelInUse(_ id: String) {
        activeModelId = id
        lastActivity = Date()
        backgroundTimer?.cancel()
        backgroundTimer = nil
        resetIdleTimer()
    }

    func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.idleTimeout * 1_000_000_000))
            if !Task.isCancelled {
                await self.unloadAll()
            }
        }
    }

    private func handleWillResignActive() {
        backgroundTimer?.cancel()
        guard activeModelId != nil else { return }
        backgroundTimer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.backgroundTimeout * 1_000_000_000))
            if !Task.isCancelled {
                await self.unloadAll()
            }
        }
    }

    private func handleDidBecomeActive() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
        if activeModelId != nil {
            resetIdleTimer()
        }
    }

    func unloadAll() async {
        idleTimer?.cancel()
        idleTimer = nil
        backgroundTimer?.cancel()
        backgroundTimer = nil

        for handler in unloadHandlers {
            await handler()
        }

        activeModelId = nil
        lastActivity = nil
    }
}
