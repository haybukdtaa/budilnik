import Foundation

/// Простой фильтр сообщений в чатах: скрывает грубые слова и ограничивает длину.
/// Основная модерация будет на сервере; здесь защита на стороне приложения.
enum ContentFilter {
    static let maxLength = 1000

    /// Длинные корни ищутся внутри слова.
    private static let roots = ["пизд", "ебат", "ебан", "ёбан", "ебал", "мудак", "гандон", "шлюх"]
    /// Короткие корни — только в начале слова или после приставки, иначе пострадают «рубля», «корабля», «употребляю».
    private static let shortRoots = ["хуй", "хуе", "хуё", "бля", "сука", "суки", "сучк"]
    private static let prefixes = ["", "на", "по", "за", "от", "вы", "до", "ни", "о", "об", "раз", "у"]

    static func isRude(_ word: String) -> Bool {
        let letters = word.lowercased().filter { $0.isLetter }
        if roots.contains(where: { letters.contains($0) }) { return true }
        return shortRoots.contains { root in prefixes.contains { letters.hasPrefix($0 + root) } }
    }

    static func clean(_ text: String) -> String {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        var words: [String] = []
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
            if isRude(String(word)) {
                words.append(String(repeating: "*", count: word.count))
            } else {
                words.append(String(word))
            }
        }
        return words.joined(separator: " ")
    }

    static func isSendable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
