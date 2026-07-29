import SwiftUI

// A native SwiftUI interpretation of shadcn's semantic token model.
// The app chrome follows macOS appearance; fixed colors are reserved for the
// physical controller twin and status signals.
enum NostromoTheme {
    // MARK: Hardware palette

    static let carbon = Color(red: 0.059, green: 0.071, blue: 0.094)
    static let keycap = Color(red: 0.110, green: 0.133, blue: 0.169)
    static let raised = Color(red: 0.153, green: 0.188, blue: 0.231)

    // MARK: Semantic colors

    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color.primary.opacity(0.035)
    static let popover = Color(nsColor: .windowBackgroundColor)
    static let foreground = Color.primary
    static let mutedForeground = Color.secondary
    static let border = Color.primary.opacity(0.105)
    static let input = Color.primary.opacity(0.14)
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentForeground = Color.white
    static let hover = Color.primary.opacity(0.055)
    static let selected = accent.opacity(0.12)
    static let focus = accent.opacity(0.78)

    static let signal = Color(red: 0.882, green: 0.478, blue: 0.055)
    static let success = Color(red: 0.188, green: 0.650, blue: 0.345)
    static let danger = Color(red: 0.870, green: 0.225, blue: 0.235)

    // Compatibility aliases for the controller and diagnostics.
    static let canvas = background
    static let panel = surface
    static let stroke = border
    static let text = foreground
    static let muted = mutedForeground
    static let blue = accent
    static let cyan = Color(red: 0.365, green: 0.816, blue: 1.0)
    static let amber = signal
    static let green = success
    static let red = danger
}

enum NostromoSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum NostromoRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
}

enum NostromoControlHeight {
    static let compact: CGFloat = 28
    static let regular: CGFloat = 36
    static let large: CGFloat = 44
}

enum NostromoSurfaceLevel {
    case card
    case elevated
    case floating
}

private struct SurfaceModifier: ViewModifier {
    let level: NostromoSurfaceLevel

    private var fill: Color {
        switch level {
        case .card: NostromoTheme.surface
        case .elevated: NostromoTheme.elevated
        case .floating: NostromoTheme.popover
        }
    }

    private var radius: CGFloat {
        switch level {
        case .card: NostromoRadius.large
        case .elevated, .floating: NostromoRadius.medium
        }
    }

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(NostromoTheme.border, lineWidth: 1)
            }
            .shadow(
                color: level == .floating ? .black.opacity(0.14) : .clear,
                radius: level == .floating ? 18 : 0,
                y: level == .floating ? 8 : 0
            )
    }
}

extension View {
    func nostromoSurface(_ level: NostromoSurfaceLevel = .card) -> some View {
        modifier(SurfaceModifier(level: level))
    }

    // Compatibility entry point used throughout the existing UI.
    func nostromoPanel() -> some View {
        nostromoSurface(.card)
    }

    func nostromoScreen() -> some View {
        background(NostromoTheme.background)
            .tint(NostromoTheme.accent)
            .foregroundStyle(NostromoTheme.foreground)
    }
}

struct NostromoCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(
        padding: CGFloat = NostromoSpace.md,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .nostromoSurface()
    }
}

enum NostromoButtonVariant {
    case primary
    case secondary
    case outline
    case ghost
    case destructive
}

struct NostromoButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let variant: NostromoButtonVariant
    var compact = false

    private var foreground: Color {
        switch variant {
        case .primary: NostromoTheme.accentForeground
        case .destructive: .white
        case .secondary, .outline, .ghost: NostromoTheme.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .primary: NostromoTheme.accent
        case .secondary: NostromoTheme.hover
        case .outline, .ghost: .clear
        case .destructive: NostromoTheme.danger
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minHeight: compact ? NostromoControlHeight.compact : NostromoControlHeight.regular)
            .background(
                background.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: NostromoRadius.small, style: .continuous)
            )
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: NostromoRadius.small, style: .continuous)
                        .strokeBorder(NostromoTheme.input)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct NostromoSectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.xxs) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.25)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(NostromoTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NostromoEyebrow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(NostromoTheme.mutedForeground)
    }
}

struct NostromoItem<Leading: View, Content: View, Trailing: View>: View {
    let leading: Leading
    let content: Content
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: NostromoSpace.sm) {
            leading
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, NostromoSpace.sm)
    }
}

struct NostromoField<Content: View>: View {
    let label: String
    let detail: String?
    let content: Content

    init(
        _ label: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.xs) {
            Text(label)
                .font(.callout.weight(.medium))
            content
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
        }
    }
}

struct NostromoKbd: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .frame(minHeight: 22)
            .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(NostromoTheme.border)
            }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .frame(height: NostromoControlHeight.compact)
        .background(color.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(0.18))
        }
        .foregroundStyle(color)
        .accessibilityLabel(title)
    }
}
