import SwiftUI

/// One model that can be downloaded: what it is, how big, and a button that
/// turns into a progress bar.
struct ModelDownloadRow: View {
    let item: ModelDownloader.Item
    /// Why this one is worth having, in a few words.
    var note: String?
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        // Reading `revision` re-checks the disk after a download lands.
        let present = downloader.revision >= 0 && item.isPresent
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: present ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(present ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(detail(present: present)).font(.callout).foregroundStyle(detailIsError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !present { control }
        }
    }

    private var detailIsError: Bool {
        if case .failed = downloader.state(item) { return true }
        return false
    }

    private func detail(present: Bool) -> String {
        if present { return "Installed" }
        switch downloader.state(item) {
        case .failed(let message): return "Download failed. \(message)"
        case .unpacking: return "Unpacking…"
        case .downloading(let fraction):
            return fraction.map { "Downloading, \(Int($0 * 100))% of \(item.size)" } ?? "Starting…"
        case .idle:
            return [note, "\(item.size) from \(item.source)"].compactMap { $0 }.joined(separator: " ")
        }
    }

    @ViewBuilder private var control: some View {
        switch downloader.state(item) {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction ?? 0).frame(width: 90)
                Button("Cancel") { downloader.cancel(item) }
            }
        case .unpacking:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Try Again") { downloader.download(item) }
        case .idle:
            Button("Download") { downloader.download(item) }
        }
    }
}
