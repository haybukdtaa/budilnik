import SwiftUI

/// Стрелки циферблата: углы по часам, от 12 часов по ходу стрелки.
enum DialAngles {
    static func hands(for date: Date, calendar: Calendar = .current) -> (hour: Double, minute: Double) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double((parts.hour ?? 0) % 12)
        let minute = Double(parts.minute ?? 0)
        return ((hour + minute / 60) * 30, minute * 6)
    }
}

/// «7 ч 40 мин» — сколько осталось до звонка.
enum DurationText {
    static func until(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded(.up)))
        let days = total / 1440
        let hours = (total % 1440) / 60
        let minutes = total % 60
        if days > 0 { return hours == 0 ? "\(days) д" : "\(days) д \(hours) ч" }
        if hours > 0 { return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин" }
        return "\(max(minutes, 1)) мин"
    }
}

/// Маленький циферблат с римскими цифрами из логотипа. Стрелки показывают время ближайшего звонка.
struct DialView: View {
    let time: Date?
    var size: CGFloat = 54

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2 - 1
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(Color(white: 0.2)), lineWidth: 1)
            for (label, dx, dy) in [("XII", 0.0, -0.7), ("III", 0.7, 0.0), ("VI", 0.0, 0.7), ("IX", -0.7, 0.0)] {
                let text = Text(label).font(.system(size: size * 0.13, design: .serif)).foregroundColor(Theme.numeral)
                context.draw(text, at: CGPoint(x: center.x + radius * dx, y: center.y + radius * dy))
            }
            guard let time else { return }
            let angles = DialAngles.hands(for: time)
            func hand(_ degrees: Double, _ length: Double, _ width: CGFloat) {
                let radians = (degrees - 90) * .pi / 180
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + radius * length * cos(radians), y: center.y + radius * length * sin(radians)))
                context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(angles.hour, 0.5, 2.2)
            hand(angles.minute, 0.78, 1.4)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(Theme.accent))
        }
        .frame(width: size, height: size)
    }
}

/// Блок «Сон» наверху будильников: циферблат, через сколько зазвонит, кнопка «Начать».
struct SleepRow: View {
    let next: Date?
    let now: Date
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            DialView(time: next)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ложусь спать").font(.app(.body))
                Text(subtitle)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button("Начать", action: onStart)
                .buttonStyle(.burgundy)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        guard let next else { return "Нет включённых будильников" }
        return "Зазвонит через \(DurationText.until(next.timeIntervalSince(now)))"
    }
}
