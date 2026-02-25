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

    public var color: Color {
        switch self {
        case .documents:    return Color(red: 0.20, green: 0.40, blue: 0.85)
        case .images:       return Color(red: 0.85, green: 0.35, blue: 0.60)
        case .video:        return Color(red: 0.75, green: 0.25, blue: 0.25)
        case .audio:        return Color(red: 0.90, green: 0.55, blue: 0.20)
        case .code:         return Color(red: 0.30, green: 0.70, blue: 0.35)
        case .archives:     return Color(red: 0.55, green: 0.45, blue: 0.75)
        case .applications: return Color(red: 0.45, green: 0.75, blue: 0.85)
        case .system:       return Color(red: 0.60, green: 0.60, blue: 0.60)
        case .caches:       return Color(red: 0.75, green: 0.75, blue: 0.50)
        case .other:        return Color(red: 0.50, green: 0.50, blue: 0.50)
        }
    }

    /// SIMD4 color for Metal rendering.
    public var simdColor: SIMD4<Float> {
        switch self {
        case .documents:    return SIMD4(0.20, 0.40, 0.85, 1.0)
        case .images:       return SIMD4(0.85, 0.35, 0.60, 1.0)
        case .video:        return SIMD4(0.75, 0.25, 0.25, 1.0)
        case .audio:        return SIMD4(0.90, 0.55, 0.20, 1.0)
        case .code:         return SIMD4(0.30, 0.70, 0.35, 1.0)
        case .archives:     return SIMD4(0.55, 0.45, 0.75, 1.0)
        case .applications: return SIMD4(0.45, 0.75, 0.85, 1.0)
        case .system:       return SIMD4(0.60, 0.60, 0.60, 1.0)
        case .caches:       return SIMD4(0.75, 0.75, 0.50, 1.0)
        case .other:        return SIMD4(0.50, 0.50, 0.50, 1.0)
        }
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
    private var hashToCategory: [UInt16: FileCategory] = [:]
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

    public func category(forHash hash: UInt16) -> FileCategory {
        hashToCategory[hash] ?? .other
    }

    public func category(forExtension ext: String) -> FileCategory {
        extensionToCategory[ext.lowercased()] ?? .other
    }

    public func color(forHash hash: UInt16) -> SIMD4<Float> {
        category(forHash: hash).simdColor
    }

    /// Get all extensions grouped by category, sorted by category.
    public var extensionsByCategory: [(category: FileCategory, extensions: [String])] {
        Self.extensionMap.map { (category: $0.key, extensions: $0.value) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
    }
}
