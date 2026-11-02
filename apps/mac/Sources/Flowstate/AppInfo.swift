import Foundation

enum AppInfo {
    static let repoURL = URL(string: "https://github.com/rdewsnap/Flowstate")!
    static let releasesURL = URL(string: "https://github.com/rdewsnap/Flowstate/releases")!

    /// From Info.plist; a bare `swift run` binary has none.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
