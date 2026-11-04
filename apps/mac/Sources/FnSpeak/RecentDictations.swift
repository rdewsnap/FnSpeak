import Foundation

/// The last few dictations, for the menu. Kept in memory only, so quitting
/// the app clears them.
final class RecentDictations: ObservableObject {
    static let shared = RecentDictations()

    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let date: Date
    }

    static let limit = 5

    @Published private(set) var items: [Item] = []

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(Item(text: trimmed, date: Date()), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    func clear() {
        items.removeAll()
    }
}
