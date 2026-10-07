import Foundation

/// Настоящий сервер. Адрес задаётся в AppConfig.serverURL, формат обмена описан в server/openapi.yaml.
@MainActor
final class HTTPBackend: SocialBackend, SyncBackend {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var isOnline: Bool { true }
    var isDemo: Bool { false }

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = HTTPBackend.parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Дата не в ISO 8601: \(text)"))
        }
    }

    /// ISO 8601 с долями секунды и без них.
    nonisolated static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private struct Empty: Codable {}
    private struct CodeBody: Codable { var code: String }
    private struct TextBody: Codable { var text: String }
    private struct ReasonBody: Codable { var reason: String }
    private struct PairBody: Codable { var friendID: UUID; var title: String; var days: Int }
    private struct SyncResponse: Codable { var accepted: [UUID] }
    private struct TimeResponse: Codable { var now: Date }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body?, as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = AccountStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.serverUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.serverUnavailable }
        switch http.statusCode {
        case 200..<300:
            if Response.self == Empty.self || data.isEmpty, let empty = Empty() as? Response { return empty }
            return try decoder.decode(Response.self, from: data)
        case 401, 403: throw BackendError.forbidden
        case 404: throw BackendError.notFound
        case 409: throw BackendError.roomFull
        case 422: throw BackendError.invalidCode
        case 429: throw BackendError.rateLimited
        default: throw BackendError.server(http.statusCode)
        }
    }

    private func get<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
        try await send("GET", path, body: Optional<Empty>.none, as: type)
    }

    private func call<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        _ = try await send(method, path, body: body, as: Empty.self)
    }

    private func call(_ method: String, _ path: String) async throws {
        _ = try await send(method, path, body: Optional<Empty>.none, as: Empty.self)
    }

    func friends() async throws -> [Friend] { try await get("v1/friends", as: [Friend].self) }
    func createInvite() async throws -> Invite { try await send("POST", "v1/invites", body: Empty(), as: Invite.self) }
    func acceptInvite(code: String) async throws -> Friend {
        try await send("POST", "v1/invites/accept", body: CodeBody(code: code), as: Friend.self)
    }
    func removeFriend(_ id: UUID) async throws { try await call("DELETE", "v1/friends/\(id.uuidString)") }
    func setVisibility(_ visibility: Visibility, for friend: UUID) async throws {
        try await call("PUT", "v1/friends/\(friend.uuidString)/visibility", body: visibility)
    }
    func nudge(friend: UUID) async throws { try await call("POST", "v1/friends/\(friend.uuidString)/nudge", body: Empty()) }

    func rooms() async throws -> [Room] { try await get("v1/rooms", as: [Room].self) }
    func createRoom(_ draft: RoomDraft) async throws -> Room { try await send("POST", "v1/rooms", body: draft, as: Room.self) }
    func joinRoom(code: String) async throws -> Room {
        try await send("POST", "v1/rooms/join", body: CodeBody(code: code), as: Room.self)
    }
    func leaveRoom(_ id: UUID) async throws { try await call("POST", "v1/rooms/\(id.uuidString)/leave", body: Empty()) }

    func messages(in conversation: ConversationID) async throws -> [ChatMessage] {
        try await get("v1/conversations/\(conversation.kind.rawValue)/\(conversation.id.uuidString)/messages", as: [ChatMessage].self)
    }
    func send(_ text: String, to conversation: ConversationID) async throws -> ChatMessage {
        try await send(
            "POST", "v1/conversations/\(conversation.kind.rawValue)/\(conversation.id.uuidString)/messages",
            body: TextBody(text: text), as: ChatMessage.self
        )
    }
    func report(message: UUID, reason: String) async throws {
        try await call("POST", "v1/messages/\(message.uuidString)/report", body: ReasonBody(reason: reason))
    }
    func block(user: UUID) async throws { try await call("POST", "v1/users/\(user.uuidString)/block", body: Empty()) }

    func leaderboard(_ kind: LeaderboardKind) async throws -> Leaderboard {
        try await get("v1/leaderboards/\(kind.rawValue)", as: Leaderboard.self)
    }
    func globalStats() async throws -> GlobalStats { try await get("v1/stats/global", as: GlobalStats.self) }
    func publishStatus(_ status: PublicStatus) async throws { try await call("PUT", "v1/me/status", body: status) }
    func inviteRewards() async throws -> [InviteReward] { try await get("v1/me/rewards", as: [InviteReward].self) }
    func pairChallenges() async throws -> [PairChallenge] { try await get("v1/pair-challenges", as: [PairChallenge].self) }
    func createPairChallenge(with friend: UUID, title: String, days: Int) async throws -> PairChallenge {
        try await send("POST", "v1/pair-challenges", body: PairBody(friendID: friend, title: title, days: days), as: PairChallenge.self)
    }
    func deleteAccount() async throws { try await call("DELETE", "v1/me") }
    func notifyWitnesses(_ notice: MissedMorningNotice) async throws {
        try await call("POST", "v1/me/missed", body: notice)
    }
    func witnessNotices() async throws -> [WitnessNotice] {
        try await get("v1/witness-notices", as: [WitnessNotice].self)
    }

    func push(_ items: [OutboxItem]) async throws -> [UUID] {
        try await send("POST", "v1/sync", body: items, as: SyncResponse.self).accepted
    }
    func serverTime() async throws -> Date { try await get("v1/time", as: TimeResponse.self).now }
}
