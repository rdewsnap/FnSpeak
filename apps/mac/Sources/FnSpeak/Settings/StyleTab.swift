import SwiftUI

/// How the cleanup model should write in each kind of app, and the apps
/// that get their own style.
struct StyleTab: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        KitForm {
            if prefs.mode != "local" && prefs.mode != "cloud" {
                KitSection {
                    HStack {
                        Label("Style needs a cleanup model. Yours is set to \(EngineSummary.modeLabel(prefs.mode)).", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cleanup…") { SettingsRouter.shared.tab = .cleanup }
                    }
                }
            }

            KitSection(title: "By kind of app") {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.label, selection: styleBinding(for: category)) {
                        ForEach(WritingStyle.allCases) { Text("\($0.label) — \($0.detail)").tag($0) }
                    }
                }
                Text("Apps outside these lists get a style picked from the app and the page you're on.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            KitSection(title: "For one app") {
                if prefs.styleOverrides.isEmpty {
                    Text("Apps without an override use their kind's style.").foregroundStyle(.secondary)
                }
                ForEach(prefs.styleOverrides.keys.sorted(), id: \.self) { bundleId in
                    HStack {
                        AppLabel(bundleId: bundleId)
                        Spacer()
                        KitPicker("", selection: overrideBinding(bundleId)) {
                            ForEach(WritingStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button { prefs.styleOverrides[bundleId] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                AddAppMenu(title: "Add app…", excluding: Set(prefs.styleOverrides.keys)) {
                    prefs.styleOverrides[$0] = (AppCategory.of($0)?.defaultStyle ?? .prose).rawValue
                }
            }
        }
    }

    private func styleBinding(for category: AppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { prefs.categoryStyle(category) },
            set: { prefs.setCategoryStyle($0, for: category) }
        )
    }

    private func overrideBinding(_ bundleId: String) -> Binding<WritingStyle> {
        Binding(
            get: { WritingStyle(rawValue: prefs.styleOverrides[bundleId] ?? "") ?? .prose },
            set: { prefs.styleOverrides[bundleId] = $0.rawValue }
        )
    }
}
