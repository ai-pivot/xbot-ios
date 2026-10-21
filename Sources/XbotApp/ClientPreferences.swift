import Foundation

enum ClientPreferences {
    static func rememberActive(_ chat: ChatSession, server: URL) {
        let value = JSONValue.object(["chat_id": .string(chat.chatID), "channel": .string(chat.channel), "label": .string(chat.title)])
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "active:" + server.absoluteString)
    }
    static func active(server: URL) -> ChatSession? {
        guard let data = UserDefaults.standard.data(forKey: "active:" + server.absoluteString),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data), !value["chat_id"].string.isEmpty else { return nil }
        return ChatSession(value)
    }
    static func clearActive(server: URL) { UserDefaults.standard.removeObject(forKey: "active:" + server.absoluteString) }
}
