import Foundation

enum OutboxKind: String, Codable {
    case alarm, journalEntry, challenge, privacy, profile
}

/// Изменение, которое ждёт отправки на сервер.
struct OutboxItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: OutboxKind
    var entityID: UUID
    /// JSON сущности. Для удаления пустой.
    var payload: Data
    var deleted: Bool
    var createdAt: Date
}

/// Очередь отправки: изменения копятся на телефоне и уходят на сервер, когда он есть и доступен.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    nonisolated static let maxItems = 2000

    @Published private(set) var items: [OutboxItem] = []
    @Published private(set) var lastSync: Date?

    private let file = FileStore<[OutboxItem]>("outbox", protection: .completeFileProtection)
    private var isSyncing = false

    private init() {
        items = file.load() ?? []
    }

    func reload() { items = file.load() ?? [] }

    /// Ставит изменение в очередь. Более старое изменение той же сущности заменяется.
    func enqueue<Value: Encodable>(_ kind: OutboxKind, id: UUID, value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        put(OutboxItem(kind: kind, entityID: id, payload: data, deleted: false, createdAt: Date()))
    }

    func enqueueDeletion(_ kind: OutboxKind, id: UUID) {
        put(OutboxItem(kind: kind, entityID: id, payload: Data(), deleted: true, createdAt: Date()))
    }

    private func put(_ item: OutboxItem) {
        items = SyncEngine.merged(items, adding: item)
        file.save(items)
    }

    /// Чистая функция объединения очереди: проверяется тестами.
    nonisolated static func merged(_ current: [OutboxItem], adding item: OutboxItem) -> [OutboxItem] {
        var result = current.filter { !($0.kind == item.kind && $0.entityID == item.entityID) }
        result.append(item)
        if result.count > maxItems {
            result.removeFirst(result.count - maxItems)
        }
        return result
    }

    func sync(using backend: SyncBackend) async {
        guard !isSyncing, !items.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        let batch = Array(items.prefix(200))
        guard let accepted = try? await backend.push(batch) else { return }
        let done = Set(accepted)
        items.removeAll { done.contains($0.id) }
        file.save(items)
        lastSync = Date()
    }

    func clear() {
        items = []
        file.delete()
    }
}
