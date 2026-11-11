import Foundation

/// Asks GitHub what the newest release is. Only ever runs when the user
/// clicks the button; FnSpeak makes no network requests by itself.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case current
        case available(version: String, page: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private static let latest = URL(string: "https://api.github.com/repos/rdewsnap/FnSpeak/releases/latest")!

    func check() {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.latest, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.outcome(data: data, response: response, error: error)
            DispatchQueue.main.async { self.state = result }
        }.resume()
    }

    private static func outcome(data: Data?, response: URLResponse?, error: Error?) -> State {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("GitHub didn't answer.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: AppInfo.version) else { return .current }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesURL
        return .available(version: version, page: page)
    }

    /// Compares dotted versions number by number; a pre-release suffix is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.split(separator: "-").first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
