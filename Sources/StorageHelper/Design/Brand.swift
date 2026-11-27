import AppKit
import SwiftUI

/// Diskward brand identity: name, tagline, palette and semantic design tokens.
///
/// Use the *semantic* tokens (`DS`) in views, not the raw palette, so meaning stays consistent:
/// mint = reclaimable, amber = needs review, red = genuinely critical. Standard controls, text,
/// backgrounds and separators use native macOS colors.
enum Brand {
    static let name = "Diskward"
    static let tagline = "Your disk, under control."

    /// Raw palette from the brand guidelines.
    enum Palette {
        static let primary = Color(hex: 0x0F2D4A)   // navy
        static let secondary = Color(hex: 0x0B6E7A) // teal
        static let accent = Color(hex: 0x34D399)    // mint
        static let lightSurface = Color(hex: 0xF7F9FC)
        static let darkSurface = Color(hex: 0x121A24)
    }

    /// The menu bar glyph from the asset catalog, rendered as a template so macOS handles
    /// light/dark and highlight states. Falls back to an SF Symbol when running without the
    /// compiled asset catalog (e.g. `swift run`).
    @MainActor static var menuBarImage: Image {
        if let image = NSImage(named: "DiskwardMenuBar") {
            image.isTemplate = true
            return Image(nsImage: image).renderingMode(.template)
        }
        return Image(systemName: "internaldrive")
    }

    /// App icon as shown in the Dock (from the bundle's AppIcon).
    @MainActor static var appIcon: NSImage { NSApp.applicationIconImage }
}

/// Semantic design tokens. Each has a light and dark variant chosen for contrast
/// (WCAG ratios against standard macOS backgrounds noted next to each).
enum DS {
    /// Interactive tint (prominent buttons, toggles, progress). Matches the AccentColor asset.
    /// Light #0B6E7A: 5.96:1 white text. Dark #0D7F8C: 3.0:1 vs dark backgrounds, 4.7:1 white text.
    static let tint = Color(light: 0x0B6E7A, dark: 0x0D7F8C)

    /// Reclaimable storage: bars, fills, large numbers. Light #059669 (3.8:1), dark mint #34D399 (8.7:1).
    static let reclaimable = Color(light: 0x059669, dark: 0x34D399)
    /// Reclaimable as small text. Light #047857 (5.5:1), dark #34D399.
    static let reclaimableText = Color(light: 0x047857, dark: 0x34D399)

    /// Needs review / caution. Amber: light #B45309 (5.0:1), dark #FBBF24 (10:1).
    static let review = Color(light: 0xB45309, dark: 0xFBBF24)

    /// Genuinely critical (irreversible deletes, failures, almost-full disk). System red.
    static let critical = Color(nsColor: .systemRed)

    /// Used space that isn't reclaimable. Navy in light (14:1), muted slate in dark (6.4:1).
    static let otherUsed = Color(light: 0x0F2D4A, dark: 0x8FA3B8)

    /// Brand surface for hero areas (onboarding, About). Normal views use native backgrounds.
    static let brandSurface = Color(light: 0xF7F9FC, dark: 0x121A24)

    /// Terminal-style output panel.
    static let terminalText = Brand.Palette.accent
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A color that follows the light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

extension Font {
    /// SF Mono for paths, commands and technical values.
    static let technical = Font.system(.caption, design: .monospaced)
}

/// Brand header used in onboarding and the menu bar panel: icon, name, tagline.
struct BrandHeader: View {
    var iconSize: CGFloat = 48
    var showTagline = true

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Brand.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.name).font(.title2.weight(.semibold))
                if showTagline {
                    Text(Brand.tagline).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Standard About panel with the tagline.
enum AboutPanel {
    @MainActor static func show() {
        let credits = NSAttributedString(
            string: Brand.tagline,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.name,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Light / Dark / System appearance, saved in user defaults and applied app-wide.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    @MainActor static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Saves and applies the mode to every window, including the menu bar panel and Settings.
    @MainActor static func set(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        mode.apply()
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Segmented Light / Dark / System control bound to the saved appearance.
struct AppearancePicker: View {
    @AppStorage(AppearanceMode.key) private var raw = AppearanceMode.system.rawValue
    var showsLabels = true

    var body: some View {
        Picker("Appearance", selection: Binding(
            get: { AppearanceMode(rawValue: raw) ?? .system },
            set: { AppearanceMode.set($0) }
        )) {
            ForEach(AppearanceMode.allCases) { mode in
                if showsLabels {
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                } else {
                    Image(systemName: mode.icon).help(mode.title).tag(mode)
                }
            }
        }
    }
}
