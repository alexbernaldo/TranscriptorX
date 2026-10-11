import SwiftUI

// MARK: - Banner stack (top of the work area; one visible, «2 avisos más»)

struct BannerStack: View {
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let banner = workspace.banners.first {
                BannerView(banner: banner, moreCount: workspace.banners.count - 1)
                    .padding(.horizontal, TX.Space.s12)
                    .padding(.top, TX.Space.s12)
                    .transition(transition(for: banner))
                    .id(banner.id)
            }
        }
        .animation(animation, value: workspace.banners.first?.id)
    }

    private var animation: Animation? {
        // Errors appear without movement (spec 9.5); the rest slide 12 pt with a fade.
        if workspace.banners.first?.kind == .error { return nil }
        return reduceMotion ? .easeOut(duration: 0.15) : TX.Motion.banner
    }

    private func transition(for banner: BannerItem) -> AnyTransition {
        if banner.kind == .error || reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -12)),
                           removal: .opacity.animation(TX.Motion.bannerClose))
    }
}

struct BannerView: View {
    let banner: BannerItem
    var moreCount = 0
    @EnvironmentObject var workspace: WorkspaceState
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                (Text(banner.title).font(.system(size: 13, weight: .semibold))
                 + Text(banner.message.map { "  " + $0 } ?? "").font(.system(size: 13)))
                    .foregroundStyle(TX.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if moreCount > 0 {
                    Button(TXL.n("banner.more", "%d aviso más", "%d avisos más", moreCount)) { workspace.cycleBanners() }
                        .buttonStyle(TXBorderlessButtonStyle(tint: TX.Colors.textSecondary))
                }
                if banner.details != nil {
                    Button(showDetails ? TXL.t("common.hideDetails", "Ocultar detalles") : TXL.t("common.details", "Detalles")) {
                        showDetails.toggle()
                    }
                    .buttonStyle(TXBorderlessButtonStyle(tint: TX.Colors.textSecondary))
                }
                ForEach(banner.actions) { action in
                    if banner.kind == .meeting && action.isPrimary {
                        Button(action.title, action: action.handler)
                            .buttonStyle(MeetingButtonStyle())
                    } else if action.isPrimary {
                        Button(action.title, action: action.handler).buttonStyle(TXSecondaryButtonStyle())
                    } else {
                        Button(action.title, action: action.handler).buttonStyle(TXBorderlessButtonStyle())
                    }
                }
                if banner.dismissible {
                    Button { workspace.dismissBanner(key: banner.key) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(TXIconButtonStyle(iconSize: 11))
                    .help(TXL.t("common.close", "Cerrar"))
                    .accessibilityLabel(TXL.t("common.close", "Cerrar"))
                }
            }
            if showDetails, let details = banner.details {
                ScrollView {
                    Text(details)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TX.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .padding(.vertical, showDetails ? 8 : 0)
        .background(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .strokeBorder(tint.opacity(banner.kind == .meeting ? 0.45 : 0.40), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return TX.Colors.info
        case .warning, .recovery: return TX.Colors.warning
        case .error: return TX.Colors.error
        case .meeting: return TX.Colors.meeting
        }
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .meeting: return "calendar.badge.clock"
        case .recovery: return "arrow.counterclockwise"
        }
    }
}

/// «Grabar ahora»: the only filled button that is not purple (spec 3.1).
struct MeetingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(nsColor: TX.Palette.meetingInk))
            .padding(.horizontal, 14)
            .frame(height: TX.Size.control)
            .background(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                .fill(Color(nsColor: TX.Palette.meeting).opacity(configuration.isPressed ? 0.85 : 1)))
    }
}

// MARK: - Toast (bottom centre of the work area)

struct ToastHost: View {
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            if let toast = workspace.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        // Rises 8 pt with a fade; leaves with a shorter fade only (spec 9.5).
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.animation(TX.Motion.bannerClose)))
                    .padding(.bottom, TX.Space.s16)
            }
        }
        .animation(TX.Motion.toast, value: workspace.toast?.id)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(workspace.toast != nil)
    }
}

struct ToastView: View {
    let toast: ToastItem
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkDrawn: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(toast.text)
                .font(.system(size: 13))
                .foregroundStyle(TX.Colors.textPrimary)
                .lineLimit(1)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    workspace.dismissToast()
                }
                .buttonStyle(TXBorderlessButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(TX.Colors.bgElevated))
        .txFloatingShadow(cornerRadius: 18)
        .clipShape(Capsule())
        .onAppear {
            if reduceMotion { checkDrawn = 1 } else { withAnimation(.easeOut(duration: 0.24)) { checkDrawn = 1 } }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch toast.icon {
        case .success:
            CheckShape().trim(from: 0, to: checkDrawn)
                .stroke(TX.Colors.success, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(TX.Colors.info).accessibilityHidden(true)
        case .warning:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(TX.Colors.warning).accessibilityHidden(true)
        case .error:
            Image(systemName: "xmark.octagon").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
        }
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}
