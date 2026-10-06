import Foundation

/// Настройки сборки. Когда появится сервер, достаточно указать его адрес здесь.
enum AppConfig {
    /// Адрес сервера, например URL(string: "https://api.example.ru"). Пока nil: приложение работает без сервера.
    static let serverURL: URL? = nil

    /// Сообщества регионов. Заполняется, когда будут созданы группы.
    static let regionCommunities: [CommunityLink] = []

    /// Сколько раз в сутки можно «разбудить» одного друга.
    static let nudgesPerFriendPerDay = 3

    /// Минимальный возраст для ставок и чатов.
    static let adultAge = 18
}
