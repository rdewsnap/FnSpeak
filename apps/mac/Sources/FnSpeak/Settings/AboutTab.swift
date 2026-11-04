import AppKit
import SwiftUI

struct AboutTab: View {
    private static let credits: [(name: String, license: String, url: String)] = [
        ("whisper.cpp", "MIT", "https://github.com/ggml-org/whisper.cpp"),
        ("sherpa-onnx", "Apache 2.0", "https://github.com/k2-fsa/sherpa-onnx"),
        ("llama.cpp", "MIT", "https://github.com/ggml-org/llama.cpp"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FnSpeak").font(.title2.bold())
                        Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                        Text("Dictation that stays on your Mac.").foregroundStyle(.secondary)
                    }
                }
                Link("FnSpeak on GitHub", destination: AppInfo.repoURL)
                Link("Release notes and downloads", destination: AppInfo.releasesURL)
            }

            Section("License") {
                Text("FnSpeak is free software under the GNU Affero General Public License, version 3 or later. © 2026 Ryan Dewsnap.")
            }

            Section("Built with") {
                ForEach(Self.credits, id: \.name) { credit in
                    LabeledContent {
                        Text(credit.license).foregroundStyle(.secondary)
                    } label: {
                        Link(credit.name, destination: URL(string: credit.url)!)
                    }
                }
                Text("Thanks to the authors and contributors of these projects.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
