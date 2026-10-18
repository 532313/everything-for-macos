import AppKit

/// The ways results can be presented, mirroring Everything's View menu.
enum ViewMode: Int, CaseIterable {
    case details = 0
    case compact = 1
    case icons = 2
    case iconsLarge = 3

    var title: String {
        switch self {
        case .details: return "Details"
        case .compact: return "List"
        case .icons: return "Icons"
        case .iconsLarge: return "Large Icons"
        }
    }

    var symbolName: String {
        switch self {
        case .details: return "list.bullet.rectangle"
        case .compact: return "list.dash"
        case .icons: return "square.grid.2x2"
        case .iconsLarge: return "square.grid.3x3"
        }
    }

    var isGrid: Bool { self == .icons || self == .iconsLarge }

    /// Side of the image area inside a grid item.
    var iconSide: CGFloat { self == .iconsLarge ? 128 : 64 }

    var itemSize: NSSize {
        switch self {
        case .iconsLarge: return NSSize(width: 190, height: 206)
        default: return NSSize(width: 118, height: 108)
        }
    }

    var itemFontSize: CGFloat { self == .iconsLarge ? 12 : 11 }

    var labelLines: Int { self == .iconsLarge ? 3 : 2 }

    static var saved: ViewMode {
        ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .details
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "viewMode")
    }
}
