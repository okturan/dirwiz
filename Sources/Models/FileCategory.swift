import SwiftUI

/// File type categories with associated colors for treemap visualization.
public enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case documents = "Documents"
    case images = "Images"
    case video = "Video"
    case audio = "Audio"
    case code = "Code"
    case archives = "Archives"
    case applications = "Applications"
    case system = "System"
    case caches = "Caches"
    case other = "Other"

    public var id: String { rawValue }

    private var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .documents:    return (0.20, 0.40, 0.85)
        case .images:       return (0.85, 0.35, 0.60)
        case .video:        return (0.75, 0.25, 0.25)
        case .audio:        return (0.90, 0.55, 0.20)
        case .code:         return (0.30, 0.70, 0.35)
        case .archives:     return (0.55, 0.45, 0.75)
        case .applications: return (0.45, 0.75, 0.85)
        case .system:       return (0.60, 0.60, 0.60)
        case .caches:       return (0.75, 0.75, 0.50)
        case .other:        return (0.50, 0.50, 0.50)
        }
    }

    public var color: Color {
        let c = rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// SIMD4 color for Metal rendering.
    public var simdColor: SIMD4<Float> {
        let c = rgb
        return SIMD4(Float(c.r), Float(c.g), Float(c.b), 1.0)
    }

    public var fileTypeDescription: String {
        switch self {
        case .documents:    return "Documents & Text"
        case .images:       return "Images & Graphics"
        case .video:        return "Video Files"
        case .audio:        return "Audio & Music"
        case .code:         return "Source Code"
        case .archives:     return "Archives & Compressed"
        case .applications: return "Applications & Bundles"
        case .system:       return "System & Config"
        case .caches:       return "Cache & Temp Files"
        case .other:        return "Other Files"
        }
    }
}

/// Maps file extensions to categories.
public struct ExtensionColorMap: Sendable {
    /// Maps extension hash -> category.
    private var hashToCategory: [UInt32: FileCategory] = [:]
    /// Maps extension string -> category (for legend display).
    private var extensionToCategory: [String: FileCategory] = [:]

    public static let shared = ExtensionColorMap()

    private static let extensionMap: [FileCategory: [String]] = [
        .documents: [
            "pdf", "doc", "docx", "txt", "rtf", "odt", "pages", "tex",
            "xls", "xlsx", "csv", "ods", "numbers",
            "ppt", "pptx", "odp", "keynote",
            "epub", "mobi",
        ],
        .images: [
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "svg",
            "webp", "heic", "heif", "ico", "raw", "cr2", "nef", "arw",
            "psd", "ai", "sketch", "fig", "xcf",
        ],
        .video: [
            "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v",
            "mpg", "mpeg", "3gp", "ogv", "ts",
        ],
        .audio: [
            "mp3", "wav", "flac", "aac", "ogg", "wma", "m4a", "aiff",
            "alac", "opus", "mid", "midi",
        ],
        .code: [
            "swift", "m", "h", "c", "cpp", "cc", "cxx", "hpp",
            "py", "rb", "js", "ts", "jsx", "tsx", "vue", "svelte",
            "java", "kt", "kts", "scala", "go", "rs", "zig",
            "html", "css", "scss", "less", "sass",
            "json", "yaml", "yml", "toml", "xml", "plist",
            "sh", "bash", "zsh", "fish", "ps1",
            "sql", "graphql", "proto", "thrift",
            "md", "markdown", "rst",
            "r", "R", "jl", "lua", "php", "pl", "pm",
            "ex", "exs", "erl", "hrl", "clj", "cljs",
            "hs", "ml", "mli", "fs", "fsx",
            "dart", "v", "sv", "vhd", "vhdl",
        ],
        .archives: [
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "zst",
            "dmg", "iso", "pkg", "deb", "rpm", "jar", "war",
        ],
        .applications: [
            "app", "framework", "dylib", "so", "bundle", "kext",
            "wasm", "exe", "dll", "msi",
        ],
        .system: [
            "sys", "conf", "cfg", "ini", "log", "lock",
            "pem", "cer", "crt", "key", "p12",
            "entitlements", "provisionprofile",
        ],
        .caches: [
            "cache", "tmp", "temp", "swp", "swo",
            "o", "obj", "pyc", "pyo", "class",
            "dSYM",
        ],
    ]

    public init() {
        for (category, extensions) in Self.extensionMap {
            for ext in extensions {
                let hash = extensionHash(".\(ext)")
                hashToCategory[hash] = category
                extensionToCategory[ext.lowercased()] = category
            }
        }
    }

    public func category(forHash hash: UInt32) -> FileCategory {
        hashToCategory[hash] ?? .other
    }

    public func category(forExtension ext: String) -> FileCategory {
        extensionToCategory[ext.lowercased()] ?? .other
    }

    public func color(forHash hash: UInt32) -> SIMD4<Float> {
        category(forHash: hash).simdColor
    }

    /// Get all extensions grouped by category, sorted by category.
    public var extensionsByCategory: [(category: FileCategory, extensions: [String])] {
        Self.extensionMap.map { (category: $0.key, extensions: $0.value) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
    }
}

// MARK: - Extension Palette (WinDirStat-style)

/// A single entry in the extension palette (one per top extension + one "Other" aggregate).
public struct PaletteEntry: Identifiable, Sendable {
    public let id: UInt32          // extensionHash (UInt32.max for "Other")
    public let extensionName: String
    public let color: SIMD4<Float>
    public let totalSize: UInt64
    public let fileCount: Int

    public var swiftUIColor: Color {
        Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))
    }
}

/// WinDirStat-style per-extension color palette.
/// Ranks extensions by total disk size and assigns vivid, distinct colors to the top 17.
/// Everything else gets a neutral fallback gray.
public struct ExtensionPalette {
    /// Ordered entries for legend display (top 17 + optional "Other" row).
    public private(set) var entries: [PaletteEntry] = []

    /// Fast lookup: extension hash → palette color.
    private var hashToColor: [UInt32: SIMD4<Float>] = [:]

    /// Increments on each `assign()`, used for change detection.
    public private(set) var generation: UInt64 = 0

    /// Neutral fallback for extensions not in the top 17.
    public static let fallbackColor = SIMD4<Float>(0.55, 0.55, 0.55, 1.0)

    // MARK: - Oklab helpers

    private static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// sRGB → Oklab (L, a, b).
    private static func rgbToOklab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b)

        var l = pow(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb, 1.0 / 3.0)
        var m = pow(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb, 1.0 / 3.0)
        var s = pow(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb, 1.0 / 3.0)

        // Guard against NaN from pow(negative, 1/3) on degenerate inputs
        if l.isNaN { l = 0 }
        if m.isNaN { m = 0 }
        if s.isNaN { s = 0 }

        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.4072456682 * m - 0.4341497268 * s
        )
    }

    /// Oklab (L, a, b) → sRGB clamped to [0, 1].
    private static func oklabToRgb(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let r = linearToSrgb(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let b = linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.6956082739 * s)

        return SIMD3(max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
    }

    /// Adjust a pure-hue sRGB color to a target Oklab L (perceived brightness).
    private static func equalizeL(_ r: Float, _ g: Float, _ b: Float, targetL: Float) -> SIMD4<Float> {
        var lab = rgbToOklab(r, g, b)
        lab.x = targetL
        let rgb = oklabToRgb(lab)
        return SIMD4(rgb.x, rgb.y, rgb.z, 1)
    }

    /// 17 vivid WinDirStat hues equalized to Oklab L = 0.65 (perceptually uniform brightness).
    /// Simple HSB equalization makes blue appear much darker than yellow; Oklab corrects this.
    private static let palette: [SIMD4<Float>] = {
        let L: Float = 0.65
        return [
            equalizeL(0.00, 0.00, 1.00, targetL: L),  //  0 Blue
            equalizeL(1.00, 0.00, 0.00, targetL: L),  //  1 Red
            equalizeL(0.00, 1.00, 0.00, targetL: L),  //  2 Green
            equalizeL(1.00, 1.00, 0.00, targetL: L),  //  3 Yellow
            equalizeL(0.00, 1.00, 1.00, targetL: L),  //  4 Cyan
            equalizeL(1.00, 0.00, 1.00, targetL: L),  //  5 Magenta
            equalizeL(1.00, 0.67, 0.00, targetL: L),  //  6 Orange
            equalizeL(0.00, 0.33, 1.00, targetL: L),  //  7 Dodger Blue
            equalizeL(1.00, 0.00, 0.33, targetL: L),  //  8 Hot Pink
            equalizeL(0.33, 1.00, 0.00, targetL: L),  //  9 Lime Green
            equalizeL(0.67, 0.00, 1.00, targetL: L),  // 10 Violet
            equalizeL(0.00, 1.00, 0.33, targetL: L),  // 11 Spring Green
            equalizeL(1.00, 0.00, 0.67, targetL: L),  // 12 Deep Pink
            equalizeL(0.00, 0.67, 1.00, targetL: L),  // 13 Sky Blue
            equalizeL(1.00, 0.33, 0.00, targetL: L),  // 14 Orange Red
            equalizeL(0.00, 1.00, 0.67, targetL: L),  // 15 Aquamarine
            equalizeL(0.33, 0.00, 1.00, targetL: L),  // 16 Indigo
        ]
    }()

    public init() {}

    /// Assign palette colors to extensions ranked by total bytes descending.
    /// Top 17 get vivid palette colors; rest get fallback gray.
    public mutating func assign(from stats: [FileTypeStat]) {
        hashToColor.removeAll()
        entries.removeAll()
        generation &+= 1

        guard !stats.isEmpty else { return }

        let sorted = stats.sorted { $0.totalSize > $1.totalSize }
        var otherSize: UInt64 = 0
        var otherCount: Int = 0

        for (index, stat) in sorted.enumerated() {
            if index < Self.palette.count {
                let color = Self.palette[index]
                hashToColor[stat.extensionHash] = color
                entries.append(PaletteEntry(
                    id: stat.extensionHash,
                    extensionName: stat.extensionName,
                    color: color,
                    totalSize: stat.totalSize,
                    fileCount: stat.fileCount
                ))
            } else {
                hashToColor[stat.extensionHash] = Self.fallbackColor
                otherSize += stat.totalSize
                otherCount += stat.fileCount
            }
        }

        // Aggregate "Other" row for legend.
        if sorted.count > Self.palette.count {
            entries.append(PaletteEntry(
                id: UInt32.max,
                extensionName: "Other",
                color: Self.fallbackColor,
                totalSize: otherSize,
                fileCount: otherCount
            ))
        }
    }

    /// Get the palette color for an extension hash.
    public func color(forHash hash: UInt32) -> SIMD4<Float> {
        hashToColor[hash] ?? Self.fallbackColor
    }

    /// Get SwiftUI Color for an extension hash.
    public func swiftUIColor(forHash hash: UInt32) -> Color {
        let c = color(forHash: hash)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
