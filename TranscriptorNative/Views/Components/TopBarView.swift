import SwiftUI

// MARK: - Top Bar with Ghost Icons
struct TopBarView: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @Binding var selectedTab: AppTab
    @Binding var showLibraryDrawer: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showQueuePanel: Bool
    @StateObject private var jobManager = JobManager.shared
    @State private var hoveredIcon: AppTab?
    
    enum AppTab: String, CaseIterable {
        case home = "house"
        case queue = "list.bullet.rectangle"
        case library = "clock"
        case settings = "gearshape"
        
        var fallbackLabel: String {
            switch self {
            case .home: return "Home"
            case .queue: return "Queue"
            case .library: return "History"
            case .settings: return "Settings"
            }
        }

        var localizationKey: String {
            switch self {
            case .home: return "topbar.tab.home"
            case .queue: return "topbar.tab.queue"
            case .library: return "topbar.tab.library"
            case .settings: return "topbar.tab.settings"
            }
        }
    }
    
    init(selectedTab: Binding<AppTab>, showLibraryDrawer: Binding<Bool> = .constant(false), showSettingsSheet: Binding<Bool> = .constant(false), showQueuePanel: Binding<Bool> = .constant(false)) {
        self._selectedTab = selectedTab
        self._showLibraryDrawer = showLibraryDrawer
        self._showSettingsSheet = showSettingsSheet
        self._showQueuePanel = showQueuePanel
    }
    
    private var activeJobCount: Int {
        jobManager.jobs.filter { $0.status == .queued || $0.status == .processing }.count
    }
    
    var body: some View {
        HStack {
            // Left side - empty (traffic lights handled by macOS)
            Spacer()
            
            // Right side - Ghost icons (60% base opacity, 100% on hover)
            HStack(spacing: 6) {
                // Queue button with badge
                queueButton
                
                ForEach([AppTab.library, .settings], id: \.self) { tab in
                    ghostIconButton(tab: tab)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(Color.clear)
    }
    
    private var queueButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                showQueuePanel.toggle()
                showLibraryDrawer = false
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: showQueuePanel ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .font(.titleMedium)
                    .foregroundColor(
                        showQueuePanel ? .accentPrimary :
                        hoveredIcon == .queue ? .textPrimary : .textSecondary
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .background(
                        Circle()
                            .fill(
                                showQueuePanel ? Color.accentPrimary.opacity(0.2) :
                                hoveredIcon == .queue ? Color.bgHover : Color.clear
                            )
                            .frame(width: 36, height: 36)
                    )
                    .scaleEffect(hoveredIcon == .queue ? 1.1 : 1.0)
                
                // Badge for active jobs
                if activeJobCount > 0 {
                    Text("\(activeJobCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.accentPrimary))
                        .offset(x: 6, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredIcon = isHovered ? .queue : nil
            }
        }
        .help(String(
            format: localizationManager.text("topbar.queue.help", fallback: "Queue (%d active)"),
            activeJobCount
        ))
        .accessibilityLabel(localizationManager.text("topbar.queue.accessibilityLabel", fallback: "Transcription queue"))
        .accessibilityHint(String(
            format: localizationManager.text("topbar.queue.accessibilityHint", fallback: "Show or hide the queue panel. %d active"),
            activeJobCount
        ))
    }
    
    private func ghostIconButton(tab: AppTab) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                switch tab {
                case .library:
                    showLibraryDrawer.toggle()
                    showQueuePanel = false
                case .settings:
                    showSettingsSheet = true
                    showLibraryDrawer = false
                    showQueuePanel = false
                default:
                    selectedTab = tab
                }
            }
        } label: {
            Image(systemName: tab.rawValue + (selectedTab == tab ? ".fill" : ""))
                .font(.titleMedium)
                .foregroundColor(
                    isTabActive(tab) ? .accentPrimary :
                    hoveredIcon == tab ? .textPrimary : .textSecondary
                )
                .frame(width: 44, height: 44)  // Minimum 44x44 hit area for accessibility
                .contentShape(Rectangle())     // Full hit area
                .background(
                    Circle()
                        .fill(
                            isTabActive(tab) ? Color.accentPrimary.opacity(0.2) :
                            hoveredIcon == tab ? Color.bgHover : Color.clear
                        )
                        .frame(width: 36, height: 36)  // Visual circle stays smaller
                )
                .scaleEffect(hoveredIcon == tab ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredIcon = isHovered ? tab : nil
            }
        }
        .help(localizationManager.text(tab.localizationKey, fallback: tab.fallbackLabel))
        .accessibilityLabel(localizationManager.text(tab.localizationKey, fallback: tab.fallbackLabel))
        .accessibilityHint(String(
            format: localizationManager.text("topbar.openTabHint", fallback: "Open %@"),
            localizationManager.text(tab.localizationKey, fallback: tab.fallbackLabel)
        ))
    }
    
    private func isTabActive(_ tab: AppTab) -> Bool {
        switch tab {
        case .library: return showLibraryDrawer
        case .settings: return showSettingsSheet
        case .queue: return showQueuePanel
        default: return selectedTab == tab
        }
    }
}

#if DEBUG
struct TopBarView_Previews: PreviewProvider {
    static var previews: some View {
        TopBarView(selectedTab: .constant(.home))
            .frame(width: 800)
            .background(Color.bgPrimary)
    }
}
#endif
