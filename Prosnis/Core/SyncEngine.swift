import Foundation

enum OutboxKind: String, Codable {
    case alarm, journalEntry, challenge, privacy, profile, wakeEvent, consent

    /// Доказательства для списаний и споров: при переполнении очереди не выбрасываются.
    var isEvidence: Bool { self == .wakeEvent || self == .consent }
}

/// Изменение, которое ждёт отправки на сервер.
struct OutboxItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: OutboxKind
    var entityID: UUID
    /// JSON сущности (даты в ISO 8601). Для удаления пустой.
    var payload: Data
    var deleted: Bool
    var createdAt: Date
    /// Связано с намазом: удаляется из очереди, если человек отзовёт согласие.
    var isSensitive: Bool?
}

/// Очередь отправки: изменения копятся на телефоне и уходят на сервер, когда он есть и доступен.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    nonisolated static let maxItems = 2000

    /// Кодировщик для всего, что уходит на сервер: даты в ISO 8601, как в server/openapi.yaml.
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @Published private(set) var items: [OutboxItem] = []
    @Published private(set) var lastSync: Date?

    private let file = FileStore<[OutboxItem]>("outbox")
    private var needsMerge = false
    private var isSyncing = false
    /// Во время отправки появилось новое: после неё отправить ещё раз.
    private var needsAnotherPass = false

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        items = result.value ?? []
        needsMerge = result.state == .unreadable
    }

    private func save() {
        if needsMerge {
            let result = file.loadWithState()
            switch result.state {
            case .loaded:
                var merged = result.value ?? []
                for item in items { merged = SyncEngine.merged(merged, adding: item) }
                items = merged
                needsMerge = false
            case .missing, .corrupt:
                needsMerge = false
            case .unreadable:
                return
            }
        }
        file.save(items)
    }

    /// Ставит изменение в очередь. Более старое изменение той же сущности заменяется.
    func enqueue<Value: Encodable>(_ kind: OutboxKind, id: UUID, value: Value, sensitive: Bool = false) {
        guard let data = try? SyncEngine.makeEncoder().encode(value) else { return }
        put(OutboxItem(kind: kind, entityID: id, payload: data, deleted: false, createdAt: Date(), isSensitive: sensitive ? true : nil))
    }

    func enqueueDeletion(_ kind: OutboxKind, id: UUID, sensitive: Bool = false) {
        put(OutboxItem(kind: kind, entityID: id, payload: Data(), deleted: true, createdAt: Date(), isSensitive: sensitive ? true : nil))
    }

    private func put(_ item: OutboxItem) {
        items = SyncEngine.merged(items, adding: item)
        save()
    }

    /// Удаляет из очереди всё, что связано с намазом (при отзыве согласия).
    func purgeSensitive() {
        items = SyncEngine.withoutSensitive(items)
        save()
    }

    nonisolated static func withoutSensitive(_ items: [OutboxItem]) -> [OutboxItem] {
        items.filter { $0.isSensitive != true }
    }

    /// Чистая функция объединения очереди: проверяется тестами.
    nonisolated static func merged(_ current: [OutboxItem], adding item: OutboxItem) -> [OutboxItem] {
        var result = current.filter { !($0.kind == item.kind && $0.entityID == item.entityID) }
        result.append(item)
        if result.count > maxItems {
            // Сначала выбрасываются старые обычные изменения; события утра и согласие — доказательства, их не теряем.
            var excess = result.count - maxItems
            var kept: [OutboxItem] = []
            for entry in result {
                if excess > 0 && !entry.kind.isEvidence {
                    excess -= 1
                    continue
                }
                kept.append(entry)
            }
            result = kept
        }
        return result
    }

    /// Что уйдёт в одной отправке: события утра первыми (для сервера решает время их получения).
    nonisolated static func batch(_ items: [OutboxItem], limit: Int = 200) -> [OutboxItem] {
        Array((items.filter { $0.kind == .wakeEvent } + items.filter { $0.kind != .wakeEvent }).prefix(limit))
    }

    /// Отправить очередь сейчас, если сервер подключён.
    func flushSoon() {
        let backend = BackendRegistry.current
        guard backend.isOnline, !backend.isDemo else { return }
        Task { await sync(using: backend) }
    }

    func sync(using backend: SyncBackend, attempt: Int = 0) async {
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        guard !items.isEmpty else { return }
        isSyncing = true
        let batch = SyncEngine.batch(items)
        let accepted = try? await backend.push(batch)
        if let accepted {
            let done = Set(accepted)
            items.removeAll { done.contains($0.id) }
            save()
            lastSync = Date()
        }
        isSyncing = false
        if accepted == nil {
            // Утром могла пропасть сеть на минуту: события утра пробуем отправить ещё несколько раз.
            guard attempt < 3, batch.contains(where: { $0.kind == .wakeEvent }) else { return }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await sync(using: backend, attempt: attempt + 1)
        } else if needsAnotherPass {
            needsAnotherPass = false
            await sync(using: backend)
        }
    }

    func clear() {
        items = []
        needsMerge = false
        file.delete()
    }
}
