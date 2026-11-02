import CryptoKit
import Foundation

/// Posts JSON to a URL of the user's choosing when notes and meetings change.
///
/// Body: `{"event": "note.created", "sent_at": "<ISO 8601>", "data": {…}}`.
/// With a secret set, `X-Flowstate-Signature: sha256=<hex>` is the
/// HMAC-SHA256 of the exact body bytes with the secret as key.
/// Fire-and-forget: two retries on network errors and 5xx, then give up.
enum Webhook {
    enum Event: String, CaseIterable {
        case noteCreated = "note.created"
        case noteUpdated = "note.updated"
        case meetingFinished = "meeting.finished"
    }

    static let retries = 2
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// The configured endpoint, if it's an http(s) URL.
    static var endpoint: URL? {
        let text = Preferences.shared.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    /// Send an event if a URL is set and the event is switched on.
    static func post(_ event: Event, data: [String: Any]) {
        guard Preferences.shared.webhookEnabled(event) else { return }
        send(event.rawValue, data: data, completion: nil)
    }

    /// Send any event name; completes on the main queue with the last HTTP
    /// status (nil when the request never got an answer).
    static func send(_ event: String, data: [String: Any], completion: ((Int?, Error?) -> Void)?) {
        guard let url = endpoint else {
            completion?(nil, URLError(.badURL))
            return
        }
        let envelope: [String: Any] = ["event": event, "sent_at": ISO8601DateFormatter().string(from: Date()), "data": data]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            completion?(nil, URLError(.cannotParseResponse))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event, forHTTPHeaderField: "X-Flowstate-Event")
        request.setValue("Flowstate/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let secret = Preferences.shared.webhookSecret, !secret.isEmpty {
            request.setValue("sha256=" + signature(body, secret: secret), forHTTPHeaderField: "X-Flowstate-Signature")
        }
        attempt(request, event: event, remaining: retries, completion: completion)
    }

    static func signature(_ body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func attempt(_ request: URLRequest, event: String, remaining: Int, completion: ((Int?, Error?) -> Void)?) {
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let retryable = error != nil || (status ?? 0) >= 500
            if retryable && remaining > 0 {
                // 2 s, then 8 s.
                let delay = pow(4.0, Double(retries - remaining)) * 2
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                    attempt(request, event: event, remaining: remaining - 1, completion: completion)
                }
                return
            }
            if let error {
                Log.error("Webhook \(event) failed: \(error.localizedDescription)")
            } else if let status, !(200..<300).contains(status) {
                Log.error("Webhook \(event) got HTTP \(status)")
            }
            DispatchQueue.main.async { completion?(status, error) }
        }.resume()
    }
}

// MARK: - Payloads

extension Note {
    var webhookData: [String: Any] {
        [
            "id": id,
            "title": title,
            "body_md": bodyMd,
            "tags": tags,
            "pinned": pinned,
            "source": source.label,
            "meeting_id": meetingId.map { $0 as Any } ?? NSNull(),
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]
    }
}

extension Meeting {
    var webhookData: [String: Any] {
        [
            "id": id,
            "title": title,
            "started_at": startedAt,
            "ended_at": endedAt.map { $0 as Any } ?? NSNull(),
            "participants": participants,
            "calendar_event_id": calendarEventId.map { $0 as Any } ?? NSNull(),
            "summary_md": summaryMd.map { $0 as Any } ?? NSNull(),
            "action_items": actionItems.map { item -> [String: Any] in
                [
                    "task": item.task,
                    "owner": item.owner.map { $0 as Any } ?? NSNull(),
                    "due": item.due.map { $0 as Any } ?? NSNull(),
                    "done": item.done,
                ]
            },
            "transcript_md": transcriptMd.map { $0 as Any } ?? NSNull(),
        ]
    }
}
