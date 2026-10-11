import SwiftUI
import AppKit

/// Key events for views that are not text fields, compatible with macOS 13
/// (`onKeyPress` needs macOS 14). The monitor is installed only while `isActive`.
struct KeyDownMonitor: ViewModifier {
    let isActive: Bool
    /// Also receive keys while a text field is being edited.
    var allowTextInput = false
    /// Return true when the event was handled (it is then consumed).
    let handler: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { update(isActive) }
            .onDisappear { remove() }
            .txOnChange(of: isActive) { update($0) }
    }

    private func update(_ active: Bool) {
        if active, monitor == nil {
            let handler = self.handler
            let allowText = allowTextInput
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Never steal keys from text input or other windows (sheets, panels).
                if !allowText, let responder = event.window?.firstResponder, responder is NSTextView, (responder as? NSTextView)?.isEditable == true {
                    return event
                }
                guard event.window === NSApp.keyWindow, allowText || event.window?.attachedSheet == nil else { return event }
                return handler(event) ? nil : event
            }
        } else if !active {
            remove()
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    func onKeyDown(active: Bool, allowTextInput: Bool = false, perform handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyDownMonitor(isActive: active, allowTextInput: allowTextInput, handler: handler))
    }
}

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let space: UInt16 = 49
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let tab: UInt16 = 48
}

extension NSEvent {
    var txModifiers: NSEvent.ModifierFlags { modifierFlags.intersection([.command, .option, .shift, .control]) }
}

// MARK: - onChange compatible with macOS 13 without deprecation warnings on newer SDKs

private struct ChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value, perform: action)
        }
    }
}

extension View {
    func txOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        modifier(ChangeObserver(value: value, action: action))
    }
}

// MARK: - Lists draw their own focus state (selection.row focused vs. unfocused)

private struct NoSystemFocusRing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

extension View {
    /// Lists and the segment column show focus through their own selection colours and ring.
    func txCustomFocusRing() -> some View { modifier(NoSystemFocusRing()) }
}
