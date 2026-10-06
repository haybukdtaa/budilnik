import Foundation

/// Простой фильтр сообщений в чатах: скрывает грубые слова и ограничивает длину.
/// Основная модерация будет на сервере; здесь защита на стороне приложения.
enum ContentFilter {
    static let maxLength = 1000

    /// Корни слов, которые заменяются звёздочками.
    private static let roots = ["хуй", "хуе", "хуё", "пизд", "ебат", "ебан", "ёбан", "ебал", "бля", "сука", "суки", "мудак", "гандон", "шлюх"]

    static func clean(_ text: String) -> String {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        var words: [String] = []
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
            let lower = word.lowercased()
            if roots.contains(where: { lower.contains($0) }) {
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
