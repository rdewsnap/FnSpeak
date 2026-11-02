import SwiftUI

struct VocabularyTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    @State private var terms: [Term] = []
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a name or term", text: $newTerm).onSubmit(addTerm)
                Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(terms, id: \.text) { term in
                    HStack {
                        Text(term.text)
                        Spacer()
                        if term.source == "learned" {
                            Text("learned")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                                .help("Picked up from a word you fixed after dictating")
                        } else {
                            Text(term.source).foregroundStyle(.secondary).font(.caption)
                        }
                        Button {
                            engine.removeTerm(term.text)
                            terms.removeAll { $0.text == term.text }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Toggle("Learn from my corrections", isOn: $prefs.learnFromCorrections)
                .help("When you fix a dictated word, Flowstate reads back just that text, on this Mac, and remembers the spelling.")
        }
        .padding()
        .onAppear(perform: reloadTerms)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        engine.addTerms([term], source: .user, replacing: false)
        newTerm = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reloadTerms() }
    }

    private func reloadTerms() {
        engine.terms { terms = $0 }
    }
}
