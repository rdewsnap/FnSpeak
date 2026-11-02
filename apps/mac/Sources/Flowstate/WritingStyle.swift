import Foundation

enum WritingStyle: String, CaseIterable, Identifiable {
    case casual, prose, code

    var id: String { rawValue }

    var label: String {
        switch self {
        case .casual: return "Casual"
        case .prose: return "Prose"
        case .code: return "Code"
        }
    }

    var detail: String {
        switch self {
        case .casual: return "Relaxed, contractions, light punctuation"
        case .prose: return "Full sentences and paragraphs"
        case .code: return "Identifiers and symbols kept exactly"
        }
    }
}

/// The kind of app text is going into, to pick a default writing style.
enum AppCategory: String, CaseIterable, Identifiable {
    case chat, documents, code

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat and messaging"
        case .documents: return "Email and documents"
        case .code: return "Code and terminals"
        }
    }

    var defaultStyle: WritingStyle {
        switch self {
        case .chat: return .casual
        case .documents: return .prose
        case .code: return .code
        }
    }

    private var bundleIds: [String] {
        switch self {
        case .chat:
            return ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
                    "ru.keepcoder.Telegram", "com.microsoft.teams2", "org.whispersystems.signal-desktop"]
        case .documents:
            return ["com.apple.mail", "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word",
                    "notion.id", "md.obsidian", "net.shinyfrog.bear", "com.readdle.smartemail-Mac"]
        case .code:
            return ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
                    "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
        }
    }

    static func of(_ bundleId: String) -> AppCategory? {
        if bundleId.hasPrefix("com.jetbrains.") { return .code }
        return allCases.first { $0.bundleIds.contains(bundleId) }
    }
}
