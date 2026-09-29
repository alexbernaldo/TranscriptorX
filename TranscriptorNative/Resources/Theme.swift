import SwiftUI
import AppKit

// MARK: - Modern Theme 2025

// MARK: - Color Palette
extension Color {
    // === Background Hierarchy ===
    static let bgPrimary = Color(nsColor: .windowBackgroundColor)
    static let bgSecondary = Color(nsColor: .controlBackgroundColor)
    static let bgTertiary = Color(nsColor: .underPageBackgroundColor)
    static let bgElevated = Color.white.opacity(0.05)
    static let bgFloating = Color(nsColor: .windowBackgroundColor).opacity(0.85)
    
    // Interactive states
    static let bgHover = Color.primary.opacity(0.06)
    static let bgPressed = Color.primary.opacity(0.10)
    static let bgSelected = Color.accentColor.opacity(0.15)
    static let bgSelectedHover = Color.accentColor.opacity(0.20)
    
    // Cinema (always-dark context)
    static let bgCinema = Color(red: 0.02, green: 0.02, blue: 0.02)
    
    // Sidebar specific
    static let sidebarBg = Color.clear // Uses VisualEffectView
    
    // === Text Colors ===
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textMuted = Color(nsColor: .quaternaryLabelColor)
    static let textInverse = Color.white
    
    // Editorial Reading Colors (softer for long-form reading)
    static let textEditorial = Color(hex: "E5E5E5") // Pearl gray - easy on eyes
    static let textEditorialMuted = Color(hex: "ABABAB") // Dimmed for inactive
    static let textEditorialActive = Color.white.opacity(0.95) // Bright for active segment
    static let textTimestamp = Color(hex: "8E8E93")  // Subtle gray for timestamps
    
    // === Border Colors ===
    static let borderColor = Color(nsColor: .separatorColor)
    static let borderSubtle = Color.primary.opacity(0.08)
    static let borderPrimary = Color.primary.opacity(0.12)
    static let borderStrong = Color.primary.opacity(0.15)
    
    // === Accent Colors (Brand: Purple identity) ===
    static let accentPrimary = Color(hex: "8B5CF6")      // Violet — primary brand color
    static let accentSecondary = Color(hex: "6366F1")    // Indigo — secondary brand color
    static let accentLight = Color(hex: "8B5CF6").opacity(0.8)
    static let accentSubtle = Color(hex: "8B5CF6").opacity(0.15)
    
    // === Semantic Colors ===
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    
    // === Speaker Colors (for diarization) ===
    static let speaker0 = Color(hex: "5E97F6")  // Blue
    static let speaker1 = Color(hex: "9B7DFF")  // Purple
    static let speaker2 = Color(hex: "4DB6AC")  // Teal
    static let speaker3 = Color(hex: "FF8A65")  // Coral
    static let speaker4 = Color(hex: "F06292")  // Pink
    static let speaker5 = Color(hex: "FFD54F")  // Amber
    
    static func speakerColor(_ index: Int) -> Color {
        let colors: [Color] = [.speaker0, .speaker1, .speaker2, .speaker3, .speaker4, .speaker5]
        return colors[index % colors.count]
    }
    
    // === Tag/Badge Colors ===
    static let tagBlue = Color.blue.opacity(0.12)
    static let tagPurple = Color.purple.opacity(0.12)
    static let tagGreen = Color.green.opacity(0.12)
    static let tagOrange = Color.orange.opacity(0.12)
    static let tagRed = Color.red.opacity(0.12)
    static let tagGray = Color.gray.opacity(0.12)
    
    // === Gradients ===
    static let gradientPrimary = LinearGradient(
        colors: [Color(hex: "8B5CF6"), Color(hex: "6366F1")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientAccent = LinearGradient(
        colors: [Color(hex: "8B5CF6"), Color(hex: "6366F1").opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Brand button gradient — use for all primary CTAs
    static let gradientBrand = LinearGradient(
        colors: [Color(hex: "9B7DFF"), Color(hex: "6366F1")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientSubtle = LinearGradient(
        colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Hex Color Initializer
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

// MARK: - Typography System
extension Font {
    // Headers
    static let displayLarge = Font.system(size: 32, weight: .bold, design: .default)
    static let displayMedium = Font.system(size: 24, weight: .bold, design: .default)
    static let displaySmall = Font.system(size: 20, weight: .semibold, design: .default)
    
    // Titles
    static let titleLarge = Font.system(size: 17, weight: .semibold, design: .default)
    static let titleMedium = Font.system(size: 15, weight: .semibold, design: .default)
    static let titleSmall = Font.system(size: 13, weight: .semibold, design: .default)
    
    // Body
    static let bodyLarge = Font.system(size: 15, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 13, weight: .regular, design: .default)
    static let bodySmall = Font.system(size: 12, weight: .regular, design: .default)
    
    // Labels
    static let labelLarge = Font.system(size: 13, weight: .medium, design: .default)
    static let labelMedium = Font.system(size: 11, weight: .medium, design: .default)
    static let labelSmall = Font.system(size: 10, weight: .medium, design: .default)
    
    // Gap-fill tokens (size 14/12/16 common in UI)
    static let bodyDefault = Font.system(size: 14, weight: .regular, design: .default)
    static let labelDefault = Font.system(size: 14, weight: .medium, design: .default)
    static let titleDefault = Font.system(size: 14, weight: .semibold, design: .default)
    static let labelBody = Font.system(size: 12, weight: .medium, design: .default)
    static let bodyXLarge = Font.system(size: 16, weight: .regular, design: .default)
    
    // Specialized - Editorial Typography
    static let transcriptTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let transcriptBody = Font.system(size: 17, weight: .regular, design: .default)
    static let transcriptTimestamp = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let sidebarItem = Font.system(size: 13, weight: .medium, design: .default)
    static let sidebarSection = Font.system(size: 11, weight: .semibold, design: .default)
    static let caption = Font.system(size: 11, weight: .regular, design: .default)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    
    // Document Mode - "Medium Style" Reading Typography
    // Uses New York (Apple's native serif) for comfortable long-form reading
    // 18px base size with 1.6 line height (set via .lineSpacing modifier)
    static let documentBody = Font.custom("New York", size: 18).weight(.regular)
    static let documentBodyFallback = Font.system(size: 18, weight: .regular, design: .serif)
    static let documentBodySans = Font.system(size: 18, weight: .regular, design: .rounded)
}

// MARK: - Visual Effect View (Translucent Background)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    init(material: NSVisualEffectView.Material = .sidebar, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Modern Capsule Tag
struct CapsuleTag: View {
    let text: String
    let color: Color
    let icon: String?
    let size: TagSize
    
    enum TagSize {
        case small, medium, large
        
        var fontSize: CGFloat {
            switch self {
            case .small: return 9
            case .medium: return 10
            case .large: return 11
            }
        }
        
        var padding: EdgeInsets {
            switch self {
            case .small: return EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            case .medium: return EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
            case .large: return EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            }
        }
    }
    
    init(_ text: String, color: Color = .tagBlue, icon: String? = nil, size: TagSize = .medium) {
        self.text = text
        self.color = color
        self.icon = icon
        self.size = size
    }
    
    private var foregroundColor: Color {
        switch color {
        case .tagBlue: return .blue
        case .tagPurple: return .purple
        case .tagGreen: return .green
        case .tagOrange: return .orange
        case .tagRed: return .red
        default: return .textSecondary
        }
    }
    
    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: size.fontSize - 1, weight: .semibold))
            }
            Text(text)
                .font(.system(size: size.fontSize, weight: .medium))
        }
        .padding(size.padding)
        .background(Capsule().fill(color))
        .foregroundColor(foregroundColor)
    }
}

// MARK: - Modern Button Styles

/// Primary filled button (accent color)
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEnabled ? Color.accentPrimary : Color.gray.opacity(0.5))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary outlined button
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Ghost/Transparent button
struct GhostButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.bgHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Icon button (toolbar style)
struct IconButtonStyle: ButtonStyle {
    @State private var isHovered = false
    let size: CGFloat
    
    init(size: CGFloat = 28) {
        self.size = size
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.5))
            .foregroundColor(isHovered ? .textPrimary : .textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.bgHover : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Destructive action button (red tint)
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isHovered ? .white : .error)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.error : Color.error.opacity(0.12))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Sidebar row style
struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .foregroundColor(isSelected ? .accentPrimary : .textSecondary)
            .onHover { hovering in
                isHovered = hovering
            }
    }
    
    private var backgroundColor: Color {
        if isSelected && isHovered { return .bgSelectedHover }
        if isSelected { return .bgSelected }
        if isHovered { return .bgHover }
        return .clear
    }
}

/// Hover button style
struct HoverButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.bgHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Card Style
struct CardView<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            )
    }
}

// MARK: - Floating Card Style
struct FloatingCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(16)
            .background(
                ZStack {
                    VisualEffectView(material: .popover, blendingMode: .behindWindow)
                    Color.bgFloating.opacity(0.5)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
    }
}

// MARK: - Animations
extension Animation {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let smooth = Animation.easeInOut(duration: 0.25)
    static let quick = Animation.easeOut(duration: 0.15)
}

// MARK: - Corner Radius Extension
struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: RectCorner
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0
        
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Shimmer Effect
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width + phase * geo.size.width * 2)
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
