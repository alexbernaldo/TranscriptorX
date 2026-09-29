import SwiftUI

// MARK: - Responsive Layout Metrics
/// Centralised layout helper that calculates responsive values from window size.
/// Create one instance at the top of a root view using `GeometryReader` and
/// pass it down (or inject via `EnvironmentValues`) to child views.
struct ResponsiveMetrics {
    let size: CGSize
    
    // MARK: - Raw Dimensions
    var width: CGFloat  { size.width }
    var height: CGFloat { size.height }
    
    // MARK: - Breakpoints
    var isCompactWidth: Bool  { width < 600 }
    var isCompactHeight: Bool { height < 760 }
    
    // MARK: - General Padding
    /// Main horizontal padding for hero / top-level sections (replaces fixed 60).
    var horizontalPadding: CGFloat { Self.clamp(width * 0.05, min: 16, max: 60) }
    /// Section-level horizontal padding (replaces fixed 40).
    var sectionPadding: CGFloat    { Self.clamp(width * 0.04, min: 16, max: 40) }
    
    // MARK: - Drawer / Panel Widths
    var drawerWidth: CGFloat  { Self.clamp(width * 0.35, min: 280, max: 400) }
    var sheetWidth: CGFloat   { Self.clamp(width * 0.50, min: 360, max: 600) }
    var prefsWidth: CGFloat   { Self.clamp(width * 0.55, min: 520, max: 720) }
    var prefsHeight: CGFloat  { Self.clamp(height * 0.70, min: 420, max: 580) }
    var sidebarWidth: CGFloat { Self.clamp(width * 0.20, min: 150, max: 210) }
    
    // MARK: - Card Widths
    var cardWidth: CGFloat { Self.clamp(width * 0.18, min: 180, max: 260) }
    
    // MARK: - Drop Area
    var dropAreaMaxWidth: CGFloat  { Self.clamp(width * 0.80, min: 400, max: 920) }
    var dropAreaMinHeight: CGFloat { isCompactHeight ? 160 : 240 }
    
    // MARK: - Dock
    var dockBottomPadding: CGFloat    { isCompactHeight ? 40 : 100 }
    var dockButtonMinWidth: CGFloat   { 120 }
    var dockButtonMaxWidth: CGFloat   { Self.clamp(width * 0.16, min: 140, max: 200) }
    
    // MARK: - TranscriptViewer
    var viewerWidthRatio: CGFloat  { isCompactWidth  ? 0.96 : 0.90 }
    var viewerHeightRatio: CGFloat { isCompactHeight ? 0.94 : 0.88 }
    var viewerOffset: CGFloat      { isCompactHeight ? -20 : -55 }
    var viewerHPadding: CGFloat    { Self.clamp(width * 0.03, min: 12, max: 32) }
    
    // MARK: - Tech Log
    var techLogWidth: CGFloat { Self.clamp(width * 0.30, min: 300, max: 400) }
    
    // MARK: - Sheets
    var urlSheetWidth: CGFloat       { Self.clamp(width * 0.50, min: 420, max: 620) }
    var transcriptionSheetWidth: CGFloat { Self.clamp(width * 0.45, min: 400, max: 520) }
    var recorderWidth: CGFloat       { Self.clamp(width * 0.38, min: 340, max: 460) }
    var recordingPanelWidth: CGFloat { Self.clamp(width * 0.32, min: 300, max: 380) }
    var modelDownloadWidth: CGFloat  { Self.clamp(width * 0.32, min: 300, max: 380) }
    
    // MARK: - Recovery / Settings
    var recoveryWidth: CGFloat  { Self.clamp(width * 0.42, min: 380, max: 520) }
    var recoveryHeight: CGFloat { Self.clamp(height * 0.55, min: 320, max: 440) }
    var settingsWidth: CGFloat  { Self.clamp(width * 0.40, min: 380, max: 500) }
    var settingsHeight: CGFloat { Self.clamp(height * 0.50, min: 280, max: 360) }
    
    // MARK: - Setup
    var setupMaxWidth: CGFloat  { Self.clamp(width * 0.75, min: 340, max: 500) }
    var setupButtonMaxWidth: CGFloat { Self.clamp(width * 0.50, min: 200, max: 300) }
    
    // MARK: - Picker Widths
    var pickerWidth: CGFloat { Self.clamp(width * 0.12, min: 140, max: 180) }
    
    // MARK: - Clamp Utility
    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(hi, Swift.max(lo, value))
    }
}

// MARK: - Environment Key
private struct ResponsiveMetricsKey: EnvironmentKey {
    static let defaultValue = ResponsiveMetrics(size: CGSize(width: 1200, height: 800))
}

extension EnvironmentValues {
    var responsiveMetrics: ResponsiveMetrics {
        get { self[ResponsiveMetricsKey.self] }
        set { self[ResponsiveMetricsKey.self] = newValue }
    }
}
