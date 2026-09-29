import SwiftUI

// MARK: - Floating Bottom Dock (Independent Capsules)
struct BottomDockView: View {
    var onRecord: () -> Void
    var onPasteLink: () -> Void
    
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    @State private var isRecordHovered = false
    @State private var isLinkHovered = false
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Default: horizontal layout
            dockButtons(axis: .horizontal)
            // Fallback: vertical layout for compact width
            dockButtons(axis: .vertical)
        }
    }
    
    @ViewBuilder
    private func dockButtons(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 16))
            : AnyLayout(VStackLayout(spacing: 10))
        
        layout {
            // Record Button - Independent Capsule
            Button(action: onRecord) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text(localizationManager.text("dock.record", fallback: "Grabar audio"))
                        .font(.labelDefault)
                        .foregroundColor(isRecordHovered ? .white : .textSecondary)
                }
                .frame(minWidth: metrics.dockButtonMinWidth, maxWidth: metrics.dockButtonMaxWidth)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(isRecordHovered ? 0.3 : 0.15), radius: isRecordHovered ? 16 : 12, y: 6)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isRecordHovered ? 0.2 : 0.1), lineWidth: 1)
                )
                .scaleEffect(isRecordHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizationManager.text("dock.record", fallback: "Grabar audio"))
            .accessibilityHint(localizationManager.text("dock.record.hint", fallback: "Abre el panel de grabación de audio"))
            .onHover { isHovered in
                withAnimation(.smooth(duration: 0.15)) {
                    isRecordHovered = isHovered
                }
            }
            
            // Paste Link Button - Independent Capsule
            Button(action: onPasteLink) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.labelDefault)
                        .foregroundColor(isLinkHovered ? .accentPrimary : .textSecondary)
                    
                    Text(localizationManager.text("dock.link", fallback: "Pegar enlace"))
                        .font(.labelDefault)
                        .foregroundColor(isLinkHovered ? .white : .textSecondary)
                }
                .frame(minWidth: metrics.dockButtonMinWidth, maxWidth: metrics.dockButtonMaxWidth)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(isLinkHovered ? 0.3 : 0.15), radius: isLinkHovered ? 16 : 12, y: 6)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isLinkHovered ? 0.2 : 0.1), lineWidth: 1)
                )
                .scaleEffect(isLinkHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizationManager.text("dock.link", fallback: "Pegar enlace"))
            .accessibilityHint(localizationManager.text("dock.link.hint", fallback: "Abre el diálogo para transcribir desde una URL"))
            .onHover { isHovered in
                withAnimation(.smooth(duration: 0.15)) {
                    isLinkHovered = isHovered
                }
            }
        }
    }
}

#if DEBUG
struct BottomDockView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.bgPrimary.ignoresSafeArea()
            
            VStack {
                Spacer()
                BottomDockView(
                    onRecord: {},
                    onPasteLink: {}
                )
                .environmentObject(LocalizationManager())
                .padding(.bottom, 30)
            }
        }
        .frame(width: 600, height: 400)
    }
}
#endif
