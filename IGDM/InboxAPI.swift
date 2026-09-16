import Foundation

/// The inbox request that Instagram's own website makes, and a small parser for its answer.
/// Kept free of UI and system frameworks so it can be tested on its own.
enum InboxAPI {
    static let url = URL(string: "https://www.instagram.com/api/v1/direct_v2/inbox/?persistentBadging=true&folder=&limit=20&thread_message_limit=1")!
    static let webAppID = "936619743392459"   // the id Instagram's website sends with every request
    static let fallbackUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    struct Thread: Equatable {
        let id: String
        let title: String
        let preview: String
        let lastMessageTimestamp: Double   // seconds since 1970
        let lastMessageIsMine: Bool
        let isUnread: Bool
    }

    struct Snapshot: Equatable {
        let threads: [Thread]
        let unseenCount: Int
    }

    /// Builds the request with the web view's cookies, so Instagram sees the same browser session.
    static func request(cookies: [HTTPCookie], csrfToken: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webAppID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFToken")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("129477", forHTTPHeaderField: "X-ASBD-ID")
        request.setValue("0", forHTTPHeaderField: "X-IG-WWW-Claim")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.instagram.com/direct/inbox/", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        return request
    }

    static func parse(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbox = root["inbox"] as? [String: Any],
              let rawThreads = inbox["threads"] as? [[String: Any]]
        else { return nil }
        return Snapshot(threads: rawThreads.compactMap(parseThread),
                        unseenCount: intValue(inbox["unseen_count"]) ?? 0)
    }

    /// Threads with an unread message from someone else that has not been notified yet.
    static func newMessages(in snapshot: Snapshot, alreadyNotified: [String: Double]) -> [Thread] {
        snapshot.threads.filter { thread in
            thread.isUnread && !thread.lastMessageIsMine
                && thread.lastMessageTimestamp > (alreadyNotified[thread.id] ?? 0)
        }
    }

    /// True when Instagram's answer says the session is no longer valid.
    static func isLoginRequired(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if root["require_login"] as? Bool == true { return true }
        let message = (root["message"] as? String ?? "").lowercased()
        return message.contains("login_required") || message.contains("checkpoint_required")
    }

    /// A short, content-free description of an answer that could not be parsed (for the log).
    static func describeUnexpected(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return "JSON with keys \(json.keys.sorted().joined(separator: ", "))"
        }
        let head = String(decoding: data.prefix(100), as: UTF8.self)
        return "\(data.count) bytes starting \(head.replacingOccurrences(of: "\n", with: " "))"
    }

    // MARK: - Parsing helpers

    private static func parseThread(_ raw: [String: Any]) -> Thread? {
        guard let id = stringValue(raw["thread_id"]) else { return nil }
        let viewerID = intValue(raw["viewer_id"])
        let item = (raw["last_permanent_item"] as? [String: Any]) ?? (raw["items"] as? [[String: Any]])?.first
        let itemTimestamp = seconds(fromMicroseconds: item?["timestamp"])
        let senderID = intValue(item?["user_id"])

        // Unread when the last message is newer than the last one the viewer saw.
        var viewerSeen: Double?
        if let viewerID, let seenAt = raw["last_seen_at"] as? [String: Any],
           let entry = seenAt[String(viewerID)] as? [String: Any] {
            viewerSeen = seconds(fromMicroseconds: entry["timestamp"])
        }
        let isUnread: Bool
        if let viewerSeen, let itemTimestamp {
            isUnread = itemTimestamp > viewerSeen
        } else {
            isUnread = intValue(raw["read_state"]) == 1
        }

        let users = raw["users"] as? [[String: Any]] ?? []
        let title = stringValue(raw["thread_title"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? users.first.flatMap { stringValue($0["username"]) }
            ?? "Instagram"

        return Thread(id: id,
                      title: title,
                      preview: previewText(for: item, users: users, senderID: senderID),
                      lastMessageTimestamp: itemTimestamp ?? 0,
                      lastMessageIsMine: viewerID != nil && senderID == viewerID,
                      isUnread: isUnread)
    }

    private static func previewText(for item: [String: Any]?, users: [[String: Any]], senderID: Int?) -> String {
        guard let item else { return "New message" }
        let text: String
        switch stringValue(item["item_type"]) ?? "" {
        case "text": text = stringValue(item["text"]) ?? "New message"
        case "media":
            let mediaType = intValue((item["media"] as? [String: Any])?["media_type"])
            text = mediaType == 2 ? "Sent a video" : "Sent a photo"
        case "raven_media": text = "Sent a disappearing photo or video"
        case "media_share", "xma_media_share": text = "Shared a post"
        case "clip": text = "Shared a reel"
        case "story_share": text = "Shared a story"
        case "reel_share": text = "Replied to your story"
        case "voice_media": text = "Sent a voice message"
        case "animated_media": text = "Sent a GIF"
        case "like": text = "❤️"
        case "link": text = stringValue((item["link"] as? [String: Any])?["text"]) ?? "Sent a link"
        default: text = "New message"
        }
        // In a group chat, say who wrote it.
        if users.count > 1, let senderID,
           let sender = users.first(where: { intValue($0["pk"]) == senderID }),
           let name = stringValue(sender["username"]) {
            return "\(name): \(text)"
        }
        return text
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// Instagram sends microseconds, sometimes as a number and sometimes as a string.
    private static func seconds(fromMicroseconds value: Any?) -> Double? {
        var micro: Double?
        if let number = value as? NSNumber { micro = number.doubleValue }
        else if let string = value as? String { micro = Double(string) }
        guard let micro, micro > 0 else { return nil }
        return micro / 1_000_000
    }
}
