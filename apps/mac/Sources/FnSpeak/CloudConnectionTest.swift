import Foundation

/// Sends one tiny request to the configured cloud endpoint to check the key,
/// URL and model, and times it. Only the word "hi" is sent.
enum CloudConnectionTest {
    struct Outcome {
        let ok: Bool
        let message: String
    }

    static func run(provider: Preferences.CloudProviderChoice, customBaseURL: String, apiKey: String, model: String) async -> Outcome {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .custom && key.isEmpty { return Outcome(ok: false, message: "Add an API key first.") }
        if model.isEmpty { return Outcome(ok: false, message: "Enter a model name first.") }

        let url: URL
        var request: URLRequest
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .groq, .custom, .fnspeak:
            let base = provider == .groq ? "https://api.groq.com/openai/v1"
                : provider == .fnspeak ? Preferences.shared.serverAPIBase : customBaseURL
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let parsed = URL(string: trimmed + "/chat/completions"), parsed.scheme?.hasPrefix("http") == true, parsed.host != nil else {
                return Outcome(ok: false, message: "That isn't a valid URL.")
            }
            url = parsed
            request = URLRequest(url: url)
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return Outcome(ok: true, message: "Connected in \(ms) ms.") }
            return Outcome(ok: false, message: failure(status: status, data: data))
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return Outcome(ok: false, message: "No answer after 20 seconds.")
            case .notConnectedToInternet: return Outcome(ok: false, message: "You appear to be offline.")
            case .cannotFindHost, .cannotConnectToHost: return Outcome(ok: false, message: "Couldn't reach \(url.host ?? "the server").")
            default: return Outcome(ok: false, message: error.localizedDescription)
            }
        } catch {
            return Outcome(ok: false, message: error.localizedDescription)
        }
    }

    private static func failure(status: Int, data: Data) -> String {
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            detail = " " + (message.count > 120 ? String(message.prefix(117)) + "…" : message)
        }
        switch status {
        case 401, 403: return "The key was rejected (\(status))." + detail
        case 404: return "Not found (404): check the URL and model name." + detail
        case 429: return "Rate limited (429). The key works, but slow down." + detail
        default: return "The server answered \(status)." + detail
        }
    }
}
